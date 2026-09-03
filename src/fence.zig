//! Markdown fenced-block filter used by `tj filter --fence`.

const std = @import("std");
const resource_prefix = "\x1b]3110;RESOURCE;files/";
const end_marker = "\x1b]3110;END\x1b\\";

pub const Filter = struct {
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    enabled: bool,
    line: std.ArrayList(u8) = .empty,
    resource_open: bool = false,
    resource_number: usize = 0,

    pub fn init(gpa: std.mem.Allocator, out: *std.Io.Writer, enabled: bool) Filter {
        return .{ .gpa = gpa, .out = out, .enabled = enabled };
    }

    pub fn deinit(self: *Filter) void {
        self.line.deinit(self.gpa);
    }

    pub fn feed(self: *Filter, bytes: []const u8) !void {
        for (bytes) |byte| {
            try self.line.append(self.gpa, byte);
            if (byte != '\n') continue;
            try self.writeLine(self.line.items);
            self.line.clearRetainingCapacity();
        }
    }

    pub fn finish(self: *Filter) !void {
        if (self.line.items.len != 0) try self.writeLine(self.line.items);
        if (self.resource_open and self.enabled) try self.out.writeAll(end_marker);
        self.resource_open = false;
    }

    fn writeLine(self: *Filter, line: []const u8) !void {
        if (!std.mem.startsWith(u8, line, "```")) return self.out.writeAll(line);

        if (self.resource_open) {
            if (self.enabled) try self.out.writeAll(end_marker);
            try self.out.writeAll(line);
            self.resource_open = false;
            return;
        }

        try self.out.writeAll(line);
        self.resource_number += 1;
        if (!self.enabled) return;

        const language = fenceLanguage(line[3..]);
        const extension = if (language.len == 0) "txt" else language;
        try self.out.print("{s}{d}.{s};{s}\x1b\\", .{ resource_prefix, self.resource_number, extension, mimeType(language) });
        self.resource_open = true;
    }
};

fn fenceLanguage(text: []const u8) []const u8 {
    const trimmed = std.mem.trimStart(u8, text, " \t");
    for (trimmed, 0..) |byte, i| {
        if (byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n') return trimmed[0..i];
    }
    return trimmed;
}

fn mimeType(language: []const u8) []const u8 {
    if (std.mem.eql(u8, language, "csv")) return "text/csv";
    if (std.mem.eql(u8, language, "json")) return "application/json";
    if (std.mem.eql(u8, language, "sh") or std.mem.eql(u8, language, "bash") or std.mem.eql(u8, language, "zsh")) return "text/x-shellscript";
    if (std.mem.eql(u8, language, "py") or std.mem.eql(u8, language, "python")) return "text/x-python";
    if (std.mem.eql(u8, language, "zig")) return "text/x-zig";
    if (std.mem.eql(u8, language, "sql")) return "application/sql";
    return "text/plain";
}

test "fence headers retain the established language mapping" {
    try std.testing.expectEqualStrings("csv", fenceLanguage(" csv note\n"));
    try std.testing.expectEqualStrings("", fenceLanguage("\n"));
    try std.testing.expectEqualStrings("text/csv", mimeType("csv"));
    try std.testing.expectEqualStrings("text/x-shellscript", mimeType("zsh"));
    try std.testing.expectEqualStrings("text/plain", mimeType("unknown"));
}
