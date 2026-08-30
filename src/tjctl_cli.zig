const std = @import("std");
const zecli = @import("zecli");
const cli_spec = @import("tjctl_spec.zig");

pub const CommandName = enum {
    new,
    use,
    ls,
    mv,
    rm,
    du,
    replay,
    current,
    complete,

    pub fn parse(text: []const u8) ?CommandName {
        const found = cli_spec.findCommand(text) orelse return null;
        return std.meta.stringToEnum(CommandName, found.name);
    }
    pub fn spec(self: CommandName) zecli.CommandSpec {
        return cli_spec.findCommand(@tagName(self)) orelse unreachable;
    }
};

pub const RoutedCommand = struct {
    which: CommandName,
    args: []const [:0]const u8,
    home: ?[]const u8,
};
pub const Command = union(enum) { command: RoutedCommand, help, version };
pub const CommandArgs = struct { owned: []const [:0]const u8, child: []const [:0]const u8 = &.{} };
pub const ParseError = error{ UnknownFlag, MissingFlagValue, UnknownSubcommand, MissingCommand, MissingChildCommand };

pub fn parse(gpa: std.mem.Allocator, args: []const [:0]const u8) !Command {
    var i: usize = 0;
    while (i < args.len and std.mem.startsWith(u8, args[i], "-")) {
        if (std.mem.eql(u8, args[i], "-h") or std.mem.eql(u8, args[i], "--help")) return .help;
        if (std.mem.eql(u8, args[i], "--version") or std.mem.eql(u8, args[i], "-V")) return .version;
        if (std.mem.eql(u8, args[i], "--home")) {
            if (i + 1 >= args.len) return error.MissingFlagValue;
            i += 2;
        } else if (std.mem.startsWith(u8, args[i], "--home=")) {
            i += 1;
        } else return error.UnknownFlag;
    }
    if (i == args.len) return .help;
    const which = CommandName.parse(args[i]) orelse return error.UnknownSubcommand;
    var parsed = zecli.parse(gpa, args[0..i], cli_spec.application.flags) catch return error.UnknownFlag;
    defer parsed.deinit(gpa);
    return .{ .command = .{ .which = which, .args = args[i + 1 ..], .home = parsed.last("home") } };
}

pub fn splitCommandArgs(command: RoutedCommand) ParseError!CommandArgs {
    if (command.which != .new and command.which != .use) return .{ .owned = command.args };
    for (command.args, 0..) |arg, i| {
        if (!std.mem.eql(u8, arg, "--")) continue;
        if (i + 1 == command.args.len) return error.MissingChildCommand;
        return .{ .owned = command.args[0..i], .child = command.args[i + 1 ..] };
    }
    return .{ .owned = command.args };
}
