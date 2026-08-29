//! The subcommands that read the journal.

const std = @import("std");
const Io = std.Io;
const zecli = @import("zecli");

const cli = @import("cli.zig");
const proxy = @import("proxy.zig");
const store = @import("store.zig");
const sys = @import("sys.zig");
const reference = @import("reference.zig");
const plain = @import("plain.zig");
const annotations = @import("annotations.zig");
const search = @import("search.zig");
const noout = @import("noout.zig");
const replay_engine = @import("replay.zig");

pub const Error = error{
    NotInJournal,
    NoSuchJournal,
    NothingRecorded,
    MissingArgument,
    BadReference,
    NoSuchInteraction,
    NoSuchResource,
    BadCount,
    BadReplayOption,
    InsideJournal,
    CrossJournalMutation,
    InvalidName,
    InvalidTag,
    NameTaken,
    InvalidAnnotations,
    UnsupportedRemoval,
    InvalidRange,
    CurrentInteraction,
    ActiveJournal,
    AmbiguousJournal,
    ConfirmationRequired,
    Cancelled,
    BadArguments,
    InvalidMetadata,
    InsideJournalRemoval,
};

pub fn run(
    gpa: std.mem.Allocator,
    io: Io,
    command: cli.RoutedCommand,
    child: []const [:0]const u8,
    parsed: *const zecli.Parsed,
    out: *Io.Writer,
) !u8 {
    const home = command.root.home;
    switch (command.which) {
        .new => {
            const result = try proxy.run(gpa, io, .{
                .journal = .new,
                .argv = child,
                .keep_osc = command.root.keep_osc or parsed.present("keep-osc"),
                .home = parsed.last("home") orelse home,
            });
            return result.exit_code;
        },
        .@"continue" => {
            const result = try proxy.run(gpa, io, .{
                .journal = .{ .existing = parsed.positionals.items[0] },
                .argv = child,
                .keep_osc = command.root.keep_osc or parsed.present("keep-osc"),
                .replay_before_start = !parsed.present("no-replay"),
                .home = parsed.last("home") orelse home,
            });
            return result.exit_code;
        },
        .noout => {
            const result = try noout.run(gpa, child);
            return result.exit_code;
        },
        .current => try out.print("{s}\n", .{try currentJournal()}),
        .journal => try journalCommand(gpa, io, home, parsed, out),
        .hist => try listInteractions(gpa, io, home, parsed, out),
        .last => try printLast(gpa, io, home, out),
        .resolve => try resolveReference(gpa, io, home, parsed, out),
        .complete => try completeReference(gpa, io, home, parsed, out),
        .cat => try catResource(gpa, io, home, parsed, out),
        .replay => try replayJournal(gpa, io, home, parsed, out),
        .name => try nameCommand(gpa, io, home, parsed, out),
        .tag => try tagCommand(gpa, io, home, parsed, out),
        .pin => try pinCommand(gpa, io, home, parsed, out),
        .rm => try removeCommand(gpa, io, home, parsed, out),
        .grep => return grepCommand(gpa, io, home, parsed, out),
    }
    return 0;
}

fn parseTestCommand(which: cli.CommandName, args: []const [:0]const u8) !zecli.Parsed {
    var discard_buf: [1024]u8 = undefined;
    var discarding = Io.Writer.Discarding.init(&discard_buf);
    return zecli.parseCommand(std.testing.allocator, &discarding.writer, args, which.spec());
}

fn grepRequestFromArgs(args: []const [:0]const u8) !GrepRequest {
    var parsed = try parseTestCommand(.grep, args);
    defer parsed.deinit(std.testing.allocator);
    return grepRequest(&parsed);
}

fn currentJournal() Error![]const u8 {
    return sys.env("TJ_JOURNAL") orelse error.NotInJournal;
}

const ColorWhen = enum { never, auto, always };

const GrepRequest = struct {
    all: bool = false,
    commands: bool = true,
    output: bool = true,
    ignore_case: bool = false,
    color: ColorWhen = .never,
    pattern: []const u8 = "",
};

fn grepRequest(parsed: *const zecli.Parsed) !GrepRequest {
    var request: GrepRequest = .{
        .all = parsed.present("all"),
        .ignore_case = parsed.present("ignore-case"),
    };
    if (parsed.present("cmd") or parsed.present("out")) {
        request.commands = parsed.present("cmd");
        request.output = parsed.present("out");
    }
    if (parsed.last("color")) |value| {
        request.color = std.meta.stringToEnum(ColorWhen, value) orelse return error.BadArguments;
    }
    request.pattern = parsed.positionals.items[0];
    if (request.pattern.len == 0 or std.mem.indexOfScalar(u8, request.pattern, '\n') != null) {
        return error.BadArguments;
    }
    return request;
}

const ActiveInteraction = struct {
    journal: []const u8,
    number: u32,
};

fn activeInteraction() ?ActiveInteraction {
    const journal = sys.env("TJ_JOURNAL") orelse return null;
    if (journal.len == 0) return null;
    const next_text = sys.env("TJ_NEXT") orelse return null;
    const next = std.fmt.parseInt(u32, next_text, 10) catch return null;
    if (next <= 1) return null;
    return .{ .journal = journal, .number = next - 1 };
}

fn colorEnabled(when: ColorWhen) bool {
    return switch (when) {
        .never => false,
        .always => true,
        .auto => blk: {
            if (!sys.isTty(1)) break :blk false;
            const term = sys.env("TERM") orelse break :blk false;
            break :blk term.len != 0 and !std.mem.eql(u8, term, "dumb");
        },
    };
}

/// TJ emits only selected lines, so GNU grep's `mt`/`ms` capabilities are the
/// relevant portion of GREP_COLORS. Later capabilities override earlier ones.
fn selectedMatchSgr(colors: ?[]const u8) []const u8 {
    const text = colors orelse return "01;31";
    var selected: []const u8 = "01;31";
    var parts = std.mem.splitScalar(u8, text, ':');
    while (parts.next()) |part| {
        if (!std.mem.startsWith(u8, part, "mt=") and !std.mem.startsWith(u8, part, "ms=")) continue;
        const candidate = part[3..];
        if (validSgr(candidate)) selected = candidate;
    }
    return selected;
}

fn validSgr(text: []const u8) bool {
    for (text) |byte| if (!std.ascii.isDigit(byte) and byte != ';') return false;
    return true;
}

const NooutRegion = struct {
    out: *Io.Writer,
    enabled: bool,
    started: bool = false,

    fn begin(self: *NooutRegion) !void {
        if (self.enabled and !self.started) {
            try self.out.writeAll(noout.begin_marker);
            self.started = true;
        }
    }

    fn finish(self: *NooutRegion) void {
        if (self.started) self.out.writeAll(noout.end_marker) catch {};
        self.started = false;
    }
};

const GrepOutput = struct {
    io: Io,
    out: *Io.Writer,
    noout_region: NooutRegion,
    match_sgr: []const u8,
    terminal_columns: ?usize,
    layout_color: bool,
    reference_width: usize,
};

/// Adds hard terminal-width boundaries while forwarding source bytes and ANSI
/// sequences unchanged. It deliberately buffers nothing: grep retains its
/// fixed-memory behavior even for a very long matching source line.
const GrepWrapWriter = struct {
    downstream: *Io.Writer,
    interface: Io.Writer,
    columns: usize,
    prefix_width: usize,
    column: usize,
    escape: enum { normal, esc, csi, string, string_esc } = .normal,

    fn init(downstream: *Io.Writer, columns: usize, prefix_width: usize) GrepWrapWriter {
        return .{
            .downstream = downstream,
            .interface = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },
            .columns = columns,
            .prefix_width = prefix_width,
            .column = prefix_width,
        };
    }

    fn drain(writer: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const self: *GrepWrapWriter = @alignCast(@fieldParentPtr("interface", writer));
        for (data[0 .. data.len - 1]) |bytes| try self.writeBytes(bytes);
        const pattern = data[data.len - 1];
        for (0..splat) |_| try self.writeBytes(pattern);
        writer.end = 0;
        return Io.Writer.countSplat(data, splat);
    }

    fn writeBytes(self: *GrepWrapWriter, bytes: []const u8) Io.Writer.Error!void {
        for (bytes) |byte| try self.writeByte(byte);
    }

    fn writeByte(self: *GrepWrapWriter, byte: u8) Io.Writer.Error!void {
        switch (self.escape) {
            .normal => {
                if (byte == 0x1b) {
                    self.escape = .esc;
                    return self.downstream.writeByte(byte);
                }
                var width: usize = 0;
                if (byte == '\t') {
                    width = 8 - (self.column % 8);
                } else if (byte >= 0x20 and byte != 0x7f and (byte & 0xc0) != 0x80) {
                    // Match history's UTF-8 policy: one cell per scalar. Wide
                    // glyphs remain the terminal's decision.
                    width = 1;
                } else if (byte == 0x08 and self.column > self.prefix_width) {
                    self.column -= 1;
                }
                if (width != 0 and self.columns > self.prefix_width and self.column + width > self.columns) {
                    try self.downstream.writeByte('\n');
                    try self.downstream.splatByteAll(' ', self.prefix_width);
                    self.column = self.prefix_width;
                    if (byte == '\t') width = 8 - (self.column % 8);
                }
                try self.downstream.writeByte(byte);
                self.column += width;
            },
            .esc => {
                try self.downstream.writeByte(byte);
                self.escape = switch (byte) {
                    '[' => .csi,
                    ']', 'P', '^', '_' => .string,
                    else => .normal,
                };
            },
            .csi => {
                try self.downstream.writeByte(byte);
                if (byte >= 0x40 and byte <= 0x7e) self.escape = .normal;
            },
            .string => {
                try self.downstream.writeByte(byte);
                if (byte == 0x07) {
                    self.escape = .normal;
                } else if (byte == 0x1b) {
                    self.escape = .string_esc;
                }
            },
            .string_esc => {
                try self.downstream.writeByte(byte);
                self.escape = if (byte == '\\') .normal else if (byte == 0x1b) .string_esc else .string;
            },
        }
    }
};

