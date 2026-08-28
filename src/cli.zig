//! Command line parsing for `tj`.
//!
//!     tj new [flags] [-- command...]   create and write a journal
//!     tj continue <id> [flags] [...]  append to an existing journal
//!     tj noout -- command...           show output without recording it
//!     tj <subcommand> [args...]        work with the journal
//!     tj                               help
//!
//! Starting a writer takes an explicit lifecycle command. This changes what
//! the shell you are typing into is, which is not something to enter by
//! mistyping a read subcommand.

const std = @import("std");

pub const Subcommand = enum {
    hist,
    journals,
    current,
    last,
    cat,
    replay,
    resolve,
    complete,
    name,
    tag,
    pin,
    rm,
    grep,

    pub fn parse(name: []const u8) ?Subcommand {
        if (std.mem.eql(u8, name, "history")) return .hist;
        return std.meta.stringToEnum(Subcommand, name);
    }
};

pub const JournalSelection = union(enum) {
    new,
    existing: []const u8,
};

pub const Proxy = struct {
    journal: JournalSelection,
    /// The command to run under the pty. Empty means "the user's shell".
    argv: []const []const u8 = &.{},
    keep_osc: bool = false,
    home: ?[]const u8 = null,
};

pub const Command = union(enum) {
    proxy: Proxy,
    noout: []const []const u8,
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
    MissingLifecycle,
    MissingJournal,
    MissingNooutSeparator,
    MissingNooutCommand,
};

/// `args` excludes the program name.
pub fn parse(args: []const []const u8) ParseError!Command {
    var options: ProxyOptions = .{};
    var i: usize = 0;

    while (i < args.len) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) return .help;
        if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) return .version;

        if (try takeFlag(args, &i, &options)) continue;

        if (std.mem.eql(u8, arg, "--")) return error.MissingLifecycle;
        if (std.mem.startsWith(u8, arg, "-")) return error.UnknownFlag;

        if (std.mem.eql(u8, arg, "new")) {
            return .{ .proxy = try parseProxy(args[i + 1 ..], options, .new) };
        }
        if (std.mem.eql(u8, arg, "continue")) {
            const rest = args[i + 1 ..];
            if (rest.len == 0 or std.mem.eql(u8, rest[0], "--") or std.mem.startsWith(u8, rest[0], "-")) {
                return error.MissingJournal;
            }
            return .{ .proxy = try parseProxy(rest[1..], options, .{ .existing = rest[0] }) };
        }
        if (std.mem.eql(u8, arg, "noout")) {
            const rest = args[i + 1 ..];
            if (rest.len == 0 or !std.mem.eql(u8, rest[0], "--")) return error.MissingNooutSeparator;
            if (rest.len == 1) return error.MissingNooutCommand;
            return .{ .noout = rest[1..] };
        }

        const which = Subcommand.parse(arg) orelse return error.UnknownSubcommand;
        const rest = args[i + 1 ..];
        return .{ .subcommand = .{ .which = which, .args = rest, .home = options.home } };
    }

    // Nothing asked for. Say what is on offer rather than guessing.
    return .help;
}

const ProxyOptions = struct {
    keep_osc: bool = false,
    home: ?[]const u8 = null,
};

/// Everything after the lifecycle selector: any remaining flags, then the
/// child command, with or without a `--` separating them.
fn parseProxy(args: []const []const u8, inherited: ProxyOptions, journal: JournalSelection) ParseError!Proxy {
    var options = inherited;
    var i: usize = 0;

    while (i < args.len) {
        if (std.mem.eql(u8, args[i], "--")) {
            return .{
                .journal = journal,
                .argv = args[i + 1 ..],
                .keep_osc = options.keep_osc,
                .home = options.home,
            };
        }
        if (try takeFlag(args, &i, &options)) continue;

        // A flag tj does not know is a mistake, not a program to run. Say so,
        // rather than reporting that `--nope` could not be executed. After the
        // separator it would be a program name, and is left alone.
        if (std.mem.startsWith(u8, args[i], "-")) return error.UnknownFlag;

        return .{
            .journal = journal,
            .argv = args[i..],
            .keep_osc = options.keep_osc,
            .home = options.home,
        };
    }
    return .{
        .journal = journal,
        .keep_osc = options.keep_osc,
        .home = options.home,
    };
}

