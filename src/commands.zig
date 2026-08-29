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
const mutation_lock = @import("mutation_lock.zig");
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
    AnnotationBusy,
    AnnotationConstraint,
    InvalidAnnotationDatabase,
    LegacyAnnotationsUnsupported,
    AnnotationDatabaseFailure,
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
        .usage => try usageCommand(gpa, io, home, parsed, out),
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

/// Stored commands and output are untrusted terminal input. Strip terminal
/// controls before they reach a report while optionally normalizing horizontal
/// whitespace for grep. TJ's own SGR styling bypasses this writer.
const GrepNormalizeWriter = struct {
    downstream: *Io.Writer,
    interface: Io.Writer,
    collapse_whitespace: bool,
    seen_content: bool = false,
    pending_space: bool = false,
    escape: enum { normal, esc, csi, string, string_esc, charset } = .normal,
    utf8: [4]u8 = undefined,
    utf8_len: usize = 0,
    utf8_expected: usize = 0,

    fn init(downstream: *Io.Writer, collapse_whitespace: bool) GrepNormalizeWriter {
        return .{
            .downstream = downstream,
            .collapse_whitespace = collapse_whitespace,
            .interface = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },
        };
    }

    fn finish(self: *GrepNormalizeWriter) Io.Writer.Error!void {
        if (self.utf8_expected != 0) try self.emitReplacement();
        self.utf8_len = 0;
        self.utf8_expected = 0;
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
        if (self.utf8_expected != 0) return self.writeUtf8Continuation(byte);
        switch (self.escape) {
            .normal => {
                if (byte == 0x1b) {
                    self.escape = .esc;
                    return;
                }
                if (byte == ' ' or byte == '\t' or byte == '\r' or byte == 0x0b or byte == 0x0c) {
                    try self.writeWhitespace(byte);
                    return;
                }
                if (byte < 0x20 or byte == 0x7f) return;
                if (byte >= 0x80) {
                    try self.writeHighByte(byte);
                    return;
                }
                try self.emitVisible(&.{byte});
            },
            .esc => {
                self.escape = switch (byte) {
                    '[' => .csi,
                    ']', 'P', 'X', '^', '_' => .string,
                    '(', ')', '*', '+' => .charset,
                    else => .normal,
                };
            },
            .csi => {
                if (byte >= 0x40 and byte <= 0x7e) self.escape = .normal;
            },
            .string => {
                if (byte == 0x07 or byte == 0x9c) {
                    self.escape = .normal;
                } else if (byte == 0x1b) {
                    self.escape = .string_esc;
                }
            },
            .string_esc => {
                self.escape = if (byte == '\\') .normal else if (byte == 0x1b) .string_esc else .string;
            },
            .charset => self.escape = .normal,
        }
    }

    fn writeWhitespace(self: *GrepNormalizeWriter, byte: u8) Io.Writer.Error!void {
        if (self.collapse_whitespace) {
            if (self.seen_content) self.pending_space = true;
            return;
        }
        try self.downstream.writeByte(if (byte == ' ' or byte == '\t') byte else ' ');
        self.seen_content = true;
    }

    fn writeHighByte(self: *GrepNormalizeWriter, byte: u8) Io.Writer.Error!void {
        if (byte >= 0x80 and byte <= 0x9f) {
            self.escape = switch (byte) {
                0x90, 0x98, 0x9d, 0x9e, 0x9f => .string,
                0x9b => .csi,
                else => .normal,
            };
            return;
        }
        const expected: usize = std.unicode.utf8ByteSequenceLength(byte) catch {
            try self.emitReplacement();
            return;
        };
        self.utf8[0] = byte;
        self.utf8_len = 1;
        self.utf8_expected = expected;
    }

    fn writeUtf8Continuation(self: *GrepNormalizeWriter, byte: u8) Io.Writer.Error!void {
        if (byte < 0x80 or byte > 0xbf) {
            try self.emitReplacement();
            self.utf8_len = 0;
            self.utf8_expected = 0;
            return self.writeByte(byte);
        }
        self.utf8[self.utf8_len] = byte;
        self.utf8_len += 1;
        if (self.utf8_len != self.utf8_expected) return;

        const bytes = self.utf8[0..self.utf8_len];
        const codepoint = std.unicode.utf8Decode(bytes) catch {
            self.utf8_len = 0;
            self.utf8_expected = 0;
            try self.emitReplacement();
            return;
        };
        self.utf8_len = 0;
        self.utf8_expected = 0;
        if (codepoint >= 0x80 and codepoint <= 0x9f) return;
        try self.emitVisible(bytes);
    }

    fn emitVisible(self: *GrepNormalizeWriter, bytes: []const u8) Io.Writer.Error!void {
        if (self.pending_space) try self.downstream.writeByte(' ');
        self.pending_space = false;
        self.seen_content = true;
        try self.downstream.writeAll(bytes);
    }

    fn emitReplacement(self: *GrepNormalizeWriter) Io.Writer.Error!void {
        try self.emitVisible("\xef\xbf\xbd");
    }
};

fn sanitizeDisplayText(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(gpa);
    var downstream = Io.Writer.Allocating.fromArrayList(gpa, &bytes);
    defer bytes = downstream.toArrayList();
    var sanitized = GrepNormalizeWriter.init(&downstream.writer, false);
    try sanitized.interface.writeAll(text);
    try sanitized.finish();
    return downstream.toOwnedSlice();
}

const GrepWindow = struct {
    start: u64,
    end: u64,
    leading_ellipsis: bool = false,
    trailing_ellipsis: bool = false,
};

