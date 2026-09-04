//! Canonical journal directory names.
//!
//! Names are identities, not labels. The date in a generated name is only a
//! human clue and must never be used for ordering or retention decisions.

const std = @import("std");
const Io = std.Io;

pub const max_len = 63;
pub const generated_len = 13;
pub const Legacy = [26]u8;

const alphabet = "0123456789abcdefghjkmnpqrstvwxyz";

pub fn isValid(name: []const u8) bool {
    if (name.len == 0 or name.len > max_len) return false;
    if (!std.ascii.isAlphanumeric(name[0]) or !std.ascii.isAlphanumeric(name[name.len - 1])) return false;
    for (name) |char| {
        if (!(std.ascii.isLower(char) or std.ascii.isDigit(char) or char == '-')) return false;
    }
    return true;
}

pub fn generate(io: Io) [generated_len]u8 {
    const millis = Io.Clock.now(.real, io).toMilliseconds();
    var random: [4]u8 = undefined;
    io.random(&random);
    const bits: u30 = @truncate(std.mem.readInt(u32, &random, .little));
    return format(millis, bits);
}

pub fn format(millis: i64, random_bits: u30) [generated_len]u8 {
    const seconds = @divFloor(millis, 1000);
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(seconds, 0)) };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    var out: [generated_len]u8 = undefined;
    _ = std.fmt.bufPrint(out[0..7], "{d:0>2}{d:0>2}{d:0>2}-", .{
        @mod(year_day.year, 100),
        month_day.month.numeric(),
        month_day.day_index + 1,
    }) catch unreachable;
    var value: u30 = random_bits;
    var i: usize = generated_len;
    while (i > 7) {
        i -= 1;
        out[i] = alphabet[@as(u5, @truncate(value))];
        value >>= 5;
    }
    return out;
}

/// Deterministic legacy ULID-shaped fixture. Existing ULID directories are
/// ordinary valid journal names; the application never interprets them.
pub fn legacy(millis: u48, entropy: [10]u8) Legacy {
    var out: Legacy = undefined;
    var time_bits = millis;
    var i: usize = 10;
    while (i > 0) {
        i -= 1;
        out[i] = alphabet[@as(u5, @truncate(time_bits))];
        time_bits >>= 5;
    }
    var entropy_bits: u80 = 0;
    for (entropy) |byte| entropy_bits = (entropy_bits << 8) | byte;
    var j: usize = out.len;
    while (j > 10) {
        j -= 1;
        out[j] = alphabet[@as(u5, @truncate(entropy_bits))];
        entropy_bits >>= 5;
    }
    return out;
}

test "journal name grammar is conservative and bounded" {
    for ([_][]const u8{ "a", "123", "release-build", "0" ** 26, "a" ** 63 }) |valid| {
        try std.testing.expect(isValid(valid));
    }
    for ([_][]const u8{ "", "-a", "a-", "Release", "a_b", "a.b", "a/b", "a" ** 64 }) |invalid| {
        try std.testing.expect(!isValid(invalid));
    }
}

test "default names contain a UTC date and deterministic Crockford tail" {
    const name = format(1787753002117, 0);
    try std.testing.expectEqualStrings("260826-000000", &name);
    try std.testing.expect(isValid(&name));
}
