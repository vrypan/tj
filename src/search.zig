//! Bounded fixed-string search over journal resource files.

const std = @import("std");
const Io = std.Io;

pub const chunk_size = 64 * 1024;

pub const Matcher = struct {
    gpa: std.mem.Allocator,
    pattern: []u8,
    failure: []usize,
    ignore_case: bool,

    pub fn init(gpa: std.mem.Allocator, pattern: []const u8, ignore_case: bool) !Matcher {
        std.debug.assert(pattern.len != 0);
        const folded = try gpa.alloc(u8, pattern.len);
        errdefer gpa.free(folded);
        for (pattern, 0..) |byte, i| folded[i] = fold(byte, ignore_case);

        const failure = try gpa.alloc(usize, pattern.len);
        errdefer gpa.free(failure);
        failure[0] = 0;
        var matched: usize = 0;
        for (folded[1..], 1..) |byte, i| {
            while (matched > 0 and folded[matched] != byte) matched = failure[matched - 1];
            if (folded[matched] == byte) matched += 1;
            failure[i] = matched;
        }

        return .{
            .gpa = gpa,
            .pattern = folded,
            .failure = failure,
            .ignore_case = ignore_case,
        };
    }

    pub fn deinit(self: *Matcher) void {
        self.gpa.free(self.pattern);
        self.gpa.free(self.failure);
        self.* = undefined;
    }
};

pub const Sink = struct {
    context: *anyopaque,
    emit: *const fn (context: *anyopaque, file: Io.File, start: u64, end: u64) anyerror!void,
};

pub const MatchSpan = struct {
    start: u64,
    end: u64,
};

/// Finds the first match within `[start, end)` without changing the file's
/// streaming cursor. The returned offsets bound the complete raw match.
pub fn firstMatchSpan(
    io: Io,
    file: Io.File,
    start: u64,
    end: u64,
    matcher: *const Matcher,
) !?MatchSpan {
    if (end < start) return error.InvalidOffset;
    var buffer: [chunk_size]u8 = undefined;
    var read_offset = start;
    var prefix_len: usize = 0;
    while (read_offset < end) {
        const remaining = end - read_offset;
        const wanted: usize = @intCast(@min(remaining, buffer.len));
        const n = try file.readPositional(io, &.{buffer[0..wanted]}, read_offset);
        if (n == 0) return error.UnexpectedEndOfFile;
        for (buffer[0..n], 0..) |raw, i| {
            const byte = fold(raw, matcher.ignore_case);
            while (prefix_len > 0 and matcher.pattern[prefix_len] != byte) {
                prefix_len = matcher.failure[prefix_len - 1];
            }
            if (matcher.pattern[prefix_len] == byte) prefix_len += 1;
            if (prefix_len != matcher.pattern.len) continue;

            const match_end = try std.math.add(u64, read_offset, i + 1);
            return .{
                .start = try std.math.sub(u64, match_end, matcher.pattern.len),
                .end = match_end,
            };
        }
        read_offset = try std.math.add(u64, read_offset, n);
    }
    return null;
}

/// Calls `sink` once for every source line containing the pattern. Offsets do
/// not include the terminating newline. Matcher state never crosses a newline.
pub fn scanFile(io: Io, file: Io.File, matcher: *const Matcher, sink: Sink) !u64 {
    var reader_buffer: [chunk_size]u8 = undefined;
    var bytes: [chunk_size]u8 = undefined;
    var reader = file.readerStreaming(io, &reader_buffer);
    var offset: u64 = 0;
    var line_start: u64 = 0;
    var prefix_len: usize = 0;
    var line_matched = false;
    var matches: u64 = 0;

    while (true) {
        const n = try reader.interface.readSliceShort(&bytes);
        if (n == 0) break;
        for (bytes[0..n]) |raw| {
            if (raw == '\n') {
                if (line_matched) {
                    try sink.emit(sink.context, file, line_start, offset);
                    matches = try std.math.add(u64, matches, 1);
                }
                offset = try std.math.add(u64, offset, 1);
                line_start = offset;
                prefix_len = 0;
                line_matched = false;
                continue;
            }

            if (!line_matched) {
                const byte = fold(raw, matcher.ignore_case);
                while (prefix_len > 0 and matcher.pattern[prefix_len] != byte) {
                    prefix_len = matcher.failure[prefix_len - 1];
                }
                if (matcher.pattern[prefix_len] == byte) prefix_len += 1;
                if (prefix_len == matcher.pattern.len) line_matched = true;
            }
            offset = try std.math.add(u64, offset, 1);
        }
    }

    if (line_matched) {
        try sink.emit(sink.context, file, line_start, offset);
        matches = try std.math.add(u64, matches, 1);
    }
    return matches;
}