/// Selects a conservative byte window around a complete match. Raw bytes are
/// treated as cells, which can only under-fill the row for UTF-8, collapsed
/// whitespace, or terminal control sequences. The complete match has priority
/// when it alone is wider than the available content area.
fn grepWindow(
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

        const has_name = self.annotation != null and self.annotation.?.name != null;
        const has_tags = self.annotation != null and self.annotation.?.tags.items.len != 0;
        const has_failure = self.exit_code != null and self.exit_code.? != 0;

        var reference_buf: [64]u8 = undefined;
        const reference_text = if (self.qualified) blk: {
            const suffix = journalDisplaySuffix(self.journal);
            break :blk try std.fmt.bufPrint(&reference_buf, "@{s}.{d}", .{ suffix, self.number });
        } else try std.fmt.bufPrint(&reference_buf, "{d}", .{self.number});
        const prefix_width = 4 + 1 + self.output.reference_width + 1 + 1 + 1;
        try self.output.out.writeByte(if (self.annotation != null and self.annotation.?.pinned) '*' else ' ');
        try self.output.out.writeByte(if (has_name) '@' else ' ');
        try self.output.out.writeByte(if (has_tags) '#' else ' ');
        if (has_failure and self.output.layout_color) try self.output.out.writeAll("\x1b[31m");
        try self.output.out.writeByte(if (has_failure) '!' else ' ');
        if (has_failure and self.output.layout_color) try self.output.out.writeAll("\x1b[0m");
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
            const fixed_width = prefix_width + self.metadataWidth();
            const budget = if (columns > fixed_width) columns - fixed_width else 0;
            try self.writePayload(file, start, end, self.output.out, budget);
        } else {
            try self.writePayload(file, start, end, self.output.out, null);
        }
        try self.output.out.writeAll("\n");
    }

    fn writePayload(
        self: *GrepLineSink,
        file: Io.File,
        start: u64,
        original_end: u64,
        writer: *Io.Writer,
        budget: ?usize,
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
        var normalized = GrepNormalizeWriter.init(writer, true);
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
        try self.writeMetadata(writer);
    }

    fn metadataWidth(self: *const GrepLineSink) usize {
        const has_name = self.annotation != null and self.annotation.?.name != null;
        const has_tags = self.annotation != null and self.annotation.?.tags.items.len != 0;
        const has_failure = self.exit_code != null and self.exit_code.? != 0;
        if (!has_name and !has_tags and !has_failure) return 0;

        var width: usize = 1;
        if (has_name) width += 1 + self.annotation.?.name.?.len;
        if (has_tags) {
            for (self.annotation.?.tags.items, 0..) |tag, i| {
                if (has_name or i != 0) width += 1;
                width += 1 + tag.len;
            }
        }
        if (has_failure) {
            if (has_name or has_tags) width += 1;
            width += 1 + decimalWidth(self.exit_code.?);
        }
        return width;
    }

    fn writeMetadata(self: *const GrepLineSink, writer: *Io.Writer) !void {
        const has_name = self.annotation != null and self.annotation.?.name != null;
        const has_tags = self.annotation != null and self.annotation.?.tags.items.len != 0;
        const has_failure = self.exit_code != null and self.exit_code.? != 0;
        if (!has_name and !has_tags and !has_failure) return;
        try writer.writeByte(' ');

        if (has_name or has_tags) {
            if (self.output.layout_color) try writer.writeAll("\x1b[32m");
            if (has_name) try writer.print("@{s}", .{self.annotation.?.name.?});
            if (has_tags) {
                for (self.annotation.?.tags.items, 0..) |tag, i| {
                    if (has_name or i != 0) try writer.writeByte(' ');
                    try writer.writeByte('#');
                    try writer.writeAll(tag);
                }
            }
            if (self.output.layout_color) try writer.writeAll("\x1b[0m");
        }
        if (has_failure) {
            if (has_name or has_tags) try writer.writeByte(' ');
            if (self.output.layout_color) try writer.writeAll("\x1b[31m");
            try writer.print("!{d}", .{self.exit_code.?});
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
        .annotation = null,
        .exit_code = 0,
    };

    try GrepLineSink.emit(&sink, file, 0, text.len);
    try std.testing.expectEqualStrings("     1 < …89MATCHab…\n", writer.writer.buffered());
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
        var normalized = GrepNormalizeWriter.init(&downstream.writer, true);

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
    const sanitized = try sanitizeDisplayText(gpa, "echo\tbefore\x1b[2Jafter\rnext\x01");
    defer gpa.free(sanitized);
    try std.testing.expectEqualStrings("echo\tbeforeafter next", sanitized);
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
    const terminal_columns = if (sys.isTty(1)) historyTerminalColumns() else null;
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
    // Grep matches against the resource files directly, so it never needs an
    // entry's recorded command text in memory.
    var interactions = store.iterateInteractions(gpa, io, root, journal, store.no_command) catch |err| switch (err) {
        error.FileNotFound => return error.NoSuchJournal,
        else => |other| return other,
    };
    defer interactions.deinit();
    var metadata = try annotations.openRead(gpa, io, root, journal);
    defer metadata.deinit(gpa);
    var journal_annotations = try annotations.loadSet(gpa, &metadata);
    defer journal_annotations.deinit(gpa);

    while (try interactions.next()) |info| {
        defer info.deinit(gpa);
        if (active) |item| {
            if (item.number == info.number and std.mem.eql(u8, item.journal, journal)) continue;
        }
        const annotation = journal_annotations.get(info.number);
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
                .annotation = annotation,
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
    try std.testing.expectEqualStrings("33", selectedMatchSgr(null));
    try std.testing.expectEqualStrings("4;32", selectedMatchSgr("fn=35:mt=1;31:ms=4;32"));
    try std.testing.expectEqualStrings("", selectedMatchSgr("mt="));
    try std.testing.expectEqualStrings("33", selectedMatchSgr("mt=not-sgr"));
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
        const entries = store.countInteractions(gpa, io, root, name) catch continue;
        const marker = if (current != null and std.mem.eql(u8, current.?, name)) "*" else " ";
        try out.print("{s} {s}  {d} {s}\n", .{
            marker,
            name,
            entries,
            if (entries == 1) "entry" else "entries",
        });
    }
}

const HistoryJournal = struct {
    name: []u8,
    /// Entry numbers only. A listing reads one entry at a time, so a journal's
    /// recorded commands never all sit in memory at once.
    numbers: []u32,

    fn deinit(self: *HistoryJournal, gpa: std.mem.Allocator) void {
        gpa.free(self.numbers);
        gpa.free(self.name);
    }

    fn has(self: *const HistoryJournal, number: u32) bool {
        for (self.numbers) |candidate| {
            if (candidate == number) return true;
        }
        return false;
    }
};

/// What a command-line argument selected, kept as a rule rather than as an
/// expanded list of entries. The number of rules is bounded by argv; expanding
/// them into entries is done twice, lazily, by `HistoryCursor`.
const HistorySelection = struct {
    journal_index: usize,
    qualified: bool,
    what: union(enum) {
        whole,
        range: InteractionRange,
        single: u32,
    },
};

/// Walks every entry the selections name, in the order they were given.
const HistoryCursor = struct {
    journals: []const HistoryJournal,
    selections: []const HistorySelection,
    selection: usize = 0,
    index: usize = 0,

    const Item = struct {
        journal_index: usize,
        number: u32,
        qualified: bool,
    };

    fn next(self: *HistoryCursor) ?Item {
        while (self.selection < self.selections.len) {
            const selection = self.selections[self.selection];
            const journal = &self.journals[selection.journal_index];
            switch (selection.what) {
                .single => |number| {
                    self.selection += 1;
                    self.index = 0;
                    return .{
                        .journal_index = selection.journal_index,
                        .number = number,
                        .qualified = selection.qualified,
                    };
                },
                .whole, .range => {
                    while (self.index < journal.numbers.len) {
                        const number = journal.numbers[self.index];
                        self.index += 1;
                        if (selection.what == .range and !selection.what.range.contains(number)) continue;
                        return .{
                            .journal_index = selection.journal_index,
                            .number = number,
                            .qualified = selection.qualified,
                        };
                    }
                    self.selection += 1;
                    self.index = 0;
                },
            }
        }
        return null;
    }
};

