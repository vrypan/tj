//! Schema-driven routing and child-argv boundary detection for `tj`.
//!
//! Every public entry/resource command is looked up through Zecli. `noout`
//! additionally carries a child argv after its mandatory boundary.

const std = @import("std");
const zecli = @import("zecli");
const cli_spec = @import("cli_spec.zig");

pub const CommandName = enum {
    tui,
    noout,
    hist,
    last,
    cat,
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
}

test "all commands share routing and preserve root options" {
    const hist = (try parse(std.testing.allocator, &.{ "--home", "/tmp/j", "hist" })).command;
    try std.testing.expectEqual(CommandName.hist, hist.which);
    try std.testing.expectEqualStrings("/tmp/j", hist.root.home.?);

    const grep = (try parse(std.testing.allocator, &.{ "--home=/tmp/j", "grep", "--all", "needle" })).command;
    try std.testing.expectEqual(CommandName.grep, grep.which);
    try std.testing.expectEqualStrings("/tmp/j", grep.root.home.?);
    try std.testing.expectEqualStrings("--all", grep.args[0]);

    const history = (try parse(std.testing.allocator, &.{"history"})).command;
    try std.testing.expectEqual(CommandName.hist, history.which);
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
    try preflightCommandArgs(.rm, &.{ "--force", "@2", "@4/out", "@6..@8" });
    try std.testing.expectError(
        error.InvalidCommandArguments,
        preflightCommandArgs(.tag, &.{ "@1", "--remove", "bug" }),
    );
}

test "root errors and actions remain distinct" {
    try std.testing.expect(try parse(std.testing.allocator, &.{ "-V", "hist" }) == .version);
    try std.testing.expect(try parse(std.testing.allocator, &.{"--help"}) == .help);
    try std.testing.expectError(error.UnknownFlag, parse(std.testing.allocator, &.{"--nope"}));
    try std.testing.expectError(error.UnknownSubcommand, parse(std.testing.allocator, &.{"run"}));
    try std.testing.expectError(error.MissingLifecycle, parse(std.testing.allocator, &.{ "--", "zsh" }));
    try std.testing.expectError(error.MissingFlagValue, parse(std.testing.allocator, &.{"--home"}));
}
