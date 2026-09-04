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
    // A line cannot be emitted until a later carriage return can no longer
    // overwrite it, so one unterminated line is the renderer's memory bound.
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

    pub fn feed(self: *Renderer, bytes: []const u8, out: anytype) !void {
        for (bytes) |value| try self.byte(value, out);
    }

    pub fn finish(self: *Renderer, out: anytype) !void {
        // A partial escape is intentionally discarded; bytes before it have
        // already been emitted into the visible line.
        if (self.line.items.len > 0) try out.writeAll(self.line.items);
    }

    fn byte(self: *Renderer, value: u8, out: anytype) !void {
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

// --- tests -----------------------------------------------------------------

fn renderToString(gpa: std.mem.Allocator, input: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    var writer = Io.Writer.Allocating.fromArrayList(gpa, &buf);
    defer buf = writer.toArrayList();
    try render(gpa, input, &writer.writer);
    return writer.toOwnedSlice();
}

fn renderChunksToString(gpa: std.mem.Allocator, input: []const u8, chunk_size: usize) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    var writer = Io.Writer.Allocating.fromArrayList(gpa, &buf);
    defer buf = writer.toArrayList();

    var renderer = Renderer.init(gpa);
    defer renderer.deinit();
    var offset: usize = 0;
    while (offset < input.len) {
        const end = @min(offset + chunk_size, input.len);
        try renderer.feed(input[offset..end], &writer.writer);
        offset = end;
    }
    try renderer.finish(&writer.writer);
    return writer.toOwnedSlice();
}

test "plain rendering is invariant across chunk boundaries" {
    const gpa = std.testing.allocator;
    const fixtures = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "plain\nfinal line", .expected = "plain\nfinal line" },
        .{ .input = "a\x1b[31mred\x1b[0mz\n", .expected = "aredz\n" },
        .{ .input = "title\x1b]0;hidden\x07shown\n", .expected = "titleshown\n" },
        .{ .input = "text\x1b", .expected = "text" },
        .{ .input = "one\r\ntwo\r\n", .expected = "one\ntwo\n" },
        .{ .input = "N\x08NA\x08AM\x08ME\x08E\n", .expected = "NAME\n" },
        .{ .input = "10%\r50%\r100%\ndone", .expected = "100%\ndone" },
    };

    for (fixtures) |fixture| {
        for ([_]usize{ 1, 2, 3, 64 }) |chunk_size| {
            const result = try renderChunksToString(gpa, fixture.input, chunk_size);
            defer gpa.free(result);
            try std.testing.expectEqualStrings(fixture.expected, result);
        }
    }
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