fn loadHistoryJournal(
    gpa: std.mem.Allocator,
    io: Io,
    root: store.Dir,
    journals: *std.ArrayList(HistoryJournal),
    name: []const u8,
) !usize {
    for (journals.items, 0..) |journal, index| {
        if (std.mem.eql(u8, journal.name, name)) return index;
    }

    const owned_name = try gpa.dupe(u8, name);
    errdefer gpa.free(owned_name);
    const numbers = store.listNumbers(gpa, io, root, name) catch |err| switch (err) {
        error.FileNotFound => return error.NoSuchJournal,
        else => return err,
    };
    errdefer gpa.free(numbers);
    try journals.append(gpa, .{
        .name = owned_name,
        .numbers = numbers,
    });
    return journals.items.len - 1;
}

fn parseHistoryJournalSelector(text: []const u8) ?[]const u8 {
    if (text.len < 3 or text[0] != '@' or text[text.len - 1] != '.') return null;
    const suffix = text[1 .. text.len - 1];
    if (suffix.len == 0 or suffix.len > reference.max_suffix) return null;
    for (suffix) |char| {
        if (!std.ascii.isDigit(char) and !std.ascii.isAlphabetic(char)) return null;
    }
    return suffix;
}

test "history journal selectors use a trailing dot" {
    try std.testing.expectEqualStrings("8wpc", parseHistoryJournalSelector("@8wpc.").?);
    try std.testing.expectEqualStrings("01m12awjf7hd5pdfvnkzmw8wpc", parseHistoryJournalSelector("@01m12awjf7hd5pdfvnkzmw8wpc.").?);
    try std.testing.expect(parseHistoryJournalSelector("8wpc") == null);
    try std.testing.expect(parseHistoryJournalSelector("@8wpc") == null);
    try std.testing.expect(parseHistoryJournalSelector("@.") == null);
    try std.testing.expect(parseHistoryJournalSelector("@bad_suffix.") == null);
}

fn appendWholeHistoryJournal(
    gpa: std.mem.Allocator,
    io: Io,
    root: store.Dir,
    journals: *std.ArrayList(HistoryJournal),
    selected: *std.ArrayList(HistorySelection),
    name: []const u8,
    qualified: bool,
) !void {
    const journal_index = try loadHistoryJournal(gpa, io, root, journals, name);
    try selected.append(gpa, .{
        .journal_index = journal_index,
        .qualified = qualified,
        .what = .whole,
    });
}

fn historyReferenceWidth(journal: *const HistoryJournal, item: HistoryCursor.Item) usize {
    const number_width = decimalWidth(item.number);
    if (!item.qualified) return number_width;
    return 1 + journalDisplaySuffix(journal.name).len + 1 + number_width;
}

