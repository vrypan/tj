//! The startup splash gets its own process-level test binary. The ordinary
//! integration suite also contains a deliberately nested terminal restoration
//! probe; keeping these independent avoids coupling two session-leader PTYs on
//! macOS while testing both lifecycles completely.

const std = @import("std");
const support = @import("it_support.zig");

test "journal writers show a restorable splash unless disabled" {
    const gpa = std.testing.allocator;
    var scratch = try support.Scratch.open();
    defer scratch.close();

    const child = try support.spawnTjctlWithSplash(gpa, &.{
        support.tjctl, "--home", scratch.path(), "new", "splash-demo", "--", "/bin/sh", "-c", "echo CHILD_STARTED",
    }, 24, 80);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try std.testing.expect(try child.readUntil(gpa, &out, "Press ENTER to continue", support.timeout_ms));
    try std.testing.expect(std.mem.indexOf(u8, out.items, "Recording journal") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "splash-demo") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "Next entry: @1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "CHILD_STARTED") == null);
    try child.write("\r");
    try std.testing.expectEqual(@as(u8, 0), try child.finish(gpa, &out, support.timeout_ms));
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[?1049h") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[?1049l") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "CHILD_STARTED") != null);

    const quiet = try support.spawnTjctlWithSplash(gpa, &.{
        support.tjctl, "--home", scratch.path(), "new", "quiet-demo", "--no-splash", "--", "/bin/sh", "-c", "echo QUIET_STARTED",
    }, 24, 80);
    var quiet_out: std.ArrayList(u8) = .empty;
    defer quiet_out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), try quiet.finish(gpa, &quiet_out, support.timeout_ms));
    try std.testing.expect(std.mem.indexOf(u8, quiet_out.items, "Recording journal") == null);
    try std.testing.expect(std.mem.indexOf(u8, quiet_out.items, "QUIET_STARTED") != null);
}