/// Consumes a flag at `i` if there is one, advancing past it.
fn takeFlag(args: []const []const u8, i: *usize, options: *ProxyOptions) ParseError!bool {
    const arg = args[i.*];

    if (std.mem.eql(u8, arg, "--keep-osc")) {
        options.keep_osc = true;
        i.* += 1;
        return true;
    }
    if (std.mem.eql(u8, arg, "--home")) {
        if (i.* + 1 >= args.len) return error.MissingFlagValue;
        options.home = args[i.* + 1];
        i.* += 2;
        return true;
    }
    if (std.mem.startsWith(u8, arg, "--home=")) {
        options.home = arg["--home=".len..];
        i.* += 1;
        return true;
    }
    return false;
}

test "a bare invocation explains itself instead of starting a writer" {
    try std.testing.expect(try parse(&.{}) == .help);
    try std.testing.expect(try parse(&.{"--keep-osc"}) == .help);
}

test "new creates a journal with the default shell" {
    const cmd = try parse(&.{"new"});
    try std.testing.expect(cmd == .proxy);
    try std.testing.expect(cmd.proxy.journal == .new);
    try std.testing.expectEqual(@as(usize, 0), cmd.proxy.argv.len);
}

test "new takes a command with or without a separator" {
    const separated = try parse(&.{ "new", "--", "zsh", "-f" });
    try std.testing.expectEqual(@as(usize, 2), separated.proxy.argv.len);
    try std.testing.expectEqualStrings("zsh", separated.proxy.argv[0]);
    try std.testing.expectEqualStrings("-f", separated.proxy.argv[1]);

    const bare = try parse(&.{ "new", "zsh", "-f" });
    try std.testing.expectEqual(@as(usize, 2), bare.proxy.argv.len);
    try std.testing.expectEqualStrings("zsh", bare.proxy.argv[0]);
}

test "flags work before or after new" {
    const before = try parse(&.{ "--keep-osc", "--home", "/tmp/j", "new" });
    try std.testing.expect(before.proxy.keep_osc);
    try std.testing.expectEqualStrings("/tmp/j", before.proxy.home.?);

    const after = try parse(&.{ "new", "--keep-osc", "--home=/tmp/j", "--", "sh" });
    try std.testing.expect(after.proxy.keep_osc);
    try std.testing.expectEqualStrings("/tmp/j", after.proxy.home.?);
    try std.testing.expectEqualStrings("sh", after.proxy.argv[0]);
}

test "an unknown flag after new is a mistake, not a program name" {
    try std.testing.expectError(error.UnknownFlag, parse(&.{ "new", "--nope" }));
    // ...but after the separator it is whatever the user meant it to be.
    const cmd = try parse(&.{ "new", "--", "--nope" });
    try std.testing.expectEqualStrings("--nope", cmd.proxy.argv[0]);
}

test "flags after the separator belong to the command" {
    const cmd = try parse(&.{ "new", "--", "sh", "--help" });
    try std.testing.expectEqual(@as(usize, 2), cmd.proxy.argv.len);
    try std.testing.expectEqualStrings("--help", cmd.proxy.argv[1]);
}

test "continue requires one journal selector and accepts a command" {
    const cmd = try parse(&.{ "continue", "abcd", "--keep-osc", "--", "zsh", "-f" });
    try std.testing.expect(cmd.proxy.journal == .existing);
    try std.testing.expectEqualStrings("abcd", cmd.proxy.journal.existing);
    try std.testing.expect(cmd.proxy.keep_osc);
    try std.testing.expectEqualStrings("zsh", cmd.proxy.argv[0]);

    const bare = try parse(&.{ "--home=/tmp/j", "continue", "01abc", "sh", "-c", "true" });
    try std.testing.expectEqualStrings("/tmp/j", bare.proxy.home.?);
    try std.testing.expectEqualStrings("sh", bare.proxy.argv[0]);
}

