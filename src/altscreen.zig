//! Keeps full-screen programs out of the journal.
//!
//! Editors, pagers and monitors switch to the terminal's alternate screen
//! buffer before painting and switch back on exit. That buffer is not part of
//! scrollback: when vim exits, the main screen is restored and nothing of the
//! editing session remains to scroll back to.
//!
//! `out` follows the same rule, so it holds what a user would find scrolling
//! back through their terminal. Everything written while the alternate screen
//! is active is dropped, along with the switch sequences themselves. What a
//! program prints before or after - a summary line, an error - is ordinary
//! output and is kept.
//!
//! This filters only what is recorded. The bytes forwarded to the terminal
//! are never touched, so the program still renders exactly as it would
//! without tj.
//!
//! Detection beats a list of program names: `git log` pages through `less`,
//! `mcat` is somebody's own tool, and `cat @41/out` replays a recording. No
//! list knows about any of those, and every one of them really does take over
//! the screen.

const std = @import("std");

const enter_patterns = [_][]const u8{ "\x1b[?1049h", "\x1b[?1047h", "\x1b[?47h" };
const leave_patterns = [_][]const u8{ "\x1b[?1049l", "\x1b[?1047l", "\x1b[?47l" };

const max_pattern = 8;

pub const Filter = struct {
    /// Inside the alternate screen, where nothing is recorded.
    inside: bool = false,

    /// Bytes held back because they might still turn out to be a switch
    /// sequence. A sequence can straddle two reads, and half of one must
    /// never reach `out`.
    partial: [max_pattern]u8 = undefined,
    partial_len: usize = 0,

    /// How many full-screen regions this interaction had, and how much output
    /// they produced. Recorded so a near-empty `out` is explainable rather
    /// than mysterious.
    regions: u32 = 0,
    suppressed: u64 = 0,

    /// `sink.keep(bytes)` receives everything that belongs in `out`.
    pub fn feed(self: *Filter, bytes: []const u8, sink: anytype) void {
        var run_start: usize = 0;
        var i: usize = 0;

        while (i < bytes.len) {
            const byte = bytes[i];

            if (self.partial_len == 0 and byte != 0x1b) {
                // The common case: an ordinary byte, nothing pending.
                if (self.inside) {
                    self.suppressed += 1;
                    run_start = i + 1;
                }
                i += 1;
                continue;
            }

            // A byte that might begin, or continue, a switch sequence. Emit
            // whatever run preceded it before holding anything back.
            if (!self.inside and i > run_start) sink.keep(bytes[run_start..i]);
            i += 1;
            self.hold(byte, sink);
            run_start = i;
        }

        if (!self.inside and bytes.len > run_start) sink.keep(bytes[run_start..]);
    }

    /// The stream ended. Anything still held was never part of a sequence, so
    /// it is ordinary output and must not be lost.
    pub fn finish(self: *Filter, sink: anytype) void {
        if (self.partial_len == 0) return;
        if (!self.inside) sink.keep(self.partial[0..self.partial_len]) else self.suppressed += self.partial_len;
        self.partial_len = 0;
    }

    /// Adds one byte to the held sequence and resolves what that means.
    fn hold(self: *Filter, byte: u8, sink: anytype) void {
        self.partial[self.partial_len] = byte;
        self.partial_len += 1;

        while (self.partial_len > 0) {
            const held = self.partial[0..self.partial_len];

            if (self.inside) {
                if (matches(held, &leave_patterns)) {
                    self.suppressed += self.partial_len;
                    self.inside = false;
                    self.partial_len = 0;
                    return;
                }
            } else if (matches(held, &enter_patterns)) {
                self.suppressed += self.partial_len;
                self.inside = true;
                self.regions += 1;
                self.partial_len = 0;
                return;
            }

            if (isPrefix(held)) return;

            // Not a switch after all. Release the first byte and try again
            // from the second, which may itself start one: `ESC ESC [ ? 1049h`
            // is a real thing to see.
            if (self.inside) {
                self.suppressed += 1;
            } else {
                sink.keep(self.partial[0..1]);
            }
            self.partial_len -= 1;
            std.mem.copyForwards(u8, self.partial[0..self.partial_len], self.partial[1 .. self.partial_len + 1]);
        }
    }

    fn matches(held: []const u8, patterns: []const []const u8) bool {
        for (patterns) |pattern| {
            if (std.mem.eql(u8, held, pattern)) return true;
        }
        return false;
    }

    fn isPrefix(held: []const u8) bool {
        for (enter_patterns ++ leave_patterns) |pattern| {
            if (held.len < pattern.len and std.mem.startsWith(u8, pattern, held)) return true;
        }
        return false;
    }
};

// --- tests -----------------------------------------------------------------

const Collector = struct {
    gpa: std.mem.Allocator,
    kept: std.ArrayList(u8) = .empty,

    fn keep(self: *Collector, bytes: []const u8) void {
        self.kept.appendSlice(self.gpa, bytes) catch unreachable;
    }
};

const Result = struct {
    kept: []u8,
    regions: u32,
    suppressed: u64,
};