/// Grep is a discovery view rather than a byte-for-byte resource renderer.
/// Normalize horizontal whitespace without buffering a source line: leading
/// and trailing runs disappear, and an internal run is emitted lazily as one
/// space when the next visible byte arrives. Terminal control sequences pass
/// through and do not count as content.
const GrepNormalizeWriter = struct {
    downstream: *Io.Writer,
    interface: Io.Writer,
    seen_content: bool = false,
    pending_space: bool = false,
    escape: enum { normal, esc, csi, string, string_esc } = .normal,

    fn init(downstream: *Io.Writer) GrepNormalizeWriter {
        return .{
            .downstream = downstream,
            .interface = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },
        };
    }

    fn finish(self: *GrepNormalizeWriter) void {
        self.pending_space = false;
    }

    fn drain(writer: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const self: *GrepNormalizeWriter = @alignCast(@fieldParentPtr("interface", writer));
        for (data[0 .. data.len - 1]) |bytes| try self.writeBytes(bytes);
        const pattern = data[data.len - 1];
        for (0..splat) |_| try self.writeBytes(pattern);
        writer.end = 0;
        return Io.Writer.countSplat(data, splat);
    }

    fn writeBytes(self: *GrepNormalizeWriter, bytes: []const u8) Io.Writer.Error!void {
        for (bytes) |byte| try self.writeByte(byte);
    }

    fn writeByte(self: *GrepNormalizeWriter, byte: u8) Io.Writer.Error!void {
        switch (self.escape) {
            .normal => {
                if (byte == 0x1b) {
                    self.escape = .esc;
                    return self.downstream.writeByte(byte);
                }
                if (byte == ' ' or byte == '\t') {
                    if (self.seen_content) self.pending_space = true;
                    return;
                }
                if (byte >= 0x20 and byte != 0x7f) {
                    if (self.pending_space) try self.downstream.writeByte(' ');
                    self.pending_space = false;
                    self.seen_content = true;
                }
                try self.downstream.writeByte(byte);
            },
            .esc => {
                try self.downstream.writeByte(byte);
                self.escape = switch (byte) {
                    '[' => .csi,
                    ']', 'P', '^', '_' => .string,
                    else => .normal,
                };
            },
            .csi => {
                try self.downstream.writeByte(byte);
                if (byte >= 0x40 and byte <= 0x7e) self.escape = .normal;
            },
            .string => {
                try self.downstream.writeByte(byte);
                if (byte == 0x07) {
                    self.escape = .normal;
                } else if (byte == 0x1b) {
                    self.escape = .string_esc;
                }
            },
            .string_esc => {
                try self.downstream.writeByte(byte);
                self.escape = if (byte == '\\') .normal else if (byte == 0x1b) .string_esc else .string;
            },
        }
    }
};

const GrepLineSink = struct {
    output: *GrepOutput,
    journal: []const u8,
    number: u32,
    resource: []const u8,
    qualified: bool,
    matcher: *const search.Matcher,
    annotation: ?*const annotations.Entry,
    exit_code: ?u8,

    fn emit(context: *anyopaque, file: Io.File, start: u64, end: u64) !void {
        const self: *GrepLineSink = @ptrCast(@alignCast(context));
        try self.output.noout_region.begin();

        var reference_buf: [64]u8 = undefined;
        const reference_text = if (self.qualified) blk: {
            const suffix = journalDisplaySuffix(self.journal);
            break :blk try std.fmt.bufPrint(&reference_buf, "@{s}.{d}", .{ suffix, self.number });
        } else try std.fmt.bufPrint(&reference_buf, "{d}", .{self.number});
        const prefix_width = 1 + 1 + self.output.reference_width + 2;
        try self.output.out.writeByte(if (self.annotation != null and self.annotation.?.pinned) '*' else ' ');
        try self.output.out.writeByte(' ');
        try self.output.out.splatByteAll(' ', self.output.reference_width - reference_text.len);
        try self.output.out.writeAll(reference_text);
        try self.output.out.writeAll("  ");

        if (self.output.terminal_columns) |columns| {
            var wrapped = GrepWrapWriter.init(self.output.out, columns, prefix_width);
            try self.writePayload(file, start, end, &wrapped.interface);
        } else {
            try self.writePayload(file, start, end, self.output.out);
        }
        try self.output.out.writeAll("\n");
    }

    fn writePayload(self: *GrepLineSink, file: Io.File, start: u64, original_end: u64, writer: *Io.Writer) !void {
        if (self.output.layout_color) try writer.writeAll("\x1b[2m");
        try writer.print("[{s}]", .{self.resource});
        if (self.output.layout_color) try writer.writeAll("\x1b[0m");
        try writer.writeByte(' ');

        var end = original_end;
        if (end > start) {
            var last: [1]u8 = undefined;
            const n = try file.readPositional(self.output.io, &.{last[0..]}, end - 1);
            if (n == 1 and last[0] == '\r') end -= 1;
        }
        var normalized = GrepNormalizeWriter.init(writer);
        try search.copyHighlightedSpan(
            self.output.io,
            file,
            start,
            end,
            self.matcher,
            self.output.match_sgr,
            &normalized.interface,
        );
        normalized.finish();

        const has_name = self.annotation != null and self.annotation.?.name != null;
        const has_tags = self.annotation != null and self.annotation.?.tags.items.len != 0;
        const has_failure = self.exit_code != null and self.exit_code.? != 0;
        if (!has_name and !has_tags and !has_failure) return;
        try writer.writeByte(' ');

        if (has_name or has_tags) {
            if (self.output.layout_color) try writer.writeAll("\x1b[2m");
            if (has_name) try writer.print("@{s}", .{self.annotation.?.name.?});
            if (has_tags) {
                if (has_name) try writer.writeByte(' ');
                try writer.writeByte('[');
                for (self.annotation.?.tags.items, 0..) |tag, i| {
                    if (i != 0) try writer.writeByte(' ');
                    try writer.writeAll(tag);
                }
                try writer.writeByte(']');
            }
            if (self.output.layout_color) try writer.writeAll("\x1b[0m");
        }
        if (has_failure) {
            if (has_name or has_tags) try writer.writeByte(' ');
            if (self.output.layout_color) try writer.writeAll("\x1b[31m");
            try writer.print("[rc={d}]", .{self.exit_code.?});
            if (self.output.layout_color) try writer.writeAll("\x1b[0m");
        }
    }
};

test "grep wrapping ignores styling and aligns continuation rows" {
    const gpa = std.testing.allocator;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    var downstream = Io.Writer.Allocating.fromArrayList(gpa, &bytes);
    defer bytes = downstream.toArrayList();
    var wrapped = GrepWrapWriter.init(&downstream.writer, 14, 5);

    try wrapped.interface.writeAll("[out] \x1b[31mabcdefgh\x1b[0m");
    try std.testing.expectEqualStrings(
        "[out] \x1b[31mabc\n     defgh\x1b[0m",
        downstream.writer.buffered(),
    );
}

test "grep display normalizes horizontal whitespace without touching control sequences" {
    const gpa = std.testing.allocator;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    var downstream = Io.Writer.Allocating.fromArrayList(gpa, &bytes);
    defer bytes = downstream.toArrayList();
    var normalized = GrepNormalizeWriter.init(&downstream.writer);

    try normalized.interface.writeAll(" \talpha   beta\t \x1b[31mgamma   \x1b[0m");
    normalized.finish();
    try std.testing.expectEqualStrings(
        "alpha beta\x1b[31m gamma\x1b[0m",
        downstream.writer.buffered(),
    );
}

fn journalDisplaySuffix(journal: []const u8) []const u8 {
    const length = @min(journal.len, 4);
    return journal[journal.len - length ..];
}

fn grepReferenceWidth(io: Io, root: store.Dir, journals: []const []const u8, qualified: bool) !usize {
    var width: usize = 1;
    for (journals) |journal| {
        const highest = try store.highestEntryNumber(io, root, journal) orelse continue;
        const number_width = decimalWidth(highest);
        const candidate = if (qualified)
            1 + journalDisplaySuffix(journal).len + 1 + number_width
        else
            number_width;
        width = @max(width, candidate);
    }
    return width;
}

fn grepCommand(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    parsed: *const zecli.Parsed,
    out: *Io.Writer,
) !u8 {
    const request = try grepRequest(parsed);

    const current = sys.env("TJ_JOURNAL");
    if (!request.all and (current == null or current.?.len == 0)) {
        note("tj grep: no current journal; use --all\n", .{});
        return 2;
    }

    var root = try store.openRoot(io, home);
    defer root.close(io);
    var matcher = try search.Matcher.init(gpa, request.pattern, request.ignore_case);
    defer matcher.deinit();
    const terminal_columns = historyTerminalColumns();
    var output: GrepOutput = .{
        .io = io,
        .out = out,
        .noout_region = .{
            .out = out,
            .enabled = current != null and current.?.len != 0 and sys.isTty(1),
        },
        .match_sgr = if (colorEnabled(request.color)) selectedMatchSgr(sys.env("GREP_COLORS")) else "",
        .terminal_columns = terminal_columns,
        .layout_color = historyColorEnabled(),
        .reference_width = 1,
    };
    defer output.noout_region.finish();
    const active = activeInteraction();
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

fn grepJournal(
    gpa: std.mem.Allocator,
    io: Io,
    root: store.Dir,
    journal: []const u8,
    request: GrepRequest,
    active: ?ActiveInteraction,
    matcher: *const search.Matcher,
    output: *GrepOutput,
    total: *u64,
) !void {
    const interactions = store.listInteractions(gpa, io, root, journal) catch |err| switch (err) {
        error.FileNotFound => return error.NoSuchJournal,
        else => |other| return other,
    };
    defer {
        for (interactions) |info| info.deinit(gpa);
        gpa.free(interactions);
    }
    var manifest = annotations.load(gpa, io, root, journal) catch |err| switch (err) {
        error.InvalidAnnotations => return error.InvalidAnnotations,
        else => return err,
    };
    defer manifest.deinit(gpa);

    for (interactions) |info| {
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
            var line_sink: GrepLineSink = .{
                .output = output,
                .journal = journal,
                .number = info.number,
                .resource = resource.name,
                .qualified = request.all,
                .matcher = matcher,
                .annotation = manifest.findConst(info.number),
                .exit_code = info.exit_code,
            };
            const found = try search.scanFile(io, file, matcher, .{
                .context = &line_sink,
                .emit = GrepLineSink.emit,
            });
            total.* = try std.math.add(u64, total.*, found);
        }
    }
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
    const automatic = try grepRequestFromArgs(&.{ "--color", "auto", "x" });
    try std.testing.expectEqual(ColorWhen.auto, automatic.color);
    try std.testing.expectEqualStrings("x", automatic.pattern);
    try std.testing.expectEqual(ColorWhen.always, (try grepRequestFromArgs(&.{ "--color", "always", "x" })).color);
    try std.testing.expectEqual(ColorWhen.always, (try grepRequestFromArgs(&.{ "--colour=always", "x" })).color);
    try std.testing.expectEqual(ColorWhen.never, (try grepRequestFromArgs(&.{ "--color=never", "x" })).color);
}

