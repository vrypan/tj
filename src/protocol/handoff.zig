//! Private OSC ELLO request used to replace an active journal writer.

const std = @import("std");

pub const max_field = 8 * 1024;
pub const max_wire = 2 + 1 + 4 + 2 + max_field + 2 + max_field;

pub const Operation = enum(u8) { new = 0, use = 1 };

pub const Request = struct {
    operation: Operation,
    keep_osc: bool = false,
    replay_before_start: bool = false,
    splash: bool = false,
    temporary: bool = false,
    title_blink_ms: u32 = 1500,
    title: [max_field]u8 = undefined,
    title_len: usize = 0,
    selector: [max_field]u8 = undefined,
    selector_len: usize = 0,

    pub fn titleSlice(self: *const Request) []const u8 {
        return self.title[0..self.title_len];
    }
    pub fn selectorSlice(self: *const Request) []const u8 {
        return self.selector[0..self.selector_len];
    }
};

pub fn encode(request: *const Request, out: []u8) ![]const u8 {
    if (request.title_len > max_field or request.selector_len > max_field) return error.RequestTooLarge;
    if (request.operation == .use and request.selector_len == 0) return error.InvalidRequest;
    const raw_len = 11 + request.title_len + request.selector_len;
    const encoded_len = std.base64.standard.Encoder.calcSize(raw_len);
    if (out.len < "\x1b]3110;HANDOFF;".len + encoded_len + 2) return error.NoSpaceLeft;

    var raw: [max_wire]u8 = undefined;
    raw[0] = 1;
    raw[1] = @intFromEnum(request.operation);
    raw[2] = (@as(u8, @intFromBool(request.keep_osc)) << 0) |
        (@as(u8, @intFromBool(request.replay_before_start)) << 1) |
        (@as(u8, @intFromBool(request.splash)) << 2) |
        (@as(u8, @intFromBool(request.temporary)) << 3);
    std.mem.writeInt(u32, raw[3..7], request.title_blink_ms, .big);
    std.mem.writeInt(u16, raw[7..9], @intCast(request.title_len), .big);
    @memcpy(raw[9 .. 9 + request.title_len], request.titleSlice());
    const selector_at = 9 + request.title_len;
    const selector_length_out: *[2]u8 = @ptrCast(raw[selector_at..].ptr);
    std.mem.writeInt(u16, selector_length_out, @intCast(request.selector_len), .big);
    @memcpy(raw[selector_at + 2 .. selector_at + 2 + request.selector_len], request.selectorSlice());

    const prefix = "\x1b]3110;HANDOFF;";
    @memcpy(out[0..prefix.len], prefix);
    _ = std.base64.standard.Encoder.encode(out[prefix.len .. prefix.len + encoded_len], raw[0..raw_len]);
    out[prefix.len + encoded_len] = 0x1b;
    out[prefix.len + encoded_len + 1] = '\\';
    return out[0 .. prefix.len + encoded_len + 2];
}

pub fn decode(encoded: []const u8) !Request {
    const raw_len = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return error.InvalidRequest;
    if (raw_len < 9 or raw_len > max_wire) return error.InvalidRequest;
    var raw: [max_wire]u8 = undefined;
    std.base64.standard.Decoder.decode(raw[0..raw_len], encoded) catch return error.InvalidRequest;
    if (raw[0] != 1 or raw[2] & ~@as(u8, 0x0f) != 0) return error.InvalidRequest;
    const operation: Operation = switch (raw[1]) {
        0 => .new,
        1 => .use,
        else => return error.InvalidRequest,
    };
    const title_len = std.mem.readInt(u16, raw[7..9], .big);
    const selector_at = 9 + @as(usize, title_len);
    if (title_len > max_field or selector_at + 2 > raw_len) return error.InvalidRequest;
    const selector_length_in: *const [2]u8 = @ptrCast(raw[selector_at..].ptr);
    const selector_len = std.mem.readInt(u16, selector_length_in, .big);
    if (selector_len > max_field or selector_at + 2 + @as(usize, selector_len) != raw_len) return error.InvalidRequest;
    if (operation == .use and selector_len == 0) return error.InvalidRequest;
    var result: Request = .{
        .operation = operation,
        .keep_osc = raw[2] & 1 != 0,
        .replay_before_start = raw[2] & 2 != 0,
        .splash = raw[2] & 4 != 0,
        .temporary = raw[2] & 8 != 0,
        .title_blink_ms = std.mem.readInt(u32, raw[3..7], .big),
        .title_len = title_len,
        .selector_len = selector_len,
    };
    @memcpy(result.title[0..title_len], raw[9..selector_at]);
    @memcpy(result.selector[0..selector_len], raw[selector_at + 2 .. raw_len]);
    return result;
}

test "handoff round trip" {
    var request: Request = .{ .operation = .use, .keep_osc = true, .replay_before_start = true, .title_blink_ms = 0, .title_len = 2, .selector_len = 4 };
    @memcpy(request.title[0..2], "TJ");
    @memcpy(request.selector[0..4], "work");
    var marker: [max_wire * 2]u8 = undefined;
    const text = try encode(&request, &marker);
    const prefix = "\x1b]3110;HANDOFF;";
    const parsed = try decode(text[prefix.len .. text.len - 2]);
    try std.testing.expectEqual(Operation.use, parsed.operation);
    try std.testing.expect(parsed.keep_osc);
    try std.testing.expectEqualStrings("TJ", parsed.titleSlice());
    try std.testing.expectEqualStrings("work", parsed.selectorSlice());
}
