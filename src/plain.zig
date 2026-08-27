//! Renders recorded output as plain text.
//!
//! `out` holds what the terminal was sent, which is the right thing to keep
//! but the wrong thing to pipe into another program. This reduces it to the
//! text a person would have read, on the same principle the journal already
//! applies to full-screen programs: what ends up on screen, not every byte
//! that got it there.
//!
//! Escape sequences go. Carriage returns are resolved rather than passed on,
//! so a progress meter that rewrote its line thirty times contributes the one
//! line it settled on. Backspace deletes, the way `man` uses it for bold.

const std = @import("std");
const Io = std.Io;

pub const Renderer = struct {
    gpa: std.mem.Allocator,
    line: std.ArrayList(u8) = .empty,
    state: State = .text,
    pending_cr: bool = false,

    const State = enum { text, escape, csi, string, string_escape, charset };

    pub fn init(gpa: std.mem.Allocator) Renderer {
        return .{ .gpa = gpa };
    }
    pub fn deinit(self: *Renderer) void {
        self.line.deinit(self.gpa);
    }

    pub fn feed(self: *Renderer, bytes: []const u8, out: *Io.Writer) !void {
        for (bytes) |value| try self.byte(value, out);
    }

    pub fn finish(self: *Renderer, out: *Io.Writer) !void {
        // A partial escape is intentionally discarded; bytes before it have
        // already been emitted into the visible line.
        if (self.line.items.len > 0) try out.writeAll(self.line.items);
    }

    fn byte(self: *Renderer, value: u8, out: *Io.Writer) !void {
        switch (self.state) {
            .escape => switch (value) {
                '[' => self.state = .csi,
                ']' => self.state = .string,
                'P', 'X', '^', '_' => self.state = .string,
                '(', ')', '*', '+' => self.state = .charset,
                else => self.state = .text,
            },
            .charset => self.state = .text,
            .csi => {
                if (value >= 0x40 and value <= 0x7e) self.state = .text;
            },
            .string => {
                if (value == 0x07) self.state = .text else if (value == 0x1b) self.state = .string_escape;
            },
            .string_escape => self.state = if (value == '\\') .text else .string,
            .text => switch (value) {
                0x1b => self.state = .escape,
                '\r' => self.pending_cr = true,
                '\n' => {
                    try out.writeAll(self.line.items);
                    try out.writeAll("\n");
                    self.line.clearRetainingCapacity();
                    self.pending_cr = false;
                },
                0x08 => {
                    if (self.line.items.len > 0) _ = self.line.pop();
                },
                else => {
                    if (value < 0x20 and value != '\t') return;
                    if (self.pending_cr) {
                        self.line.clearRetainingCapacity();
                        self.pending_cr = false;
                    }
                    try self.line.append(self.gpa, value);
                },
            },
        }
    }
};

pub fn render(gpa: std.mem.Allocator, bytes: []const u8, out: *Io.Writer) !void {
    var renderer = Renderer.init(gpa);
    defer renderer.deinit();
    try renderer.feed(bytes, out);
    try renderer.finish(out);
}

/// Removes ANSI escape sequences, leaving the characters between them.
fn stripEscapes(gpa: std.mem.Allocator, bytes: []const u8, out: *std.ArrayList(u8)) !void {
    var i: usize = 0;
    while (i < bytes.len) {
        const byte = bytes[i];

        if (byte == 0x1b) {
            i = skipSequence(bytes, i);
            continue;
        }
        if (byte == 0x08) {
            // Backspace: `man` writes "X\bX" to embolden.
            if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') _ = out.pop();
            i += 1;
            continue;
        }
        // Other C0 controls carry no text.
        if (byte < 0x20 and byte != '\n' and byte != '\r' and byte != '\t') {
            i += 1;
            continue;
        }

        try out.append(gpa, byte);
        i += 1;
    }
}

/// Returns the index just past the escape sequence starting at `start`.
fn skipSequence(bytes: []const u8, start: usize) usize {
    var i = start + 1;
    if (i >= bytes.len) return bytes.len;

    switch (bytes[i]) {
        // CSI: parameters, then intermediates, then one final byte.
        '[' => {
            i += 1;
            while (i < bytes.len and bytes[i] >= 0x30 and bytes[i] <= 0x3f) i += 1;
            while (i < bytes.len and bytes[i] >= 0x20 and bytes[i] <= 0x2f) i += 1;
            if (i < bytes.len) i += 1;
            return i;
        },
        // OSC: ends at BEL or ST.
        ']' => return skipToStringTerminator(bytes, i + 1, true),
        // DCS, SOS, PM, APC: end at ST.
        'P', 'X', '^', '_' => return skipToStringTerminator(bytes, i + 1, false),
        // Everything else is a two-byte escape, character set selection
        // included: ESC ( B and friends take one more byte.
        '(', ')', '*', '+' => return @min(i + 2, bytes.len),
        else => return i + 1,
    }
}