fn writeHistoryReference(
    out: *Io.Writer,
    journal: *const HistoryJournal,
    item: HistoryCursor.Item,
    width: usize,
    color_enabled: bool,
) !void {
    const actual_width = historyReferenceWidth(journal, item);
    try out.splatByteAll(' ', width - actual_width);
    if (color_enabled) try out.writeAll("\x1b[33m");
    if (item.qualified) {
        try out.print("@{s}.{d}", .{ journalDisplaySuffix(journal.name), item.number });
    } else {
        try out.print("{d}", .{item.number});
    }
    if (color_enabled) try out.writeAll("\x1b[0m");
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

    var journals: std.ArrayList(HistoryJournal) = .empty;
    defer {
        for (journals.items) |*journal| journal.deinit(gpa);
        journals.deinit(gpa);
    }
    var selected: std.ArrayList(HistorySelection) = .empty;
    defer selected.deinit(gpa);

    if (parsed.positionals.items.len == 0) {
        try appendWholeHistoryJournal(gpa, io, root, &journals, &selected, try currentJournal(), false);
    } else {
        for (parsed.positionals.items) |text| {
            if (parseHistoryJournalSelector(text)) |suffix| {
                const journal = try store.findNewestJournal(gpa, io, root, suffix) orelse return error.NoSuchJournal;
                defer gpa.free(journal);
                try appendWholeHistoryJournal(gpa, io, root, &journals, &selected, journal, true);
                continue;
            }

            const maybe_range = parseInteractionRange(text) catch |err| switch (err) {
                error.CrossJournalMutation => return error.InvalidRange,
                else => |other| return other,
            };
            if (maybe_range) |range| {
                const journal_index = try loadHistoryJournal(gpa, io, root, &journals, try currentJournal());
                if (!rangeSelectsAny(journals.items[journal_index].numbers, range)) {
                    return error.NoSuchInteraction;
                }
                try selected.append(gpa, .{
                    .journal_index = journal_index,
                    .qualified = false,
                    .what = .{ .range = range },
                });
                continue;
            }

            const target = try locateCommandTarget(gpa, io, root, text);
            defer target.deinit(gpa);
            try requireInteraction(target);
            const journal_index = try loadHistoryJournal(gpa, io, root, &journals, target.journal);
            if (!journals.items[journal_index].has(target.number)) return error.NoSuchInteraction;
            const current = sys.env("TJ_JOURNAL");
            try selected.append(gpa, .{
                .journal_index = journal_index,
                .qualified = target.syntactically_qualified or current == null or
                    !std.mem.eql(u8, current.?, target.journal),
                .what = .{ .single = target.number },
            });
        }
    }

    // Column widths depend on every visible entry, so they need a pass before
    // anything is printed. It keeps nothing: each entry is read, measured, and
    // released, and the print pass reads it again. Two cheap passes cost less
    // than one resident copy of the journal.
    // Columns are fixed, so nothing has to be read before printing starts.
    // The reference column is as wide as its journal's highest entry number
    // ever needs, which the sorted number list already knows; the size column
    // is as wide as `formatHumanSize` can ever be. Both are exact rather than
    // guessed, and a listing lines up with every other listing of the same
    // journal instead of shifting with whatever the filter happened to match.
    var number_width: usize = 1;
    for (selected.items) |selection| {
        const journal = &journals.items[selection.journal_index];
        if (journal.numbers.len == 0) continue;
        var width = decimalWidth(journal.numbers[journal.numbers.len - 1]);
        if (selection.qualified) width += 1 + journalDisplaySuffix(journal.name).len + 1;
        number_width = @max(number_width, width);
    }
    const size_width = max_entry_size_width;

    const date_width = 12;
    const prefix_width = 4 + 1 + number_width + 1 + size_width + 1 + date_width + 1;
    const columns = historyTerminalColumns();
    const payload_width: ?usize = if (columns) |value|
        if (value > prefix_width) value - prefix_width else 1
    else
        null;
    const color_enabled = historyColorEnabled();
    const current = sys.env("TJ_JOURNAL");
    var noout_region: NooutRegion = .{
        .out = out,
        .enabled = current != null and current.?.len != 0 and sys.isTty(1),
    };
    defer noout_region.finish();
    const now_ms = Io.Clock.now(.real, io).toMilliseconds();

    var render_metadata: ?annotations.Connection = null;
    defer if (render_metadata) |*metadata| metadata.deinit(gpa);
    var render_journal: ?usize = null;
    var render_annotations: annotations.Set = .{};
    defer render_annotations.deinit(gpa);
    var render_cursor: HistoryCursor = .{ .journals = journals.items, .selections = selected.items };
    while (render_cursor.next()) |item| {
        const journal = &journals.items[item.journal_index];
        if (render_journal != item.journal_index) {
            if (render_metadata) |*metadata| metadata.deinit(gpa);
            render_metadata = null;
            render_metadata = try annotations.openRead(gpa, io, root, journal.name);
            render_annotations.deinit(gpa);
            render_annotations = try annotations.loadSet(gpa, &render_metadata.?);
            render_journal = item.journal_index;
        }
        const annotation = render_annotations.get(item.number);
        if (!historyEntryVisible(annotation, filters.items, pinned_only)) continue;

        const info = try store.readInteraction(
            gpa,
            io,
            root,
            journal.name,
            item.number,
            store.listing_command_limit,
        ) orelse continue;
        defer info.deinit(gpa);

        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(gpa);
        const command = try sanitizeDisplayText(gpa, firstLine(info.command));
        defer gpa.free(command);
        try payload.appendSlice(gpa, command);

        var metadata_start: ?usize = null;
        var rc_start: ?usize = null;
        const has_name = annotation != null and annotation.?.name != null;
        const has_tags = annotation != null and annotation.?.tags.items.len != 0;
        const has_failure = info.exit_code != null and info.exit_code.? != 0;
        if (has_name or has_tags or has_failure) {
            if (payload.items.len != 0) try payload.append(gpa, ' ');
            if (has_name or has_tags) metadata_start = payload.items.len;
            if (has_name) {
                try payload.append(gpa, '@');
                try payload.appendSlice(gpa, annotation.?.name.?);
            }
            if (has_tags) {
                for (annotation.?.tags.items, 0..) |tag, tag_i| {
                    if (has_name or tag_i != 0) try payload.append(gpa, ' ');
                    try payload.append(gpa, '#');
                    try payload.appendSlice(gpa, tag);
                }
            }
            if (has_failure) {
                if (has_name or has_tags) try payload.append(gpa, ' ');
                rc_start = payload.items.len;
                try payload.print(gpa, "!{d}", .{info.exit_code.?});
            }
        }

        var lines = try wrapHistoryText(gpa, payload.items, payload_width, prefix_width);
        defer lines.deinit(gpa);
        try noout_region.begin();

        var size_buf: [24]u8 = undefined;
        const size_text = formatEntrySize(info, &size_buf);
        var date_buf: [date_width]u8 = undefined;
        const timing = store.readTiming(gpa, io, root, journal.name, info.number);
        const date_text = formatLsDate(if (timing) |value| value.started else null, now_ms, &date_buf);

        for (lines.items, 0..) |line, line_i| {
            if (line_i == 0) {
                try out.writeByte(if (annotation != null and annotation.?.pinned) '*' else ' ');
                try out.writeByte(if (has_name) '@' else ' ');
                try out.writeByte(if (has_tags) '#' else ' ');
                if (has_failure and color_enabled) try out.writeAll("\x1b[31m");
                try out.writeByte(if (has_failure) '!' else ' ');
                if (has_failure and color_enabled) try out.writeAll("\x1b[0m");
                try out.writeByte(' ');
                try writeHistoryReference(out, journal, item, number_width, color_enabled);
                try out.writeByte(' ');
                try out.splatByteAll(' ', size_width - size_text.len);
                if (color_enabled) try out.writeAll("\x1b[32m");
                try out.writeAll(size_text);
                if (color_enabled) try out.writeAll("\x1b[0m");
                try out.writeByte(' ');
                if (color_enabled) try out.writeAll("\x1b[34m");
                try out.writeAll(date_text);
                if (color_enabled) try out.writeAll("\x1b[0m");
                try out.writeByte(' ');
            } else {
                try out.splatByteAll(' ', prefix_width);
            }
            try writeHistoryLine(out, payload.items, line, metadata_start, rc_start, color_enabled);
            try out.writeByte('\n');
        }
    }
}

fn usageCommand(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    parsed: *const zecli.Parsed,
    out: *Io.Writer,
) !void {
    var root = try store.openRoot(io, home);
    defer root.close(io);

    const journal = try currentJournal();
    const measured = store.measureJournalUsage(gpa, io, root, journal) catch |err| switch (err) {
        error.FileNotFound => return error.NoSuchJournal,
        else => |other| return other,
    };
    defer measured.deinit(gpa);

    var noout_region: NooutRegion = .{
        .out = out,
        .enabled = sys.isTty(1),
    };
    defer noout_region.finish();
    try noout_region.begin();

    var total_buf: [24]u8 = undefined;
    const exact_bytes = parsed.present("bytes");
    const total_text = formatUsageSize(measured.total_bytes, exact_bytes, &total_buf);
    if (!parsed.present("chart") and !exact_bytes) {
        try out.print("{s}\n", .{total_text});
        return;
    }
    if (!parsed.present("chart")) {
        for (measured.entries) |entry| try out.print("@{d} {d}\n", .{ entry.number, entry.bytes });
        return;
    }

    const color_enabled = historyColorEnabled();
    try out.writeAll("Total ");
    if (color_enabled) try out.writeAll("\x1b[32m");
    try out.writeAll(total_text);
    if (color_enabled) try out.writeAll("\x1b[0m");
    try out.writeAll("\n\nEntry Size Chart\n");

    var reference_width: usize = 2;
    var size_width: usize = 1;
    var largest: u64 = 0;
    for (measured.entries) |entry| {
        reference_width = @max(reference_width, 1 + decimalWidth(entry.number));
        var size_buf: [24]u8 = undefined;
        size_width = @max(size_width, formatUsageSize(entry.bytes, exact_bytes, &size_buf).len);
        largest = @max(largest, entry.bytes);
    }
    const prefix_width = reference_width + 1 + size_width + 1;
    const columns = historyTerminalColumns() orelse 80;
    const available = if (columns > prefix_width) columns - prefix_width else 1;

    for (measured.entries) |entry| {
        const actual_reference_width = 1 + decimalWidth(entry.number);
        try out.splatByteAll(' ', reference_width - actual_reference_width);
        if (color_enabled) try out.writeAll("\x1b[33m");
        try out.print("@{d}", .{entry.number});
        if (color_enabled) try out.writeAll("\x1b[0m");
        try out.writeByte(' ');

        var size_buf: [24]u8 = undefined;
        const size_text = formatUsageSize(entry.bytes, exact_bytes, &size_buf);
        try out.splatByteAll(' ', size_width - size_text.len);
        if (color_enabled) try out.writeAll("\x1b[32m");
        try out.writeAll(size_text);
        if (color_enabled) try out.writeAll("\x1b[0m");

        const width = usageBarWidth(entry.bytes, largest, available);
        if (width != 0) {
            try out.writeByte(' ');
            try out.splatBytesAll("█", width);
        }
        try out.writeByte('\n');
    }
}

