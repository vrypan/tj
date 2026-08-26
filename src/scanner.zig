//! Streaming scanner over the shell-to-terminal byte stream.
//!
//! It recognises exactly two OSC families and treats everything else as
//! opaque bytes:
//!
//!   * `OSC 5107 ; tj ; ...`  the tj protocol - consumed, not shown to the
//!     terminal (unless `keep_osc`), and turned into events.
//!   * `OSC 133 ; ...`        shell integration boundaries - turned into
//!     events *and* forwarded, since the outer terminal may implement them too.
//!
//! Two rules drive the design. Any sequence may be split across reads, so all
//! partial-match state lives in the struct rather than on the stack. And no
//! byte the program wrote may ever be swallowed: a sequence that never
//! terminates is abandoned after `max_osc` bytes and replayed verbatim.
//!
//! Only sequences that might still turn out to be tj's are withheld. The
//! moment the payload cannot match `tj_prefix`, everything buffered so far is
//! released and the rest streams straight through, so a terminal emitting a
//! megabyte inline image is never held up.

const std = @import("std");

const esc = 0x1b;
const bel = 0x07;

/// Also the point at which an unterminated sequence is abandoned.
pub const max_osc = 8192;

const tj_prefix = "5107;tj;";
const osc133_prefix = "133;";

pub const Event = union(enum) {
    /// `OSC 133;A` - the shell is about to draw a prompt.
    prompt_start,
    /// `OSC 5107;tj;cmd;<base64>` - the command line as the user typed it.
    command_line: []const u8,
    /// `OSC 5107;tj;expanded;<base64>` - the same line after the shell
    /// integration rewrote journal references into paths. Only sent when the
    /// two differ.
    command_expanded: []const u8,
    /// `OSC 133;C` - the command starts running now.
    command_run,
    /// `OSC 133;D[;rc]` - the command finished.
    command_end: ?u8,
    /// A malformed or unsupported tj sequence. Carries the payload for the
    /// session log; the sequence itself is dropped.
    protocol_error: []const u8,
};

const State = enum {
    /// Ordinary bytes.
    ground,
    /// Saw ESC, waiting to see whether it opens an OSC.
    esc,
    /// Inside an OSC whose payload still matches `tj_prefix`. Withheld.
    probe,
    /// Inside a confirmed tj sequence. Withheld.
    capture,
    /// Inside an OSC that is not tj's. Already forwarded; still buffered so
    /// the payload can be parsed for OSC 133 events.
    pass,
};