test "grep rejects missing multiline extra and unknown patterns" {
    try std.testing.expectError(error.ReportedCliError, grepRequestFromArgs(&.{}));
    try std.testing.expectError(error.BadArguments, grepRequestFromArgs(&.{""}));
    try std.testing.expectError(error.BadArguments, grepRequestFromArgs(&.{"a\nb"}));
    try std.testing.expectError(error.ReportedCliError, grepRequestFromArgs(&.{ "a", "b" }));
    try std.testing.expectError(error.ReportedCliError, grepRequestFromArgs(&.{ "--wat", "a" }));
    try std.testing.expectError(error.ReportedCliError, grepRequestFromArgs(&.{"--color"}));
    try std.testing.expectError(error.ReportedCliError, grepRequestFromArgs(&.{ "--color", "a" }));
    try std.testing.expectError(error.ReportedCliError, grepRequestFromArgs(&.{ "--color", "sometimes", "a" }));
    try std.testing.expectError(error.ReportedCliError, grepRequestFromArgs(&.{ "--color=sometimes", "a" }));
}

test "GNU grep selected-match colors use mt and ms capabilities" {
    try std.testing.expectEqualStrings("01;31", selectedMatchSgr(null));
    try std.testing.expectEqualStrings("4;32", selectedMatchSgr("fn=35:mt=1;31:ms=4;32"));
    try std.testing.expectEqualStrings("", selectedMatchSgr("mt="));
    try std.testing.expectEqualStrings("01;31", selectedMatchSgr("mt=not-sgr"));
}

fn listJournals(gpa: std.mem.Allocator, io: Io, home: ?[]const u8, out: *Io.Writer) !void {
    var root = try store.openRoot(io, home);
    defer root.close(io);

    const journals = try store.listJournals(gpa, io, root);
    defer {
        for (journals) |name| gpa.free(name);
        gpa.free(journals);
    }

    const current = sys.env("TJ_JOURNAL");
    for (journals) |name| {
        const interactions = store.listInteractions(gpa, io, root, name) catch continue;
        defer {
            for (interactions) |info| info.deinit(gpa);
            gpa.free(interactions);
        }
        const marker = if (current != null and std.mem.eql(u8, current.?, name)) "*" else " ";
        try out.print("{s} {s}  {d} {s}\n", .{
            marker,
            name,
            interactions.len,
            if (interactions.len == 1) "entry" else "entries",
        });
    }
}

fn listInteractions(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    parsed: *const zecli.Parsed,
    out: *Io.Writer,
) !void {
    var root = try store.openRoot(io, home);
    defer root.close(io);

    var filters: std.ArrayList([]u8) = .empty;
    defer {
        for (filters.items) |tag| gpa.free(tag);
        filters.deinit(gpa);
    }
    for (parsed.flags.items) |flag| {
        if (!std.mem.eql(u8, flag.name, "tag")) continue;
        try filters.append(gpa, annotations.normalizeTag(gpa, flag.value.?) catch return error.InvalidTag);
    }
    const pinned_only = parsed.present("pinned");
    const wanted = if (parsed.positionals.items.len == 1) parsed.positionals.items[0] else null;

    var journal_owned: ?[]u8 = null;
    defer if (journal_owned) |name| gpa.free(name);
    const journal: []const u8 = if (wanted) |selector| blk: {
        journal_owned = try store.findNewestJournal(gpa, io, root, selector) orelse return error.NoSuchJournal;
        break :blk journal_owned.?;
    } else try currentJournal();

    var manifest = annotations.load(gpa, io, root, journal) catch |err| switch (err) {
        error.InvalidAnnotations => return error.InvalidAnnotations,
        else => return err,
    };
    defer manifest.deinit(gpa);

    const interactions = store.listInteractions(gpa, io, root, journal) catch |err| switch (err) {
        error.FileNotFound => return error.NoSuchJournal,
        else => return err,
    };
    defer {
        for (interactions) |info| info.deinit(gpa);
        gpa.free(interactions);
    }

    var number_width: usize = 1;
    for (interactions) |info| {
        if (!historyEntryVisible(&manifest, info.number, filters.items, pinned_only)) continue;
        number_width = @max(number_width, decimalWidth(info.number));
    }

    const columns = historyTerminalColumns();
    const prefix_width = 1 + 1 + number_width + 2;
    const payload_width: ?usize = if (columns) |value|
        if (value > prefix_width)
            value - prefix_width
        else
            1
    else
        null;
    const color_enabled = historyColorEnabled();
    const current = sys.env("TJ_JOURNAL");
    var noout_region: NooutRegion = .{
        .out = out,
        .enabled = current != null and current.?.len != 0 and sys.isTty(1),
    };
    defer noout_region.finish();

    for (interactions) |info| {
        const annotation = manifest.findConst(info.number);
        if (!historyEntryVisible(&manifest, info.number, filters.items, pinned_only)) continue;

        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(gpa);
        try payload.appendSlice(gpa, firstLine(info.command));

        var dim_start: ?usize = null;
        var rc_start: ?usize = null;
        const has_name = annotation != null and annotation.?.name != null;
        const has_tags = annotation != null and annotation.?.tags.items.len != 0;
        const has_failure = info.exit_code != null and info.exit_code.? != 0;
        if (has_name or has_tags or has_failure) {
            if (payload.items.len != 0) try payload.append(gpa, ' ');
            if (has_name or has_tags) dim_start = payload.items.len;
            if (has_name) {
                try payload.append(gpa, '@');
                try payload.appendSlice(gpa, annotation.?.name.?);
            }
            if (has_tags) {
                if (has_name) try payload.append(gpa, ' ');
                try payload.append(gpa, '[');
                for (annotation.?.tags.items, 0..) |tag, tag_i| {
                    if (tag_i != 0) try payload.append(gpa, ' ');
                    try payload.appendSlice(gpa, tag);
                }
                try payload.append(gpa, ']');
            }
            if (has_failure) {
                if (has_name or has_tags) try payload.append(gpa, ' ');
                rc_start = payload.items.len;
                try payload.print(gpa, "[rc={d}]", .{info.exit_code.?});
            }
        }

        var lines = try wrapHistoryText(gpa, payload.items, payload_width, prefix_width);
        defer lines.deinit(gpa);
        try noout_region.begin();

        for (lines.items, 0..) |line, line_i| {
            if (line_i == 0) {
                try out.writeByte(if (annotation != null and annotation.?.pinned) '*' else ' ');
                try out.writeByte(' ');
                try out.splatByteAll(' ', number_width - decimalWidth(info.number));
                try out.print("{d}  ", .{info.number});
            } else {
                try out.splatByteAll(' ', prefix_width);
            }

            try writeHistoryLine(out, payload.items, line, dim_start, rc_start, color_enabled);
            try out.writeByte('\n');
        }
    }
}

fn historyEntryVisible(
    manifest: *const annotations.Manifest,
    number: u32,
    tags: []const []const u8,
    pinned_only: bool,
) bool {
    const annotation = manifest.findConst(number);
    if (pinned_only and (annotation == null or !annotation.?.pinned)) return false;
    return manifest.hasAllTags(number, tags);
}

fn decimalWidth(number: u32) usize {
    var value = number;
    var width: usize = 1;
    while (value >= 10) : (value /= 10) width += 1;
    return width;
}

fn historyTerminalColumns() ?usize {
    if (!sys.isTty(1)) return null;
    if (sys.getWinsize(1)) |size| {
        if (size.col != 0) return size.col;
    } else |_| {}
    if (sys.env("COLUMNS")) |text| {
        const columns = std.fmt.parseInt(usize, text, 10) catch 0;
        if (columns != 0) return columns;
    }
    return 80;
}

fn historyColorEnabled() bool {
    if (!sys.isTty(1) or sys.envPresent("NO_COLOR")) return false;
    const term = sys.env("TERM") orelse return false;
    return !std.mem.eql(u8, term, "dumb");
}

const HistoryLine = struct { start: usize, end: usize };

fn historyCell(text: []const u8, index: usize, column: usize) struct { bytes: usize, width: usize } {
    const byte = text[index];
    if (byte == '\t') return .{ .bytes = 1, .width = 8 - (column % 8) };
    if (byte < 0x20 or byte == 0x7f) return .{ .bytes = 1, .width = 0 };
    if (byte < 0x80) return .{ .bytes = 1, .width = 1 };
    const sequence_len: usize = std.unicode.utf8ByteSequenceLength(byte) catch return .{ .bytes = 1, .width = 1 };
    if (index + sequence_len > text.len) return .{ .bytes = 1, .width = 1 };
    _ = std.unicode.utf8Decode(text[index .. index + sequence_len]) catch return .{ .bytes = 1, .width = 1 };
    return .{ .bytes = sequence_len, .width = 1 };
}

fn wrapHistoryText(
    gpa: std.mem.Allocator,
    text: []const u8,
    width: ?usize,
    start_column: usize,
) !std.ArrayList(HistoryLine) {
    var lines: std.ArrayList(HistoryLine) = .empty;
    errdefer lines.deinit(gpa);
    if (text.len == 0 or width == null) {
        try lines.append(gpa, .{ .start = 0, .end = text.len });
        return lines;
    }

    const available = @max(width.?, 1);
    var start: usize = 0;
    while (start < text.len) {
        var index = start;
        var column = start_column;
        var last_space: ?usize = null;
        while (index < text.len) {
            const cell = historyCell(text, index, column);
            if (column + cell.width > start_column + available) {
                if (text[index] == ' ' or text[index] == '\t') last_space = index;
                break;
            }
            if (text[index] == ' ' or text[index] == '\t') last_space = index;
            index += cell.bytes;
            column += cell.width;
        }

        if (index == text.len) {
            try lines.append(gpa, .{ .start = start, .end = text.len });
            break;
        }

        var end: usize = undefined;
        var next: usize = undefined;
        if (last_space != null and last_space.? > start) {
            end = last_space.?;
            while (end > start and text[end - 1] == ' ') end -= 1;
            next = last_space.? + 1;
            while (next < text.len and (text[next] == ' ' or text[next] == '\t')) next += 1;
        } else if (index > start) {
            end = index;
            next = index;
        } else {
            const cell = historyCell(text, start, start_column);
            end = start + cell.bytes;
            next = end;
        }
        try lines.append(gpa, .{ .start = start, .end = end });
        start = next;
    }
    return lines;
}

fn writeHistoryLine(
    out: *Io.Writer,
    text: []const u8,
    line: HistoryLine,
    dim_start: ?usize,
    rc_start: ?usize,
    color_enabled: bool,
) !void {
    if (!color_enabled) return out.writeAll(text[line.start..line.end]);

    var position = line.start;
    if (dim_start) |start| {
        const styled_start = @max(line.start, start);
        const styled_end = @min(line.end, rc_start orelse line.end);
        if (position < @min(styled_start, line.end)) {
            try out.writeAll(text[position..@min(styled_start, line.end)]);
            position = @min(styled_start, line.end);
        }
        if (styled_start < styled_end) {
            try out.writeAll("\x1b[2m");
            try out.writeAll(text[styled_start..styled_end]);
            try out.writeAll("\x1b[0m");
            position = styled_end;
        }
    }
    if (rc_start) |start| {
        const styled_start = @max(line.start, start);
        if (position < @min(styled_start, line.end)) {
            try out.writeAll(text[position..@min(styled_start, line.end)]);
            position = @min(styled_start, line.end);
        }
        if (styled_start < line.end) {
            try out.writeAll("\x1b[31m");
            try out.writeAll(text[styled_start..line.end]);
            try out.writeAll("\x1b[0m");
            position = line.end;
        }
    }
    if (position < line.end) try out.writeAll(text[position..line.end]);
}