fn formatUsageSize(bytes: u64, exact: bool, buf: *[24]u8) []const u8 {
    if (!exact) return formatHumanSize(bytes, buf);
    return std.fmt.bufPrint(buf, "{d}", .{bytes}) catch "?";
}

fn usageBarWidth(bytes: u64, largest: u64, available: usize) usize {
    if (bytes == 0 or largest == 0 or available == 0) return 0;
    const numerator = @as(u128, bytes) * available;
    return @intCast((numerator + largest - 1) / largest);
}

test "usage chart bars preserve small entries and avoid integer overflow" {
    try std.testing.expectEqual(@as(usize, 0), usageBarWidth(0, 10, 80));
    try std.testing.expectEqual(@as(usize, 0), usageBarWidth(10, 0, 80));
    try std.testing.expectEqual(@as(usize, 5), usageBarWidth(5, 10, 10));
    try std.testing.expectEqual(@as(usize, 4), usageBarWidth(1, 3, 10));
    try std.testing.expectEqual(@as(usize, 80), usageBarWidth(std.math.maxInt(u64), std.math.maxInt(u64), 80));
}

/// The widest string `formatEntrySize` can produce. `formatHumanSize` divides
/// while `bytes >= unit * 1024`, so the whole part always stays below 1024:
/// the widest results are `1023b` below the first unit and `1023k` above it.
pub const max_entry_size_width = 5;

fn formatEntrySize(info: store.InteractionInfo, buf: *[24]u8) []const u8 {
    if (!info.out_present) return "-";
    return formatHumanSize(info.out_bytes, buf);
}

fn formatHumanSize(bytes: u64, buf: *[24]u8) []const u8 {
    if (bytes < 1024) return std.fmt.bufPrint(buf, "{d}b", .{bytes}) catch "?";

    const suffixes = "kMGTPE";
    var unit: u64 = 1024;
    var suffix: usize = 0;
    while (suffix + 1 < suffixes.len and bytes >= unit * 1024) {
        unit *= 1024;
        suffix += 1;
    }
    var whole = bytes / unit;
    if (whole < 10) {
        const tenth = ((bytes % unit) * 10 + unit / 2) / unit;
        if (tenth < 10) {
            return std.fmt.bufPrint(buf, "{d}.{d}{c}", .{ whole, tenth, suffixes[suffix] }) catch "?";
        }
        whole += 1;
    }
    return std.fmt.bufPrint(buf, "{d}{c}", .{ whole, suffixes[suffix] }) catch "?";
}

/// `ls -l`-style UTC date: current-year entries show HH:MM, older entries the
/// year. UTC keeps output deterministic and matches the timestamps in meta.
fn formatLsDate(started_ms: ?i64, now_ms: i64, buf: *[12]u8) []const u8 {
    buf.* = "--- -- --:--".*;
    const millis = started_ms orelse return buf;
    if (millis < 0) return buf;

    const seconds = @divFloor(millis, 1000);
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(seconds) };
    const day = epoch.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const time = epoch.getDaySeconds();
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    const month_index: usize = @intCast(month_day.month.numeric() - 1);
    @memcpy(buf[0..3], months[month_index]);
    const month_date: u32 = month_day.day_index + 1;
    buf[4] = if (month_date >= 10) '0' + @as(u8, @intCast(month_date / 10)) else ' ';
    buf[5] = '0' + @as(u8, @intCast(month_date % 10));

    const now_year = if (now_ms >= 0) blk: {
        const now_seconds = @divFloor(now_ms, 1000);
        const now_epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(now_seconds) };
        break :blk now_epoch.getEpochDay().calculateYearDay().year;
    } else year_day.year;
    if (year_day.year == now_year) {
        const hour = time.getHoursIntoDay();
        const minute = time.getMinutesIntoHour();
        buf[7] = '0' + @as(u8, @intCast(hour / 10));
        buf[8] = '0' + @as(u8, @intCast(hour % 10));
        buf[9] = ':';
        buf[10] = '0' + @as(u8, @intCast(minute / 10));
        buf[11] = '0' + @as(u8, @intCast(minute % 10));
    } else {
        const year: u32 = @intCast(year_day.year);
        buf[7] = ' ';
        buf[8] = '0' + @as(u8, @intCast((year / 1000) % 10));
        buf[9] = '0' + @as(u8, @intCast((year / 100) % 10));
        buf[10] = '0' + @as(u8, @intCast((year / 10) % 10));
        buf[11] = '0' + @as(u8, @intCast(year % 10));
    }
    return buf;
}

