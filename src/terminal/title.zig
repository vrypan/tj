//! Terminal-title lifecycle and streaming OSC filtering.
//!
//! Writers use the title stack and fallback helpers. Replay uses the streaming
//! scanner to omit recorded title changes without altering journal bytes.

const std = @import("std");
const c = std.c;
const sys = @import("../sys.zig");

const esc = 0x1b;
const bel = 0x07;
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
    const sequence = std.fmt.bufPrint(&buf, "\x1b]0;{s}\x1b\\", .{journal}) catch return;
    sys.writeAll(fd, sequence) catch {};
}

const State = enum { ground, escape, probe, title, pass };
pub const Mode = enum { pass, omit, capture };

const BoundaryState = enum {
    ground,
    escape,
    csi,
    osc,
    osc_escape,
    control_string,
    control_string_escape,
};

/// Tracks whether a complete title sequence can be inserted without splitting
/// a control sequence emitted by the child across PTY reads.
const ControlBoundary = struct {
    state: BoundaryState = .ground,

    fn safe(self: *const ControlBoundary) bool {
        return self.state == .ground;
    }

    fn feed(self: *ControlBoundary, bytes: []const u8) void {
        for (bytes) |byte| self.feedByte(byte);
    }

    fn feedByte(self: *ControlBoundary, byte: u8) void {
        if (self.state != .ground and (byte == 0x18 or byte == 0x1a)) {
            self.state = .ground;
            return;
        }
        if (byte == 0x9c) {
            self.state = .ground;
            return;
        }

        self.state = switch (self.state) {
            .ground => switch (byte) {
                esc => .escape,
                0x9b => .csi,
                0x9d => .osc,
                0x90, 0x98, 0x9e, 0x9f => .control_string,
                else => .ground,
            },
            .escape => switch (byte) {
                '[' => .csi,
                ']' => .osc,
                'P', 'X', '^', '_' => .control_string,
                0x20...0x2f => .escape,
                else => .ground,
            },
            .csi => switch (byte) {
                esc => .escape,
                0x40...0x7e => .ground,
                else => .csi,
            },
            .osc => switch (byte) {
                esc => .osc_escape,
                bel => .ground,
                else => .osc,
            },
            .osc_escape => if (byte == '\\') .ground else if (byte == esc) .osc_escape else .osc,
            .control_string => if (byte == esc) .control_string_escape else .control_string,
            .control_string_escape => if (byte == '\\') .ground else if (byte == esc) .control_string_escape else .control_string,
        };
    }
};

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
                const recognized = self.state == .title;
                if (!recognized or (self.mode != .omit and self.mode != .capture)) {
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
        const capture = self.state == .title and self.mode == .capture;
        // A still-probing one-byte OSC is not a title after all.
        if (self.state != .title) {
            try sink.emit(&[_]u8{ esc, ']' });
            try sink.emit(self.buf[0..self.len]);
        } else if (capture) {
            try sink.title(self.buf[0], self.buf[2..self.len]);
        } else if (!omit) {
            try sink.emit(&[_]u8{ esc, ']' });
            try sink.emit(self.buf[0..self.len]);
        }
        if (!omit and !capture) try sink.emit(if (terminated_by_bel) &[_]u8{bel} else &[_]u8{ esc, '\\' });
        self.state = .ground;
        self.len = 0;
        self.esc_pending = false;
    }
};

