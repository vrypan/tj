//! The PTY fixture itself must enforce deadlines and clean up failed children.

const std = @import("std");
const harness = @import("harness.zig");
const support = @import("it_support.zig");

test "environment guards restore unset empty and populated values" {
    const gpa = std.testing.allocator;
    const name = "TJ_TEST_ENV_GUARD";
    var original = try support.EnvGuard.init(gpa, &.{name});
    defer original.deinit();

    support.sys.unsetEnv(name);
    {
        var environment = try support.EnvGuard.init(gpa, &.{name});
        defer environment.deinit();
        support.sys.setEnv(name, "changed");
    }
    try std.testing.expect(!support.sys.envPresent(name));

    support.sys.setEnv(name, "");
    {
        var environment = try support.EnvGuard.init(gpa, &.{name});
        defer environment.deinit();
        support.sys.setEnv(name, "changed");
    }
    try std.testing.expect(support.sys.envPresent(name));
    try std.testing.expect(support.sys.env(name) == null);

    support.sys.setEnv(name, "original");
    {
        var environment = try support.EnvGuard.init(gpa, &.{name});
        defer environment.deinit();
        support.sys.setEnv(name, "changed");
    }
    try std.testing.expectEqualStrings("original", support.sys.env(name).?);
}

test "pty deadlines expire while output flows and reap the child" {
    const gpa = std.testing.allocator;
    const child = try harness.spawn(
        gpa,
        &.{ "/bin/sh", "-c", "trap '' HUP TERM INT; while :; do printf x; /bin/sleep 0.01; done" },
        24,
        80,
    );
    var transcript: std.ArrayList(u8) = .empty;
    defer transcript.deinit(gpa);

    try std.testing.expect(!try child.readUntil(gpa, &transcript, "never-produced", 100));
    try std.testing.expect(transcript.items.len > 0);
    try std.testing.expectError(error.PtyTimeout, child.finish(gpa, &transcript, 100));
}
