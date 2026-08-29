//! Schema-driven routing and child-argv boundary detection for `tj`.
//!
//! Every public command is looked up through Zecli. `new`, `continue`, and
//! `noout` additionally carry a child argv; only the boundary is identified
//! here, and Zecli still parses their TJ-owned prefix.

const std = @import("std");
const zecli = @import("zecli");
const cli_spec = @import("cli_spec.zig");

pub const CommandName = enum {
    new,
    @"continue",
    noout,
    hist,
    journal,
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

    pub fn parse(name: []const u8) ?CommandName {
        const found = cli_spec.findCommand(name) orelse return null;
        return std.meta.stringToEnum(CommandName, found.name);
    }

    pub fn spec(self: CommandName) zecli.CommandSpec {
        return cli_spec.findCommand(@tagName(self)) orelse unreachable;
    }
};

pub const RootOptions = struct {
    keep_osc: bool = false,
    home: ?[]const u8 = null,
};

pub const JournalSelection = union(enum) {
    new,
    existing: []const u8,
};

/// Typed request consumed by the PTY proxy after Zecli parsed TJ's prefix.
pub const Proxy = struct {
    journal: JournalSelection,
    argv: []const []const u8 = &.{},
    keep_osc: bool = false,
    replay_before_start: bool = false,
    home: ?[]const u8 = null,
};

pub const RoutedCommand = struct {
    which: CommandName,
    args: []const [:0]const u8,
    root: RootOptions,
};

pub const Command = union(enum) {
    command: RoutedCommand,
    help,
    version,
};

pub const CommandArgs = struct {
    owned: []const [:0]const u8,
    child: []const [:0]const u8 = &.{},
};

pub const ParseError = error{
    UnknownFlag,
    MissingFlagValue,
    UnknownSubcommand,
    MissingLifecycle,
    MissingNooutSeparator,
    MissingNooutCommand,
    InvalidCommandArguments,
};

const FlagToken = struct {
    spec: zecli.FlagSpec,
    inline_value: bool,
};

/// Routes one application invocation. `args` excludes the program name.
pub fn parse(gpa: std.mem.Allocator, args: []const [:0]const u8) !Command {
    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        if (isHelp(arg)) return .help;
        if (std.mem.eql(u8, arg, "--")) return error.MissingLifecycle;

        if (std.mem.startsWith(u8, arg, "-")) {
            const token = findApplicationFlagToken(arg) orelse return error.UnknownFlag;
            if (zecli.takesValue(token.spec) and !token.inline_value) {
                if (i + 1 >= args.len) return error.MissingFlagValue;
                i += 2;
            } else {
                i += 1;
            }
            continue;
        }

        const which = CommandName.parse(arg) orelse return error.UnknownSubcommand;
        var parsed = zecli.parse(gpa, args[0..i], cli_spec.application.flags) catch return error.UnknownFlag;
        defer parsed.deinit(gpa);
        if (parsed.present("version")) return .version;
        return .{ .command = .{
            .which = which,
            .args = args[i + 1 ..],
            .root = .{
                .keep_osc = parsed.present("keep-osc"),
                .home = parsed.last("home"),
            },
        } };
    }

    var parsed = zecli.parse(gpa, args, cli_spec.application.flags) catch return error.UnknownFlag;
    defer parsed.deinit(gpa);
    if (parsed.present("version")) return .version;
    return .help;
}

/// Separates TJ-owned arguments from a child argv without interpreting child
/// options. Every returned `owned` slice is subsequently parsed by Zecli.
pub fn splitCommandArgs(command: RoutedCommand) ParseError!CommandArgs {
    return switch (command.which) {
        .new => splitImplicitChild(command.args, command.which.spec(), 0),
        .@"continue" => splitImplicitChild(command.args, command.which.spec(), 1),
        .noout => splitNoout(command.args),
        else => .{ .owned = command.args },
    };
}

/// These are the only destructive/mode raw-argv checks Zecli cannot express.
/// Values and arity are still parsed by Zecli after this preflight succeeds.
pub fn preflightCommandArgs(which: CommandName, args: []const [:0]const u8) ParseError!void {
    switch (which) {
        .name, .tag, .pin => {
            for (args, 0..) |arg, i| {
                if (std.mem.eql(u8, arg, "--")) break;
                if (std.mem.eql(u8, arg, "--remove") and i != 0) return error.InvalidCommandArguments;
            }
        },
        else => {},
    }
}