fn skipToStringTerminator(bytes: []const u8, from: usize, bel_ends: bool) usize {
    var i = from;
    while (i < bytes.len) {
        if (bel_ends and bytes[i] == 0x07) return i + 1;
        if (bytes[i] == 0x1b and i + 1 < bytes.len and bytes[i + 1] == '\\') return i + 2;
        i += 1;
    }
    return bytes.len;
}

/// Within a line, everything before the last carriage return was overwritten
/// on screen and never seen.
fn resolveOverwrites(text: []const u8, out: *Io.Writer) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.writeAll("\n");
        first = false;

        // Trailing carriage returns end the line rather than overwriting it.
        // A pty commonly produces several: the program writes CRLF and the
        // terminal's own newline translation adds another CR.
        const body = std.mem.trimEnd(u8, line, "\r");

        const visible = if (std.mem.lastIndexOfScalar(u8, body, '\r')) |at|
            body[at + 1 ..]
        else
            body;
        try out.writeAll(visible);
    }
}

// --- tests -----------------------------------------------------------------

fn renderToString(gpa: std.mem.Allocator, input: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    var writer = Io.Writer.Allocating.fromArrayList(gpa, &buf);
    defer buf = writer.toArrayList();
    try render(gpa, input, &writer.writer);
    return writer.toOwnedSlice();
}

test "plain text is left alone" {
    const gpa = std.testing.allocator;
    const result = try renderToString(gpa, "hello world\nsecond line\n");
    defer gpa.free(result);
    try std.testing.expectEqualStrings("hello world\nsecond line\n", result);
}

test "colours and cursor movement are removed" {
    const gpa = std.testing.allocator;
    const result = try renderToString(gpa, "\x1b[31mred\x1b[0m and \x1b[1;32mgreen\x1b[m\n");
    defer gpa.free(result);
    try std.testing.expectEqualStrings("red and green\n", result);
}

test "window titles and other OSC sequences are removed" {
    const gpa = std.testing.allocator;
    const result = try renderToString(gpa, "\x1b]0;my title\x07text\x1b]8;;http://x\x1b\\link\n");
    defer gpa.free(result);
    try std.testing.expectEqualStrings("textlink\n", result);
}

test "carriage returns leave only what stayed on screen" {
    const gpa = std.testing.allocator;
    const result = try renderToString(gpa, "10%\r50%\r100%\ndone\n");
    defer gpa.free(result);
    try std.testing.expectEqualStrings("100%\ndone\n", result);
}

test "CRLF line endings become plain newlines" {
    const gpa = std.testing.allocator;
    const result = try renderToString(gpa, "one\r\ntwo\r\n");
    defer gpa.free(result);
    try std.testing.expectEqualStrings("one\ntwo\n", result);
}

test "the doubled carriage returns a pty produces are not overwrites" {
    const gpa = std.testing.allocator;
    // What a program writing CRLF actually looks like once the terminal has
    // applied its own newline translation.
    const result = try renderToString(gpa, "red\r\r\n10%\r100% done\r\r\n");
    defer gpa.free(result);
    try std.testing.expectEqualStrings("red\n100% done\n", result);
}

test "backspace deletes, as man pages expect" {
    const gpa = std.testing.allocator;
    const result = try renderToString(gpa, "N\x08NA\x08AM\x08ME\x08E\n");
    defer gpa.free(result);
    try std.testing.expectEqualStrings("NAME\n", result);
}

test "bracketed paste and mode switches leave no trace" {
    const gpa = std.testing.allocator;
    const result = try renderToString(gpa, "\x1b[?2004hprompt\x1b[?2004l\x1b(B\x1b=x\n");
    defer gpa.free(result);
    try std.testing.expectEqualStrings("promptx\n", result);
}

test "a truncated escape sequence does not eat the rest of the file" {
    const gpa = std.testing.allocator;
    const result = try renderToString(gpa, "text\x1b[");
    defer gpa.free(result);
    try std.testing.expectEqualStrings("text", result);
}

test "tabs survive" {
    const gpa = std.testing.allocator;
    const result = try renderToString(gpa, "a\tb\n");
    defer gpa.free(result);
    try std.testing.expectEqualStrings("a\tb\n", result);
}
