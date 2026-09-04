//! `tj grep` - bounded literal search across a journal's commands and output.

const std = @import("std");
const Io = std.Io;
const zecli = @import("zecli");

const store = @import("../journal/store.zig");
const sys = @import("../sys.zig");
const pins = @import("../journal/pins.zig");
const search = @import("../journal/search.zig");
const report = @import("../presentation/report.zig");
const cmd_context = @import("context.zig");
const cmd_tui = @import("tui.zig");
const presentation = @import("../presentation/entry.zig");

pub fn grepRequestFromArgs(args: []const [:0]const u8) !GrepRequest {
    var parsed = try cmd_context.parseTestCommand(.grep, args);
    defer parsed.deinit(std.testing.allocator);
    return grepRequest(&parsed);
}

pub const ColorWhen = enum { never, auto, always };

pub const GrepRequest = struct {
    all: bool = false,
    tui: bool = false,
    commands: bool = true,
    output: bool = true,
    ignore_case: bool = false,
    color: ColorWhen = .never,
    pattern: []const u8 = "",
};

pub fn grepRequest(parsed: *const zecli.Parsed) !GrepRequest {
    var request: GrepRequest = .{
        .all = parsed.enabled("all"),
        .tui = parsed.enabled("tui"),
        .ignore_case = parsed.enabled("ignore-case"),
    };
    if (parsed.enabled("cmd") or parsed.enabled("out")) {
        request.commands = parsed.enabled("cmd");
        request.output = parsed.enabled("out");
    }
    if (parsed.last("color")) |value| {
        request.color = std.meta.stringToEnum(ColorWhen, value) orelse return error.BadArguments;
    }
    const positionals = parsed.positionals.items;
    const passthrough = if (parsed.has_passthrough) parsed.passthrough.items else null;
    request.pattern = if (passthrough) |literal| blk: {
        if (positionals.len != 0 or literal.len != 1) return error.BadArguments;
        break :blk literal[0];
    } else blk: {
        if (positionals.len != 1) return error.BadArguments;
        break :blk positionals[0];
    };
    if (request.pattern.len == 0 or std.mem.indexOfScalar(u8, request.pattern, '\n') != null) {
        return error.BadArguments;
    }
    return request;
}

pub fn colorEnabled(io: Io, when: ColorWhen) bool {
    return switch (when) {
        .never => false,
        .always => true,
        .auto => blk: {
            if (!sys.isTty(io, 1)) break :blk false;
            const term = sys.env("TERM") orelse break :blk false;
            break :blk term.len != 0 and !std.mem.eql(u8, term, "dumb");
        },
    };
}

/// TJ emits only selected lines, so GNU grep's `mt`/`ms` capabilities are the
/// relevant portion of GREP_COLORS. Later capabilities override earlier ones.
pub fn selectedMatchSgr(colors: ?[]const u8) []const u8 {
    const text = colors orelse return "33";
    var selected: []const u8 = "33";
    var parts = std.mem.splitScalar(u8, text, ':');
    while (parts.next()) |part| {
        if (!std.mem.startsWith(u8, part, "mt=") and !std.mem.startsWith(u8, part, "ms=")) continue;
        const candidate = part[3..];
        if (validSgr(candidate)) selected = candidate;
    }
    return selected;
}

pub fn validSgr(text: []const u8) bool {
    for (text) |byte| if (!std.ascii.isDigit(byte) and byte != ';') return false;
    return true;
}

pub const GrepOutput = struct {
    io: Io,
    out: *Io.Writer,
    noout_region: report.NooutRegion,
    match_sgr: []const u8,
    terminal_columns: ?usize,
    layout_color: bool,
    reference_width: usize,
};

pub const GrepWindow = struct {
    start: u64,
    end: u64,
    leading_ellipsis: bool = false,
    trailing_ellipsis: bool = false,
};