test "history wrapping prefers words and hard-wraps oversized words" {
    const gpa = std.testing.allocator;
    var words = try wrapHistoryText(gpa, "alpha beta gamma", 10, 0);
    defer words.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), words.items.len);
    try std.testing.expectEqualStrings("alpha beta", "alpha beta gamma"[words.items[0].start..words.items[0].end]);
    try std.testing.expectEqualStrings("gamma", "alpha beta gamma"[words.items[1].start..words.items[1].end]);

    var hard = try wrapHistoryText(gpa, "abcdefgh", 3, 0);
    defer hard.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 3), hard.items.len);
    try std.testing.expectEqualStrings("abc", "abcdefgh"[hard.items[0].start..hard.items[0].end]);
    try std.testing.expectEqualStrings("def", "abcdefgh"[hard.items[1].start..hard.items[1].end]);
    try std.testing.expectEqualStrings("gh", "abcdefgh"[hard.items[2].start..hard.items[2].end]);
}

test "history dims annotations and renders failures in red" {
    const gpa = std.testing.allocator;
    const text = "false @build [bug] [rc=1]";
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    var writer = Io.Writer.Allocating.fromArrayList(gpa, &bytes);
    defer bytes = writer.toArrayList();

    try writeHistoryLine(&writer.writer, text, .{ .start = 0, .end = text.len }, 6, 19, true);
    try std.testing.expectEqualStrings(
        "false \x1b[2m@build [bug] \x1b[0m\x1b[31m[rc=1]\x1b[0m",
        writer.writer.buffered(),
    );
}

fn printLast(gpa: std.mem.Allocator, io: Io, home: ?[]const u8, out: *Io.Writer) !void {
    const journal = try currentJournal();

    var root = try store.openRoot(io, home);
    defer root.close(io);

    const number = try store.lastCompleted(gpa, io, root, journal) orelse
        return error.NothingRecorded;
    try out.print("{d}\n", .{number});
}

/// Multi-line commands are real; a listing shows only the first line of one.
fn firstLine(text: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, text, '\n') orelse return text;
    return text[0..end];
}

test "firstLine stops at the first newline" {
    try std.testing.expectEqualStrings("git status", firstLine("git status"));
    try std.testing.expectEqualStrings("for f in *; do", firstLine("for f in *; do\n  echo $f\ndone"));
    try std.testing.expectEqualStrings("", firstLine(""));
}

// --- the `@` namespace -----------------------------------------------------

/// Prints the path a reference names. The shell integration calls this for
/// every `@`-word on a command line, so it has to be quiet and quick.
fn resolveReference(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    parsed: *const zecli.Parsed,
    out: *Io.Writer,
) !void {
    const ref = reference.parse(parsed.positionals.items[0]) catch return error.BadReference;

    var root = try store.openRoot(io, home);
    defer root.close(io);

    const found = try store.locate(gpa, io, root, sys.env("TJ_JOURNAL"), ref);
    defer found.deinit(gpa);

    // The resource inside may not exist yet, but the interaction must, or the
    // caller would be handed a path to nothing.
    if (!found.exists) return error.NoSuchInteraction;
    try out.print("{s}\n", .{found.path});
}

/// Candidate words for a partially typed reference, one per line. Kept lenient
/// on purpose: the input is mid-typing and mostly will not parse.
fn completeReference(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    parsed: *const zecli.Parsed,
    out: *Io.Writer,
) !void {
    const partial = if (parsed.positionals.items.len > 0) parsed.positionals.items[0] else "@";
    if (partial.len == 0 or partial[0] != '@') return;

    var root = store.openRoot(io, home) catch return;
    defer root.close(io);

    const rest = partial[1..];
    if (std.mem.lastIndexOfScalar(u8, rest, '/')) |slash| {
        try completeResources(gpa, io, root, rest[0..slash], rest[slash + 1 ..], out);
    } else {
        try completeInteractions(gpa, io, root, rest, out);
    }
}

/// `@4<TAB>` and `@pgsd.<TAB>` - which interactions exist.
fn completeInteractions(
    gpa: std.mem.Allocator,
    io: Io,
    root: store.Dir,
    body: []const u8,
    out: *Io.Writer,
) !void {
    var prefix = body;
    var qualifier: []const u8 = "";
    var journal_owned: ?[]u8 = null;
    defer if (journal_owned) |name| gpa.free(name);

    const journal: []const u8 = if (std.mem.lastIndexOfScalar(u8, body, '.')) |dot| blk: {
        qualifier = body[0 .. dot + 1];
        prefix = body[dot + 1 ..];
        journal_owned = try store.findNewestJournal(gpa, io, root, body[0..dot]) orelse return;
        break :blk journal_owned.?;
    } else sys.env("TJ_JOURNAL") orelse return;

    const numbers = store.listNumbers(gpa, io, root, journal) catch return;
    defer gpa.free(numbers);

    for (numbers) |number| {
        var buf: [16]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d}", .{number}) catch continue;
        if (!std.mem.startsWith(u8, text, prefix)) continue;
        try out.print("@{s}{s}\n", .{ qualifier, text });
    }

    var manifest = annotations.load(gpa, io, root, journal) catch return;
    defer manifest.deinit(gpa);
    for (manifest.entries.items) |entry| {
        const name = entry.name orelse continue;
        if (!store.interactionExists(io, root, journal, entry.number)) continue;
        if (!std.mem.startsWith(u8, name, prefix)) continue;
        try out.print("@{s}{s}\n", .{ qualifier, name });
    }
}

/// `@42/<TAB>` and `@42/files/<TAB>` - what the interaction holds.
fn completeResources(
    gpa: std.mem.Allocator,
    io: Io,
    root: store.Dir,
    body: []const u8,
    prefix: []const u8,
    out: *Io.Writer,
) !void {
    // Everything before the last slash is settled; only the last segment is
    // still being typed.
    const cut = std.mem.indexOfScalar(u8, body, '/') orelse body.len;
    const ref_text = std.fmt.allocPrint(gpa, "@{s}", .{body[0..cut]}) catch return;
    defer gpa.free(ref_text);
    const ref = reference.parse(ref_text) catch return;
    const directory = if (cut < body.len) body[cut + 1 ..] else "";

    const found = store.locate(gpa, io, root, sys.env("TJ_JOURNAL"), ref) catch return;
    defer found.deinit(gpa);
    if (!found.exists) return;

    const names = if (directory.len == 0)
        store.listResources(gpa, io, root, found.journal, found.number) catch return
    else
        listWithin(gpa, io, root, found.journal, found.number, directory) catch return;
    defer {
        for (names) |name| gpa.free(name);
        gpa.free(names);
    }

    for (names) |name| {
        if (!std.mem.startsWith(u8, name, prefix)) continue;
        try out.print("@{s}/{s}\n", .{ body, name });
    }
}

fn listWithin(
    gpa: std.mem.Allocator,
    io: Io,
    root: store.Dir,
    journal: []const u8,
    number: u32,
    directory: []const u8,
) ![][]u8 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const sub = try std.fmt.bufPrint(&path_buf, "{s}/{d}/{s}", .{ journal, number, directory });

    var dir = try root.openDir(io, sub, .{ .iterate = true });
    defer dir.close(io);

    var found: std.ArrayList([]u8) = .empty;
    errdefer {
        for (found.items) |name| gpa.free(name);
        found.deinit(gpa);
    }

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const name = if (entry.kind == .directory)
            try std.fmt.allocPrint(gpa, "{s}/", .{entry.name})
        else
            try gpa.dupe(u8, entry.name);
        try found.append(gpa, name);
    }
    return found.toOwnedSlice(gpa);
}

// --- interaction annotations ----------------------------------------------

const CommandTarget = struct {
    journal: []u8,
    number: u32,
    subpath: []const u8,
    syntactically_qualified: bool = false,

    fn deinit(self: CommandTarget, gpa: std.mem.Allocator) void {
        gpa.free(self.journal);
    }
};

fn locateCommandTarget(
    gpa: std.mem.Allocator,
    io: Io,
    root: store.Dir,
    text: []const u8,
) !CommandTarget {
    if (reference.parse(text)) |parsed| {
        const qualified = parsed.body == .qualified;
        const found = try store.locate(gpa, io, root, sys.env("TJ_JOURNAL"), parsed);
        defer found.deinit(gpa);
        if (!found.exists) return error.NoSuchInteraction;
        return .{
            .journal = try gpa.dupe(u8, found.journal),
            .number = found.number,
            .subpath = parsed.subpath,
            .syntactically_qualified = qualified,
        };
    } else |err| switch (err) {
        error.Malformed => return error.BadReference,
        error.NotAReference => {},
    }

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try root.realPath(io, &root_buf);
    const root_path = root_buf[0..root_len];
    if (!std.mem.startsWith(u8, text, root_path) or text.len <= root_path.len or text[root_path.len] != '/') {
        return error.BadReference;
    }
    const relative = text[root_path.len + 1 ..];
    const journal_end = std.mem.indexOfScalar(u8, relative, '/') orelse return error.BadReference;
    const journal = relative[0..journal_end];
    const after_journal = relative[journal_end + 1 ..];
    const number_end = std.mem.indexOfScalar(u8, after_journal, '/') orelse after_journal.len;
    const number = std.fmt.parseInt(u32, after_journal[0..number_end], 10) catch return error.BadReference;
    if (number == 0 or !store.interactionExists(io, root, journal, number)) return error.NoSuchInteraction;
    const subpath = if (number_end < after_journal.len) after_journal[number_end + 1 ..] else "";
    if (subpath.len != 0) {
        const check = try std.fmt.allocPrint(gpa, "@1/{s}", .{subpath});
        defer gpa.free(check);
        _ = reference.parse(check) catch return error.BadReference;
    }
    return .{
        .journal = try gpa.dupe(u8, journal),
        .number = number,
        .subpath = subpath,
    };
}

fn requireMutationTarget(
    gpa: std.mem.Allocator,
    io: Io,
    root: store.Dir,
    text: []const u8,
) !CommandTarget {
    const current = try currentJournal();
    const target = try locateCommandTarget(gpa, io, root, text);
    errdefer target.deinit(gpa);
    if (target.syntactically_qualified or !std.mem.eql(u8, target.journal, current)) {
        return error.CrossJournalMutation;
    }
    return target;
}

fn requireInteraction(target: CommandTarget) !void {
    if (target.subpath.len != 0) return error.BadReference;
}