fn filterAll(gpa: std.mem.Allocator, input: []const u8, chunk: usize) !Result {
    var collector: Collector = .{ .gpa = gpa };
    var filter: Filter = .{};
    var i: usize = 0;
    while (i < input.len) {
        const end = @min(i + chunk, input.len);
        filter.feed(input[i..end], &collector);
        i = end;
    }
    filter.finish(&collector);
    return .{
        .kept = try collector.kept.toOwnedSlice(gpa),
        .regions = filter.regions,
        .suppressed = filter.suppressed,
    };
}

test "ordinary output is kept exactly as it arrived" {
    const gpa = std.testing.allocator;
    const input = "hello\r\n\x1b[31mred\x1b[0m\r\n\x1b]0;title\x07";
    const r = try filterAll(gpa, input, 64);
    defer gpa.free(r.kept);
    try std.testing.expectEqualStrings(input, r.kept);
    try std.testing.expectEqual(@as(u32, 0), r.regions);
}

test "a full-screen session leaves nothing behind" {
    const gpa = std.testing.allocator;
    const input = "\x1b[?1049h" ++ "vim paints a whole screen here" ++ "\x1b[?1049l";
    const r = try filterAll(gpa, input, 1024);
    defer gpa.free(r.kept);
    try std.testing.expectEqualStrings("", r.kept);
    try std.testing.expectEqual(@as(u32, 1), r.regions);
    try std.testing.expectEqual(@as(u64, input.len), r.suppressed);
}

test "what a program prints around a full-screen session is kept" {
    const gpa = std.testing.allocator;
    const input = "before\r\n\x1b[?1049hhidden\x1b[?1049lafter\r\n";
    const r = try filterAll(gpa, input, 1024);
    defer gpa.free(r.kept);
    try std.testing.expectEqualStrings("before\r\nafter\r\n", r.kept);
}

test "the older switch sequences work the same way" {
    const gpa = std.testing.allocator;
    for ([_][]const u8{ "\x1b[?1047h", "\x1b[?47h" }, [_][]const u8{ "\x1b[?1047l", "\x1b[?47l" }) |enter, leave| {
        var buf: [64]u8 = undefined;
        const input = try std.fmt.bufPrint(&buf, "a{s}hidden{s}b", .{ enter, leave });
        const r = try filterAll(gpa, input, 1024);
        defer gpa.free(r.kept);
        try std.testing.expectEqualStrings("ab", r.kept);
    }
}

test "the result does not depend on how the stream is chunked" {
    const gpa = std.testing.allocator;
    const input =
        "$ vi notes\r\n" ++
        "\x1b[?1049h\x1b[2J\x1b[H~\r\n~\r\n\x1b[?25l painting \x1b[?25h\x1b[?1049l" ++
        "\x1b[?2004hback at the prompt\r\n";

    const whole = try filterAll(gpa, input, input.len);
    defer gpa.free(whole.kept);

    var chunk: usize = 1;
    while (chunk <= input.len) : (chunk += 1) {
        const piece = try filterAll(gpa, input, chunk);
        defer gpa.free(piece.kept);
        try std.testing.expectEqualStrings(whole.kept, piece.kept);
        try std.testing.expectEqual(whole.regions, piece.regions);
        try std.testing.expectEqual(whole.suppressed, piece.suppressed);
    }
}

test "sequences that only look similar are kept" {
    const gpa = std.testing.allocator;
    // Bracketed paste, cursor visibility, and a truncated lookalike.
    const input = "\x1b[?2004h\x1b[?25l\x1b[?104h\x1b[?1049\x1b[m";
    const r = try filterAll(gpa, input, 1024);
    defer gpa.free(r.kept);
    try std.testing.expectEqualStrings(input, r.kept);
    try std.testing.expectEqual(@as(u32, 0), r.regions);
}

test "a doubled escape before a switch is handled" {
    const gpa = std.testing.allocator;
    const input = "\x1b\x1b[?1049hhidden\x1b[?1049l!";
    const r = try filterAll(gpa, input, 1);
    defer gpa.free(r.kept);
    // The stray ESC is ordinary output; the switch that follows is not.
    try std.testing.expectEqualStrings("\x1b!", r.kept);
    try std.testing.expectEqual(@as(u32, 1), r.regions);
}

test "output ending mid-sequence is not swallowed" {
    const gpa = std.testing.allocator;
    const input = "text\x1b[?10";
    const r = try filterAll(gpa, input, 3);
    defer gpa.free(r.kept);
    try std.testing.expectEqualStrings(input, r.kept);
}

test "a program killed inside the alternate screen records nothing of it" {
    const gpa = std.testing.allocator;
    const input = "start\x1b[?1049hnever came back";
    const r = try filterAll(gpa, input, 4);
    defer gpa.free(r.kept);
    try std.testing.expectEqualStrings("start", r.kept);
    try std.testing.expectEqual(@as(u32, 1), r.regions);
}

test "several full-screen programs in one interaction" {
    const gpa = std.testing.allocator;
    const input = "a\x1b[?1049hx\x1b[?1049lb\x1b[?1049hy\x1b[?1049lc";
    const r = try filterAll(gpa, input, 5);
    defer gpa.free(r.kept);
    try std.testing.expectEqualStrings("abc", r.kept);
    try std.testing.expectEqual(@as(u32, 2), r.regions);
}