/// Selects a conservative byte window around a complete match. Raw bytes are
/// treated as cells, which can only under-fill the row for UTF-8, collapsed
/// whitespace, or terminal control sequences. The complete match has priority
/// when it alone is wider than the available content area.
pub fn grepWindow(
    line_start: u64,
    line_end: u64,
    match_start: u64,
    match_end: u64,
    budget: usize,
) GrepWindow {
    std.debug.assert(line_start <= match_start);
    std.debug.assert(match_start <= match_end);
    std.debug.assert(match_end <= line_end);

    const budget_u64: u64 = @intCast(budget);
    if (line_end - line_start <= budget_u64) return .{ .start = line_start, .end = line_end };

    const match_len_u64 = match_end - match_start;
    if (match_len_u64 > budget_u64) {
        return .{
            .start = match_start,
            .end = match_end,
            .leading_ellipsis = match_start > line_start,
            .trailing_ellipsis = match_end < line_end,
        };
    }

    const match_len: usize = @intCast(match_len_u64);
    const left_available: usize = @intCast(match_start - line_start);
    const right_available: usize = @intCast(line_end - match_end);
    var remaining = budget - match_len;
    var leading_ellipsis = false;
    var trailing_ellipsis = false;

    if (left_available != 0 and right_available != 0) {
        if (remaining >= 2) {
            leading_ellipsis = true;
            trailing_ellipsis = true;
            remaining -= 2;
        } else if (remaining == 1) {
            trailing_ellipsis = true;
            remaining = 0;
        }
    } else if (left_available != 0 and remaining != 0) {
        leading_ellipsis = true;
        remaining -= 1;
    } else if (right_available != 0 and remaining != 0) {
        trailing_ellipsis = true;
        remaining -= 1;
    }

    var left_take = @min(left_available, remaining / 2);
    var right_take = @min(right_available, remaining - left_take);
    var unused = remaining - left_take - right_take;
    const left_room = left_available - left_take;
    const extra_left = @min(left_room, unused);
    left_take += extra_left;
    unused -= extra_left;
    right_take += @min(right_available - right_take, unused);

    return .{
        .start = match_start - left_take,
        .end = match_end + right_take,
        .leading_ellipsis = leading_ellipsis and left_take < left_available,
        .trailing_ellipsis = trailing_ellipsis and right_take < right_available,
    };
}