fn printCanonical(out: *Io.Writer, current: ?[]const u8, journal: []const u8, number: u32) !void {
    if (current) |id| {
        if (std.mem.eql(u8, id, journal)) return out.print("@{d}", .{number});
    }
    try out.print("@{s}.{d}", .{ journal, number });
}

fn openCurrentMutation(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
) !struct { root: store.Dir, journal: []const u8, lock: Io.File } {
    const journal = try currentJournal();
    var root = try store.openRoot(io, home);
    errdefer root.close(io);
    const lock = try annotations.acquireMutationLock(io, root, journal);
    errdefer lock.close(io);
    try store.recoverPendingOutputRemovals(gpa, io, root, journal);
    store.cleanupJournalTrash(io, root, journal);
    return .{ .root = root, .journal = journal, .lock = lock };
}

fn pruneMissingAnnotations(
    gpa: std.mem.Allocator,
    io: Io,
    root: store.Dir,
    journal: []const u8,
    manifest: *annotations.Manifest,
) void {
    var i: usize = 0;
    while (i < manifest.entries.items.len) {
        const number = manifest.entries.items[i].number;
        if (store.interactionExists(io, root, journal, number)) {
            i += 1;
        } else {
            manifest.removeInteraction(gpa, number);
        }
    }
}

const NameRequest = union(enum) {
    list,
    query: []const u8,
    set: struct { ref: []const u8, name: []const u8 },
    remove: []const u8,
};

fn nameRequest(parsed: *const zecli.Parsed) !NameRequest {
    const args = parsed.positionals.items;
    if (parsed.present("remove")) {
        if (args.len != 1) return error.BadArguments;
        return .{ .remove = args[0] };
    }
    return switch (args.len) {
        0 => .list,
        1 => .{ .query = args[0] },
        2 => .{ .set = .{ .ref = args[0], .name = args[1] } },
        else => error.BadArguments,
    };
}

fn nameCommand(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    parsed: *const zecli.Parsed,
    out: *Io.Writer,
) !void {
    switch (try nameRequest(parsed)) {
        .list => {
            const current = try currentJournal();
            var root = try store.openRoot(io, home);
            defer root.close(io);
            var manifest = try annotations.load(gpa, io, root, current);
            defer manifest.deinit(gpa);
            for (manifest.entries.items) |entry| {
                const name = entry.name orelse continue;
                if (!store.interactionExists(io, root, current, entry.number)) continue;
                try out.print("{s}  @{d}\n", .{ name, entry.number });
            }
            return;
        },
        .query => |ref| {
            var root = try store.openRoot(io, home);
            defer root.close(io);
            const target = try locateCommandTarget(gpa, io, root, ref);
            defer target.deinit(gpa);
            try requireInteraction(target);
            var manifest = try annotations.load(gpa, io, root, target.journal);
            defer manifest.deinit(gpa);
            const entry = manifest.findConst(target.number) orelse return;
            const name = entry.name orelse return;
            try out.print("{s}  ", .{name});
            try printCanonical(out, sys.env("TJ_JOURNAL"), target.journal, target.number);
            return out.writeAll("\n");
        },
        .remove => |name| {
            var mutation = try openCurrentMutation(gpa, io, home);
            defer mutation.lock.close(io);
            defer mutation.root.close(io);
            var manifest = try annotations.load(gpa, io, mutation.root, mutation.journal);
            defer manifest.deinit(gpa);
            pruneMissingAnnotations(gpa, io, mutation.root, mutation.journal, &manifest);
            try manifest.removeName(gpa, name);
            return annotations.save(gpa, io, mutation.root, mutation.journal, &manifest);
        },
        .set => |request| {
            var root = try store.openRoot(io, home);
            defer root.close(io);
            const target = try requireMutationTarget(gpa, io, root, request.ref);
            defer target.deinit(gpa);
            try requireInteraction(target);
            var mutation = try openCurrentMutation(gpa, io, home);
            defer mutation.lock.close(io);
            defer mutation.root.close(io);
            if (!store.interactionExists(io, mutation.root, mutation.journal, target.number)) return error.NoSuchInteraction;
            var manifest = try annotations.load(gpa, io, mutation.root, mutation.journal);
            defer manifest.deinit(gpa);
            pruneMissingAnnotations(gpa, io, mutation.root, mutation.journal, &manifest);
            try manifest.setName(gpa, target.number, request.name);
            try annotations.save(gpa, io, mutation.root, mutation.journal, &manifest);
        },
    }
}

const TagRequest = union(enum) {
    list,
    query: []const u8,
    add: struct { ref: []const u8, tags: []const []const u8 },
    remove: struct { ref: []const u8, tags: []const []const u8 },
};

fn tagRequest(parsed: *const zecli.Parsed) !TagRequest {
    const args = parsed.positionals.items;
    if (parsed.present("remove")) {
        if (args.len < 2) return error.MissingArgument;
        return .{ .remove = .{ .ref = args[0], .tags = args[1..] } };
    }
    return switch (args.len) {
        0 => .list,
        1 => .{ .query = args[0] },
        else => .{ .add = .{ .ref = args[0], .tags = args[1..] } },
    };
}

fn tagCommand(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    parsed: *const zecli.Parsed,
    out: *Io.Writer,
) !void {
    switch (try tagRequest(parsed)) {
        .list => {
            const current = try currentJournal();
            var root = try store.openRoot(io, home);
            defer root.close(io);
            var manifest = try annotations.load(gpa, io, root, current);
            defer manifest.deinit(gpa);
            for (manifest.entries.items) |entry| {
                if (entry.tags.items.len == 0 or !store.interactionExists(io, root, current, entry.number)) continue;
                try out.print("@{d}", .{entry.number});
                for (entry.tags.items) |tag| try out.print("  {s}", .{tag});
                try out.writeAll("\n");
            }
        },
        .query => |ref| {
            if (try parseInteractionRange(ref)) |range| {
                return queryTagsRange(gpa, io, home, range, out);
            }
            var root = try store.openRoot(io, home);
            defer root.close(io);
            const target = try locateCommandTarget(gpa, io, root, ref);
            defer target.deinit(gpa);
            try requireInteraction(target);
            var manifest = try annotations.load(gpa, io, root, target.journal);
            defer manifest.deinit(gpa);
            const entry = manifest.findConst(target.number) orelse return;
            if (entry.tags.items.len == 0) return;
            try printCanonical(out, sys.env("TJ_JOURNAL"), target.journal, target.number);
            for (entry.tags.items) |tag| try out.print("  {s}", .{tag});
            try out.writeAll("\n");
        },
        .add => |request| try updateTags(gpa, io, home, request.ref, request.tags, false),
        .remove => |request| try updateTags(gpa, io, home, request.ref, request.tags, true),
    }
}

fn updateTags(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    ref: []const u8,
    tags: []const []const u8,
    removing: bool,
) !void {
    if (try parseInteractionRange(ref)) |range| {
        return updateTagsRange(gpa, io, home, range, tags, removing);
    }
    const target = blk: {
        var root = try store.openRoot(io, home);
        defer root.close(io);
        break :blk try requireMutationTarget(gpa, io, root, ref);
    };
    defer target.deinit(gpa);
    try requireInteraction(target);

    var mutation = try openCurrentMutation(gpa, io, home);
    defer mutation.lock.close(io);
    defer mutation.root.close(io);
    if (!store.interactionExists(io, mutation.root, mutation.journal, target.number)) return error.NoSuchInteraction;
    var manifest = try annotations.load(gpa, io, mutation.root, mutation.journal);
    defer manifest.deinit(gpa);
    pruneMissingAnnotations(gpa, io, mutation.root, mutation.journal, &manifest);
    for (tags) |tag| {
        if (removing) {
            try manifest.removeTag(gpa, target.number, tag);
        } else {
            try manifest.addTag(gpa, target.number, tag);
        }
    }
    try annotations.save(gpa, io, mutation.root, mutation.journal, &manifest);
}

fn queryTagsRange(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    range: InteractionRange,
    out: *Io.Writer,
) !void {
    const current = try currentJournal();
    var root = try store.openRoot(io, home);
    defer root.close(io);
    const numbers = try store.listNumbers(gpa, io, root, current);
    defer gpa.free(numbers);
    if (!rangeSelectsAny(numbers, range)) return error.NoSuchInteraction;

    var manifest = try annotations.load(gpa, io, root, current);
    defer manifest.deinit(gpa);
    for (numbers) |number| {
        if (!range.contains(number)) continue;
        const entry = manifest.findConst(number) orelse continue;
        if (entry.tags.items.len == 0) continue;
        try out.print("@{d}", .{number});
        for (entry.tags.items) |tag| try out.print("  {s}", .{tag});
        try out.writeAll("\n");
    }
}

fn updateTagsRange(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    range: InteractionRange,
    tags: []const []const u8,
    removing: bool,
) !void {
    var mutation = try openCurrentMutation(gpa, io, home);
    defer mutation.lock.close(io);
    defer mutation.root.close(io);
    const numbers = try store.listNumbers(gpa, io, mutation.root, mutation.journal);
    defer gpa.free(numbers);
    if (!rangeSelectsAny(numbers, range)) return error.NoSuchInteraction;

    var manifest = try annotations.load(gpa, io, mutation.root, mutation.journal);
    defer manifest.deinit(gpa);
    pruneMissingAnnotations(gpa, io, mutation.root, mutation.journal, &manifest);
    for (numbers) |number| {
        if (!range.contains(number)) continue;
        for (tags) |tag| {
            if (removing) {
                try manifest.removeTag(gpa, number, tag);
            } else {
                try manifest.addTag(gpa, number, tag);
            }
        }
    }
    try annotations.save(gpa, io, mutation.root, mutation.journal, &manifest);
}

const PinRequest = union(enum) {
    list,
    set: []const u8,
    remove: []const u8,
};

fn pinRequest(parsed: *const zecli.Parsed) !PinRequest {
    const args = parsed.positionals.items;
    if (parsed.present("remove")) {
        if (args.len != 1) return error.BadArguments;
        return .{ .remove = args[0] };
    }
    return switch (args.len) {
        0 => .list,
        1 => .{ .set = args[0] },
        else => error.BadArguments,
    };
}

fn pinCommand(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    parsed: *const zecli.Parsed,
    out: *Io.Writer,
) !void {
    switch (try pinRequest(parsed)) {
        .list => {
            const current = try currentJournal();
            var root = try store.openRoot(io, home);
            defer root.close(io);
            var manifest = try annotations.load(gpa, io, root, current);
            defer manifest.deinit(gpa);
            for (manifest.entries.items) |entry| {
                if (entry.pinned and store.interactionExists(io, root, current, entry.number)) {
                    try out.print("@{d}\n", .{entry.number});
                }
            }
        },
        .set => |ref| try updatePin(gpa, io, home, ref, true),
        .remove => |ref| try updatePin(gpa, io, home, ref, false),
    }
}