pub const Scanner = struct {
    /// Forward tj's own sequences to the terminal instead of consuming them.
    keep_osc: bool = false,

    state: State = .ground,
    buf: [max_osc]u8 = undefined,
    len: usize = 0,
    /// The payload outgrew `buf`; events cannot be parsed from it.
    overflowed: bool = false,
    /// Saw ESC inside an OSC: the next byte decides whether it was ST.
    esc_pending: bool = false,
    /// Which terminator ended the sequence, so `keep_osc` can replay it exactly.
    terminator: u8 = esc,

    /// `sink` must provide:
    ///   data(bytes)    - forward to the terminal and record into `out`
    ///   control(bytes) - forward to the terminal only
    ///   event(Event)
    pub fn feed(self: *Scanner, bytes: []const u8, sink: anytype) void {
        var i: usize = 0;
        while (i < bytes.len) switch (self.state) {
            .ground => {
                const start = i;
                while (i < bytes.len and bytes[i] != esc) i += 1;
                if (i > start) sink.data(bytes[start..i]);
                if (i < bytes.len) {
                    i += 1;
                    self.state = .esc;
                }
            },
            .esc => {
                const byte = bytes[i];
                i += 1;
                switch (byte) {
                    ']' => {
                        self.state = .probe;
                        self.len = 0;
                        self.overflowed = false;
                        self.esc_pending = false;
                    },
                    esc => sink.data(&[_]u8{esc}),
                    else => {
                        sink.data(&[_]u8{ esc, byte });
                        self.state = .ground;
                    },
                }
            },
            .probe, .capture => i = self.scanWithheld(bytes, i, sink),
            .pass => i = self.scanPassthrough(bytes, i, sink),
        };
    }

    /// Called when the stream ends mid-sequence: nothing may be left withheld.
    pub fn flush(self: *Scanner, sink: anytype) void {
        switch (self.state) {
            .esc => sink.data(&[_]u8{esc}),
            // An ESC seen but not yet resolved was never forwarded either.
            .probe, .capture => self.abandon(sink, if (self.esc_pending) &[_]u8{esc} else &.{}),
            .ground, .pass => {},
        }
        self.state = .ground;
        self.len = 0;
        self.esc_pending = false;
    }

    /// Inside a sequence that might be tj's, so bytes are held back until we
    /// know whether the terminal should see them.
    fn scanWithheld(self: *Scanner, bytes: []const u8, from: usize, sink: anytype) usize {
        var i = from;
        while (i < bytes.len) {
            const byte = bytes[i];
            i += 1;

            if (self.esc_pending) {
                self.esc_pending = false;
                if (byte == '\\') {
                    self.terminator = esc;
                    self.finishTj(sink);
                    return i;
                }
                if (!self.push(esc)) {
                    self.abandon(sink, &[_]u8{ esc, byte });
                    return i;
                }
                if (!self.push(byte)) {
                    self.abandon(sink, &[_]u8{byte});
                    return i;
                }
            } else if (byte == esc) {
                self.esc_pending = true;
                continue;
            } else if (byte == bel) {
                self.terminator = bel;
                self.finishTj(sink);
                return i;
            } else if (!self.push(byte)) {
                self.abandon(sink, &[_]u8{byte});
                return i;
            }

            if (self.state == .probe) {
                self.classify(sink);
                if (self.state == .pass) return i;
            }
        }
        return i;
    }

    /// Inside a sequence that is not tj's. Bytes go straight out; a copy is
    /// kept only so OSC 133 can be parsed at the terminator.
    fn scanPassthrough(self: *Scanner, bytes: []const u8, from: usize, sink: anytype) usize {
        var i = from;
        const start = i;
        var terminated = false;

        while (i < bytes.len) {
            const byte = bytes[i];
            i += 1;

            if (self.esc_pending) {
                self.esc_pending = false;
                if (byte == '\\') {
                    terminated = true;
                    break;
                }
                _ = self.push(esc);
                _ = self.push(byte);
            } else if (byte == esc) {
                self.esc_pending = true;
            } else if (byte == bel) {
                terminated = true;
                break;
            } else {
                _ = self.push(byte);
            }
        }

        sink.data(bytes[start..i]);

        if (terminated) {
            self.finishPassthrough(sink);
            self.state = .ground;
            self.len = 0;
        } else if (self.overflowed) {
            // Nothing was withheld, so there is nothing to replay; just stop
            // scanning for a terminator that is clearly not coming.
            self.state = .ground;
            self.len = 0;
            self.esc_pending = false;
        }
        return i;
    }

    /// Decide whether the payload so far can still be a tj sequence.
    fn classify(self: *Scanner, sink: anytype) void {
        const shared = @min(self.len, tj_prefix.len);
        if (std.mem.eql(u8, self.buf[0..shared], tj_prefix[0..shared])) {
            if (self.len >= tj_prefix.len) self.state = .capture;
            return;
        }
        // Not ours. Release what was withheld and stream the remainder.
        sink.data(&[_]u8{ esc, ']' });
        sink.data(self.buf[0..self.len]);
        self.state = .pass;
    }

    fn push(self: *Scanner, byte: u8) bool {
        if (self.len >= self.buf.len) {
            self.overflowed = true;
            return false;
        }
        self.buf[self.len] = byte;
        self.len += 1;
        return true;
    }

    /// An OSC that never terminated. Give the bytes back to the terminal
    /// exactly as they arrived rather than eating them. `pending` carries the
    /// bytes that did not fit in the buffer, which would otherwise be lost.
    fn abandon(self: *Scanner, sink: anytype, pending: []const u8) void {
        sink.data(&[_]u8{ esc, ']' });
        sink.data(self.buf[0..self.len]);
        if (pending.len > 0) sink.data(pending);
        self.state = .ground;
        self.len = 0;
        self.esc_pending = false;
    }

    fn finishTj(self: *Scanner, sink: anytype) void {
        if (self.keep_osc) {
            sink.control(&[_]u8{ esc, ']' });
            sink.control(self.buf[0..self.len]);
            if (self.terminator == bel) {
                sink.control(&[_]u8{bel});
            } else {
                sink.control(&[_]u8{ esc, '\\' });
            }
        }

        const payload = self.buf[0..self.len];
        self.state = .ground;
        self.len = 0;

        if (self.overflowed or payload.len < tj_prefix.len) {
            sink.event(.{ .protocol_error = payload });
            return;
        }
        const rest = payload[tj_prefix.len..];

        if (std.mem.startsWith(u8, rest, "cmd;") or std.mem.startsWith(u8, rest, "expanded;")) {
            const is_expanded = rest[0] == 'e';
            const encoded = rest[if (is_expanded) "expanded;".len else "cmd;".len..];
            var decoded: [max_osc]u8 = undefined;
            const decoder = std.base64.standard.Decoder;
            const size = decoder.calcSizeForSlice(encoded) catch {
                sink.event(.{ .protocol_error = payload });
                return;
            };
            if (size > decoded.len) {
                sink.event(.{ .protocol_error = payload });
                return;
            }
            decoder.decode(decoded[0..size], encoded) catch {
                sink.event(.{ .protocol_error = payload });
                return;
            };
            if (is_expanded) {
                sink.event(.{ .command_expanded = decoded[0..size] });
            } else {
                sink.event(.{ .command_line = decoded[0..size] });
            }
            return;
        }

        // `begin` and `end` publish output resources; not implemented yet, but
        // already stripped from the stream so programs can emit them safely.
        if (std.mem.startsWith(u8, rest, "begin;") or std.mem.eql(u8, rest, "end")) return;

        sink.event(.{ .protocol_error = payload });
    }

    fn finishPassthrough(self: *Scanner, sink: anytype) void {
        if (self.overflowed) return;
        const payload = self.buf[0..self.len];
        if (!std.mem.startsWith(u8, payload, osc133_prefix)) return;

        var fields = std.mem.splitScalar(u8, payload[osc133_prefix.len..], ';');
        const kind = fields.next() orelse return;
        if (kind.len != 1) return;

        switch (kind[0]) {
            'A' => sink.event(.prompt_start),
            'C' => sink.event(.command_run),
            'D' => {
                const code = fields.next();
                sink.event(.{ .command_end = if (code) |text| std.fmt.parseInt(u8, text, 10) catch null else null });
            },
            else => {},
        }
    }
};