pub const GrepLineSink = struct {
    output: *GrepOutput,
    journal: []const u8,
    number: u32,
    resource: []const u8,
    qualified: bool,
    matcher: *const search.Matcher,
    pinned: bool,
    exit_code: ?u8,

    pub fn emit(context: *anyopaque, file: Io.File, start: u64, end: u64) !void {
        const self: *GrepLineSink = @ptrCast(@alignCast(context));
        try self.output.noout_region.begin();
        const entry = presentation.EntryPresentation.init(
            self.journal,
            self.number,
            self.qualified,
            self.pinned,
            self.exit_code,
        );
        const flags = entry.flags();
        var reference_buf: [96]u8 = undefined;
        const reference_text = try entry.formatReference(&reference_buf);
        const prefix_width = 2 + 1 + self.output.reference_width + 1 + 1 + 1;
        try self.output.out.writeByte(flags[0]);
        if (entry.failed() and self.output.layout_color) try self.output.out.writeAll("\x1b[31m");
        try self.output.out.writeByte(flags[1]);
        if (entry.failed() and self.output.layout_color) try self.output.out.writeAll("\x1b[0m");
        try self.output.out.writeByte(' ');
        try self.output.out.splatByteAll(' ', self.output.reference_width - reference_text.len);
        if (self.output.layout_color) try self.output.out.writeAll("\x1b[33m");
        try self.output.out.writeAll(reference_text);
        if (self.output.layout_color) try self.output.out.writeAll("\x1b[0m");
        try self.output.out.writeByte(' ');
        if (self.output.layout_color) try self.output.out.writeAll("\x1b[2m");
        try self.output.out.writeByte(if (std.mem.eql(u8, self.resource, "cmd")) '>' else '<');
        if (self.output.layout_color) try self.output.out.writeAll("\x1b[0m");
        try self.output.out.writeByte(' ');

        if (self.output.terminal_columns) |columns| {
            const fixed_width = prefix_width + entry.metadataSuffixWidth();
            const budget = if (columns > fixed_width) columns - fixed_width else 0;
            try self.writePayload(file, start, end, self.output.out, budget, &entry);
        } else {
            try self.writePayload(file, start, end, self.output.out, null, &entry);
        }
        try self.output.out.writeAll("\n");
    }

    pub fn writePayload(
        self: *GrepLineSink,
        file: Io.File,
        start: u64,
        original_end: u64,
        writer: *Io.Writer,
        budget: ?usize,
        entry: *const presentation.EntryPresentation,
    ) !void {
        var end = original_end;
        if (end > start) {
            var last: [1]u8 = undefined;
            const n = try file.readPositional(self.output.io, &.{last[0..]}, end - 1);
            if (n == 1 and last[0] == '\r') end -= 1;
        }

        var window: GrepWindow = .{ .start = start, .end = end };
        if (budget) |width| {
            if (end - start > width) {
                const match = (try search.firstMatchSpan(self.output.io, file, start, end, self.matcher)) orelse
                    return error.UnexpectedEndOfFile;
                window = grepWindow(start, end, match.start, match.end, width);
            }
        }
        if (window.leading_ellipsis) try writer.writeAll("…");
        var normalized = report.SanitizingWriter.init(writer, true);
        try search.copyHighlightedSpan(
            self.output.io,
            file,
            window.start,
            window.end,
            self.matcher,
            self.output.match_sgr,
            writer,
            &normalized.interface,
        );
        try normalized.finish();

        if (window.trailing_ellipsis) try writer.writeAll("…");
        try self.writeMetadata(writer, entry);
    }

    pub fn writeMetadata(
        self: *const GrepLineSink,
        writer: *Io.Writer,
        entry: *const presentation.EntryPresentation,
    ) !void {
        var iterator = entry.metadata();
        while (iterator.next()) |part| {
            try writer.writeByte(' ');
            if (self.output.layout_color) try writer.writeAll("\x1b[31m");
            switch (part) {
                .failure => |code| try writer.print("!{d}", .{code}),
            }
            if (self.output.layout_color) try writer.writeAll("\x1b[0m");
        }
    }
};

test "grep windows retain the complete match and nearby context" {
    try std.testing.expectEqualDeep(
        GrepWindow{ .start = 5, .end = 13, .leading_ellipsis = true, .trailing_ellipsis = true },
        grepWindow(0, 20, 8, 10, 10),
    );
    try std.testing.expectEqualDeep(
        GrepWindow{ .start = 8, .end = 18, .leading_ellipsis = true, .trailing_ellipsis = true },
        grepWindow(0, 20, 8, 18, 5),
    );
    try std.testing.expectEqualDeep(
        GrepWindow{ .start = 0, .end = 5 },
        grepWindow(0, 5, 1, 3, 5),
    );
}

test "terminal grep emits one width-bounded row containing the match" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const text = "0123456789MATCHabcdefghij";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(io, "grep-window", .{ .read = true });
    defer file.close(io);
    try file.writePositionalAll(io, text, 0);

    var matcher = try search.Matcher.init(gpa, "MATCH", false);
    defer matcher.deinit();
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    var writer = Io.Writer.Allocating.fromArrayList(gpa, &bytes);
    defer bytes = writer.toArrayList();
    var output: GrepOutput = .{
        .io = io,
        .out = &writer.writer,
        .noout_region = .{ .out = &writer.writer, .enabled = false },
        .match_sgr = "",
        .terminal_columns = 20,
        .layout_color = false,
        .reference_width = 1,
    };
    var sink: GrepLineSink = .{
        .output = &output,
        .journal = "journal",
        .number = 1,
        .resource = "out",
        .qualified = false,
        .matcher = &matcher,
        .pinned = false,
        .exit_code = 0,
    };

    try GrepLineSink.emit(&sink, file, 0, text.len);
    try std.testing.expectEqualStrings("   1 < …789MATCHabc…\n", writer.writer.buffered());
}

