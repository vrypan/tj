//! Shared presentation for the commands that report on a journal.
//!
//! History, usage, grep, and removal all make the same handful of decisions:
//! how wide the terminal is, whether colour is wanted, how to render a size,
//! and how to make stored bytes safe to print. Each was written where its
//! first caller happened to live, so the names said `history` or `Grep` while
//! three other commands used them. They belong together, named for the job.

const std = @import("std");
const Io = std.Io;

const noout = @import("../protocol/noout.zig");
const store = @import("../journal/store.zig");
const sys = @import("../sys.zig");

/// Wraps a report in an OSC noout region so a journal writer records the
/// command but not the listing it produced.
pub const NooutRegion = struct {
    out: *Io.Writer,
    enabled: bool,
    started: bool = false,

    pub fn begin(self: *NooutRegion) !void {
        if (self.enabled and !self.started) {
            try self.out.writeAll(noout.begin_marker);
            self.started = true;
        }
    }

    pub fn finish(self: *NooutRegion) void {
        if (self.started) self.out.writeAll(noout.end_marker) catch {};
        self.started = false;
    }
};

pub fn decimalWidth(number: u32) usize {
    var value = number;
    var width: usize = 1;
    while (value >= 10) : (value /= 10) width += 1;
    return width;
}

/// The terminal's width, or null when stdout is not one.
pub fn terminalColumns(io: Io) ?usize {
    if (!sys.isTty(io, 1)) return null;
    if (sys.getWinsize(1)) |size| {
        if (size.col != 0) return size.col;
    } else |_| {}
    if (sys.env("COLUMNS")) |text| {
        const columns = std.fmt.parseInt(usize, text, 10) catch 0;
        if (columns != 0) return columns;
    }
    return 80;
}

/// Whether a report should colour its own layout. Distinct from `--color`,
/// which is a per-command request about matches rather than about layout.
pub fn layoutColorEnabled(io: Io) bool {
    if (!sys.isTty(io, 1) or sys.envPresent("NO_COLOR")) return false;
    const term = sys.env("TERM") orelse return false;
    return !std.mem.eql(u8, term, "dumb");
}

/// The widest string `formatEntrySize` can produce. `formatHumanSize` divides
/// while `bytes >= unit * 1024`, so the whole part always stays below 1024:
/// the widest results are `1023b` below the first unit and `1023k` above it.
pub const max_entry_size_width = 5;

pub fn formatEntrySize(info: store.InteractionInfo, buf: *[24]u8) []const u8 {
    if (!info.out_present) return "-";
    return formatHumanSize(info.out_bytes, buf);
}

pub fn formatHumanSize(bytes: u64, buf: *[24]u8) []const u8 {
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

/// Stored commands and output are untrusted terminal input. Strip terminal
/// controls before they reach a report while optionally normalizing horizontal
/// whitespace for grep. TJ's own SGR styling bypasses this writer.
pub const SanitizingWriter = struct {
    downstream: *Io.Writer,
    interface: Io.Writer,
    collapse_whitespace: bool,
    seen_content: bool = false,
    pending_space: bool = false,
    escape: enum { normal, esc, csi, string, string_esc, charset } = .normal,
    utf8: [4]u8 = undefined,
    utf8_len: usize = 0,
    utf8_expected: usize = 0,

    pub fn init(downstream: *Io.Writer, collapse_whitespace: bool) SanitizingWriter {
        return .{
            .downstream = downstream,
            .collapse_whitespace = collapse_whitespace,
            .interface = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },
        };
    }

    pub fn finish(self: *SanitizingWriter) Io.Writer.Error!void {
        if (self.utf8_expected != 0) try self.emitReplacement();
        self.utf8_len = 0;
        self.utf8_expected = 0;
        self.pending_space = false;
    }

    fn drain(writer: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const self: *SanitizingWriter = @alignCast(@fieldParentPtr("interface", writer));
        for (data[0 .. data.len - 1]) |bytes| try self.writeBytes(bytes);
        const pattern = data[data.len - 1];
        for (0..splat) |_| try self.writeBytes(pattern);
        writer.end = 0;
        return Io.Writer.countSplat(data, splat);
    }

    fn writeBytes(self: *SanitizingWriter, bytes: []const u8) Io.Writer.Error!void {
        for (bytes) |byte| try self.writeByte(byte);
    }

    fn writeByte(self: *SanitizingWriter, byte: u8) Io.Writer.Error!void {
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

    fn writeWhitespace(self: *SanitizingWriter, byte: u8) Io.Writer.Error!void {
        if (self.collapse_whitespace) {
            if (self.seen_content) self.pending_space = true;
            return;
        }
        try self.downstream.writeByte(if (byte == ' ' or byte == '\t') byte else ' ');
        self.seen_content = true;
    }

    fn writeHighByte(self: *SanitizingWriter, byte: u8) Io.Writer.Error!void {
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

    fn writeUtf8Continuation(self: *SanitizingWriter, byte: u8) Io.Writer.Error!void {
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

    fn emitVisible(self: *SanitizingWriter, bytes: []const u8) Io.Writer.Error!void {
        if (self.pending_space) try self.downstream.writeByte(' ');
        self.pending_space = false;
        self.seen_content = true;
        try self.downstream.writeAll(bytes);
    }

    fn emitReplacement(self: *SanitizingWriter) Io.Writer.Error!void {
        try self.emitVisible("\xef\xbf\xbd");
    }
};

pub fn sanitizeDisplayText(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(gpa);
    var downstream = Io.Writer.Allocating.fromArrayList(gpa, &bytes);
    defer bytes = downstream.toArrayList();
    var sanitized = SanitizingWriter.init(&downstream.writer, false);
    try sanitized.interface.writeAll(text);
    try sanitized.finish();
    return downstream.toOwnedSlice();
}