fn historyEntryVisible(
    annotation: ?*const annotations.Entry,
    tags: []const []const u8,
    pinned_only: bool,
) bool {
    if (pinned_only and (annotation == null or !annotation.?.pinned)) return false;
    if (tags.len == 0) return true;
    const entry = annotation orelse return false;
    for (tags) |wanted| {
        var found = false;
        for (entry.tags.items) |actual| {
            if (std.mem.eql(u8, wanted, actual)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
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
    metadata_start: ?usize,
    rc_start: ?usize,
    color_enabled: bool,
) !void {
    if (!color_enabled) return out.writeAll(text[line.start..line.end]);

    var position = line.start;
    if (metadata_start) |start| {
        const styled_start = @max(line.start, start);
        const styled_end = @min(line.end, rc_start orelse line.end);
        if (position < @min(styled_start, line.end)) {
            try out.writeAll(text[position..@min(styled_start, line.end)]);
            position = @min(styled_start, line.end);
        }
        if (styled_start < styled_end) {
            try out.writeAll("\x1b[32m");
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

test "history renders annotations green and failures red" {
    const gpa = std.testing.allocator;
    const text = "false @build #bug !1";
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    var writer = Io.Writer.Allocating.fromArrayList(gpa, &bytes);
    defer bytes = writer.toArrayList();

    try writeHistoryLine(&writer.writer, text, .{ .start = 0, .end = text.len }, 6, 18, true);
    try std.testing.expectEqualStrings(
        "false \x1b[32m@build #bug \x1b[0m\x1b[31m!1\x1b[0m",
        writer.writer.buffered(),
    );
}

test "long listing formats human sizes and ls-style UTC dates" {
    var size_buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("0b", formatHumanSize(0, &size_buf));
    try std.testing.expectEqualStrings("999b", formatHumanSize(999, &size_buf));
    try std.testing.expectEqualStrings("1.5k", formatHumanSize(1536, &size_buf));
    try std.testing.expectEqualStrings("18k", formatHumanSize(18 * 1024, &size_buf));
    try std.testing.expectEqualStrings("6.1M", formatHumanSize(6 * 1024 * 1024 + 1024 * 1024 / 10, &size_buf));

    // The history size column is a fixed width, so the formatter must never
    // exceed it. Probe every unit boundary and the extremes rather than trust
    // the reasoning in the constant's comment.
    var widest: usize = 0;
    var unit: u64 = 1;
    for (0..7) |_| {
        for ([_]u64{ 0, 1, 9, 10, 999, 1000, 1023, 1024, 1025 }) |offset| {
            const bytes = unit *| offset;
            var probe_buf: [24]u8 = undefined;
            widest = @max(widest, formatHumanSize(bytes, &probe_buf).len);
        }
        unit *|= 1024;
    }
    var extreme_buf: [24]u8 = undefined;
    widest = @max(widest, formatHumanSize(std.math.maxInt(u64), &extreme_buf).len);
    try std.testing.expectEqual(max_entry_size_width, widest);

    const current = store.parseTimestamp("2026-08-29T10:14:00.000Z").?;
    const now = store.parseTimestamp("2026-12-01T00:00:00.000Z").?;
    const old = store.parseTimestamp("2025-03-14T09:00:00.000Z").?;
    var date_buf: [12]u8 = undefined;
    try std.testing.expectEqualStrings("Aug 29 10:14", formatLsDate(current, now, &date_buf));
    try std.testing.expectEqualStrings("Mar 14  2025", formatLsDate(old, now, &date_buf));
    try std.testing.expectEqualStrings("--- -- --:--", formatLsDate(null, now, &date_buf));
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

    var metadata = annotations.openRead(gpa, io, root, journal) catch return;
    defer metadata.deinit(gpa);
    var names = metadata.names() catch return;
    defer names.deinit();
    while (names.next() catch return) |entry| {
        if (!store.interactionExists(io, root, journal, entry.number)) continue;
        if (!std.mem.startsWith(u8, entry.name, prefix)) continue;
        try out.print("@{s}{s}\n", .{ qualifier, entry.name });
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
    mode: mutation_lock.Mode,
) !struct { root: store.Dir, journal: []const u8, lock: Io.File } {
    const journal = try currentJournal();
    var root = try store.openRoot(io, home);
    errdefer root.close(io);
    const lock = try mutation_lock.acquire(io, root, journal, mode);
    errdefer lock.close(io);
    if (mode == .exclusive) {
        try store.recoverPendingOutputRemovals(gpa, io, root, journal);
        try annotations.recoverStagedRemovals(gpa, io, root, journal);
        store.cleanupJournalTrash(io, root, journal);
    }
    return .{ .root = root, .journal = journal, .lock = lock };
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
            var metadata = try annotations.openRead(gpa, io, root, current);
            defer metadata.deinit(gpa);
            var names = try metadata.names();
            defer names.deinit();
            while (try names.next()) |entry| {
                if (!store.interactionExists(io, root, current, entry.number)) continue;
                try out.print("{s}  @{d}\n", .{ entry.name, entry.number });
            }
            return;
        },
        .query => |ref| {
            var root = try store.openRoot(io, home);
            defer root.close(io);
            const target = try locateCommandTarget(gpa, io, root, ref);
            defer target.deinit(gpa);
            try requireInteraction(target);
            var metadata = try annotations.openRead(gpa, io, root, target.journal);
            defer metadata.deinit(gpa);
            var entry = try metadata.get(gpa, target.number) orelse return;
            defer entry.deinit(gpa);
            const name = entry.name orelse return;
            try out.print("{s}  ", .{name});
            try printCanonical(out, sys.env("TJ_JOURNAL"), target.journal, target.number);
            return out.writeAll("\n");
        },
        .remove => |name| {
            var mutation = try openCurrentMutation(gpa, io, home, .shared);
            defer mutation.lock.close(io);
            defer mutation.root.close(io);
            var metadata = try annotations.openWrite(gpa, io, mutation.root, mutation.journal);
            defer metadata.deinit(gpa);
            var transaction = try metadata.begin();
            defer transaction.deinit();
            try metadata.removeName(name);
            return transaction.commit();
        },
        .set => |request| {
            var root = try store.openRoot(io, home);
            defer root.close(io);
            const target = try requireMutationTarget(gpa, io, root, request.ref);
            defer target.deinit(gpa);
            try requireInteraction(target);
            var mutation = try openCurrentMutation(gpa, io, home, .shared);
            defer mutation.lock.close(io);
            defer mutation.root.close(io);
            if (!store.interactionExists(io, mutation.root, mutation.journal, target.number)) return error.NoSuchInteraction;
            var metadata = try annotations.openWrite(gpa, io, mutation.root, mutation.journal);
            defer metadata.deinit(gpa);
            var transaction = try metadata.begin();
            defer transaction.deinit();
            if (try metadata.numberForName(request.name)) |owner| {
                if (!store.interactionExists(io, mutation.root, mutation.journal, owner)) {
                    try metadata.removeName(request.name);
                }
            }
            try metadata.setName(target.number, request.name);
            try transaction.commit();
        },
    }
}

const TagRequest = union(enum) {
    list,
    query: []const []const u8,
    add: struct { targets: []const []const u8, tags: []const []const u8 },
    remove: struct { targets: []const []const u8, tags: []const []const u8 },
};

fn tagRequest(parsed: *const zecli.Parsed, target_count: usize) !TagRequest {
    const args = parsed.positionals.items;
    if (args.len == 0) {
        if (parsed.present("remove")) return error.MissingArgument;
        return .list;
    }
    if (target_count == 0 or target_count > args.len) return error.BadArguments;
    const targets = args[0..target_count];
    const tags = args[target_count..];
    if (parsed.present("remove")) {
        if (tags.len == 0) return error.MissingArgument;
        return .{ .remove = .{ .targets = targets, .tags = tags } };
    }
    if (tags.len == 0) return .{ .query = targets };
    return .{ .add = .{ .targets = targets, .tags = tags } };
}

fn tagTargetCount(io: Io, root: store.Dir, args: []const []const u8) !usize {
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try root.realPath(io, &root_buf);
    const root_path = root_buf[0..root_len];

    var count: usize = 0;
    for (args) |arg| {
        const shorthand = arg.len != 0 and arg[0] == '@';
        const expanded = std.mem.startsWith(u8, arg, root_path) and
            arg.len > root_path.len and arg[root_path.len] == '/';
        if (!shorthand and !expanded) break;
        count += 1;
    }
    return count;
}

fn tagCommand(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    parsed: *const zecli.Parsed,
    out: *Io.Writer,
) !void {
    const target_count = if (parsed.positionals.items.len == 0) 0 else blk: {
        var root = try store.openRoot(io, home);
        defer root.close(io);
        break :blk try tagTargetCount(io, root, parsed.positionals.items);
    };
    switch (try tagRequest(parsed, target_count)) {
        .list => {
            const current = try currentJournal();
            var root = try store.openRoot(io, home);
            defer root.close(io);
            var metadata = try annotations.openRead(gpa, io, root, current);
            defer metadata.deinit(gpa);
            var rows = try metadata.tags();
            defer rows.deinit();
            var printed: ?u32 = null;
            while (try rows.next()) |row| {
                if (!store.interactionExists(io, root, current, row.number)) continue;
                if (printed != row.number) {
                    if (printed != null) try out.writeAll("\n");
                    try out.print("@{d}", .{row.number});
                    printed = row.number;
                }
                try out.print("  {s}", .{row.tag});
            }
            if (printed != null) try out.writeAll("\n");
        },
        .query => |targets| {
            for (targets) |target| try queryTags(gpa, io, home, target, out);
        },
        .add => |request| {
            for (request.targets) |target| try updateTags(gpa, io, home, target, request.tags, false);
        },
        .remove => |request| {
            for (request.targets) |target| try updateTags(gpa, io, home, target, request.tags, true);
        },
    }
}

fn queryTags(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    ref: []const u8,
    out: *Io.Writer,
) !void {
    if (try parseInteractionRange(ref)) |range| {
        return queryTagsRange(gpa, io, home, range, out);
    }
    var root = try store.openRoot(io, home);
    defer root.close(io);
    const target = try locateCommandTarget(gpa, io, root, ref);
    defer target.deinit(gpa);
    try requireInteraction(target);
    var metadata = try annotations.openRead(gpa, io, root, target.journal);
    defer metadata.deinit(gpa);
    var entry = (try metadata.get(gpa, target.number)) orelse return;
    defer entry.deinit(gpa);
    if (entry.tags.items.len == 0) return;
    try printCanonical(out, sys.env("TJ_JOURNAL"), target.journal, target.number);
    for (entry.tags.items) |tag| try out.print("  {s}", .{tag});
    try out.writeAll("\n");
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

    var mutation = try openCurrentMutation(gpa, io, home, .shared);
    defer mutation.lock.close(io);
    defer mutation.root.close(io);
    if (!store.interactionExists(io, mutation.root, mutation.journal, target.number)) return error.NoSuchInteraction;
    const normalized = try normalizeTags(gpa, tags);
    defer freeTags(gpa, normalized);
    var metadata = try annotations.openWrite(gpa, io, mutation.root, mutation.journal);
    defer metadata.deinit(gpa);
    var transaction = try metadata.begin();
    defer transaction.deinit();
    for (normalized) |tag| {
        if (removing) {
            try metadata.removeTag(target.number, tag);
        } else {
            try metadata.addTag(target.number, tag);
        }
    }
    try transaction.commit();
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

    var metadata = try annotations.openRead(gpa, io, root, current);
    defer metadata.deinit(gpa);
    for (numbers) |number| {
        if (!range.contains(number)) continue;
        var entry = (try metadata.get(gpa, number)) orelse continue;
        defer entry.deinit(gpa);
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
    var mutation = try openCurrentMutation(gpa, io, home, .shared);
    defer mutation.lock.close(io);
    defer mutation.root.close(io);
    const numbers = try store.listNumbers(gpa, io, mutation.root, mutation.journal);
    defer gpa.free(numbers);
    if (!rangeSelectsAny(numbers, range)) return error.NoSuchInteraction;

    const normalized = try normalizeTags(gpa, tags);
    defer freeTags(gpa, normalized);
    var metadata = try annotations.openWrite(gpa, io, mutation.root, mutation.journal);
    defer metadata.deinit(gpa);
    var transaction = try metadata.begin();
    defer transaction.deinit();
    for (numbers) |number| {
        if (!range.contains(number)) continue;
        for (normalized) |tag| {
            if (removing) {
                try metadata.removeTag(number, tag);
            } else {
                try metadata.addTag(number, tag);
            }
        }
    }
    try transaction.commit();
}

fn normalizeTags(gpa: std.mem.Allocator, tags: []const []const u8) ![][]u8 {
    const normalized = try gpa.alloc([]u8, tags.len);
    errdefer gpa.free(normalized);
    var completed: usize = 0;
    errdefer for (normalized[0..completed]) |tag| gpa.free(tag);
    for (tags, 0..) |tag, index| {
        normalized[index] = try annotations.normalizeTag(gpa, tag);
        completed += 1;
    }
    return normalized;
}

fn freeTags(gpa: std.mem.Allocator, tags: [][]u8) void {
    for (tags) |tag| gpa.free(tag);
    gpa.free(tags);
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
            var metadata = try annotations.openRead(gpa, io, root, current);
            defer metadata.deinit(gpa);
            var pins = try metadata.pins();
            defer pins.deinit();
            while (try pins.next()) |number| {
                if (store.interactionExists(io, root, current, number)) try out.print("@{d}\n", .{number});
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

    var mutation = try openCurrentMutation(gpa, io, home, .shared);
    defer mutation.lock.close(io);
    defer mutation.root.close(io);
    if (!store.interactionExists(io, mutation.root, mutation.journal, target.number)) return error.NoSuchInteraction;
    var metadata = try annotations.openWrite(gpa, io, mutation.root, mutation.journal);
    defer metadata.deinit(gpa);
    var transaction = try metadata.begin();
    defer transaction.deinit();
    try metadata.setPinned(target.number, pinned);
    try transaction.commit();
}

fn updatePinRange(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    range: InteractionRange,
    pinned: bool,
) !void {
    var mutation = try openCurrentMutation(gpa, io, home, .shared);
    defer mutation.lock.close(io);
    defer mutation.root.close(io);
    const numbers = try store.listNumbers(gpa, io, mutation.root, mutation.journal);
    defer gpa.free(numbers);
    if (!rangeSelectsAny(numbers, range)) return error.NoSuchInteraction;

    var metadata = try annotations.openWrite(gpa, io, mutation.root, mutation.journal);
    defer metadata.deinit(gpa);
    var transaction = try metadata.begin();
    defer transaction.deinit();
    for (numbers) |number| {
        if (range.contains(number)) try metadata.setPinned(number, pinned);
    }
    try transaction.commit();
}

const RemoveRequest = struct {
    targets: []const []const u8,
    force: bool,
};

fn removeRequest(parsed: *const zecli.Parsed) !RemoveRequest {
    if (parsed.positionals.items.len == 0) return error.BadArguments;
    return .{ .targets = parsed.positionals.items, .force = parsed.present("force") };
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
        var parsed = try parseTestCommand(.tag, &.{ "--remove", "@2", "@4..@6", "bug", "parser" });
        defer parsed.deinit(gpa);
        const request = (try tagRequest(&parsed, 2)).remove;
        try std.testing.expectEqual(@as(usize, 2), request.targets.len);
        try std.testing.expectEqualStrings("@2", request.targets[0]);
        try std.testing.expectEqualStrings("@4..@6", request.targets[1]);
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
        var parsed = try parseTestCommand(.rm, &.{ "--force", "@2", "@4/out", "@6..@8" });
        defer parsed.deinit(gpa);
        const request = try removeRequest(&parsed);
        try std.testing.expectEqual(@as(usize, 3), request.targets.len);
        try std.testing.expectEqualStrings("@2", request.targets[0]);
        try std.testing.expectEqualStrings("@4/out", request.targets[1]);
        try std.testing.expectEqualStrings("@6..@8", request.targets[2]);
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
    for (request.targets) |target| {
        try removeInteraction(gpa, io, home, target, request.force);
    }
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

    const entries = try store.countInteractions(gpa, io, root, journal);
    if (!force) {
        var metadata = try annotations.openRead(gpa, io, root, journal);
        defer metadata.deinit(gpa);
        var pins = try metadata.pins();
        defer pins.deinit();
        while (try pins.next()) |number| {
            if (store.interactionExists(io, root, journal, number)) return error.PinnedInteraction;
        }
        if (!sys.isTty(0)) return error.ConfirmationRequired;
        try out.print("Remove journal {s} with {d} {s}? [y/N] ", .{
            journal,
            entries,
            if (entries == 1) "entry" else "entries",
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

    var mutation = try openCurrentMutation(gpa, io, home, .exclusive);
    defer mutation.lock.close(io);
    defer mutation.root.close(io);
    if (!std.mem.eql(u8, target.journal, mutation.journal)) return error.CrossJournalMutation;
    if (!store.interactionExists(io, mutation.root, mutation.journal, target.number)) return error.NoSuchInteraction;
    const highest = try store.highestNumber(gpa, io, mutation.root, mutation.journal) orelse
        return error.NoSuchInteraction;
    if (target.number >= highest) return error.CurrentInteraction;

    var read_metadata = try annotations.openRead(gpa, io, mutation.root, mutation.journal);
    defer read_metadata.deinit(gpa);
    if (!force and try read_metadata.isPinned(target.number)) {
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
    var metadata = try annotations.openWrite(gpa, io, mutation.root, mutation.journal);
    defer metadata.deinit(gpa);
    var transaction = try metadata.begin();
    defer transaction.deinit();
    try metadata.removeEntry(target.number);
    try transaction.commit();
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

fn removeInteractionRange(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    range: InteractionRange,
    force: bool,
) !void {
    var mutation = try openCurrentMutation(gpa, io, home, .exclusive);
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

    var read_metadata = try annotations.openRead(gpa, io, mutation.root, mutation.journal);
    defer read_metadata.deinit(gpa);

    var staged_paths: std.ArrayList([]u8) = .empty;
    defer {
        for (staged_paths.items) |path| gpa.free(path);
        staged_paths.deinit(gpa);
    }
    try staged_paths.ensureTotalCapacity(gpa, selected);

    var skipped_pinned: usize = 0;
    for (numbers) |number| {
        if (number < range.first or number > range.last) continue;
        if (!force and try read_metadata.isPinned(number)) {
            skipped_pinned += 1;
            continue;
        }
        const staged = try store.stageInteractionRemoval(gpa, io, mutation.root, mutation.journal, number);
        staged_paths.appendAssumeCapacity(staged);
    }

    if (staged_paths.items.len != 0) {
        var metadata = try annotations.openWrite(gpa, io, mutation.root, mutation.journal);
        defer metadata.deinit(gpa);
        var transaction = try metadata.begin();
        defer transaction.deinit();
        for (numbers) |number| {
            if (number < range.first or number > range.last) continue;
            if (!force and try metadata.isPinned(number)) continue;
            try metadata.removeEntry(number);
        }
        try transaction.commit();
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

    // `tj cat ./notes.txt` is a plain file read that happens to share a
    // command with references. Opening the journal root up front made it fail
    // with "no journal yet" on a machine that has never recorded one, so the
    // root is opened only once an argument actually needs it.
    var root: LazyRoot = .{ .io = io, .home = home };
    defer root.close();

    for (request.refs) |text| {
        const maybe_range = parseInteractionRange(text) catch |err| switch (err) {
            // Cat ranges are deliberately current-journal-only, but this is a
            // syntax limitation rather than an attempted cross-journal write.
            error.CrossJournalMutation => return error.InvalidRange,
            else => |other| return other,
        };
        if (maybe_range) |range| {
            try catRange(gpa, io, try root.get(), request, range, out);
        } else {
            try catOne(gpa, io, &root, request, text, out);
        }
    }
}

/// Opens the journal root on first use. A reference or a range needs it; a
/// filesystem path does not, and must not fail because no journal exists yet.
const LazyRoot = struct {
    io: Io,
    home: ?[]const u8,
    dir: ?store.Dir = null,

    fn get(self: *LazyRoot) !store.Dir {
        if (self.dir) |dir| return dir;
        const dir = try store.openRoot(self.io, self.home);
        self.dir = dir;
        return dir;
    }

    fn close(self: *LazyRoot) void {
        if (self.dir) |dir| dir.close(self.io);
        self.dir = null;
    }
};

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

    var opened: LazyRoot = .{ .io = io, .home = null, .dir = root };
    for (numbers) |number| {
        if (!range.contains(number)) continue;
        var ref_buf: [16]u8 = undefined;
        const ref = try std.fmt.bufPrint(&ref_buf, "@{d}", .{number});
        try catOne(gpa, io, &opened, request, ref, out);
    }
}

fn catOne(
    gpa: std.mem.Allocator,
    io: Io,
    root: *LazyRoot,
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
fn openTarget(gpa: std.mem.Allocator, io: Io, root: *LazyRoot, text: []const u8) !Io.File {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var path: []const u8 = text;
    var owned: ?[]const u8 = null;
    defer if (owned) |value| gpa.free(value);

    if (reference.parse(text)) |parsed| {
        const found = try store.locate(gpa, io, try root.get(), sys.env("TJ_JOURNAL"), parsed);
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