test "grep display normalizes whitespace and strips terminal controls" {
    const gpa = std.testing.allocator;
    const input = " \talpha   beta\t \x1b[31mgamma\x1b[0m\rdelta " ++
        "\x1b]0;PWNED\x07tail\x01 \xf0\x9f\x98\x80 \x9b2J";
    for ([_]usize{ 1, 2, 3, 64 }) |chunk_size| {
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(gpa);
        var downstream = Io.Writer.Allocating.fromArrayList(gpa, &bytes);
        defer bytes = downstream.toArrayList();
        var normalized = report.SanitizingWriter.init(&downstream.writer, true);

        var offset: usize = 0;
        while (offset < input.len) {
            const end = @min(offset + chunk_size, input.len);
            try normalized.interface.writeAll(input[offset..end]);
            offset = end;
        }
        try normalized.finish();
        try std.testing.expectEqualStrings(
            "alpha beta gamma delta tail \xf0\x9f\x98\x80",
            downstream.writer.buffered(),
        );
    }
}

test "history display sanitization preserves ordinary spacing" {
    const gpa = std.testing.allocator;
    const sanitized = try report.sanitizeDisplayText(gpa, "echo\tbefore\x1b[2Jafter\rnext\x01");
    defer gpa.free(sanitized);
    try std.testing.expectEqualStrings("echo\tbeforeafter next", sanitized);
}

pub fn grepReferenceWidth(io: Io, root: store.Dir, journals: []const []const u8, qualified: bool) !usize {
    var width: usize = 1;
    for (journals) |journal| {
        const highest = try store.highestEntryNumber(io, root, journal) orelse continue;
        const number_width = report.decimalWidth(highest);
        const candidate = if (qualified)
            1 + journal.len + 1 + number_width
        else
            number_width;
        width = @max(width, candidate);
    }
    return width;
}

pub fn grepCommand(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    parsed: *const zecli.Parsed,
    out: *Io.Writer,
) !u8 {
    const request = try grepRequest(parsed);

    if (request.tui and (request.all or parsed.present("color"))) return error.BadArguments;

    const current = sys.env("TJ_JOURNAL");
    if (!request.all and (current == null or current.?.len == 0)) {
        if (request.tui) {
            cmd_context.note("tj grep --tui: no current journal\n", .{});
        } else {
            cmd_context.note("tj grep: no current journal; use --all\n", .{});
        }
        return 2;
    }

    var root = try store.openRoot(io, home);
    defer root.close(io);
    var matcher = try search.Matcher.init(gpa, request.pattern, request.ignore_case);
    defer matcher.deinit();
    const active = cmd_context.activeInteraction();

    if (request.tui) {
        var numbers: std.ArrayList(u32) = .empty;
        defer numbers.deinit(gpa);
        try collectMatchingEntries(gpa, io, root, current.?, request, active, &matcher, &numbers);
        if (numbers.items.len == 0) return 1;
        try cmd_tui.runFiltered(gpa, io, home, numbers.items);
        return 0;
    }

    const terminal_columns = if (sys.isTty(io, 1)) report.terminalColumns(io) else null;
    var output: GrepOutput = .{
        .io = io,
        .out = out,
        .noout_region = .{
            .out = out,
            .enabled = current != null and current.?.len != 0 and sys.isTty(io, 1),
        },
        .match_sgr = if (colorEnabled(io, request.color)) selectedMatchSgr(sys.env("GREP_COLORS")) else "",
        .terminal_columns = terminal_columns,
        .layout_color = report.layoutColorEnabled(io),
        .reference_width = 1,
    };
    defer output.noout_region.finish();
    var total: u64 = 0;

    if (request.all) {
        const journals = try store.listJournals(gpa, io, root);
        defer {
            for (journals) |journal| gpa.free(journal);
            gpa.free(journals);
        }
        output.reference_width = try grepReferenceWidth(io, root, journals, true);
        for (journals) |journal| {
            try grepJournal(gpa, io, root, journal, request, active, &matcher, &output, &total);
        }
    } else {
        output.reference_width = try grepReferenceWidth(io, root, &.{current.?}, false);
        try grepJournal(gpa, io, root, current.?, request, active, &matcher, &output, &total);
    }
    return if (total == 0) 1 else 0;
}

