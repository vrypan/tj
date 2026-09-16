//! Application-specific checks layered on Zecli's invocation router.

const std = @import("std");
const zecli = @import("zecli");
const cli_spec = @import("tj_spec.zig");
const reference = @import("../journal/reference.zig");

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

test "generated command tags canonicalize aliases" {
    try std.testing.expectEqual(std.meta.fields(CommandName).len, cli_spec.application.commands.len);
    try std.testing.expectEqual(CommandName.history, try (zecli.Command{
        .name = "history",
        .spec = cli_spec.findCommand("h").?,
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

test "ordinary command parsers treat double dash tails as positionals" {
    const allocator = std.testing.allocator;
    var buffer_storage: [2048]u8 = undefined;
    var buffer = std.Io.Writer.Discarding.init(&buffer_storage);

    var cat = try zecli.parseCommand(
        allocator,
        &buffer.writer,
        &.{ "--", "@42/out" },
        cli_spec.findCommand("cat").?,
    );
    defer cat.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), cat.positionals.items.len);
    try std.testing.expectEqualStrings("@42/out", cat.positionals.items[0]);
    try std.testing.expect(!cat.has_passthrough);

    var grep = try zecli.parseCommand(
        allocator,
        &buffer.writer,
        &.{ "pattern", "--", "@42", "--help", "--" },
        cli_spec.findCommand("grep").?,
    );
    defer grep.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 4), grep.positionals.items.len);
    try std.testing.expectEqualStrings("pattern", grep.positionals.items[0]);
    try std.testing.expectEqualStrings("@42", grep.positionals.items[1]);
    try std.testing.expectEqualStrings("--help", grep.positionals.items[2]);
    try std.testing.expectEqualStrings("--", grep.positionals.items[3]);

    var complete = try zecli.parseCommand(
        allocator,
        &buffer.writer,
        &.{ "--", "" },
        cli_spec.findCommand("complete").?,
    );
    defer complete.deinit(allocator);
    try std.testing.expectEqualStrings("", complete.positionals.items[0]);

    try std.testing.expectError(
        error.ReportedCliError,
        zecli.parseCommand(allocator, &buffer.writer, &.{"--"}, cli_spec.findCommand("resolve").?),
    );
}

test "Invocation honors positional double dash mode without changing filter" {
    const allocator = std.testing.allocator;
    var buffer_storage: [2048]u8 = undefined;
    var buffer = std.Io.Writer.Discarding.init(&buffer_storage);
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();

    var invocation = try zecli.Invocation.init(
        allocator,
        &buffer.writer,
        cli_spec.application,
        &.{ "cat", "@1/out", "--", "@2/out" },
        &environ,
    );
    defer invocation.deinit(allocator);
    const cat = invocation.getCommand().?;
    try std.testing.expectEqual(@as(usize, 2), cat.positionals().len);
    try std.testing.expect(cat.passthrough() == null);

    var filter = try zecli.Invocation.init(
        allocator,
        &buffer.writer,
        cli_spec.application,
        &.{ "filter", "--noout", "--", "/bin/echo", "--help" },
        &environ,
    );
    defer filter.deinit(allocator);
    try std.testing.expectEqualStrings("--help", filter.getCommand().?.passthrough().?[1]);
}