test "continue requires a journal selector" {
    try std.testing.expectError(error.MissingJournal, parse(&.{"continue"}));
    try std.testing.expectError(error.MissingJournal, parse(&.{ "continue", "--" }));
    try std.testing.expectError(error.MissingJournal, parse(&.{ "continue", "--home", "/tmp/j" }));
}

test "noout requires a separator and preserves child arguments" {
    const cmd = try parse(&.{ "noout", "--", "printf", "--help", "two words" });
    try std.testing.expect(cmd == .noout);
    try std.testing.expectEqual(@as(usize, 3), cmd.noout.len);
    try std.testing.expectEqualStrings("printf", cmd.noout[0]);
    try std.testing.expectEqualStrings("--help", cmd.noout[1]);
    try std.testing.expectEqualStrings("two words", cmd.noout[2]);
}

test "noout rejects an omitted separator or command" {
    try std.testing.expectError(error.MissingNooutSeparator, parse(&.{"noout"}));
    try std.testing.expectError(error.MissingNooutSeparator, parse(&.{ "noout", "printf" }));
    try std.testing.expectError(error.MissingNooutCommand, parse(&.{ "noout", "--" }));
}

test "global help and version still take precedence over noout" {
    try std.testing.expect(try parse(&.{ "--help", "noout", "--", "false" }) == .help);
    try std.testing.expect(try parse(&.{ "--version", "noout", "--", "false" }) == .version);
}

test "a command with no lifecycle is refused rather than guessed at" {
    try std.testing.expectError(error.MissingLifecycle, parse(&.{ "--", "zsh" }));
}

test "subcommands are recognised and keep their arguments" {
    const cmd = try parse(&.{ "hist", "01abc" });
    try std.testing.expectEqual(Subcommand.hist, cmd.subcommand.which);
    try std.testing.expectEqualStrings("01abc", cmd.subcommand.args[0]);
}

test "grep is a subcommand and retains global home and its own options" {
    const cmd = try parse(&.{ "--home", "/tmp/j", "grep", "--all", "needle" });
    try std.testing.expectEqual(Subcommand.grep, cmd.subcommand.which);
    try std.testing.expectEqualStrings("/tmp/j", cmd.subcommand.home.?);
    try std.testing.expectEqualSlices([]const u8, &.{ "--all", "needle" }, cmd.subcommand.args);
}

test "history is the same subcommand as hist" {
    const cmd = try parse(&.{"history"});
    try std.testing.expectEqual(Subcommand.hist, cmd.subcommand.which);
}

test "a journal location given before a subcommand reaches it" {
    const cmd = try parse(&.{ "--home", "/tmp/j", "journals" });
    try std.testing.expectEqual(Subcommand.journals, cmd.subcommand.which);
    try std.testing.expectEqualStrings("/tmp/j", cmd.subcommand.home.?);
}

test "help and version win over anything else" {
    try std.testing.expect(try parse(&.{"--help"}) == .help);
    try std.testing.expect(try parse(&.{ "-V", "journals" }) == .version);
}

test "unknown flags and unknown subcommands are told apart" {
    try std.testing.expectError(error.UnknownFlag, parse(&.{"--nope"}));
    try std.testing.expectError(error.UnknownSubcommand, parse(&.{"zsh"}));
    // The old name for `hist`, so this is a plausible thing to type.
    try std.testing.expectError(error.UnknownSubcommand, parse(&.{"list"}));
    try std.testing.expectError(error.UnknownSubcommand, parse(&.{"run"}));
    try std.testing.expectError(error.UnknownSubcommand, parse(&.{"sess" ++ "ions"}));
    try std.testing.expectError(error.MissingFlagValue, parse(&.{"--home"}));
}
