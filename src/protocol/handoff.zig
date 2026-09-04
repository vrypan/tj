//! Private OSC ELLO request used to replace an active journal writer.

const std = @import("std");

pub const max_field = 8 * 1024;
/// Random per-writer token exported as `TJ_SESSION_ID`. HANDOFF replaces the
/// active journal writer, so the proxy honours it only when the request
/// carries this token: `tjctl` inherits it through the environment, while
/// untrusted bytes merely displayed on the terminal never see it.
pub const session_len = 32;
/// Generous bound on the decoded payload: the fixed header never approaches
/// 96 bytes and the trailing selector is capped at `max_field`.
pub const max_wire = 96 + max_field;

pub const Operation = enum { new, use };

/// A handoff only changes which journal the writer records into. It carries no
/// proxy settings: keep-osc, splash, and the title/blink lifecycle belong to
/// the writer that is already running and are untouched by a switch.
pub const Request = struct {
    operation: Operation,
    /// `new` only: start the target as a temporary journal.
    temporary: bool = false,
    /// `use` only: replay the target's transcript before recording resumes.
    replay_before_start: bool = false,
    session: [session_len]u8 = @splat(0),
    selector: [max_field]u8 = undefined,
    selector_len: usize = 0,

    pub fn selectorSlice(self: *const Request) []const u8 {
        return self.selector[0..self.selector_len];
    }
    pub fn sessionSlice(self: *const Request) []const u8 {
        return &self.session;
    }
};

/// The decoded payload is text, in the same envelope style as CONTEXT:
///
///     2;OP;TEMP;REPLAY;TOKEN;SELECTOR
///
/// `OP` is `new` or `use`, `TEMP` and `REPLAY` are `0` or `1`, `TOKEN` is the
/// session token, and `SELECTOR` is the target journal - the only variable
/// field, kept last so it needs no length prefix. Journal selectors cannot
/// contain a separator, so the split back out is unambiguous.
pub fn encode(request: *const Request, out: []u8) ![]const u8 {
    if (request.selector_len > max_field) return error.RequestTooLarge;
    if (request.operation == .use and request.selector_len == 0) return error.InvalidRequest;
    // The token is one plain text field; the proxy generates it that way.
    if (std.mem.indexOfScalar(u8, request.sessionSlice(), ';') != null) return error.InvalidRequest;

    var raw: [max_wire]u8 = undefined;
    const payload = std.fmt.bufPrint(&raw, "2;{t};{d};{d};{s};{s}", .{
        request.operation,
        @intFromBool(request.temporary),
        @intFromBool(request.replay_before_start),
        request.sessionSlice(),
        request.selectorSlice(),
    }) catch return error.RequestTooLarge;

    const encoded_len = std.base64.standard.Encoder.calcSize(payload.len);
    const prefix = "\x1b]3110;HANDOFF;";
    if (out.len < prefix.len + encoded_len + 2) return error.NoSpaceLeft;
    @memcpy(out[0..prefix.len], prefix);
    _ = std.base64.standard.Encoder.encode(out[prefix.len .. prefix.len + encoded_len], payload);
    out[prefix.len + encoded_len] = 0x1b;
    out[prefix.len + encoded_len + 1] = '\\';
    return out[0 .. prefix.len + encoded_len + 2];
}

pub fn decode(encoded: []const u8) !Request {
    const raw_len = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return error.InvalidRequest;
    if (raw_len > max_wire) return error.InvalidRequest;
    var raw: [max_wire]u8 = undefined;
    std.base64.standard.Decoder.decode(raw[0..raw_len], encoded) catch return error.InvalidRequest;

    var fields = std.mem.splitScalar(u8, raw[0..raw_len], ';');
    if (!std.mem.eql(u8, try field(&fields), "2")) return error.InvalidRequest;
    const operation = std.meta.stringToEnum(Operation, try field(&fields)) orelse return error.InvalidRequest;
    const temporary = try flagField(&fields);
    const replay = try flagField(&fields);
    const session = try field(&fields);
    if (session.len != session_len) return error.InvalidRequest;

    // The selector is the last field and cannot itself contain a separator,
    // so its bytes are exactly the remainder of the payload.
    const selector = fields.rest();
    if (selector.len > max_field) return error.InvalidRequest;
    if (operation == .use and selector.len == 0) return error.InvalidRequest;

    var result: Request = .{
        .operation = operation,
        .temporary = temporary,
        .replay_before_start = replay,
        .selector_len = selector.len,
    };
    @memcpy(&result.session, session);
    @memcpy(result.selector[0..selector.len], selector);
    return result;
}