fn updatePin(gpa: std.mem.Allocator, io: Io, home: ?[]const u8, ref: []const u8, pinned: bool) !void {
    if (try parseInteractionRange(ref)) |range| {
        return updatePinRange(gpa, io, home, range, pinned);
    }
    const target = blk: {
        var root = try store.openRoot(io, home);
        defer root.close(io);
        break :blk try requireMutationTarget(gpa, io, root, ref);
    };
    defer target.deinit(gpa);
    try requireInteraction(target);

    var mutation = try openCurrentMutation(gpa, io, home);
    defer mutation.lock.close(io);
    defer mutation.root.close(io);
    if (!store.interactionExists(io, mutation.root, mutation.journal, target.number)) return error.NoSuchInteraction;
    var manifest = try annotations.load(gpa, io, mutation.root, mutation.journal);
    defer manifest.deinit(gpa);
    pruneMissingAnnotations(gpa, io, mutation.root, mutation.journal, &manifest);
    try manifest.setPinned(gpa, target.number, pinned);
    try annotations.save(gpa, io, mutation.root, mutation.journal, &manifest);
}

fn updatePinRange(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    range: InteractionRange,
    pinned: bool,
) !void {
    var mutation = try openCurrentMutation(gpa, io, home);
    defer mutation.lock.close(io);
    defer mutation.root.close(io);
    const numbers = try store.listNumbers(gpa, io, mutation.root, mutation.journal);
    defer gpa.free(numbers);
    if (!rangeSelectsAny(numbers, range)) return error.NoSuchInteraction;

    var manifest = try annotations.load(gpa, io, mutation.root, mutation.journal);
    defer manifest.deinit(gpa);
    pruneMissingAnnotations(gpa, io, mutation.root, mutation.journal, &manifest);
    for (numbers) |number| {
        if (range.contains(number)) try manifest.setPinned(gpa, number, pinned);
    }
    try annotations.save(gpa, io, mutation.root, mutation.journal, &manifest);
}

const RemoveRequest = struct {
    target: []const u8,
    force: bool,
};

fn removeRequest(parsed: *const zecli.Parsed) !RemoveRequest {
    if (parsed.positionals.items.len != 1) return error.BadArguments;
    return .{ .target = parsed.positionals.items[0], .force = parsed.present("force") };
}

const JournalRequest = union(enum) {
    list,
    remove: struct { selector: []const u8, force: bool },
};

fn journalRequest(parsed: *const zecli.Parsed) !JournalRequest {
    const args = parsed.positionals.items;
    if (args.len == 1 and std.mem.eql(u8, args[0], "list")) {
        if (parsed.present("force")) return error.BadArguments;
        return .list;
    }
    if (args.len == 2 and std.mem.eql(u8, args[0], "rm")) {
        return .{ .remove = .{ .selector = args[1], .force = parsed.present("force") } };
    }
    return error.BadArguments;
}

test "annotation and removal requests select one semantic mode" {
    const gpa = std.testing.allocator;

    {
        var parsed = try parseTestCommand(.name, &.{});
        defer parsed.deinit(gpa);
        try std.testing.expect(try nameRequest(&parsed) == .list);
    }
    {
        var parsed = try parseTestCommand(.name, &.{ "@2", "build-failure" });
        defer parsed.deinit(gpa);
        const request = (try nameRequest(&parsed)).set;
        try std.testing.expectEqualStrings("@2", request.ref);
        try std.testing.expectEqualStrings("build-failure", request.name);
    }
    {
        var parsed = try parseTestCommand(.tag, &.{ "--remove", "@2", "bug", "parser" });
        defer parsed.deinit(gpa);
        const request = (try tagRequest(&parsed)).remove;
        try std.testing.expectEqualStrings("@2", request.ref);
        try std.testing.expectEqual(@as(usize, 2), request.tags.len);
    }
    {
        var parsed = try parseTestCommand(.pin, &.{"@2"});
        defer parsed.deinit(gpa);
        try std.testing.expectEqualStrings("@2", (try pinRequest(&parsed)).set);
    }
    {
        var parsed = try parseTestCommand(.journal, &.{ "rm", "abcd", "--force" });
        defer parsed.deinit(gpa);
        const request = (try journalRequest(&parsed)).remove;
        try std.testing.expectEqualStrings("abcd", request.selector);
        try std.testing.expect(request.force);
    }
    {
        var parsed = try parseTestCommand(.rm, &.{ "--force", "@2" });
        defer parsed.deinit(gpa);
        const request = try removeRequest(&parsed);
        try std.testing.expectEqualStrings("@2", request.target);
        try std.testing.expect(request.force);
    }
}

fn journalCommand(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    parsed: *const zecli.Parsed,
    out: *Io.Writer,
) !void {
    switch (try journalRequest(parsed)) {
        .list => try listJournals(gpa, io, home, out),
        .remove => |request| try removeJournal(gpa, io, home, request.selector, request.force, out),
    }
}

fn removeCommand(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    parsed: *const zecli.Parsed,
    out: *Io.Writer,
) !void {
    _ = out;
    const request = try removeRequest(parsed);
    return removeInteraction(gpa, io, home, request.target, request.force);
}

fn removeJournal(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    selector: []const u8,
    force: bool,
    out: *Io.Writer,
) !void {
    if (sys.env("TJ_JOURNAL") != null) return error.InsideJournalRemoval;
    var root = try store.openRoot(io, home);
    defer root.close(io);
    const journal = try store.findUniqueJournal(gpa, io, root, selector);
    defer gpa.free(journal);

    const interactions = try store.listInteractions(gpa, io, root, journal);
    defer {
        for (interactions) |info| info.deinit(gpa);
        gpa.free(interactions);
    }
    if (!force) {
        var manifest = try annotations.load(gpa, io, root, journal);
        defer manifest.deinit(gpa);
        if (manifest.hasPins()) return error.PinnedInteraction;
        if (!sys.isTty(0)) return error.ConfirmationRequired;
        try out.print("Remove journal {s} with {d} {s}? [y/N] ", .{
            journal,
            interactions.len,
            if (interactions.len == 1) "entry" else "entries",
        });
        try out.flush();
        var answer_buf: [32]u8 = undefined;
        const read = try sys.read(0, &answer_buf);
        const answer = std.mem.trim(u8, answer_buf[0..read], " \t\r\n");
        if (!(std.ascii.eqlIgnoreCase(answer, "y") or std.ascii.eqlIgnoreCase(answer, "yes"))) {
            return error.Cancelled;
        }
    }
    return store.removeJournal(gpa, io, root, journal, force) catch |err| switch (err) {
        error.ActiveJournal => error.ActiveJournal,
        else => return err,
    };
}

fn removeInteraction(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    interaction: []const u8,
    force: bool,
) !void {
    if (try parseInteractionRange(interaction)) |range| {
        return removeInteractionRange(gpa, io, home, range, force);
    }
    const target = blk: {
        var root = try store.openRoot(io, home);
        defer root.close(io);
        break :blk try requireMutationTarget(gpa, io, root, interaction);
    };
    defer target.deinit(gpa);
    const output_only = std.mem.eql(u8, target.subpath, "out");
    if (target.subpath.len != 0 and !output_only) return error.UnsupportedRemoval;

    var mutation = try openCurrentMutation(gpa, io, home);
    defer mutation.lock.close(io);
    defer mutation.root.close(io);
    if (!std.mem.eql(u8, target.journal, mutation.journal)) return error.CrossJournalMutation;
    if (!store.interactionExists(io, mutation.root, mutation.journal, target.number)) return error.NoSuchInteraction;
    const highest = try store.highestNumber(gpa, io, mutation.root, mutation.journal) orelse
        return error.NoSuchInteraction;
    if (target.number >= highest) return error.CurrentInteraction;

    var manifest = try annotations.load(gpa, io, mutation.root, mutation.journal);
    defer manifest.deinit(gpa);
    pruneMissingAnnotations(gpa, io, mutation.root, mutation.journal, &manifest);
    if (!force and interactionPinned(&manifest, target.number)) {
        note("tj: skipped pinned entry @{d}; use --force to remove it\n", .{target.number});
        return;
    }

    if (output_only) {
        return store.removeOutput(gpa, io, mutation.root, mutation.journal, target.number) catch |err| switch (err) {
            error.InvalidMetadata => error.InvalidMetadata,
            else => return err,
        };
    }

    const staged = try store.stageInteractionRemoval(gpa, io, mutation.root, mutation.journal, target.number);
    defer gpa.free(staged);
    manifest.removeInteraction(gpa, target.number);
    try annotations.save(gpa, io, mutation.root, mutation.journal, &manifest);
    try store.finishStagedRemoval(io, mutation.root, staged);
}

const InteractionRange = struct {
    first: u32,
    last: u32,

    fn contains(self: InteractionRange, number: u32) bool {
        return self.first <= number and number <= self.last;
    }
};

/// Ranges are a small command-level grammar extension, not references resolved
/// by zsh. They deliberately select numeric interactions in the current
/// journal; names, resources, `@-`, and qualified journals are not ranges.
fn parseInteractionRange(text: []const u8) !?InteractionRange {
    if (text.len == 0 or text[0] != '@') return null;
    const cut = std.mem.indexOf(u8, text, "..") orelse return null;
    if (std.mem.indexOf(u8, text[cut + 2 ..], "..") != null) return error.InvalidRange;

    const first = try parseInteractionRangeEndpoint(text[0..cut]);
    const last = try parseInteractionRangeEndpoint(text[cut + 2 ..]);
    if (first > last) return error.InvalidRange;
    return .{ .first = first, .last = last };
}

fn parseInteractionRangeEndpoint(text: []const u8) !u32 {
    const parsed = reference.parse(text) catch return error.InvalidRange;
    if (parsed.subpath.len != 0 or parsed.trailing_slash) return error.InvalidRange;
    return switch (parsed.body) {
        .current => |target| switch (target) {
            .number => |number| number,
            .name => error.InvalidRange,
        },
        .qualified => error.CrossJournalMutation,
        .previous => error.InvalidRange,
    };
}

fn rangeSelectsAny(numbers: []const u32, range: InteractionRange) bool {
    for (numbers) |number| if (range.contains(number)) return true;
    return false;
}

fn interactionPinned(manifest: *const annotations.Manifest, number: u32) bool {
    const entry = manifest.findConst(number) orelse return false;
    return entry.pinned;
}

