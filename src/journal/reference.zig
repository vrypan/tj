//! The `@` namespace for previous computations.
//!
//!     @42/out                           entry 42, current journal
//!     @-/out                            the last completed entry
//!     @release-build.42                 entry 42 in another journal
//!     @build.42/files/data.csv          the same, by a unique suffix
//!
//! Selectors resolve by exact canonical journal name first, then by a unique
//! suffix. Dots separate journal selectors from entry selectors.
//!
//! This module is only the grammar. Turning a reference into a path is the
//! store's job, since only it knows what is on disk.

const std = @import("std");
pub const max_suffix = 63;

pub const Target = u32;

pub const Body = union(enum) {
    /// `@-`
    previous,
    /// `@N`
    current: Target,
    /// `@SUFFIX.N`
    qualified: struct { suffix: []const u8, target: Target },
};

pub const Reference = struct {
    body: Body,
    /// What followed the interaction, without its leading slash. Empty means
    /// the reference names the interaction itself.
    subpath: []const u8 = "",
    /// Whether a trailing slash was present, which completion cares about:
    /// `@42` is still being typed, `@42/` is asking what is inside.
    trailing_slash: bool = false,
};

pub const Error = error{
    /// Not `@`-prefixed, or not shaped like a reference at all. The word
    /// belongs to the command, not to tj: leave it exactly as it is.
    NotAReference,
    /// Shaped like a reference but invalid. Worth complaining about.
    Malformed,
};

pub fn parse(word: []const u8) Error!Reference {
    if (word.len < 2 or word[0] != '@') return error.NotAReference;

    const rest = word[1..];
    const slash = std.mem.indexOfScalar(u8, rest, '/');
    const body_text = if (slash) |at| rest[0..at] else rest;
    const subpath = if (slash) |at| rest[at + 1 ..] else "";

    const body = try parseBody(body_text);
    try validateSubpath(subpath);

    return .{
        .body = body,
        .subpath = subpath,
        .trailing_slash = slash != null,
    };
}

fn parseBody(text: []const u8) Error!Body {
    if (text.len == 0) return error.NotAReference;
    if (std.mem.eql(u8, text, "-")) return .previous;

    if (std.mem.indexOfScalar(u8, text, '.')) |dot| {
        const suffix = text[0..dot];
        const target = text[dot + 1 ..];
        if (suffix.len == 0 or suffix.len > max_suffix) return error.NotAReference;
        if (!validJournalSelector(suffix)) return error.NotAReference;
        return .{ .qualified = .{ .suffix = suffix, .target = try parseNumber(target) } };
    }

    for (text) |char| if (!std.ascii.isDigit(char)) return error.NotAReference;
    return .{ .current = try parseNumber(text) };
}

fn parseNumber(text: []const u8) Error!u32 {
    if (text.len == 0) return error.Malformed;
    for (text) |char| if (!std.ascii.isDigit(char)) return error.Malformed;
    const value = std.fmt.parseInt(u32, text, 10) catch return error.Malformed;
    // Interactions are numbered from 1.
    if (value == 0) return error.Malformed;
    return value;
}

/// A resource path must stay inside its interaction: a program that publishes
/// one chooses the name, so this is a security boundary, not a nicety.
pub fn validateSubpath(subpath: []const u8) Error!void {
    if (subpath.len == 0) return;
    if (subpath[0] == '/') return error.Malformed;

    var segments = std.mem.splitScalar(u8, subpath, '/');
    while (segments.next()) |segment| {
        if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return error.Malformed;
        for (segment) |char| if (char < 0x20) return error.Malformed;
    }
    // A single trailing slash is fine; anything else empty is not.
    if (std.mem.indexOf(u8, subpath, "//") != null) return error.Malformed;
}

fn validJournalSelector(name: []const u8) bool {
    if (name.len == 0 or name.len > max_suffix) return false;
    if (!std.ascii.isAlphanumeric(name[0]) or !std.ascii.isAlphanumeric(name[name.len - 1])) return false;
    for (name) |char| {
        if (!(std.ascii.isLower(char) or std.ascii.isDigit(char) or char == '-')) return false;
    }
    return true;
}

/// Whether a word is worth handing to the resolver at all. Used by the shell
/// integration to leave everything else strictly alone.
pub fn looksLikeReference(word: []const u8) bool {
    _ = parse(word) catch return false;
    return true;
}

// --- tests -----------------------------------------------------------------

test "plain entry references" {
    const ref = try parse("@42");
    try std.testing.expectEqual(@as(u32, 42), ref.body.current);
    try std.testing.expectEqualStrings("", ref.subpath);
    try std.testing.expect(!ref.trailing_slash);
}

test "a subpath is kept verbatim" {
    const ref = try parse("@42/files/data.csv");
    try std.testing.expectEqual(@as(u32, 42), ref.body.current);
    try std.testing.expectEqualStrings("files/data.csv", ref.subpath);
    try std.testing.expect(ref.trailing_slash);
}

test "a trailing slash is distinguishable from none" {
    try std.testing.expect((try parse("@42/")).trailing_slash);
    try std.testing.expectEqualStrings("", (try parse("@42/")).subpath);
    try std.testing.expect(!(try parse("@42")).trailing_slash);
}

test "the previous entry" {
    try std.testing.expect((try parse("@-")).body == .previous);
    try std.testing.expectEqualStrings("out", (try parse("@-/out")).subpath);
}

test "journal-qualified references" {
    const ref = try parse("@release-build.42/out");
    try std.testing.expectEqualStrings("release-build", ref.body.qualified.suffix);
    try std.testing.expectEqual(@as(u32, 42), ref.body.qualified.target);
    try std.testing.expectEqualStrings("out", ref.subpath);

    const full = try parse("@01knxf1n5ffvk9jsm8wve1pgsd.7");
    try std.testing.expectEqualStrings("01knxf1n5ffvk9jsm8wve1pgsd", full.body.qualified.suffix);
    try std.testing.expectEqual(@as(u32, 7), full.body.qualified.target);
}

test "an all-digit reference is never read as a journal suffix" {
    const ref = try parse("@1234567890");
    try std.testing.expect(ref.body == .current);
    try std.testing.expectEqual(@as(u32, 1234567890), ref.body.current);
}

test "ordinary words are left alone" {
    // The whole point: these must reach the command untouched.
    for ([_][]const u8{
        "user@host",
        "@",
        "@Uppercase",
        "@bad_name/bar",
        "git@github.com:me/repo.git",
        "me@example.com",
        "",
        "ls",
        "-@42",
    }) |word| {
        try std.testing.expect(!looksLikeReference(word));
    }
}

test "references that are shaped right but invalid are reported" {
    // Interactions start at 1, so @0 cannot exist.
    try std.testing.expectError(error.Malformed, parse("@0"));
    try std.testing.expectError(error.Malformed, parse("@release-build.0"));
    try std.testing.expectError(error.Malformed, parse("@release-build."));
}

test "subpaths cannot escape the entry directory" {
    try std.testing.expectError(error.Malformed, parse("@42//etc/passwd"));
    try std.testing.expectError(error.Malformed, parse("@42/../../etc/passwd"));
    try std.testing.expectError(error.Malformed, parse("@42/files/../../../etc/passwd"));
    try std.testing.expectError(error.Malformed, parse("@42/./out"));
    try std.testing.expectError(error.Malformed, parse("@-/.."));
}

test "journal selectors are bounded" {
    try std.testing.expect(looksLikeReference("@" ++ "a" ** 63 ++ ".1"));
    try std.testing.expect(!looksLikeReference("@" ++ "a" ** 64 ++ ".1"));
}
