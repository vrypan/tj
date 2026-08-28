//! ULIDs identify journals: a 48-bit millisecond timestamp followed by 80
//! random bits, written as 26 Crockford base32 characters.
//!
//! The timestamp comes first and the encoding is base32, so journal
//! directories sort chronologically under a plain `ls` with no index to
//! maintain. tj stores and prints them lowercase.

const std = @import("std");
const Io = std.Io;

pub const len = 26;
pub const Ulid = [len]u8;

/// Crockford base32: the digits, then the lowercase letters with i, l, o and u
/// removed so they cannot be confused with 1 and 0.
const alphabet = "0123456789abcdefghjkmnpqrstvwxyz";

const timestamp_chars = 10;
const entropy_chars = 16;

pub fn generate(io: Io) Ulid {
    const millis = Io.Clock.now(.real, io).toMilliseconds();
    var entropy: [10]u8 = undefined;
    io.random(&entropy);
    return encode(@truncate(@as(u64, @bitCast(millis))), entropy);
}

pub fn encode(millis: u48, entropy: [10]u8) Ulid {
    var out: Ulid = undefined;

    var time_bits: u48 = millis;
    var i: usize = timestamp_chars;
    while (i > 0) {
        i -= 1;
        out[i] = alphabet[@as(u5, @truncate(time_bits))];
        time_bits >>= 5;
    }

    var entropy_bits: u80 = 0;
    for (entropy) |byte| entropy_bits = (entropy_bits << 8) | byte;
    var j: usize = len;
    while (j > timestamp_chars) {
        j -= 1;
        out[j] = alphabet[@as(u5, @truncate(entropy_bits))];
        entropy_bits >>= 5;
    }

    return out;
}

pub fn timestampOf(ulid: Ulid) u48 {
    var millis: u48 = 0;
    for (ulid[0..timestamp_chars]) |char| {
        millis = (millis << 5) | (digitOf(char) orelse 0);
    }
    return millis;
}

/// Whether `name` is a well-formed lowercase ULID. Used to tell journal
/// directories apart from anything else that lands in the store.
pub fn isValid(name: []const u8) bool {
    if (name.len != len) return false;
    for (name) |char| {
        if (digitOf(char) == null) return false;
    }
    return true;
}

fn digitOf(char: u8) ?u5 {
    return switch (char) {
        '0'...'9' => @intCast(char - '0'),
        'a'...'h' => @intCast(char - 'a' + 10),
        'j', 'k' => @intCast(char - 'j' + 18),
        'm', 'n' => @intCast(char - 'm' + 20),
        'p'...'t' => @intCast(char - 'p' + 22),
        'v'...'z' => @intCast(char - 'v' + 27),
        else => null,
    };
}

test "encoding is 26 characters from the Crockford alphabet" {
    const id = encode(0x0192_3f5a_bcde, .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 });
    try std.testing.expectEqual(@as(usize, 26), id.len);
    for (id) |char| try std.testing.expect(std.mem.indexOfScalar(u8, alphabet, char) != null);
    try std.testing.expect(isValid(&id));
}

test "the all-zero ulid encodes to all zeros" {
    const id = encode(0, .{0} ** 10);
    try std.testing.expectEqualStrings("0" ** 26, &id);
}

test "the timestamp survives a round trip" {
    for ([_]u48{ 0, 1, 1000, 0x0192_3f5a_bcde, std.math.maxInt(u48) }) |millis| {
        const id = encode(millis, .{0} ** 10);
        try std.testing.expectEqual(millis, timestampOf(id));
    }
}

test "later timestamps sort after earlier ones" {
    // The property the store depends on: chronological order is lexicographic
    // order, so `ls` alone lists journals oldest to newest.
    var previous = encode(0, .{0xff} ** 10);
    for ([_]u48{ 1, 2, 1000, 1 << 20, 1 << 40, std.math.maxInt(u48) }) |millis| {
        const id = encode(millis, .{0} ** 10);
        try std.testing.expect(std.mem.lessThan(u8, &previous, &id));
        previous = id;
    }
}

test "entropy occupies the last sixteen characters only" {
    const a = encode(12345, .{0} ** 10);
    const b = encode(12345, .{0xff} ** 10);
    try std.testing.expectEqualStrings(a[0..10], b[0..10]);
    try std.testing.expect(!std.mem.eql(u8, a[10..], b[10..]));
    try std.testing.expectEqualStrings("z" ** 16, b[10..]);
}

test "isValid rejects wrong lengths and excluded letters" {
    try std.testing.expect(!isValid("tooshort"));
    try std.testing.expect(!isValid("0" ** 25));
    try std.testing.expect(!isValid("0" ** 27));
    for ([_]u8{ 'i', 'l', 'o', 'u', 'A', '-', ' ' }) |bad| {
        var name = [_]u8{'0'} ** 26;
        name[13] = bad;
        try std.testing.expect(!isValid(&name));
    }
}