fn removeInteractionRange(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    range: InteractionRange,
    force: bool,
) !void {
    var mutation = try openCurrentMutation(gpa, io, home);
    defer mutation.lock.close(io);
    defer mutation.root.close(io);

    const numbers = try store.listNumbers(gpa, io, mutation.root, mutation.journal);
    defer gpa.free(numbers);
    if (numbers.len == 0) return error.NoSuchInteraction;

    // The highest directory is the running removal command in normal use, or
    // an unfinished boundary left by the last writer. Validate this before
    // staging any directory so a protected range cannot partially apply.
    const highest = numbers[numbers.len - 1];
    if (range.contains(highest)) return error.CurrentInteraction;

    var selected: usize = 0;
    for (numbers) |number| {
        if (range.contains(number)) selected += 1;
    }
    if (selected == 0) return error.NoSuchInteraction;

    var manifest = try annotations.load(gpa, io, mutation.root, mutation.journal);
    defer manifest.deinit(gpa);
    pruneMissingAnnotations(gpa, io, mutation.root, mutation.journal, &manifest);

    var staged_paths: std.ArrayList([]u8) = .empty;
    defer {
        for (staged_paths.items) |path| gpa.free(path);
        staged_paths.deinit(gpa);
    }
    try staged_paths.ensureTotalCapacity(gpa, selected);

    var skipped_pinned: usize = 0;
    for (numbers) |number| {
        if (number < range.first or number > range.last) continue;
        if (!force and interactionPinned(&manifest, number)) {
            skipped_pinned += 1;
            continue;
        }
        const staged = try store.stageInteractionRemoval(gpa, io, mutation.root, mutation.journal, number);
        staged_paths.appendAssumeCapacity(staged);
        manifest.removeInteraction(gpa, number);
    }

    if (staged_paths.items.len != 0) {
        try annotations.save(gpa, io, mutation.root, mutation.journal, &manifest);
    }
    for (staged_paths.items) |path| try store.finishStagedRemoval(io, mutation.root, path);
    if (skipped_pinned != 0) {
        note("tj: skipped {d} pinned {s}; use --force to remove {s}\n", .{
            skipped_pinned,
            if (skipped_pinned == 1) "entry" else "entries",
            if (skipped_pinned == 1) "it" else "them",
        });
    }
}

test "entry ranges are inclusive numeric current-journal references" {
    const range = (try parseInteractionRange("@2..@10")).?;
    try std.testing.expectEqual(@as(u32, 2), range.first);
    try std.testing.expectEqual(@as(u32, 10), range.last);
    try std.testing.expect((try parseInteractionRange("@2")) == null);
    try std.testing.expect((try parseInteractionRange("/tmp/a..b")) == null);
    try std.testing.expectError(error.InvalidRange, parseInteractionRange("@10..@2"));
    try std.testing.expectError(error.InvalidRange, parseInteractionRange("@two..@ten"));
    try std.testing.expectError(error.InvalidRange, parseInteractionRange("@2/out..@10/out"));
    try std.testing.expectError(error.CrossJournalMutation, parseInteractionRange("@abcd.2..@abcd.10"));
}

// --- reading resources ------------------------------------------------------

const read_chunk_size = 64 * 1024;

const CatRequest = struct {
    as_written: bool,
    window: Window,
    refs: []const []const u8,
};

fn catRequest(parsed: *const zecli.Parsed, stdout_is_tty: bool) CatRequest {
    var request: CatRequest = .{
        .as_written = stdout_is_tty,
        .window = .all,
        .refs = parsed.positionals.items,
    };
    for (parsed.flags.items) |flag| {
        if (std.mem.eql(u8, flag.name, "raw")) {
            request.as_written = true;
        } else if (std.mem.eql(u8, flag.name, "plain")) {
            request.as_written = false;
        } else if (std.mem.eql(u8, flag.name, "head")) {
            request.window = .{ .head = std.fmt.parseInt(usize, flag.value.?, 10) catch unreachable };
        } else if (std.mem.eql(u8, flag.name, "tail")) {
            request.window = .{ .tail = std.fmt.parseInt(usize, flag.value.?, 10) catch unreachable };
        }
    }
    return request;
}

/// `tj cat @42` - print what an interaction recorded, without needing the
/// shell integration to expand anything. Useful from bash, from a script, or
/// from a shell that is not running under tj at all.
fn catResource(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    parsed: *const zecli.Parsed,
    out: *Io.Writer,
) !void {
    // Terminals can render escape sequences, pipes cannot. Follow the usual
    // convention and let either flag settle it explicitly.
    const request = catRequest(parsed, sys.isTty(1));

    var root = try store.openRoot(io, home);
    defer root.close(io);

    for (request.refs) |text| {
        const maybe_range = parseInteractionRange(text) catch |err| switch (err) {
            // Cat ranges are deliberately current-journal-only, but this is a
            // syntax limitation rather than an attempted cross-journal write.
            error.CrossJournalMutation => return error.InvalidRange,
            else => |other| return other,
        };
        if (maybe_range) |range| {
            try catRange(gpa, io, root, request, range, out);
        } else {
            try catOne(gpa, io, root, request, text, out);
        }
    }
}

fn catRange(
    gpa: std.mem.Allocator,
    io: Io,
    root: store.Dir,
    request: CatRequest,
    range: InteractionRange,
    out: *Io.Writer,
) !void {
    const current = try currentJournal();
    const numbers = try store.listNumbers(gpa, io, root, current);
    defer gpa.free(numbers);
    if (!rangeSelectsAny(numbers, range)) return error.NoSuchInteraction;

    // Reading the `out` currently being produced would feed cat's own output
    // back into the same file. Refuse the whole range before emitting a byte.
    if (activeInteraction()) |active| {
        if (std.mem.eql(u8, active.journal, current) and range.contains(active.number)) {
            return error.CurrentInteraction;
        }
    }

    for (numbers) |number| {
        if (!range.contains(number)) continue;
        var ref_buf: [16]u8 = undefined;
        const ref = try std.fmt.bufPrint(&ref_buf, "@{d}", .{number});
        try catOne(gpa, io, root, request, ref, out);
    }
}

fn catOne(
    gpa: std.mem.Allocator,
    io: Io,
    root: store.Dir,
    request: CatRequest,
    text: []const u8,
    out: *Io.Writer,
) !void {
    var file = try openTarget(gpa, io, root, text);
    defer file.close(io);

    // Rendering feeds the same window as raw bytes, so line counts always
    // describe what the caller sees rather than terminal control traffic.
    var sink = WindowSink.init(gpa, request.window, out);
    defer sink.deinit();
    if (request.as_written) {
        try copyFile(io, file, &sink);
    } else {
        try renderFile(gpa, io, file, &sink);
    }
    try sink.finish();

    // Silence about what was left out would let a reader - a person or an
    // agent - take a fragment for the whole thing. It goes to stderr so that
    // stdout stays exactly what was asked for.
    if (sink.shownLines() < sink.totalLines()) {
        note("tj: {s}: showing {d} of {d} lines\n", .{
            text,
            sink.shownLines(),
            sink.totalLines(),
        });
    }
}

fn copyFile(io: Io, file: Io.File, out: anytype) !void {
    var reader_buffer: [read_chunk_size]u8 = undefined;
    var bytes: [read_chunk_size]u8 = undefined;
    var reader = file.readerStreaming(io, &reader_buffer);
    while (true) {
        const n = try reader.interface.readSliceShort(&bytes);
        if (n == 0) break;
        try out.writeAll(bytes[0..n]);
    }
}

fn renderFile(gpa: std.mem.Allocator, io: Io, file: Io.File, out: anytype) !void {
    var renderer = plain.Renderer.init(gpa);
    defer renderer.deinit();
    var reader_buffer: [read_chunk_size]u8 = undefined;
    var bytes: [read_chunk_size]u8 = undefined;
    var reader = file.readerStreaming(io, &reader_buffer);
    while (true) {
        const n = try reader.interface.readSliceShort(&bytes);
        if (n == 0) break;
        try renderer.feed(bytes[0..n], out);
    }
    try renderer.finish(out);
}

/// How much of a resource to print.
const Window = union(enum) {
    all,
    head: usize,
    tail: usize,
};

test "cat request preserves option occurrence order" {
    const gpa = std.testing.allocator;
    var parsed = try parseTestCommand(.cat, &.{
        "--raw", "--plain", "--head", "10", "--tail=3", "--head=1", "--", "-recording",
    });
    defer parsed.deinit(gpa);
    const request = catRequest(&parsed, true);
    try std.testing.expect(!request.as_written);
    try std.testing.expectEqual(@as(usize, 1), request.window.head);
    try std.testing.expectEqualStrings("-recording", request.refs[0]);

    try std.testing.expectError(error.ReportedCliError, parseTestCommand(.cat, &.{ "--head", "bad", "@1" }));
}

/// Applies a line window without retaining bytes that cannot be returned.
/// Tail storage is proportional to the requested final lines, not the file.
const WindowSink = struct {
    gpa: std.mem.Allocator,
    window: Window,
    out: *Io.Writer,
    tail: std.ArrayList(u8) = .empty,
    tail_lines: usize = 0,
    head_newlines: usize = 0,
    total_newlines: u64 = 0,
    total_any: bool = false,
    total_ends_newline: bool = false,

    fn init(gpa: std.mem.Allocator, window: Window, out: *Io.Writer) WindowSink {
        return .{ .gpa = gpa, .window = window, .out = out };
    }

    fn deinit(self: *WindowSink) void {
        self.tail.deinit(self.gpa);
    }

    pub fn writeAll(self: *WindowSink, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        self.total_any = true;
        self.total_ends_newline = bytes[bytes.len - 1] == '\n';
        self.total_newlines = std.math.add(
            u64,
            self.total_newlines,
            @as(u64, @intCast(std.mem.count(u8, bytes, "\n"))),
        ) catch return error.ResourceTooLarge;

        switch (self.window) {
            .all => try self.out.writeAll(bytes),
            .head => |n| try self.writeHead(n, bytes),
            .tail => |n| try self.writeTail(n, bytes),
        }
    }

    fn writeHead(self: *WindowSink, n: usize, bytes: []const u8) !void {
        if (n == 0 or self.head_newlines >= n) return;

        var end = bytes.len;
        var offset: usize = 0;
        while (std.mem.indexOfScalar(u8, bytes[offset..], '\n')) |relative| {
            const newline = offset + relative;
            self.head_newlines += 1;
            if (self.head_newlines == n) {
                end = newline + 1;
                break;
            }
            offset = newline + 1;
        }
        try self.out.writeAll(bytes[0..end]);
    }

    fn writeTail(self: *WindowSink, n: usize, bytes: []const u8) !void {
        if (n == 0) return;
        for (bytes) |byte| {
            if (self.tail.items.len == 0) {
                self.tail_lines = 1;
            } else if (self.tail.items[self.tail.items.len - 1] == '\n') {
                if (self.tail_lines == n) self.dropFirstTailLine();
                self.tail_lines += 1;
            }
            try self.tail.append(self.gpa, byte);
        }
    }

    fn dropFirstTailLine(self: *WindowSink) void {
        const cut = (std.mem.indexOfScalar(u8, self.tail.items, '\n') orelse unreachable) + 1;
        const remaining = self.tail.items.len - cut;
        std.mem.copyForwards(u8, self.tail.items[0..remaining], self.tail.items[cut..]);
        self.tail.items.len = remaining;
        self.tail_lines -= 1;
    }

    fn finish(self: *WindowSink) !void {
        if (self.window == .tail) try self.out.writeAll(self.tail.items);
    }

    fn totalLines(self: *const WindowSink) u64 {
        return self.total_newlines + @intFromBool(self.total_any and !self.total_ends_newline);
    }

    fn shownLines(self: *const WindowSink) u64 {
        return switch (self.window) {
            .all => self.totalLines(),
            .head => |n| @min(self.totalLines(), @as(u64, @intCast(n))),
            .tail => |n| @min(self.totalLines(), @as(u64, @intCast(n))),
        };
    }
};