fn splitNoout(args: []const [:0]const u8) ParseError!CommandArgs {
    if (args.len == 1 and isHelp(args[0])) return .{ .owned = args };
    if (args.len == 0 or !std.mem.eql(u8, args[0], "--")) return error.MissingNooutSeparator;
    if (args.len == 1) return error.MissingNooutCommand;
    return .{ .owned = &.{}, .child = args[1..] };
}

fn splitImplicitChild(
    args: []const [:0]const u8,
    spec: zecli.CommandSpec,
    owned_positionals: usize,
) CommandArgs {
    var positionals: usize = 0;
    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            return .{ .owned = args[0..i], .child = args[i + 1 ..] };
        }
        if (isHelp(arg)) {
            i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-") and arg.len > 1) {
            if (findCommandFlagToken(spec, arg)) |token| {
                if (zecli.takesValue(token.spec) and !token.inline_value and i + 1 < args.len) {
                    i += 2;
                } else {
                    i += 1;
                }
            } else {
                // Keep unknown flags in TJ's prefix so Zecli reports them.
                i += 1;
            }
            continue;
        }
        if (positionals < owned_positionals) {
            positionals += 1;
            i += 1;
            continue;
        }
        return .{ .owned = args[0..i], .child = args[i..] };
    }
    return .{ .owned = args };
}

fn longFlagName(arg: []const u8) ?struct { name: []const u8, inline_value: bool } {
    if (std.mem.startsWith(u8, arg, "--") and arg.len > 2) {
        const raw = arg[2..];
        const eql = std.mem.indexOfScalar(u8, raw, '=');
        return .{ .name = if (eql) |at| raw[0..at] else raw, .inline_value = eql != null };
    }
    return null;
}

fn findApplicationFlagToken(arg: []const u8) ?FlagToken {
    if (longFlagName(arg)) |long| {
        const spec = zecli.findApplicationFlag(cli_spec.application, long.name) orelse return null;
        return .{ .spec = spec, .inline_value = long.inline_value };
    }
    return findShortFlagToken(cli_spec.application.flags, arg);
}

fn findCommandFlagToken(command: zecli.CommandSpec, arg: []const u8) ?FlagToken {
    if (longFlagName(arg)) |long| {
        const spec = zecli.findFlag(command, long.name) orelse return null;
        return .{ .spec = spec, .inline_value = long.inline_value };
    }
    return findShortFlagToken(command.flags, arg);
}

fn findShortFlagToken(flags: []const zecli.FlagSpec, arg: []const u8) ?FlagToken {
    if (arg.len == 2 and arg[0] == '-') {
        for (flags) |flag| {
            if (flag.short == arg[1]) return .{ .spec = flag, .inline_value = false };
        }
    }
    return null;
}

fn isHelp(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help");
}

test "every command tag has one specification and aliases canonicalize" {
    try std.testing.expectEqual(std.meta.fields(CommandName).len, cli_spec.application.commands.len);
    inline for (std.meta.fields(CommandName)) |field| {
        const which: CommandName = @enumFromInt(field.value);
        try std.testing.expectEqualStrings(field.name, which.spec().name);
        try std.testing.expectEqual(which, CommandName.parse(field.name).?);
    }
    try std.testing.expectEqual(CommandName.hist, CommandName.parse("history").?);
}

test "a bare invocation explains itself instead of starting a writer" {
    try std.testing.expect(try parse(std.testing.allocator, &.{}) == .help);
    try std.testing.expect(try parse(std.testing.allocator, &.{"--keep-osc"}) == .help);
}

test "all commands share routing and preserve root options" {
    const new_cmd = (try parse(std.testing.allocator, &.{ "--home", "/tmp/j", "new", "--keep-osc" })).command;
    try std.testing.expectEqual(CommandName.new, new_cmd.which);
    try std.testing.expectEqualStrings("/tmp/j", new_cmd.root.home.?);

    const grep = (try parse(std.testing.allocator, &.{ "--home=/tmp/j", "grep", "--all", "needle" })).command;
    try std.testing.expectEqual(CommandName.grep, grep.which);
    try std.testing.expectEqualStrings("/tmp/j", grep.root.home.?);
    try std.testing.expectEqualStrings("--all", grep.args[0]);

    const history = (try parse(std.testing.allocator, &.{"history"})).command;
    try std.testing.expectEqual(CommandName.hist, history.which);
}