const MatchOnlySink = struct {
    fn emit(_: *anyopaque, _: Io.File, _: u64, _: u64) !void {}
};

const MatchingEntryVisitor = struct {
    gpa: std.mem.Allocator,
    numbers: *std.ArrayList(u32),
    sink_context: u8 = 0,

    fn beginResource(
        _: *MatchingEntryVisitor,
        _: []const u8,
        _: store.InteractionInfo,
        _: []const u8,
        _: *const search.Matcher,
    ) !void {}

    fn sink(self: *MatchingEntryVisitor) search.Sink {
        return .{ .context = &self.sink_context, .emit = MatchOnlySink.emit };
    }

    fn endResource(self: *MatchingEntryVisitor, number: u32, found: u64) !bool {
        if (found == 0) return false;
        try self.numbers.append(self.gpa, number);
        return true;
    }
};

const FormattedMatchVisitor = struct {
    output: *GrepOutput,
    io: Io,
    root: store.Dir,
    qualified: bool,
    total: *u64,
    line_sink: GrepLineSink = undefined,

    fn beginResource(
        self: *FormattedMatchVisitor,
        journal: []const u8,
        info: store.InteractionInfo,
        resource: []const u8,
        matcher: *const search.Matcher,
    ) !void {
        self.line_sink = .{
            .output = self.output,
            .journal = journal,
            .number = info.number,
            .resource = resource,
            .qualified = self.qualified,
            .matcher = matcher,
            .pinned = try pins.isPinned(self.io, self.root, journal, info.number),
            .exit_code = info.exit_code,
        };
    }

    fn sink(self: *FormattedMatchVisitor) search.Sink {
        return .{ .context = &self.line_sink, .emit = GrepLineSink.emit };
    }

    fn endResource(self: *FormattedMatchVisitor, _: u32, found: u64) !bool {
        self.total.* = try std.math.add(u64, self.total.*, found);
        return false;
    }
};

fn traverseGrepJournal(
    gpa: std.mem.Allocator,
    io: Io,
    root: store.Dir,
    journal: []const u8,
    request: GrepRequest,
    active: ?cmd_context.ActiveInteraction,
    matcher: *const search.Matcher,
    visitor: anytype,
) !void {
    // Matching reads resource files directly; recorded command text never
    // needs to be resident merely to traverse a journal.
    var interactions = store.iterateInteractions(gpa, io, root, journal, store.no_command) catch |err| switch (err) {
        error.FileNotFound => return error.NoSuchJournal,
        else => |other| return other,
    };
    defer interactions.deinit();

    while (try interactions.next()) |info| {
        defer info.deinit(gpa);
        if (active) |item| {
            if (item.number == info.number and std.mem.eql(u8, item.journal, journal)) continue;
        }
        for ([_]struct { enabled: bool, name: []const u8 }{
            .{ .enabled = request.commands, .name = "cmd" },
            .{ .enabled = request.output, .name = "out" },
        }) |resource| {
            if (!resource.enabled) continue;
            var path_buf: [96]u8 = undefined;
            const path = try std.fmt.bufPrint(&path_buf, "{s}/{d}/{s}", .{ journal, info.number, resource.name });
            var file = root.openFile(io, path, .{}) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => |other| return other,
            };
            defer file.close(io);

            try visitor.beginResource(journal, info, resource.name, matcher);
            const found = try search.scanFile(io, file, matcher, visitor.sink());
            if (try visitor.endResource(info.number, found)) break;
        }
    }
}

fn collectMatchingEntries(
    gpa: std.mem.Allocator,
    io: Io,
    root: store.Dir,
    journal: []const u8,
    request: GrepRequest,
    active: ?cmd_context.ActiveInteraction,
    matcher: *const search.Matcher,
    numbers: *std.ArrayList(u32),
) !void {
    var visitor: MatchingEntryVisitor = .{
        .gpa = gpa,
        .numbers = numbers,
    };
    try traverseGrepJournal(gpa, io, root, journal, request, active, matcher, &visitor);
}

