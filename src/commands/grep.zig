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
const presentation = @import("../presentation/entry.zig");

pub fn grepRequestFromArgs(args: []const [:0]const u8) !GrepRequest {
    var parsed = try cmd_context.parseTestCommand(.grep, args);
    defer parsed.deinit(std.testing.allocator);
    return grepRequest(&parsed);
}

pub const ColorWhen = enum { never, auto, always };

pub const GrepRequest = struct {
    all: bool = false,
    numbers: bool = false,
    commands: bool = true,
    output: bool = true,
    ignore_case: bool = false,
    color: ColorWhen = .never,
    pattern: []const u8 = "",
};

pub const GrepStats = struct {
    number_lists: std.atomic.Value(usize) = .init(0),
    entry_opens: std.atomic.Value(usize) = .init(0),
    resource_opens: std.atomic.Value(usize) = .init(0),
    rc_probes: std.atomic.Value(usize) = .init(0),
    pin_probes: std.atomic.Value(usize) = .init(0),
    out_length_probes: std.atomic.Value(usize) = .init(0),
    live_jobs: std.atomic.Value(usize) = .init(0),
    max_lock: std.atomic.Mutex = .unlocked,
    max_live_jobs: usize = 0,
    search: search.Stats = .{},

    fn add(counter: *std.atomic.Value(usize)) void {
        _ = counter.fetchAdd(1, .monotonic);
    }

    fn jobStart(self: *GrepStats) void {
        const live = self.live_jobs.fetchAdd(1, .monotonic) + 1;
        while (!self.max_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.max_lock.unlock();
        self.max_live_jobs = @max(self.max_live_jobs, live);
    }

    fn jobEnd(self: *GrepStats) void {
        _ = self.live_jobs.fetchSub(1, .monotonic);
    }
};

pub const GrepStatsSnapshot = struct {
    number_lists: usize,
    entry_opens: usize,
    resource_opens: usize,
    rc_probes: usize,
    pin_probes: usize,
    out_length_probes: usize,
    bytes_read: u64,
    read_calls: usize,
    max_live_jobs: usize,
};

pub fn grepStatsSnapshot(stats: *const GrepStats) GrepStatsSnapshot {
    return .{
        .number_lists = stats.number_lists.load(.monotonic),
        .entry_opens = stats.entry_opens.load(.monotonic),
        .resource_opens = stats.resource_opens.load(.monotonic),
        .rc_probes = stats.rc_probes.load(.monotonic),
        .pin_probes = stats.pin_probes.load(.monotonic),
        .out_length_probes = stats.out_length_probes.load(.monotonic),
        .bytes_read = stats.search.bytes.load(.monotonic),
        .read_calls = stats.search.calls.load(.monotonic),
        .max_live_jobs = stats.max_live_jobs,
    };
}

pub fn grepRequest(parsed: *const zecli.Parsed) !GrepRequest {
    var request: GrepRequest = .{
        .all = parsed.enabled("all"),
        .numbers = parsed.enabled("numbers"),
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
    stats: ?*GrepStats = null,
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
    entry_dir: ?*store.Dir = null,
    metadata_loaded: bool = true,

    fn loadMetadata(self: *GrepLineSink) !void {
        if (self.metadata_loaded) return;
        const entry_dir = self.entry_dir orelse return error.InvalidState;
        if (self.output.stats) |stats| GrepStats.add(&stats.pin_probes);
        self.pinned = try pins.isPinnedInEntry(self.output.io, entry_dir.*);
        if (self.output.stats) |stats| GrepStats.add(&stats.rc_probes);
        self.exit_code = store.entryExitCode(self.output.io, entry_dir.*);
        self.metadata_loaded = true;
    }

    pub fn emit(context: *anyopaque, file: Io.File, start: u64, end: u64) !void {
        const self: *GrepLineSink = @ptrCast(@alignCast(context));
        try self.loadMetadata();
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
        var display_end = original_end;
        if (display_end > start) {
            var last: [1]u8 = undefined;
            const n = try file.readPositional(self.output.io, &.{last[0..]}, display_end - 1);
            if (n == 1 and last[0] == '\r') display_end -= 1;
        }

        var window: GrepWindow = .{ .start = start, .end = display_end };
        if (budget) |width| {
            if (display_end - start > width) {
                // Match the original interval before presentation removes a
                // trailing CR. A pattern that includes only that CR has no
                // visible bytes, so anchor its clipping window at line end.
                const raw_match = (try search.firstMatchSpan(
                    self.output.io,
                    file,
                    start,
                    original_end,
                    self.matcher,
                )) orelse
                    return error.UnexpectedEndOfFile;
                const match = search.MatchSpan{
                    .start = @min(raw_match.start, display_end),
                    .end = @min(raw_match.end, display_end),
                };
                window = grepWindow(start, display_end, match.start, match.end, width);
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

fn grepReferenceWidth(journals: []const JournalEntries, qualified: bool) usize {
    var width: usize = 1;
    for (journals) |journal| {
        const highest = if (journal.numbers.len == 0) continue else journal.numbers[journal.numbers.len - 1];
        const number_width = report.decimalWidth(highest);
        const candidate = if (qualified)
            1 + journal.name.len + 1 + number_width
        else
            number_width;
        width = @max(width, candidate);
    }
    return width;
}

const JournalEntries = struct {
    name: []const u8,
    numbers: []u32,
};

fn listGrepNumbers(
    gpa: std.mem.Allocator,
    io: Io,
    root: store.Dir,
    journal: []const u8,
    stats: ?*GrepStats,
) ![]u32 {
    if (stats) |value| GrepStats.add(&value.number_lists);
    return store.listNumbers(gpa, io, root, journal);
}

pub fn grepCommand(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    parsed: *const zecli.Parsed,
    out: *Io.Writer,
) !u8 {
    const request = try grepRequest(parsed);

    if (request.numbers and (request.all or parsed.present("color"))) return error.BadArguments;

    const current = sys.env("TJ_JOURNAL");
    if (!request.all and (current == null or current.?.len == 0)) {
        if (request.numbers) {
            cmd_context.note(io, "tj grep --numbers: no current journal\n", .{});
        } else {
            cmd_context.note(io, "tj grep: no current journal; use --all\n", .{});
        }
        return 2;
    }

    var root = try store.openRoot(io, home);
    defer root.close(io);
    var matcher = try search.Matcher.init(gpa, request.pattern, request.ignore_case);
    defer matcher.deinit();
    const active = cmd_context.activeInteraction();

    if (request.numbers) {
        var numbers: std.ArrayList(u32) = .empty;
        defer numbers.deinit(gpa);
        const entries = try listGrepNumbers(gpa, io, root, current.?, null);
        defer gpa.free(entries);
        try collectMatchingEntries(gpa, io, root, current.?, entries, request, active, &matcher, &numbers);
        if (numbers.items.len == 0) return 1;
        var noout_region: report.NooutRegion = .{
            .out = out,
            .enabled = sys.isTty(io, 1),
        };
        defer noout_region.finish();
        try noout_region.begin();
        for (numbers.items, 0..) |number, index| {
            if (index != 0) try out.writeByte(' ');
            try out.print("{d}", .{number});
        }
        try out.writeByte('\n');
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
        var entries: std.ArrayList(JournalEntries) = .empty;
        defer {
            for (entries.items) |item| gpa.free(item.numbers);
            entries.deinit(gpa);
        }
        for (journals) |journal| {
            const numbers = listGrepNumbers(gpa, io, root, journal, null) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => |other| return other,
            };
            errdefer gpa.free(numbers);
            try entries.append(gpa, .{ .name = journal, .numbers = numbers });
        }
        output.reference_width = grepReferenceWidth(entries.items, true);
        for (entries.items) |journal| {
            try grepJournal(gpa, io, root, journal.name, journal.numbers, request, active, &matcher, &output, &total, null);
        }
    } else {
        const numbers = listGrepNumbers(gpa, io, root, current.?, null) catch |err| switch (err) {
            error.FileNotFound => return error.NoSuchJournal,
            else => |other| return other,
        };
        defer gpa.free(numbers);
        output.reference_width = grepReferenceWidth(&.{.{ .name = current.?, .numbers = numbers }}, false);
        try grepJournal(gpa, io, root, current.?, numbers, request, active, &matcher, &output, &total, null);
    }
    return if (total == 0) 1 else 0;
}

const MatchingEntryVisitor = struct {
    gpa: std.mem.Allocator,
    numbers: *std.ArrayList(u32),
    stats: ?*GrepStats,

    fn beginEntry(
        _: *MatchingEntryVisitor,
        _: []const u8,
        _: u32,
        _: *store.Dir,
    ) !void {}

    fn beginResource(
        _: *MatchingEntryVisitor,
        _: []const u8,
        _: *const search.Matcher,
    ) !void {}

    fn scan(self: *MatchingEntryVisitor, io: Io, file: Io.File, matcher: *const search.Matcher) !u64 {
        return if (try search.fileContainsMeasured(
            io,
            file,
            matcher,
            if (self.stats) |stats| &stats.search else null,
        )) 1 else 0;
    }

    fn endResource(self: *MatchingEntryVisitor, number: u32, found: u64) !bool {
        if (found == 0) return false;
        try self.numbers.append(self.gpa, number);
        return true;
    }
};

// Four workers retained the large-resource speedup without the intermittent
// tiny-file contention measured at eight workers.
const max_grep_workers = 4;
const parallel_entry_threshold = 64;

fn grepWorkerCount(entry_count: usize, forced: ?usize) usize {
    if (entry_count == 0) return 1;
    if (forced) |count| return @max(1, @min(count, @min(max_grep_workers, entry_count)));
    if (entry_count < parallel_entry_threshold) return 1;
    const cpu_count = std.Thread.getCpuCount() catch return 1;
    return @max(1, @min(cpu_count, @min(max_grep_workers, entry_count)));
}

fn entryContains(
    io: Io,
    journal_dir: store.Dir,
    number: u32,
    request: GrepRequest,
    matcher: *const search.Matcher,
    stats: ?*GrepStats,
) !bool {
    var number_buf: [16]u8 = undefined;
    const entry_name = try std.fmt.bufPrint(&number_buf, "{d}", .{number});
    var entry_dir = journal_dir.openDir(io, entry_name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return false,
        else => |other| return other,
    };
    defer entry_dir.close(io);
    if (stats) |value| GrepStats.add(&value.entry_opens);
    for ([_]struct { enabled: bool, name: []const u8 }{
        .{ .enabled = request.commands, .name = "cmd" },
        .{ .enabled = request.output, .name = "out" },
    }) |resource| {
        if (!resource.enabled) continue;
        var file = entry_dir.openFile(io, resource.name, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => |other| return other,
        };
        defer file.close(io);
        if (stats) |value| GrepStats.add(&value.resource_opens);
        if (try search.fileContainsMeasured(
            io,
            file,
            matcher,
            if (stats) |value| &value.search else null,
        )) return true;
    }
    return false;
}

const ParallelNumbers = struct {
    io: Io,
    root: store.Dir,
    journal: []const u8,
    numbers: []const u32,
    request: GrepRequest,
    active: ?cmd_context.ActiveInteraction,
    matcher: *const search.Matcher,
    matched: []bool,
    next: std.atomic.Value(usize) = .init(0),
    start: std.atomic.Value(bool) = .init(false),
    abort: std.atomic.Value(bool) = .init(false),
    error_lock: std.atomic.Mutex = .unlocked,
    first_error: ?anyerror = null,
    stats: ?*GrepStats,

    fn setError(self: *ParallelNumbers, err: anyerror) void {
        while (!self.error_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.error_lock.unlock();
        if (self.first_error == null) self.first_error = err;
        self.abort.store(true, .release);
    }

    fn worker(self: *ParallelNumbers) void {
        while (!self.start.load(.acquire)) std.atomic.spinLoopHint();
        if (self.abort.load(.acquire)) return;
        var journal_dir = self.root.openDir(self.io, self.journal, .{ .follow_symlinks = false }) catch |err| {
            self.setError(err);
            return;
        };
        defer journal_dir.close(self.io);
        while (!self.abort.load(.acquire)) {
            const index = self.next.fetchAdd(1, .monotonic);
            if (index >= self.numbers.len) return;
            const number = self.numbers[index];
            if (self.active) |item| {
                if (item.number == number and std.mem.eql(u8, item.journal, self.journal)) continue;
            }
            if (self.stats) |stats| stats.jobStart();
            defer if (self.stats) |stats| stats.jobEnd();
            self.matched[index] = entryContains(self.io, journal_dir, number, self.request, self.matcher, self.stats) catch |err| {
                self.setError(err);
                return;
            };
        }
    }
};

fn collectMatchingEntriesParallel(
    gpa: std.mem.Allocator,
    io: Io,
    root: store.Dir,
    journal: []const u8,
    entry_numbers: []const u32,
    request: GrepRequest,
    active: ?cmd_context.ActiveInteraction,
    matcher: *const search.Matcher,
    numbers: *std.ArrayList(u32),
    forced_workers: ?usize,
    stats: ?*GrepStats,
) !void {
    const worker_count = grepWorkerCount(entry_numbers.len, forced_workers);
    if (worker_count == 1) {
        return collectMatchingEntriesSerial(gpa, io, root, journal, entry_numbers, request, active, matcher, numbers, stats);
    }
    const matched = try gpa.alloc(bool, entry_numbers.len);
    defer gpa.free(matched);
    @memset(matched, false);
    var state: ParallelNumbers = .{
        .io = io,
        .root = root,
        .journal = journal,
        .numbers = entry_numbers,
        .request = request,
        .active = active,
        .matcher = matcher,
        .matched = matched,
        .stats = stats,
    };
    var threads: [max_grep_workers]std.Thread = undefined;
    var spawned: usize = 0;
    while (spawned < worker_count) : (spawned += 1) {
        threads[spawned] = std.Thread.spawn(.{}, ParallelNumbers.worker, .{&state}) catch {
            state.abort.store(true, .release);
            state.start.store(true, .release);
            for (threads[0..spawned]) |thread| thread.join();
            return collectMatchingEntriesSerial(gpa, io, root, journal, entry_numbers, request, active, matcher, numbers, stats);
        };
    }
    state.start.store(true, .release);
    for (threads[0..spawned]) |thread| thread.join();
    if (state.first_error) |err| return err;
    for (entry_numbers, matched) |number, found| if (found) try numbers.append(gpa, number);
}

const FormattedMatchVisitor = struct {
    output: *GrepOutput,
    qualified: bool,
    total: *u64,
    line_sink: GrepLineSink = undefined,
    stats: ?*GrepStats,

    fn beginEntry(
        self: *FormattedMatchVisitor,
        journal: []const u8,
        number: u32,
        entry_dir: *store.Dir,
    ) !void {
        self.line_sink = .{
            .output = self.output,
            .journal = journal,
            .number = number,
            .resource = undefined,
            .qualified = self.qualified,
            .matcher = undefined,
            .pinned = false,
            .exit_code = null,
            .entry_dir = entry_dir,
            .metadata_loaded = false,
        };
    }

    fn beginResource(
        self: *FormattedMatchVisitor,
        resource: []const u8,
        matcher: *const search.Matcher,
    ) !void {
        self.line_sink.resource = resource;
        self.line_sink.matcher = matcher;
    }

    fn sink(self: *FormattedMatchVisitor) search.Sink {
        return .{ .context = &self.line_sink, .emit = GrepLineSink.emit };
    }

    fn scan(self: *FormattedMatchVisitor, io: Io, file: Io.File, matcher: *const search.Matcher) !u64 {
        return search.scanFileMeasured(
            io,
            file,
            matcher,
            self.sink(),
            if (self.stats) |stats| &stats.search else null,
        );
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
    numbers: []const u32,
    request: GrepRequest,
    active: ?cmd_context.ActiveInteraction,
    matcher: *const search.Matcher,
    visitor: anytype,
    stats: ?*GrepStats,
) !void {
    _ = gpa;
    var journal_dir = root.openDir(io, journal, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return error.NoSuchJournal,
        else => |other| return other,
    };
    defer journal_dir.close(io);

    for (numbers) |number| {
        if (active) |item| {
            if (item.number == number and std.mem.eql(u8, item.journal, journal)) continue;
        }
        var number_buf: [16]u8 = undefined;
        const entry_name = try std.fmt.bufPrint(&number_buf, "{d}", .{number});
        var entry_dir = journal_dir.openDir(io, entry_name, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => continue,
            else => |other| return other,
        };
        defer entry_dir.close(io);
        if (stats) |value| GrepStats.add(&value.entry_opens);
        try visitor.beginEntry(journal, number, &entry_dir);
        for ([_]struct { enabled: bool, name: []const u8 }{
            .{ .enabled = request.commands, .name = "cmd" },
            .{ .enabled = request.output, .name = "out" },
        }) |resource| {
            if (!resource.enabled) continue;
            var file = entry_dir.openFile(io, resource.name, .{}) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => |other| return other,
            };
            defer file.close(io);
            if (stats) |value| GrepStats.add(&value.resource_opens);

            try visitor.beginResource(resource.name, matcher);
            const found = try visitor.scan(io, file, matcher);
            if (try visitor.endResource(number, found)) break;
        }
    }
}

fn collectMatchingEntries(
    gpa: std.mem.Allocator,
    io: Io,
    root: store.Dir,
    journal: []const u8,
    entry_numbers: []const u32,
    request: GrepRequest,
    active: ?cmd_context.ActiveInteraction,
    matcher: *const search.Matcher,
    numbers: *std.ArrayList(u32),
) !void {
    return collectMatchingEntriesParallel(
        gpa,
        io,
        root,
        journal,
        entry_numbers,
        request,
        active,
        matcher,
        numbers,
        null,
        null,
    );
}

fn collectMatchingEntriesSerial(
    gpa: std.mem.Allocator,
    io: Io,
    root: store.Dir,
    journal: []const u8,
    entry_numbers: []const u32,
    request: GrepRequest,
    active: ?cmd_context.ActiveInteraction,
    matcher: *const search.Matcher,
    numbers: *std.ArrayList(u32),
    stats: ?*GrepStats,
) !void {
    var visitor: MatchingEntryVisitor = .{
        .gpa = gpa,
        .numbers = numbers,
        .stats = stats,
    };
    try traverseGrepJournal(gpa, io, root, journal, entry_numbers, request, active, matcher, &visitor, stats);
}

test "grep worker selection stays serial for small inputs and respects its cap" {
    try std.testing.expectEqual(@as(usize, 1), grepWorkerCount(0, null));
    try std.testing.expectEqual(@as(usize, 1), grepWorkerCount(parallel_entry_threshold - 1, null));
    try std.testing.expectEqual(@as(usize, 1), grepWorkerCount(100, 1));
    try std.testing.expectEqual(@as(usize, 2), grepWorkerCount(100, 2));
    try std.testing.expectEqual(@as(usize, max_grep_workers), grepWorkerCount(100, max_grep_workers + 10));
}

test "parallel number collection matches serial order and active exclusion" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "work");
    var listed: std.ArrayList(u32) = .empty;
    defer listed.deinit(gpa);
    for (1..97) |raw_number| {
        const number: u32 = @intCast(raw_number);
        try listed.append(gpa, number);
        var path_buf: [32]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "work/{d}", .{number});
        try tmp.dir.createDirPath(io, path);
        if (number % 3 == 0) {
            var resource_buf: [40]u8 = undefined;
            const resource = try std.fmt.bufPrint(&resource_buf, "{s}/out", .{path});
            const file = try tmp.dir.createFile(io, resource, .{});
            defer file.close(io);
            try file.writeStreamingAll(io, "needle\n");
        }
        if (number % 5 == 0) {
            var resource_buf: [40]u8 = undefined;
            const resource = try std.fmt.bufPrint(&resource_buf, "{s}/cmd", .{path});
            const file = try tmp.dir.createFile(io, resource, .{});
            defer file.close(io);
            try file.writeStreamingAll(io, "Needle in command\n");
        }
    }
    const active = cmd_context.ActiveInteraction{ .journal = "work", .number = 96 };
    for ([_]bool{ false, true }) |ignore_case| {
        var matcher = try search.Matcher.init(gpa, if (ignore_case) "NEEDLE" else "needle", ignore_case);
        defer matcher.deinit();
        const request: GrepRequest = .{
            .commands = true,
            .output = true,
            .ignore_case = ignore_case,
            .pattern = if (ignore_case) "NEEDLE" else "needle",
        };
        var serial: std.ArrayList(u32) = .empty;
        defer serial.deinit(gpa);
        try collectMatchingEntriesParallel(
            gpa,
            io,
            tmp.dir,
            "work",
            listed.items,
            request,
            active,
            &matcher,
            &serial,
            1,
            null,
        );
        for ([_]usize{ 2, max_grep_workers, max_grep_workers + 1 }) |workers| {
            var parallel: std.ArrayList(u32) = .empty;
            defer parallel.deinit(gpa);
            var stats: GrepStats = .{};
            try collectMatchingEntriesParallel(
                gpa,
                io,
                tmp.dir,
                "work",
                listed.items,
                request,
                active,
                &matcher,
                &parallel,
                workers,
                &stats,
            );
            try std.testing.expectEqualSlices(u32, serial.items, parallel.items);
            const snapshot = grepStatsSnapshot(&stats);
            try std.testing.expect(snapshot.max_live_jobs <= @min(workers, max_grep_workers));
            try std.testing.expect(snapshot.max_live_jobs > 0);
            try std.testing.expect(snapshot.resource_opens <= snapshot.entry_opens * 2);
        }
        try std.testing.expectEqual(@as(u32, 3), serial.items[0]);
        try std.testing.expectEqual(@as(u32, if (ignore_case) 95 else 93), serial.items[serial.items.len - 1]);
    }

    for ([_]GrepRequest{
        .{ .commands = true, .output = false, .pattern = "needle" },
        .{ .commands = false, .output = true, .pattern = "needle" },
        .{ .commands = true, .output = true, .pattern = "absent" },
    }) |request| {
        var matcher = try search.Matcher.init(gpa, request.pattern, false);
        defer matcher.deinit();
        var serial: std.ArrayList(u32) = .empty;
        defer serial.deinit(gpa);
        try collectMatchingEntriesParallel(gpa, io, tmp.dir, "work", listed.items, request, null, &matcher, &serial, 1, null);
        var parallel: std.ArrayList(u32) = .empty;
        defer parallel.deinit(gpa);
        try collectMatchingEntriesParallel(gpa, io, tmp.dir, "work", listed.items, request, null, &matcher, &parallel, 2, null);
        try std.testing.expectEqualSlices(u32, serial.items, parallel.items);
    }
}

test "parallel number collection propagates resource open errors" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "work/1");
    try tmp.dir.createDirPath(io, "work/2");
    var entry = try tmp.dir.openDir(io, "work/1", .{});
    defer entry.close(io);
    try entry.symLink(io, "cmd", "cmd", .{});
    var matcher = try search.Matcher.init(gpa, "needle", false);
    defer matcher.deinit();
    var found: std.ArrayList(u32) = .empty;
    defer found.deinit(gpa);
    try std.testing.expectError(
        error.SymLinkLoop,
        collectMatchingEntriesParallel(
            gpa,
            io,
            tmp.dir,
            "work",
            &.{ 1, 2 },
            .{ .commands = true, .output = false, .pattern = "needle" },
            null,
            &matcher,
            &found,
            2,
            null,
        ),
    );
}

test "grep traversal defers metadata and lists journal numbers once" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for (1..3) |number| {
        var path_buf: [32]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "work/{d}", .{number});
        try tmp.dir.createDirPath(io, path);
        for ([_][]const u8{ "cmd", "out", "rc", "pin" }) |resource| {
            var resource_buf: [48]u8 = undefined;
            const resource_path = try std.fmt.bufPrint(&resource_buf, "{s}/{s}", .{ path, resource });
            const file = try tmp.dir.createFile(io, resource_path, .{});
            defer file.close(io);
            if (std.mem.eql(u8, resource, "cmd") or std.mem.eql(u8, resource, "out")) {
                try file.writeStreamingAll(io, if (number == 1) "needle\nneedle again\n" else "ordinary\n");
            } else if (std.mem.eql(u8, resource, "rc")) {
                try file.writeStreamingAll(io, "7\n");
            }
        }
    }
    var matcher = try search.Matcher.init(gpa, "needle", false);
    defer matcher.deinit();
    const request: GrepRequest = .{ .pattern = "needle" };

    var number_stats: GrepStats = .{};
    const listed = try listGrepNumbers(gpa, io, tmp.dir, "work", &number_stats);
    defer gpa.free(listed);
    var found: std.ArrayList(u32) = .empty;
    defer found.deinit(gpa);
    try collectMatchingEntriesParallel(
        gpa,
        io,
        tmp.dir,
        "work",
        listed,
        request,
        null,
        &matcher,
        &found,
        1,
        &number_stats,
    );
    const number_snapshot = grepStatsSnapshot(&number_stats);
    try std.testing.expectEqual(@as(usize, 1), number_snapshot.number_lists);
    try std.testing.expectEqual(@as(usize, 0), number_snapshot.rc_probes);
    try std.testing.expectEqual(@as(usize, 0), number_snapshot.pin_probes);
    try std.testing.expectEqual(@as(usize, 0), number_snapshot.out_length_probes);

    var discard_buffer: [256]u8 = undefined;
    var discard = Io.Writer.Discarding.init(&discard_buffer);
    var no_match_stats: GrepStats = .{};
    var absent = try search.Matcher.init(gpa, "absent", false);
    defer absent.deinit();
    var no_match_output: GrepOutput = .{
        .io = io,
        .out = &discard.writer,
        .noout_region = .{ .out = &discard.writer, .enabled = false },
        .match_sgr = "",
        .terminal_columns = null,
        .layout_color = false,
        .reference_width = 1,
        .stats = &no_match_stats,
    };
    var total: u64 = 0;
    try grepJournal(gpa, io, tmp.dir, "work", listed, request, null, &absent, &no_match_output, &total, &no_match_stats);
    const no_match_snapshot = grepStatsSnapshot(&no_match_stats);
    try std.testing.expectEqual(@as(usize, 0), no_match_snapshot.rc_probes);
    try std.testing.expectEqual(@as(usize, 0), no_match_snapshot.pin_probes);

    var match_stats: GrepStats = .{};
    var match_output = no_match_output;
    match_output.stats = &match_stats;
    total = 0;
    try grepJournal(gpa, io, tmp.dir, "work", listed, request, null, &matcher, &match_output, &total, &match_stats);
    const match_snapshot = grepStatsSnapshot(&match_stats);
    try std.testing.expectEqual(@as(u64, 4), total);
    try std.testing.expectEqual(@as(usize, 1), match_snapshot.rc_probes);
    try std.testing.expectEqual(@as(usize, 1), match_snapshot.pin_probes);
    try std.testing.expectEqual(@as(usize, 0), match_snapshot.out_length_probes);
}

pub fn grepJournal(
    gpa: std.mem.Allocator,
    io: Io,
    root: store.Dir,
    journal: []const u8,
    entry_numbers: []const u32,
    request: GrepRequest,
    active: ?cmd_context.ActiveInteraction,
    matcher: *const search.Matcher,
    output: *GrepOutput,
    total: *u64,
    stats: ?*GrepStats,
) !void {
    var visitor: FormattedMatchVisitor = .{
        .output = output,
        .qualified = request.all,
        .total = total,
        .stats = stats,
    };
    try traverseGrepJournal(gpa, io, root, journal, entry_numbers, request, active, matcher, &visitor, stats);
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
    try std.testing.expect((try grepRequestFromArgs(&.{ "x", "--numbers" })).numbers);
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