// --- tests -----------------------------------------------------------------

const Recorder = struct {
    gpa: std.mem.Allocator,
    forwarded: std.ArrayList(u8) = .empty,
    recorded: std.ArrayList(u8) = .empty,
    events: std.ArrayList(Event) = .empty,

    fn deinit(self: *Recorder) void {
        for (self.events.items) |recorded_event| switch (recorded_event) {
            .command_line, .command_expanded, .protocol_error => |text| self.gpa.free(text),
            else => {},
        };
        self.forwarded.deinit(self.gpa);
        self.recorded.deinit(self.gpa);
        self.events.deinit(self.gpa);
    }

    fn data(self: *Recorder, bytes: []const u8) void {
        self.forwarded.appendSlice(self.gpa, bytes) catch unreachable;
        self.recorded.appendSlice(self.gpa, bytes) catch unreachable;
    }

    fn control(self: *Recorder, bytes: []const u8) void {
        self.forwarded.appendSlice(self.gpa, bytes) catch unreachable;
    }

    fn event(self: *Recorder, ev: Event) void {
        // The scanner hands out slices of its own scratch buffer.
        const owned: Event = switch (ev) {
            .command_line => |text| .{ .command_line = self.gpa.dupe(u8, text) catch unreachable },
            .command_expanded => |text| .{ .command_expanded = self.gpa.dupe(u8, text) catch unreachable },
            .protocol_error => |text| .{ .protocol_error = self.gpa.dupe(u8, text) catch unreachable },
            else => ev,
        };
        self.events.append(self.gpa, owned) catch unreachable;
    }
};

