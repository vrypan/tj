//! Application-specific checks layered on Zecli's invocation router.

const std = @import("std");
const zecli = @import("zecli");
const cli_spec = @import("cli_spec.zig");
const reference = @import("reference.zig");

pub const CommandName = zecli.CommandEnum(cli_spec.application);

/// `tj @42/out` is deliberately narrow shorthand for `tj resolve @42/out`.
/// Keep root flags before the reference so the synthetic command has the same
/// shape Zecli normally receives: `tj --home DIR resolve @42/out`.
pub fn routeBareReference(
    arena: std.mem.Allocator,
    args: []const [:0]const u8,
) ![]const [:0]const u8 {
    var candidate: ?usize = null;
    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--home")) {
            if (candidate != null or i + 1 >= args.len) return args;
            i += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--home=")) {
            if (candidate != null) return args;
            i += 1;
            continue;
        }
        if (arg.len > 0 and arg[0] == '-') return args;
        if (candidate != null) return args;
        _ = reference.parse(arg) catch return args;
        candidate = i;
        i += 1;
    }

    const index = candidate orelse return args;
    const routed = try arena.alloc([:0]const u8, args.len + 1);
    @memcpy(routed[0..index], args[0..index]);
    routed[index] = "resolve";
    @memcpy(routed[index + 1 ..], args[index..]);
    return routed;
}

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

test "a bare reference routes to resolve after root flags" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const routed = try routeBareReference(arena_state.allocator(), &.{ "--home", "/tmp/tj", "@42/out" });
    try std.testing.expectEqualStrings("--home", routed[0]);
    try std.testing.expectEqualStrings("/tmp/tj", routed[1]);
    try std.testing.expectEqualStrings("resolve", routed[2]);
    try std.testing.expectEqualStrings("@42/out", routed[3]);
}

test "a non-reference stays a normal root command" {
    const args: []const [:0]const u8 = &.{"not-a-command"};
    const routed = try routeBareReference(std.testing.allocator, args);
    try std.testing.expectEqual(args.ptr, routed.ptr);
}

test "annotation removal remains a leading mode" {
    try validateRemoveOrdering(.name, &.{ "name", "--remove", "old-name" });
    try validateRemoveOrdering(.rm, &.{ "rm", "--force", "@2" });
    try std.testing.expectError(
        error.InvalidCommandArguments,
        validateRemoveOrdering(.tag, &.{ "tag", "@1", "--remove", "bug" }),
    );
}
