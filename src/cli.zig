//! Application-specific checks layered on Zecli's invocation router.

const std = @import("std");
const zecli = @import("zecli");
const cli_spec = @import("cli_spec.zig");

pub const CommandName = zecli.CommandEnum(cli_spec.application);

/// Annotation removal is deliberately a leading mode: accepting it after a
/// target would make the remaining words change meaning halfway through the
/// command. Zecli owns routing and parsing; this is TJ's one raw-order rule.
pub fn validateRemoveOrdering(which: CommandName, args: []const [:0]const u8) !void {
    switch (which) {
        .name, .tag, .pin => {},
        else => return,
    }
    for (args, 0..) |arg, i| {
        if (!std.mem.eql(u8, arg, "--remove")) continue;
        if (i == 0) return error.InvalidCommandArguments;
        const previous = cli_spec.findCommand(args[i - 1]) orelse return error.InvalidCommandArguments;
        if (!std.mem.eql(u8, previous.name, @tagName(which))) return error.InvalidCommandArguments;
    }
}

test "generated command tags canonicalize aliases" {
    try std.testing.expectEqual(std.meta.fields(CommandName).len, cli_spec.application.commands.len);
    try std.testing.expectEqual(CommandName.hist, try (zecli.Command{
        .name = "hist",
        .spec = cli_spec.findCommand("history").?,
        .parsed = .{},
    }).as(CommandName));
}

test "annotation removal remains a leading mode" {
    try validateRemoveOrdering(.name, &.{ "name", "--remove", "old-name" });
    try validateRemoveOrdering(.rm, &.{ "rm", "--force", "@2" });
    try std.testing.expectError(
        error.InvalidCommandArguments,
        validateRemoveOrdering(.tag, &.{ "tag", "@1", "--remove", "bug" }),
    );
}