/// Copies `[start, end)` without changing the file's streaming cursor.
pub fn copySpan(io: Io, file: Io.File, start: u64, end: u64, out: *Io.Writer) !void {
    if (end < start) return error.InvalidOffset;
    var buffer: [chunk_size]u8 = undefined;
    var offset = start;
    while (offset < end) {
        const remaining = end - offset;
        const wanted: usize = @intCast(@min(remaining, buffer.len));
        const n = try file.readPositional(io, &.{buffer[0..wanted]}, offset);
        if (n == 0) return error.UnexpectedEndOfFile;
        try out.writeAll(buffer[0..n]);
        offset = try std.math.add(u64, offset, n);
    }
}

/// Copies a matching line while surrounding every non-overlapping match with
/// SGR sequences. The line is rescanned positionally, so memory remains fixed
/// even when one source line is very large.
pub fn copyHighlightedSpan(
    io: Io,
    file: Io.File,
    start: u64,
    end: u64,
    matcher: *const Matcher,
    sgr: []const u8,
    out: *Io.Writer,
) !void {
    if (end < start) return error.InvalidOffset;
    if (sgr.len == 0) return copySpan(io, file, start, end, out);

    var buffer: [chunk_size]u8 = undefined;
    var read_offset = start;
    var emitted_until = start;
    var prefix_len: usize = 0;
    while (read_offset < end) {
        const remaining = end - read_offset;
        const wanted: usize = @intCast(@min(remaining, buffer.len));
        const n = try file.readPositional(io, &.{buffer[0..wanted]}, read_offset);
        if (n == 0) return error.UnexpectedEndOfFile;
        for (buffer[0..n], 0..) |raw, i| {
            const byte = fold(raw, matcher.ignore_case);
            while (prefix_len > 0 and matcher.pattern[prefix_len] != byte) {
                prefix_len = matcher.failure[prefix_len - 1];
            }
            if (matcher.pattern[prefix_len] == byte) prefix_len += 1;
            if (prefix_len != matcher.pattern.len) continue;

            const match_end = try std.math.add(u64, read_offset, i + 1);
            const match_start = try std.math.sub(u64, match_end, matcher.pattern.len);
            try copySpan(io, file, emitted_until, match_start, out);
            try out.writeAll("\x1b[");
            try out.writeAll(sgr);
            try out.writeAll("m");
            try copySpan(io, file, match_start, match_end, out);
            try out.writeAll("\x1b[m");
            emitted_until = match_end;
            // GNU grep reports non-overlapping matches.
            prefix_len = 0;
        }
        read_offset = try std.math.add(u64, read_offset, n);
    }
    try copySpan(io, file, emitted_until, end, out);
}

fn fold(byte: u8, ignore_case: bool) u8 {
    return if (ignore_case and byte >= 'A' and byte <= 'Z') byte + ('a' - 'A') else byte;
}

const TestSink = struct {
    ranges: std.ArrayList([2]u64) = .empty,

    fn emit(context: *anyopaque, _: Io.File, start: u64, end: u64) !void {
        const self: *TestSink = @ptrCast(@alignCast(context));
        try self.ranges.append(std.testing.allocator, .{ start, end });
    }
};

fn scanText(text: []const u8, pattern: []const u8, ignore_case: bool) !TestSink {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(io, "resource", .{ .read = true });
    defer file.close(io);
    try file.writePositionalAll(io, text, 0);

    var matcher = try Matcher.init(std.testing.allocator, pattern, ignore_case);
    defer matcher.deinit();
    var found: TestSink = .{};
    _ = try scanFile(io, file, &matcher, .{ .context = &found, .emit = TestSink.emit });
    return found;
}

test "fixed search reports each matching line once and resets at newlines" {
    var found = try scanText("alpha alpha\nha\nalp\nha\nlast alpha", "alpha", false);
    defer found.ranges.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices([2]u64, &.{ .{ 0, 11 }, .{ 22, 32 } }, found.ranges.items);
}

test "fixed search preserves CR NUL final lines and folds ASCII only" {
    var found = try scanText("no\nMiX\x00ED\r\nfinal", "mix\x00ed", true);
    defer found.ranges.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices([2]u64, &.{.{ 3, 10 }}, found.ranges.items);

    var non_ascii = try scanText("\xc3\x84\n\xc3\xa4\n", "\xc3\x84", true);
    defer non_ascii.ranges.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices([2]u64, &.{.{ 0, 2 }}, non_ascii.ranges.items);
}

test "matcher survives the repository chunk boundary" {
    const gpa = std.testing.allocator;
    const prefix = try gpa.alloc(u8, chunk_size - 2);
    defer gpa.free(prefix);
    @memset(prefix, 'x');
    const text = try std.mem.concat(gpa, u8, &.{ prefix, "needle\ntail\n" });
    defer gpa.free(text);
    var found = try scanText(text, "needle", false);
    defer found.ranges.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), found.ranges.items.len);
    try std.testing.expectEqual(@as(u64, chunk_size + 4), found.ranges.items[0][1]);
}

