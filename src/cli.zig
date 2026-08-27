//! Command line parsing for `tj`.
//!
//!     tj run [flags] [-- command...]   start a session
//!     tj <subcommand> [args...]        work with the journal
//!     tj                               help
//!
//! Starting a session takes an explicit `run`. A session changes what the
//! shell you are typing into is, which is not something to end up inside by
//! mistyping a subcommand.

const std = @import("std");

pub const Subcommand = enum {
    run,
    hist,
    sessions,
    current,
    last,
    cat,
    replay,
    resolve,
    complete,

    pub fn parse(name: []const u8) ?Subcommand {
        if (std.mem.eql(u8, name, "history")) return .hist;
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
    subcommand: struct {
        which: Subcommand,
        args: []const []const u8,
        /// Honoured here too, so `tj --home X hist` reads the journal it names
        /// rather than quietly reading the default one.
        home: ?[]const u8 = null,
    },
    help,
    version,
};

pub const ParseError = error{
    UnknownFlag,
    MissingFlagValue,
    UnknownSubcommand,
    /// A command to run, with no `run` in front of it.
    MissingRun,
};

/// `args` excludes the program name.
pub fn parse(args: []const []const u8) ParseError!Command {
    var proxy: Proxy = .{};
    var i: usize = 0;

    while (i < args.len) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) return .help;
        if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) return .version;

        if (try takeFlag(args, &i, &proxy)) continue;

        // `tj -- zsh` used to start a session. It now needs saying out loud.
        if (std.mem.eql(u8, arg, "--")) return error.MissingRun;
        if (std.mem.startsWith(u8, arg, "-")) return error.UnknownFlag;

        const which = Subcommand.parse(arg) orelse return error.UnknownSubcommand;
        const rest = args[i + 1 ..];
        if (which == .run) return .{ .proxy = try parseRun(rest, proxy) };
        return .{ .subcommand = .{ .which = which, .args = rest, .home = proxy.home } };
    }

    // Nothing asked for. Say what is on offer rather than guessing.
    return .help;
}

/// Everything after `run`: any remaining flags, then the command, with or
/// without a `--` separating them.
fn parseRun(args: []const []const u8, inherited: Proxy) ParseError!Proxy {
    var proxy = inherited;
    var i: usize = 0;

    while (i < args.len) {
        if (std.mem.eql(u8, args[i], "--")) {
            proxy.argv = args[i + 1 ..];
            return proxy;
        }
        if (try takeFlag(args, &i, &proxy)) continue;

        // A flag tj does not know is a mistake, not a program to run. Say so,
        // rather than reporting that `--nope` could not be executed. After the
        // separator it would be a program name, and is left alone.
        if (std.mem.startsWith(u8, args[i], "-")) return error.UnknownFlag;

        // A bare command, so `tj run zsh -f` works as well as `tj run -- zsh -f`.
        proxy.argv = args[i..];
        return proxy;
    }
    return proxy;
}

/// Consumes a flag at `i` if there is one, advancing past it.
fn takeFlag(args: []const []const u8, i: *usize, proxy: *Proxy) ParseError!bool {
    const arg = args[i.*];

    if (std.mem.eql(u8, arg, "--keep-osc")) {
        proxy.keep_osc = true;
        i.* += 1;
        return true;
    }
    if (std.mem.eql(u8, arg, "--home")) {
        if (i.* + 1 >= args.len) return error.MissingFlagValue;
        proxy.home = args[i.* + 1];
        i.* += 2;
        return true;
    }
    if (std.mem.startsWith(u8, arg, "--home=")) {
        proxy.home = arg["--home=".len..];
        i.* += 1;
        return true;
    }
    return false;
}

test "a bare invocation explains itself instead of starting a session" {
    try std.testing.expect(try parse(&.{}) == .help);
    try std.testing.expect(try parse(&.{"--keep-osc"}) == .help);
}

test "run starts a session with the default shell" {
    const cmd = try parse(&.{"run"});
    try std.testing.expect(cmd == .proxy);
    try std.testing.expectEqual(@as(usize, 0), cmd.proxy.argv.len);
}

test "run takes a command with or without a separator" {
    const separated = try parse(&.{ "run", "--", "zsh", "-f" });
    try std.testing.expectEqual(@as(usize, 2), separated.proxy.argv.len);
    try std.testing.expectEqualStrings("zsh", separated.proxy.argv[0]);
    try std.testing.expectEqualStrings("-f", separated.proxy.argv[1]);

    const bare = try parse(&.{ "run", "zsh", "-f" });
    try std.testing.expectEqual(@as(usize, 2), bare.proxy.argv.len);
    try std.testing.expectEqualStrings("zsh", bare.proxy.argv[0]);
}

test "flags work before or after run" {
    const before = try parse(&.{ "--keep-osc", "--home", "/tmp/j", "run" });
    try std.testing.expect(before.proxy.keep_osc);
    try std.testing.expectEqualStrings("/tmp/j", before.proxy.home.?);

    const after = try parse(&.{ "run", "--keep-osc", "--home=/tmp/j", "--", "sh" });
    try std.testing.expect(after.proxy.keep_osc);
    try std.testing.expectEqualStrings("/tmp/j", after.proxy.home.?);
    try std.testing.expectEqualStrings("sh", after.proxy.argv[0]);
}

test "an unknown flag after run is a mistake, not a program name" {
    try std.testing.expectError(error.UnknownFlag, parse(&.{ "run", "--nope" }));
    // ...but after the separator it is whatever the user meant it to be.
    const cmd = try parse(&.{ "run", "--", "--nope" });
    try std.testing.expectEqualStrings("--nope", cmd.proxy.argv[0]);
}

test "flags after the separator belong to the command" {
    const cmd = try parse(&.{ "run", "--", "sh", "--help" });
    try std.testing.expectEqual(@as(usize, 2), cmd.proxy.argv.len);
    try std.testing.expectEqualStrings("--help", cmd.proxy.argv[1]);
}

test "a command with no run is refused rather than guessed at" {
    try std.testing.expectError(error.MissingRun, parse(&.{ "--", "zsh" }));
}

test "subcommands are recognised and keep their arguments" {
    const cmd = try parse(&.{ "hist", "01abc" });
    try std.testing.expectEqual(Subcommand.hist, cmd.subcommand.which);
    try std.testing.expectEqualStrings("01abc", cmd.subcommand.args[0]);
}

test "history is the same subcommand as hist" {
    const cmd = try parse(&.{"history"});
    try std.testing.expectEqual(Subcommand.hist, cmd.subcommand.which);
}

test "a journal location given before a subcommand reaches it" {
    const cmd = try parse(&.{ "--home", "/tmp/j", "sessions" });
    try std.testing.expectEqual(Subcommand.sessions, cmd.subcommand.which);
    try std.testing.expectEqualStrings("/tmp/j", cmd.subcommand.home.?);
}

test "help and version win over anything else" {
    try std.testing.expect(try parse(&.{"--help"}) == .help);
    try std.testing.expect(try parse(&.{ "-V", "sessions" }) == .version);
}

test "unknown flags and unknown subcommands are told apart" {
    try std.testing.expectError(error.UnknownFlag, parse(&.{"--nope"}));
    try std.testing.expectError(error.UnknownSubcommand, parse(&.{"zsh"}));
    // The old name for `hist`, so this is a plausible thing to type.
    try std.testing.expectError(error.UnknownSubcommand, parse(&.{"list"}));
    try std.testing.expectError(error.MissingFlagValue, parse(&.{"--home"}));
}