/// Feeds `input` in `chunk` sized pieces to prove the scanner is insensitive
/// to how the stream is cut up.
fn run(gpa: std.mem.Allocator, input: []const u8, chunk: usize, keep_osc: bool) Recorder {
    var recorder: Recorder = .{ .gpa = gpa };
    var scanner: Scanner = .{ .keep_osc = keep_osc };
    var i: usize = 0;
    while (i < input.len) {
        const end = @min(i + chunk, input.len);
        scanner.feed(input[i..end], &recorder);
        i = end;
    }
    scanner.flush(&recorder);
    return recorder;
}

test "ordinary output passes through untouched" {
    const gpa = std.testing.allocator;
    const input = "hello\r\n\x1b[31mred\x1b[0m\r\n";
    var r = run(gpa, input, input.len, false);
    defer r.deinit();
    try std.testing.expectEqualStrings(input, r.forwarded.items);
    try std.testing.expectEqualStrings(input, r.recorded.items);
    try std.testing.expectEqual(@as(usize, 0), r.events.items.len);
}

test "tj sequences are stripped from the stream" {
    const gpa = std.testing.allocator;
    // "ls -l" base64 encodes to bHMgLWw=
    const input = "a\x1b]5107;tj;cmd;bHMgLWw=\x1b\\b";
    var r = run(gpa, input, input.len, false);
    defer r.deinit();
    try std.testing.expectEqualStrings("ab", r.forwarded.items);
    try std.testing.expectEqualStrings("ab", r.recorded.items);
    try std.testing.expectEqual(@as(usize, 1), r.events.items.len);
    try std.testing.expectEqualStrings("ls -l", r.events.items[0].command_line);
}

test "keep_osc forwards tj sequences but never records them" {
    const gpa = std.testing.allocator;
    const input = "a\x1b]5107;tj;cmd;bHMgLWw=\x1b\\b";
    var r = run(gpa, input, input.len, true);
    defer r.deinit();
    try std.testing.expectEqualStrings(input, r.forwarded.items);
    try std.testing.expectEqualStrings("ab", r.recorded.items);
}

test "OSC 133 boundaries are forwarded and reported" {
    const gpa = std.testing.allocator;
    const input = "\x1b]133;A\x1b\\\x1b]133;C\x07out\x1b]133;D;7\x1b\\";
    var r = run(gpa, input, input.len, false);
    defer r.deinit();
    try std.testing.expectEqualStrings(input, r.forwarded.items);
    try std.testing.expectEqual(@as(usize, 3), r.events.items.len);
    try std.testing.expect(r.events.items[0] == .prompt_start);
    try std.testing.expect(r.events.items[1] == .command_run);
    try std.testing.expectEqual(@as(?u8, 7), r.events.items[2].command_end);
}

test "OSC 133;D without a status reports no status" {
    const gpa = std.testing.allocator;
    const input = "\x1b]133;D\x1b\\";
    var r = run(gpa, input, input.len, false);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 1), r.events.items.len);
    try std.testing.expectEqual(@as(?u8, null), r.events.items[0].command_end);
}

test "other OSC consumers are left alone" {
    const gpa = std.testing.allocator;
    // Same OSC number, different second field: not ours, must not be stripped.
    const input = "\x1b]5107;other;stuff\x1b\\\x1b]0;window title\x07";
    var r = run(gpa, input, input.len, false);
    defer r.deinit();
    try std.testing.expectEqualStrings(input, r.forwarded.items);
    try std.testing.expectEqual(@as(usize, 0), r.events.items.len);
}