test "positional span copying leaves a streaming cursor unchanged" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(io, "resource", .{ .read = true });
    defer file.close(io);
    try file.writePositionalAll(io, "first\nsecond\n", 0);

    var reader_buf: [16]u8 = undefined;
    var reader = file.readerStreaming(io, &reader_buf);
    var first: [6]u8 = undefined;
    try reader.interface.readSliceAll(&first);

    var bytes: std.ArrayList(u8) = .empty;
    var writer = Io.Writer.Allocating.fromArrayList(gpa, &bytes);
    try copySpan(io, file, 6, 12, &writer.writer);
    bytes = writer.toArrayList();
    defer bytes.deinit(gpa);
    try std.testing.expectEqualStrings("second", bytes.items);

    var next: [6]u8 = undefined;
    try reader.interface.readSliceAll(&next);
    try std.testing.expectEqualStrings("second", &next);
}

test "a sparse single line larger than sixty-four mibibytes stays bounded" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(io, "large-resource", .{ .read = true });
    defer file.close(io);
    const beyond_old_limit: u64 = 65 * 1024 * 1024;
    try file.writePositionalAll(io, "needle\n", beyond_old_limit);

    var matcher = try Matcher.init(gpa, "needle", false);
    defer matcher.deinit();
    var found: TestSink = .{};
    defer found.ranges.deinit(gpa);
    try std.testing.expectEqual(@as(u64, 1), try scanFile(io, file, &matcher, .{
        .context = &found,
        .emit = TestSink.emit,
    }));
    try std.testing.expectEqualSlices([2]u64, &.{.{ 0, beyond_old_limit + "needle".len }}, found.ranges.items);

    var discard_buf: [4096]u8 = undefined;
    var discarding = Io.Writer.Discarding.init(&discard_buf);
    try copySpan(io, file, found.ranges.items[0][0], found.ranges.items[0][1], &discarding.writer);
    try std.testing.expectEqual(beyond_old_limit + "needle".len, discarding.fullCount());
}

test "highlighted copying finds non-overlapping matches across chunk boundaries" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(io, "highlight", .{ .read = true });
    defer file.close(io);
    const prefix = try gpa.alloc(u8, chunk_size - 1);
    defer gpa.free(prefix);
    @memset(prefix, 'x');
    const text = try std.mem.concat(gpa, u8, &.{ prefix, "Needle needle aaa" });
    defer gpa.free(text);
    try file.writePositionalAll(io, text, 0);

    var matcher = try Matcher.init(gpa, "needle", true);
    defer matcher.deinit();
    var bytes: std.ArrayList(u8) = .empty;
    var writer = Io.Writer.Allocating.fromArrayList(gpa, &bytes);
    try copyHighlightedSpan(io, file, 0, text.len, &matcher, "4;31", &writer.writer);
    bytes = writer.toArrayList();
    defer bytes.deinit(gpa);
    const highlighted = "\x1b[4;31mNeedle\x1b[m \x1b[4;31mneedle\x1b[m aaa";
    try std.testing.expectEqualStrings(prefix, bytes.items[0..prefix.len]);
    try std.testing.expectEqualStrings(highlighted, bytes.items[prefix.len..]);

    var overlap_matcher = try Matcher.init(gpa, "aa", false);
    defer overlap_matcher.deinit();
    var overlap: std.ArrayList(u8) = .empty;
    var overlap_writer = Io.Writer.Allocating.fromArrayList(gpa, &overlap);
    try copyHighlightedSpan(io, file, text.len - 3, text.len, &overlap_matcher, "1", &overlap_writer.writer);
    overlap = overlap_writer.toArrayList();
    defer overlap.deinit(gpa);
    try std.testing.expectEqualStrings("\x1b[1maa\x1b[ma", overlap.items);
}

test "first match span crosses chunks and honors ASCII folding" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(io, "first-match", .{ .read = true });
    defer file.close(io);
    const prefix = try gpa.alloc(u8, chunk_size - 2);
    defer gpa.free(prefix);
    @memset(prefix, 'x');
    try file.writePositionalAll(io, prefix, 0);
    try file.writePositionalAll(io, "Needle tail needle", prefix.len);

    var matcher = try Matcher.init(gpa, "needle", true);
    defer matcher.deinit();
    const found = (try firstMatchSpan(io, file, 0, prefix.len + "Needle tail needle".len, &matcher)).?;
    try std.testing.expectEqual(@as(u64, prefix.len), found.start);
    try std.testing.expectEqual(@as(u64, prefix.len + "Needle".len), found.end);
}
