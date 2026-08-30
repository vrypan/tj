//! Terminal-title lifecycle and streaming OSC filtering.
//!
//! Writers use the title stack and fallback helpers. Replay uses the streaming
//! scanner to omit recorded title changes without altering journal bytes.

const std = @import("std");
const c = std.c;
const sys = @import("sys.zig");

const esc = 0x1b;
const bel = 0x07;
const prefix = "TJ |";
const max_title = 32 * 1024;

pub const push_sequence = "\x1b[22;0t";
pub const pop_sequence = "\x1b[23;0t";

/// A title stack is process-global terminal state. This flag lets panic and
/// splash signal paths restore it even though Zig will not run defers there.
var title_pushed: std.atomic.Value(bool) = .init(false);

pub fn push(fd: sys.Fd) void {
    sys.writeAll(fd, push_sequence) catch return;
    title_pushed.store(true, .monotonic);
}

pub fn pop(fd: sys.Fd) void {
    if (!title_pushed.swap(false, .monotonic)) return;
    sys.writeAll(fd, pop_sequence) catch {};
}

/// Uses only the async-signal-safe `write(2)` operation.
pub fn restoreFromSignal(fd: sys.Fd) void {
    if (!title_pushed.swap(false, .monotonic)) return;
    _ = c.write(fd, pop_sequence.ptr, pop_sequence.len);
}

pub fn writeFallback(fd: sys.Fd, journal: []const u8) void {
    var buf: [128]u8 = undefined;
    const sequence = std.fmt.bufPrint(&buf, "\x1b]0;TJ | {s}\x1b\\", .{journal}) catch return;
    sys.writeAll(fd, sequence) catch {};
}

const State = enum { ground, escape, probe, title, pass };
pub const Mode = enum { pass, prefix, omit };

pub const Decorator = struct {
    mode: Mode = .pass,
    state: State = .ground,
    buf: [max_title]u8 = undefined,
    len: usize = 0,
    esc_pending: bool = false,

    /// `sink` provides `emit(bytes)`, which writes bytes to the outer terminal.
    pub fn feed(self: *Decorator, bytes: []const u8, sink: anytype) !void {
        if (self.mode == .pass) {
            try sink.emit(bytes);
            return;
        }

        var i: usize = 0;
        while (i < bytes.len) switch (self.state) {
            .ground => {
                const start = i;
                while (i < bytes.len and bytes[i] != esc) i += 1;
                if (i > start) try sink.emit(bytes[start..i]);
                if (i < bytes.len) {
                    i += 1;
                    self.state = .escape;
                }
            },
            .escape => {
                const byte = bytes[i];
                i += 1;
                if (byte == ']') {
                    self.state = .probe;
                    self.len = 0;
                    self.esc_pending = false;
                } else {
                    try sink.emit(&[_]u8{ esc, byte });
                    self.state = .ground;
                }
            },
            .probe, .title => i = try self.scanCandidate(bytes, i, sink),
            .pass => i = try self.scanPass(bytes, i, sink),
        };
    }

    /// Releases a partial sequence exactly as received at end of stream.
    pub fn flush(self: *Decorator, sink: anytype) !void {
        switch (self.state) {
            .ground => {},
            .escape => try sink.emit(&[_]u8{esc}),
            .probe, .title => {
                // In omit mode, a recognized title prefix is unsafe to replay
                // even without its terminator: it would leave the terminal
                // consuming subsequent screen output as title text.
                if (self.mode != .omit) {
                    try sink.emit(&[_]u8{ esc, ']' });
                    try sink.emit(self.buf[0..self.len]);
                    if (self.esc_pending) try sink.emit(&[_]u8{esc});
                }
            },
            .pass => if (self.esc_pending) try sink.emit(&[_]u8{esc}),
        }
        self.state = .ground;
        self.len = 0;
        self.esc_pending = false;
    }

    fn scanCandidate(self: *Decorator, bytes: []const u8, from: usize, sink: anytype) !usize {
        var i = from;
        while (i < bytes.len) {
            const byte = bytes[i];
            i += 1;

            if (self.esc_pending) {
                self.esc_pending = false;
                if (byte == '\\') {
                    try self.finishTitle(sink, false);
                    return i;
                }
                if (self.state == .title and self.mode == .omit) {
                    // The body is deliberately discarded, so an omitted title
                    // has no length-dependent memory or transparency limit.
                } else if (self.len > self.buf.len - 2) {
                    try self.releaseCandidate(sink);
                    try sink.emit(&[_]u8{ esc, byte });
                    return i;
                } else {
                    _ = self.pushByte(esc);
                    _ = self.pushByte(byte);
                }
            } else if (byte == esc) {
                self.esc_pending = true;
                continue;
            } else if (byte == bel) {
                try self.finishTitle(sink, true);
                return i;
            } else if (self.state == .title and self.mode == .omit) {
                // Keep scanning only for BEL or ST.
            } else if (!self.pushByte(byte)) {
                try self.releaseCandidate(sink);
                try sink.emit(bytes[i - 1 .. i]);
                return i;
            }

            if (self.state == .probe) try self.classify(sink);
            if (self.state == .pass) return i;
        }
        return i;
    }

    fn classify(self: *Decorator, sink: anytype) !void {
        if (self.len == 1) {
            if (isTitleSelector(self.buf[0])) return;
            try self.releaseCandidate(sink);
            return;
        }
        if (self.len >= 2) {
            if (isTitleSelector(self.buf[0]) and self.buf[1] == ';') {
                self.state = .title;
            } else {
                try self.releaseCandidate(sink);
            }
        }
    }

    fn scanPass(self: *Decorator, bytes: []const u8, from: usize, sink: anytype) !usize {
        var i = from;
        while (i < bytes.len) {
            const byte = bytes[i];
            i += 1;
            try sink.emit(bytes[i - 1 .. i]);
            if (self.esc_pending) {
                self.esc_pending = false;
                if (byte == '\\') {
                    self.state = .ground;
                    return i;
                }
            } else if (byte == esc) {
                self.esc_pending = true;
            } else if (byte == bel) {
                self.state = .ground;
                return i;
            }
        }
        return i;
    }

    fn pushByte(self: *Decorator, byte: u8) bool {
        if (self.len == self.buf.len) return false;
        self.buf[self.len] = byte;
        self.len += 1;
        return true;
    }

    fn releaseCandidate(self: *Decorator, sink: anytype) !void {
        try sink.emit(&[_]u8{ esc, ']' });
        try sink.emit(self.buf[0..self.len]);
        self.state = .pass;
        self.len = 0;
        self.esc_pending = false;
    }

    fn finishTitle(self: *Decorator, sink: anytype, terminated_by_bel: bool) !void {
        const omit = self.state == .title and self.mode == .omit;
        // A still-probing one-byte OSC is not a title after all.
        if (self.state != .title) {
            try sink.emit(&[_]u8{ esc, ']' });
            try sink.emit(self.buf[0..self.len]);
        } else if (!omit) {
            try sink.emit(&[_]u8{ esc, ']' });
            try sink.emit(self.buf[0..2]);
            const title = self.buf[2..self.len];
            if (!std.mem.startsWith(u8, title, prefix)) {
                try sink.emit(prefix);
                if (title.len != 0) try sink.emit(" ");
            }
            try sink.emit(title);
        }
        if (!omit) try sink.emit(if (terminated_by_bel) &[_]u8{bel} else &[_]u8{ esc, '\\' });
        self.state = .ground;
        self.len = 0;
        self.esc_pending = false;
    }
};