pub fn grepJournal(
    gpa: std.mem.Allocator,
    io: Io,
    root: store.Dir,
    journal: []const u8,
    request: GrepRequest,
    active: ?cmd_context.ActiveInteraction,
    matcher: *const search.Matcher,
    output: *GrepOutput,
    total: *u64,
) !void {
    var visitor: FormattedMatchVisitor = .{
        .output = output,
        .io = io,
        .root = root,
        .qualified = request.all,
        .total = total,
    };
    try traverseGrepJournal(gpa, io, root, journal, request, active, matcher, &visitor);
}

test "grep arguments select resources and preserve literal syntax" {
    const defaults = try grepRequestFromArgs(&.{"needle"});
    try std.testing.expect(defaults.commands and defaults.output);

    const selected = try grepRequestFromArgs(&.{ "--out", "--out", "--cmd", "-i", "[x].*" });
    try std.testing.expect(selected.commands and selected.output and selected.ignore_case);
    try std.testing.expectEqualStrings("[x].*", selected.pattern);

    const leading = try grepRequestFromArgs(&.{ "--", "-needle" });
    try std.testing.expectEqualStrings("-needle", leading.pattern);

    try std.testing.expectEqual(ColorWhen.never, (try grepRequestFromArgs(&.{"x"})).color);
    try std.testing.expect((try grepRequestFromArgs(&.{ "--tui", "x" })).tui);
    const automatic = try grepRequestFromArgs(&.{ "--color", "auto", "x" });
    try std.testing.expectEqual(ColorWhen.auto, automatic.color);
    try std.testing.expectEqualStrings("x", automatic.pattern);
    try std.testing.expectEqual(ColorWhen.always, (try grepRequestFromArgs(&.{ "--color", "always", "x" })).color);
    try std.testing.expectEqual(ColorWhen.always, (try grepRequestFromArgs(&.{ "--colour=always", "x" })).color);
    try std.testing.expectEqual(ColorWhen.never, (try grepRequestFromArgs(&.{ "--color=never", "x" })).color);
}

test "grep rejects missing multiline extra and unknown patterns" {
    try std.testing.expectError(error.BadArguments, grepRequestFromArgs(&.{}));
    try std.testing.expectError(error.BadArguments, grepRequestFromArgs(&.{""}));
    try std.testing.expectError(error.BadArguments, grepRequestFromArgs(&.{"a\nb"}));
    try std.testing.expectError(error.ReportedCliError, grepRequestFromArgs(&.{ "a", "b" }));
    try std.testing.expectError(error.BadArguments, grepRequestFromArgs(&.{ "--", "a", "b" }));
    try std.testing.expectError(error.BadArguments, grepRequestFromArgs(&.{ "a", "--", "b" }));
    try std.testing.expectError(error.ReportedCliError, grepRequestFromArgs(&.{ "--wat", "a" }));
    try std.testing.expectError(error.ReportedCliError, grepRequestFromArgs(&.{"--color"}));
    try std.testing.expectError(error.ReportedCliError, grepRequestFromArgs(&.{ "--color", "a" }));
    try std.testing.expectError(error.ReportedCliError, grepRequestFromArgs(&.{ "--color", "sometimes", "a" }));
    try std.testing.expectError(error.ReportedCliError, grepRequestFromArgs(&.{ "--color=sometimes", "a" }));
}

test "GNU grep selected-match colors use mt and ms capabilities" {
    try std.testing.expectEqualStrings("33", selectedMatchSgr(null));
    try std.testing.expectEqualStrings("4;32", selectedMatchSgr("fn=35:mt=1;31:ms=4;32"));
    try std.testing.expectEqualStrings("", selectedMatchSgr("mt="));
    try std.testing.expectEqualStrings("33", selectedMatchSgr("mt=not-sgr"));
}