fn note(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
    sys.writeAll(2, text) catch {};
}

fn applyWindow(gpa: std.mem.Allocator, window: Window, text: []const u8, chunk_size: usize) !struct {
    bytes: []u8,
    shown_lines: u64,
    total_lines: u64,
} {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(gpa);
    var writer = Io.Writer.Allocating.fromArrayList(gpa, &result);
    defer result = writer.toArrayList();
    var sink = WindowSink.init(gpa, window, &writer.writer);
    defer sink.deinit();

    var offset: usize = 0;
    while (offset < text.len) {
        const end = @min(offset + chunk_size, text.len);
        try sink.writeAll(text[offset..end]);
        offset = end;
    }
    try sink.finish();
    return .{
        .bytes = try writer.toOwnedSlice(),
        .shown_lines = sink.shownLines(),
        .total_lines = sink.totalLines(),
    };
}

test "streaming windows keep whole lines across chunk boundaries" {
    const gpa = std.testing.allocator;
    const cases = [_]struct {
        window: Window,
        input: []const u8,
        expected: []const u8,
        shown: u64,
        total: u64,
    }{
        .{ .window = .all, .input = "one\ntwo\nthree\n", .expected = "one\ntwo\nthree\n", .shown = 3, .total = 3 },
        .{ .window = .{ .head = 2 }, .input = "one\ntwo\nthree\n", .expected = "one\ntwo\n", .shown = 2, .total = 3 },
        .{ .window = .{ .tail = 2 }, .input = "one\ntwo\nthree\n", .expected = "two\nthree\n", .shown = 2, .total = 3 },
        .{ .window = .{ .head = 0 }, .input = "one\ntwo", .expected = "", .shown = 0, .total = 2 },
        .{ .window = .{ .tail = 0 }, .input = "one\ntwo", .expected = "", .shown = 0, .total = 2 },
        .{ .window = .{ .head = 1 }, .input = "one\ntwo", .expected = "one\n", .shown = 1, .total = 2 },
        .{ .window = .{ .tail = 1 }, .input = "one\ntwo", .expected = "two", .shown = 1, .total = 2 },
        .{ .window = .{ .tail = 2 }, .input = "one\ntwo", .expected = "one\ntwo", .shown = 2, .total = 2 },
        .{ .window = .{ .tail = 2 }, .input = "", .expected = "", .shown = 0, .total = 0 },
    };

    for (cases) |case| {
        for ([_]usize{ 1, 2, 3, 64 }) |chunk_size| {
            const result = try applyWindow(gpa, case.window, case.input, chunk_size);
            defer gpa.free(result.bytes);
            try std.testing.expectEqualStrings(case.expected, result.bytes);
            try std.testing.expectEqual(case.shown, result.shown_lines);
            try std.testing.expectEqual(case.total, result.total_lines);
        }
    }
}

/// Accepts a reference or a path to the same thing.
///
/// Inside a journal writer, shorthand `@42/out` becomes canonical
/// `~[@42]/out`, which zsh expands to a path before tj executes. Insisting on a
/// reference would therefore make `tj cat @42` work everywhere except the
/// place it is most likely to be typed. Outside a writer there is no named
/// directory expansion and the reference is resolved here instead. Either way
/// it ends at the same open file.
fn openTarget(gpa: std.mem.Allocator, io: Io, root: store.Dir, text: []const u8) !Io.File {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var path: []const u8 = text;
    var owned: ?[]const u8 = null;
    defer if (owned) |value| gpa.free(value);

    if (reference.parse(text)) |parsed| {
        const found = try store.locate(gpa, io, root, sys.env("TJ_JOURNAL"), parsed);
        defer found.deinit(gpa);
        if (!found.exists) return error.NoSuchInteraction;
        owned = try gpa.dupe(u8, found.path);
        path = owned.?;
    } else |err| switch (err) {
        // Shaped like a reference but wrong: worth saying so rather than
        // trying it as a filename.
        error.Malformed => return error.BadReference,
        error.NotAReference => {},
    }

    // Naming the interaction rather than a resource means its output, whether
    // that came from `@42` or from the path `~[@42]` expanded to.
    if (isDirectory(io, path)) {
        path = std.fmt.bufPrint(&path_buf, "{s}/out", .{path}) catch return error.BadReference;
    }

    return store.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => error.NoSuchResource,
        else => |other| other,
    };
}

fn isDirectory(io: Io, path: []const u8) bool {
    var dir = store.Dir.cwd().openDir(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

// --- replaying a journal -----------------------------------------------------

const ReplayRequest = struct {
    replay: replay_engine.Options,
    wanted: ?[]const u8,
};

fn replayRequest(parsed: *const zecli.Parsed) !ReplayRequest {
    var request: ReplayRequest = .{ .replay = .{}, .wanted = null };
    if (parsed.last("typing")) |text| request.replay.typing_ms = parseReplayMillis(text) catch return error.BadReplayOption;
    if (parsed.last("max-pause")) |text| request.replay.max_pause_ms = parseReplayMillis(text) catch return error.BadReplayOption;
    if (parsed.last("from")) |text| request.replay.from = parseReplayNumber(text) catch return error.BadReplayOption;
    if (parsed.last("to")) |text| request.replay.to = parseReplayNumber(text) catch return error.BadReplayOption;
    if (parsed.present("prompt")) {
        request.replay.prompt = parsed.last("prompt") orelse return error.BadReplayOption;
        request.replay.use_recorded_prompt = false;
    }
    if (parsed.last("speed")) |text| request.replay.speed = parseReplaySpeed(text) catch return error.BadReplayOption;
    request.replay.duration_only = parsed.present("duration");
    if (parsed.positionals.items.len == 1) request.wanted = parsed.positionals.items[0];
    return request;
}

fn replayRequestFromArgs(args: []const [:0]const u8) !ReplayRequest {
    var parsed = try parseTestCommand(.replay, args);
    defer parsed.deinit(std.testing.allocator);
    return replayRequest(&parsed);
}

/// `tj replay <journal>` - play a recording back into the terminal.
///
/// Nothing is re-executed: this is the output that was captured, escape
/// sequences and all, so it looks the way it looked. What cannot be
/// reconstructed is when each byte arrived, since only the start and end of
/// each interaction were recorded - so output appears at once, and the pacing
/// comes from the real durations and the real gaps between commands.
fn replayJournal(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    parsed: *const zecli.Parsed,
    out: *Io.Writer,
) !void {
    const request = try replayRequest(parsed);
    const replay = request.replay;
    const wanted = request.wanted;

    // Replaying inside a live journal writer would feed the recording back
    // into the journal: the replayed shell-integration markers read as real command
    // boundaries, which truncates the recording of the replay itself and
    // pins the replayed exit status onto it. Asking for the duration prints
    // no recording, so it stays allowed - `tj-tape` needs it.
    if (!replay.duration_only and sys.env("TJ_JOURNAL") != null) return error.InsideJournal;

    var root = try store.openRoot(io, home);
    defer root.close(io);

    // A suffix works here as it does anywhere else a journal is named. With
    // no journal named, the most recent one: there is no current journal to
    // fall back on, since replay only runs outside one.
    var owned: ?[]u8 = null;
    defer if (owned) |name| gpa.free(name);

    const journal: []const u8 = if (wanted) |name| blk: {
        owned = try store.findNewestJournal(gpa, io, root, name) orelse return error.NoSuchJournal;
        break :blk owned.?;
    } else blk: {
        const journals = try store.listJournals(gpa, io, root);
        defer {
            for (journals) |name| gpa.free(name);
            gpa.free(journals);
        }
        if (journals.len == 0) return error.NothingRecorded;
        owned = try gpa.dupe(u8, journals[0]);
        break :blk owned.?;
    };

    try replay_engine.play(gpa, io, root, journal, replay, out);
}

fn parseReplayNumber(text: []const u8) !u32 {
    const number = std.fmt.parseInt(u32, text, 10) catch return error.BadReplayOption;
    if (number == 0) return error.BadReplayOption;
    return number;
}

fn parseReplayMillis(text: []const u8) !u64 {
    return std.fmt.parseInt(u64, text, 10) catch error.BadReplayOption;
}

fn parseReplaySpeed(text: []const u8) !f64 {
    const speed = std.fmt.parseFloat(f64, text) catch return error.BadReplayOption;
    if (!std.math.isFinite(speed) or speed <= 0) return error.BadReplayOption;
    return speed;
}

test "replay entry ranges parse directly into u32" {
    const minimum = try replayRequestFromArgs(&.{ "--from", "1", "--to=4294967295" });
    try std.testing.expectEqual(@as(u32, 1), minimum.replay.from);
    try std.testing.expectEqual(std.math.maxInt(u32), minimum.replay.to);

    try std.testing.expectError(error.BadReplayOption, replayRequestFromArgs(&.{ "--from", "0" }));
    try std.testing.expectError(error.BadReplayOption, replayRequestFromArgs(&.{"--to=4294967296"}));
}

test "replay accepts only finite positive speeds" {
    for ([_][]const u8{ "0.5", "1", "2" }) |text| {
        const speed = try parseReplaySpeed(text);
        try std.testing.expect(speed > 0);
        try std.testing.expect(std.math.isFinite(speed));
    }

    for ([_][]const u8{ "nan", "inf", "-inf", "0", "-1" }) |text| {
        try std.testing.expectError(error.BadReplayOption, parseReplaySpeed(text));
    }
}

test "replay millisecond options use their final u64 type" {
    const parsed = try replayRequestFromArgs(&.{ "--typing=18446744073709551615", "--max-pause", "0" });
    try std.testing.expectEqual(std.math.maxInt(u64), parsed.replay.typing_ms);
    try std.testing.expectEqual(@as(u64, 0), parsed.replay.max_pause_ms);
    try std.testing.expectError(
        error.BadReplayOption,
        replayRequestFromArgs(&.{ "--typing", "18446744073709551616" }),
    );
}

test "replay rejects more than one journal name" {
    try std.testing.expectError(error.ReportedCliError, replayRequestFromArgs(&.{ "first", "second" }));
}