fn isTitleSelector(byte: u8) bool {
    return byte == '0' or byte == '1' or byte == '2';
}

const TestSink = struct {
    gpa: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,

    pub fn emit(self: *TestSink, bytes: []const u8) !void {
        try self.bytes.appendSlice(self.gpa, bytes);
    }
};

fn transform(gpa: std.mem.Allocator, input: []const u8, chunk: usize, mode: Mode) ![]u8 {
    var sink: TestSink = .{ .gpa = gpa };
    defer sink.bytes.deinit(gpa);
    var decorator: Decorator = .{ .mode = mode };
    var at: usize = 0;
    while (at < input.len) {
        const end = @min(input.len, at + chunk);
        try decorator.feed(input[at..end], &sink);
        at = end;
    }
    try decorator.flush(&sink);
    return gpa.dupe(u8, sink.bytes.items);
}

test "window and tab titles are prefixed across every read split" {
    const gpa = std.testing.allocator;
    const input = "a\x1b]0;~/Devel/\x07b\x1b]1;tab\x1b\\c\x1b]2;vim README.md\x1b\\d";
    const expected = "a\x1b]0;TJ | ~/Devel/\x07b\x1b]1;TJ | tab\x1b\\c\x1b]2;TJ | vim README.md\x1b\\d";
    var chunk: usize = 1;
    while (chunk <= input.len) : (chunk += 1) {
        const actual = try transform(gpa, input, chunk, .prefix);
        defer gpa.free(actual);
        try std.testing.expectEqualStrings(expected, actual);
    }
}

test "title decoration is idempotent and leaves other controls alone" {
    const gpa = std.testing.allocator;
    const input = "\x1b]2;TJ | already\x1b\\\x1b]7;file:///tmp\x07\x1b[31mred\x1b[0m";
    const actual = try transform(gpa, input, 2, .prefix);
    defer gpa.free(actual);
    try std.testing.expectEqualStrings(input, actual);
}

test "window and tab titles can be omitted across every read split" {
    const gpa = std.testing.allocator;
    const input = "a\x1b]0;historical\x07b\x1b]1;old tab\x1b\\c\x1b]2;old title\x1b\\d\x1b]7;file:///tmp\x07";
    const expected = "abcd\x1b]7;file:///tmp\x07";
    var chunk: usize = 1;
    while (chunk <= input.len) : (chunk += 1) {
        const actual = try transform(gpa, input, chunk, .omit);
        defer gpa.free(actual);
        try std.testing.expectEqualStrings(expected, actual);
    }
}

test "omitting titles is bounded and drops an unfinished title" {
    const gpa = std.testing.allocator;
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(gpa);
    try input.appendSlice(gpa, "before\x1b]2;");
    try input.appendNTimes(gpa, 'x', max_title + 100);
    try input.appendSlice(gpa, "\x1b\\after\x1b]0;unfinished");

    const actual = try transform(gpa, input.items, 17, .omit);
    defer gpa.free(actual);
    try std.testing.expectEqualStrings("beforeafter", actual);
}

test "disabled decoration and unfinished sequences are byte transparent" {
    const gpa = std.testing.allocator;
    const input = "before\x1b]2;unfinished\x1b";
    const disabled = try transform(gpa, input, 1, .pass);
    defer gpa.free(disabled);
    try std.testing.expectEqualStrings(input, disabled);
    const unfinished = try transform(gpa, input, 1, .prefix);
    defer gpa.free(unfinished);
    try std.testing.expectEqualStrings(input, unfinished);
}

test "an oversized title remains byte transparent" {
    const gpa = std.testing.allocator;
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(gpa);
    try input.appendSlice(gpa, "\x1b]2;");
    try input.appendNTimes(gpa, 'x', max_title + 100);
    try input.appendSlice(gpa, "\x1b\\after");

    const actual = try transform(gpa, input.items, 17, .prefix);
    defer gpa.free(actual);
    try std.testing.expectEqualStrings(input.items, actual);
}
