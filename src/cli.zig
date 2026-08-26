//! Command line parsing for `tj`.
//!
//!     tj [flags] [-- command...]   run the proxy
//!     tj <subcommand> [args...]    journal queries
//!
//! A leading `--` always means "everything after this is the command to run",
//! so `tj -- resolve` runs the program `resolve` rather than the subcommand.

const std = @import("std");

pub const Subcommand = enum {
    resolve,
    current,
    last,
    list,
    sessions,
    complete,

    pub fn parse(name: []const u8) ?Subcommand {
        return std.meta.stringToEnum(Subcommand, name);
    }
};

pub const Proxy = struct {
    /// The command to run under the pty. Empty means "the user's shell".
    argv: []const []const u8 = &.{},
    keep_osc: bool = false,
    home: ?[]const u8 = null,
};

pub const Command = union(enum) {
    proxy: Proxy,
    subcommand: struct { which: Subcommand, args: []const []const u8 },
    help,
    version,
};

pub const ParseError = error{
    UnknownFlag,
    MissingFlagValue,
};

/// `args` excludes the program name.
pub fn parse(args: []const []const u8) ParseError!Command {
    var proxy: Proxy = .{};
    var i: usize = 0;

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--")) {
            proxy.argv = args[i + 1 ..];
            return .{ .proxy = proxy };
        }
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) return .help;
        if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) return .version;
        if (std.mem.eql(u8, arg, "--keep-osc")) {
            proxy.keep_osc = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--home")) {
            if (i + 1 >= args.len) return error.MissingFlagValue;
            i += 1;
            proxy.home = args[i];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--home=")) {
            proxy.home = arg["--home=".len..];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) return error.UnknownFlag;

        if (Subcommand.parse(arg)) |which| {
            return .{ .subcommand = .{ .which = which, .args = args[i + 1 ..] } };
        }
        return error.UnknownFlag;
    }

    return .{ .proxy = proxy };
}

test "bare invocation is the proxy with the default shell" {
    const cmd = try parse(&.{});
    try std.testing.expect(cmd == .proxy);
    try std.testing.expectEqual(@as(usize, 0), cmd.proxy.argv.len);
    try std.testing.expect(!cmd.proxy.keep_osc);
    try std.testing.expect(cmd.proxy.home == null);
}

test "double dash passes the rest through as the command" {
    const cmd = try parse(&.{ "--keep-osc", "--", "zsh", "-f" });
    try std.testing.expect(cmd.proxy.keep_osc);
    try std.testing.expectEqual(@as(usize, 2), cmd.proxy.argv.len);
    try std.testing.expectEqualStrings("zsh", cmd.proxy.argv[0]);
    try std.testing.expectEqualStrings("-f", cmd.proxy.argv[1]);
}

test "flags after the double dash belong to the command" {
    const cmd = try parse(&.{ "--", "sh", "--help" });
    try std.testing.expectEqual(@as(usize, 2), cmd.proxy.argv.len);
    try std.testing.expectEqualStrings("--help", cmd.proxy.argv[1]);
}

test "home accepts both spellings" {
    const split = try parse(&.{ "--home", "/tmp/j" });
    try std.testing.expectEqualStrings("/tmp/j", split.proxy.home.?);
    const joined = try parse(&.{"--home=/tmp/j"});
    try std.testing.expectEqualStrings("/tmp/j", joined.proxy.home.?);
}

test "subcommands are recognised and keep their arguments" {
    const cmd = try parse(&.{ "resolve", "@42/out" });
    try std.testing.expectEqual(Subcommand.resolve, cmd.subcommand.which);
    try std.testing.expectEqualStrings("@42/out", cmd.subcommand.args[0]);
}

test "help and version win over anything else" {
    try std.testing.expect(try parse(&.{"--help"}) == .help);
    try std.testing.expect(try parse(&.{ "-V", "resolve" }) == .version);
}

test "unknown flags and bare words are errors" {
    try std.testing.expectError(error.UnknownFlag, parse(&.{"--nope"}));
    try std.testing.expectError(error.UnknownFlag, parse(&.{"zsh"}));
    try std.testing.expectError(error.MissingFlagValue, parse(&.{"--home"}));
}