test "a tj-lookalike prefix is not stripped" {
    const gpa = std.testing.allocator;
    const input = "\x1b]5107;tjunk;x\x1b\\";
    var r = run(gpa, input, input.len, false);
    defer r.deinit();
    try std.testing.expectEqualStrings(input, r.forwarded.items);
}

test "an unterminated sequence is replayed rather than swallowed" {
    const gpa = std.testing.allocator;
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(gpa);
    try input.appendSlice(gpa, "\x1b]5107;tj;cmd;");
    try input.appendSlice(gpa, "A" ** (max_osc + 100));

    var r = run(gpa, input.items, 512, false);
    defer r.deinit();
    // Everything up to the abandon point comes back out, and the tail streams
    // through as ordinary bytes: no byte is lost.
    try std.testing.expectEqual(input.items.len, r.forwarded.items.len);
    try std.testing.expectEqualStrings(input.items, r.forwarded.items);
}

test "a stream ending mid-sequence releases what was withheld" {
    const gpa = std.testing.allocator;
    const input = "x\x1b]5107;tj;cm";
    var r = run(gpa, input, input.len, false);
    defer r.deinit();
    try std.testing.expectEqualStrings(input, r.forwarded.items);
}

test "a lone trailing ESC is not eaten" {
    const gpa = std.testing.allocator;
    var r = run(gpa, "abc\x1b", 1, false);
    defer r.deinit();
    try std.testing.expectEqualStrings("abc\x1b", r.forwarded.items);
}

test "ESC inside an OSC payload is not mistaken for a terminator" {
    const gpa = std.testing.allocator;
    const input = "\x1b]0;a\x1bXb\x07";
    var r = run(gpa, input, input.len, false);
    defer r.deinit();
    try std.testing.expectEqualStrings(input, r.forwarded.items);
}

test "results are identical however the stream is chunked" {
    const gpa = std.testing.allocator;
    const input =
        "prompt$ \x1b]133;A\x1b\\" ++
        "\x1b]5107;tj;cmd;ZWNobyBoaQ==\x1b\\" ++
        "\x1b]133;C\x07" ++
        "hi\r\n\x1b[32mgreen\x1b[0m" ++
        "\x1b]0;title\x07" ++
        "\x1b]133;D;0\x1b\\" ++
        "next$ ";

    var whole = run(gpa, input, input.len, false);
    defer whole.deinit();

    var chunk: usize = 1;
    while (chunk <= input.len) : (chunk += 1) {
        var piece = run(gpa, input, chunk, false);
        defer piece.deinit();
        try std.testing.expectEqualStrings(whole.forwarded.items, piece.forwarded.items);
        try std.testing.expectEqualStrings(whole.recorded.items, piece.recorded.items);
        try std.testing.expectEqual(whole.events.items.len, piece.events.items.len);
        for (whole.events.items, piece.events.items) |expected, actual| {
            try std.testing.expectEqual(std.meta.activeTag(expected), std.meta.activeTag(actual));
            if (expected == .command_line) {
                try std.testing.expectEqualStrings(expected.command_line, actual.command_line);
            }
        }
    }
}

test "the forwarded stream is byte-identical to the input when nothing is ours" {
    const gpa = std.testing.allocator;
    const input =
        "\x1b[?2004h\x1b]0;zsh\x07$ \x1b]133;A\x1b\\ls\r\n" ++
        "\x1b]7;file://host/tmp\x1b\\\x1b[1mbold\x1b[0m\x07\r\n";

    var chunk: usize = 1;
    while (chunk <= input.len) : (chunk += 1) {
        var r = run(gpa, input, chunk, false);
        defer r.deinit();
        try std.testing.expectEqualStrings(input, r.forwarded.items);
    }
}