fn field(fields: *std.mem.SplitIterator(u8, .scalar)) ![]const u8 {
    return fields.next() orelse error.InvalidRequest;
}

fn flagField(fields: *std.mem.SplitIterator(u8, .scalar)) !bool {
    const text = try field(fields);
    if (std.mem.eql(u8, text, "0")) return false;
    if (std.mem.eql(u8, text, "1")) return true;
    return error.InvalidRequest;
}

test "handoff round trip" {
    var request: Request = .{ .operation = .use, .replay_before_start = true, .selector_len = 4 };
    @memcpy(&request.session, "0123456789abcdef0123456789abcdef");
    @memcpy(request.selector[0..4], "work");
    var marker: [max_wire * 2]u8 = undefined;
    const text = try encode(&request, &marker);
    const prefix = "\x1b]3110;HANDOFF;";
    const parsed = try decode(text[prefix.len .. text.len - 2]);
    try std.testing.expectEqual(Operation.use, parsed.operation);
    try std.testing.expect(parsed.replay_before_start);
    try std.testing.expect(!parsed.temporary);
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef", parsed.sessionSlice());
    try std.testing.expectEqualStrings("work", parsed.selectorSlice());
}

test "a generated new handoff carries an empty selector" {
    var request: Request = .{ .operation = .new, .temporary = true };
    @memcpy(&request.session, "0123456789abcdef0123456789abcdef");
    var marker: [max_wire * 2]u8 = undefined;
    const text = try encode(&request, &marker);
    const prefix = "\x1b]3110;HANDOFF;";
    const parsed = try decode(text[prefix.len .. text.len - 2]);
    try std.testing.expectEqual(Operation.new, parsed.operation);
    try std.testing.expect(parsed.temporary);
    try std.testing.expectEqualStrings("", parsed.selectorSlice());
}

test "the decoded handoff payload is the documented text envelope" {
    var request: Request = .{ .operation = .new, .temporary = true, .selector_len = 4 };
    @memcpy(&request.session, "0123456789abcdef0123456789abcdef");
    @memcpy(request.selector[0..4], "work");
    var marker: [max_wire * 2]u8 = undefined;
    const text = try encode(&request, &marker);
    const prefix = "\x1b]3110;HANDOFF;";
    const encoded = text[prefix.len .. text.len - 2];
    var raw: [max_wire]u8 = undefined;
    const raw_len = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
    try std.base64.standard.Decoder.decode(raw[0..raw_len], encoded);
    try std.testing.expectEqualStrings(
        "2;new;1;0;0123456789abcdef0123456789abcdef;work",
        raw[0..raw_len],
    );
}

test "malformed handoff payloads are rejected" {
    for ([_][]const u8{
        // The retired binary version-one envelope.
        "\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00",
        "",
        // Wrong version, unknown operation, non-boolean flags.
        "1;new;0;0;0123456789abcdef0123456789abcdef;work",
        "2;mv;0;0;0123456789abcdef0123456789abcdef;work",
        "2;new;2;0;0123456789abcdef0123456789abcdef;work",
        "2;new;0;x;0123456789abcdef0123456789abcdef;work",
        // A token of the wrong length.
        "2;new;0;0;short;work",
        // `use` with no selector.
        "2;use;0;0;0123456789abcdef0123456789abcdef;",
        // Truncated before the token field.
        "2;new;0;0",
    }) |payload| {
        var encoded: [max_wire * 2]u8 = undefined;
        const text = std.base64.standard.Encoder.encode(&encoded, payload);
        try std.testing.expectError(error.InvalidRequest, decode(text));
    }
}