/// Captures application titles and periodically redraws them with a fixed-width
/// recording marker. The proxy owns all calls, so writes cannot interleave
/// with bytes being forwarded from the child PTY.
pub const Blinker = struct {
    fd: sys.Fd,
    interval_ms: u32,
    next_tick_ms: i64,
    filled: bool = true,
    parser: Decorator = .{ .mode = .capture },
    boundary: ControlBoundary = .{},
    window: [max_title]u8 = undefined,
    window_len: usize = 0,
    icon: [max_title]u8 = undefined,
    icon_len: usize = 0,
    has_window: bool = false,
    has_icon: bool = false,

    pub fn init(fd: sys.Fd, interval_ms: u32, now_ms: i64) Blinker {
        std.debug.assert(interval_ms != 0);
        return .{
            .fd = fd,
            .interval_ms = interval_ms,
            .next_tick_ms = now_ms + @as(i64, interval_ms),
        };
    }

    pub fn startJournal(self: *Blinker, journal: []const u8) !void {
        const initial = std.fmt.bufPrint(&self.window, "{s}", .{journal}) catch return error.TitleTooLong;
        self.window_len = initial.len;
        @memcpy(self.icon[0..initial.len], initial);
        self.icon_len = initial.len;
        self.has_window = true;
        self.has_icon = true;
        try self.writeTitle('0', initial);
    }

    pub fn feed(self: *Blinker, bytes: []const u8) !void {
        try self.parser.feed(bytes, self);
    }

    pub fn flush(self: *Blinker) !void {
        try self.parser.flush(self);
    }

    /// Called by the capture parser for bytes that are not title sequences.
    pub fn emit(self: *Blinker, bytes: []const u8) !void {
        self.boundary.feed(bytes);
        try sys.writeAll(self.fd, bytes);
    }

    /// Called only for a complete, bounded OSC 0, 1, or 2 title.
    pub fn title(self: *Blinker, selector: u8, value: []const u8) !void {
        switch (selector) {
            '0' => {
                self.storeTitle(&self.window, &self.window_len, &self.has_window, value);
                self.storeTitle(&self.icon, &self.icon_len, &self.has_icon, value);
            },
            '1' => self.storeTitle(&self.icon, &self.icon_len, &self.has_icon, value),
            '2' => self.storeTitle(&self.window, &self.window_len, &self.has_window, value),
            else => unreachable,
        }
        try self.writeTitle(selector, value);
    }

    pub fn timeout(self: *const Blinker, now_ms: i64) c_int {
        if (now_ms >= self.next_tick_ms) {
            if (!self.boundary.safe()) return @intCast(self.interval_ms);
            return 0;
        }
        return @intCast(self.next_tick_ms - now_ms);
    }

    pub fn tick(self: *Blinker, now_ms: i64) !void {
        if (now_ms < self.next_tick_ms) return;
        if (!self.boundary.safe()) return;
        self.filled = !self.filled;
        self.next_tick_ms = now_ms + @as(i64, self.interval_ms);

        if (self.has_window and self.has_icon and
            std.mem.eql(u8, self.window[0..self.window_len], self.icon[0..self.icon_len]))
        {
            try self.writeTitle('0', self.window[0..self.window_len]);
            return;
        }
        if (self.has_icon) try self.writeTitle('1', self.icon[0..self.icon_len]);
        if (self.has_window) try self.writeTitle('2', self.window[0..self.window_len]);
    }

    fn storeTitle(self: *Blinker, dest: *[max_title]u8, len: *usize, present: *bool, value: []const u8) void {
        _ = self;
        @memcpy(dest[0..value.len], value);
        len.* = value.len;
        present.* = true;
    }

    fn writeTitle(self: *Blinker, selector: u8, value: []const u8) !void {
        const lead = [_]u8{ esc, ']', selector, ';' };
        try sys.writeAll(self.fd, &lead);
        try sys.writeAll(self.fd, if (self.filled) "● " else "○ ");
        try sys.writeAll(self.fd, value);
        try sys.writeAll(self.fd, &[_]u8{ esc, '\\' });
    }
};

fn isTitleSelector(byte: u8) bool {
    return byte == '0' or byte == '1' or byte == '2';
}

test "title insertion waits for split terminal control sequences" {
    var boundary: ControlBoundary = .{};
    for ([_]struct { first: []const u8, second: []const u8 }{
        .{ .first = "\x1b[31", .second = "m" },
        .{ .first = "\x1b]777;partial", .second = "\x1b\\" },
        .{ .first = "\x1bPpayload", .second = "\x1b\\" },
        .{ .first = "\x9b31", .second = "m" },
    }) |sequence| {
        boundary.feed(sequence.first);
        try std.testing.expect(!boundary.safe());
        boundary.feed(sequence.second);
        try std.testing.expect(boundary.safe());
    }

    boundary.feed("\x1b]777;partial");
    var blinker = Blinker.init(-1, 100, 0);
    blinker.boundary = boundary;
    try std.testing.expectEqual(@as(c_int, 100), blinker.timeout(100));
    try blinker.tick(100);
    try std.testing.expectEqual(@as(i64, 100), blinker.next_tick_ms);
}

const TestSink = struct {
    gpa: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,

    pub fn emit(self: *TestSink, bytes: []const u8) !void {
        try self.bytes.appendSlice(self.gpa, bytes);
    }

    pub fn title(self: *TestSink, selector: u8, value: []const u8) !void {
        try self.bytes.append(self.gpa, selector);
        try self.bytes.appendSlice(self.gpa, ":");
        try self.bytes.appendSlice(self.gpa, value);
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

test "title capture reports complete titles and forwards everything else" {
    const gpa = std.testing.allocator;
    const input = "a\x1b]0;both\x07b\x1b]1;tab\x1b\\c\x1b]2;window\x1b\\d";
    const expected = "a0:bothb1:tabc2:windowd";
    var chunk: usize = 1;
    while (chunk <= input.len) : (chunk += 1) {
        const actual = try transform(gpa, input, chunk, .capture);
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

test "disabled title handling is byte transparent" {
    const gpa = std.testing.allocator;
    const input = "before\x1b]2;unfinished\x1b";
    const disabled = try transform(gpa, input, 1, .pass);
    defer gpa.free(disabled);
    try std.testing.expectEqualStrings(input, disabled);
}