test "new and continue split child argv without parsing it" {
    const new_bare = (try parse(std.testing.allocator, &.{ "new", "zsh", "-f" })).command;
    const new_parts = try splitCommandArgs(new_bare);
    try std.testing.expectEqual(@as(usize, 0), new_parts.owned.len);
    try std.testing.expectEqualStrings("zsh", new_parts.child[0]);
    try std.testing.expectEqualStrings("-f", new_parts.child[1]);

    const new_separated = (try parse(std.testing.allocator, &.{ "new", "--home=/tmp/j", "--", "--nope" })).command;
    const separated_parts = try splitCommandArgs(new_separated);
    try std.testing.expectEqualStrings("--home=/tmp/j", separated_parts.owned[0]);
    try std.testing.expectEqualStrings("--nope", separated_parts.child[0]);

    const continued = (try parse(std.testing.allocator, &.{ "continue", "abcd", "--keep-osc", "--no-replay", "zsh", "-f" })).command;
    const continued_parts = try splitCommandArgs(continued);
    try std.testing.expectEqual(@as(usize, 3), continued_parts.owned.len);
    try std.testing.expectEqualStrings("abcd", continued_parts.owned[0]);
    try std.testing.expectEqualStrings("--no-replay", continued_parts.owned[2]);
    try std.testing.expectEqualStrings("zsh", continued_parts.child[0]);
}

test "unknown process flags stay owned and child help stays with the child" {
    const unknown = (try parse(std.testing.allocator, &.{ "new", "--nope", "zsh" })).command;
    const unknown_parts = try splitCommandArgs(unknown);
    try std.testing.expectEqualStrings("--nope", unknown_parts.owned[0]);
    try std.testing.expectEqualStrings("zsh", unknown_parts.child[0]);

    const child_help = (try parse(std.testing.allocator, &.{ "new", "sh", "--help" })).command;
    const help_parts = try splitCommandArgs(child_help);
    try std.testing.expectEqual(@as(usize, 0), help_parts.owned.len);
    try std.testing.expectEqualStrings("--help", help_parts.child[1]);
}

test "noout requires its explicit child boundary but permits command help" {
    const routed = (try parse(std.testing.allocator, &.{ "noout", "--", "printf", "--help" })).command;
    const parts = try splitCommandArgs(routed);
    try std.testing.expectEqualStrings("printf", parts.child[0]);
    try std.testing.expectEqualStrings("--help", parts.child[1]);

    const help = (try parse(std.testing.allocator, &.{ "noout", "--help" })).command;
    try std.testing.expectEqualStrings("--help", (try splitCommandArgs(help)).owned[0]);

    const missing = (try parse(std.testing.allocator, &.{ "noout", "printf" })).command;
    try std.testing.expectError(error.MissingNooutSeparator, splitCommandArgs(missing));
    const empty = (try parse(std.testing.allocator, &.{ "noout", "--" })).command;
    try std.testing.expectError(error.MissingNooutCommand, splitCommandArgs(empty));
}

test "mutation preflights preserve mode position and destructive target safety" {
    try preflightCommandArgs(.name, &.{ "--remove", "old-name" });
    try preflightCommandArgs(.rm, &.{ "--force", "@2" });
    try std.testing.expectError(
        error.InvalidCommandArguments,
        preflightCommandArgs(.tag, &.{ "@1", "--remove", "bug" }),
    );
}

test "root errors and actions remain distinct" {
    try std.testing.expect(try parse(std.testing.allocator, &.{ "-V", "journal", "list" }) == .version);
    try std.testing.expect(try parse(std.testing.allocator, &.{"--help"}) == .help);
    try std.testing.expectError(error.UnknownFlag, parse(std.testing.allocator, &.{"--nope"}));
    try std.testing.expectError(error.UnknownSubcommand, parse(std.testing.allocator, &.{"run"}));
    try std.testing.expectError(error.MissingLifecycle, parse(std.testing.allocator, &.{ "--", "zsh" }));
    try std.testing.expectError(error.MissingFlagValue, parse(std.testing.allocator, &.{"--home"}));
}
