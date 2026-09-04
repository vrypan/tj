//! The startup splash gets its own process-level test binary. The ordinary
//! integration suite also contains a deliberately nested terminal restoration
//! probe; keeping these independent avoids coupling two session-leader PTYs on
//! macOS while testing both lifecycles completely.

const std = @import("std");
const support = @import("it_support.zig");

test "journal writers show a restorable splash unless disabled" {
    const gpa = std.testing.allocator;
    support.sys.setEnv("TJ_TITLE", "TJ | %3~");
    support.sys.setEnv("TJ_TITLE_BLINK", "1500");
    support.sys.setEnv("TJ_NO_SPLASH", "false");
    var scratch = try support.Scratch.open();
    defer scratch.close();

    const child = try support.spawnTjctlWithSplash(gpa, &.{
        support.tjctl, "--home", scratch.path(), "new", "splash-demo", "--", "/bin/sh", "-c", "echo CHILD_STARTED:$TJ_TITLE:$TJ_TITLE_BLINK",
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
    try std.testing.expect(std.mem.indexOf(u8, out.items, "CHILD_STARTED:TJ | %3~:1500") != null);

    const quiet = try support.spawnTjctlWithSplash(gpa, &.{
        support.tjctl, "--home", scratch.path(), "new", "quiet-demo", "--no-splash", "--", "/bin/sh", "-c", "echo QUIET_STARTED",
    }, 24, 80);
    var quiet_out: std.ArrayList(u8) = .empty;
    defer quiet_out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), try quiet.finish(gpa, &quiet_out, support.timeout_ms));
    try std.testing.expect(std.mem.indexOf(u8, quiet_out.items, "Recording journal") == null);
    try std.testing.expect(std.mem.indexOf(u8, quiet_out.items, "QUIET_STARTED") != null);

    support.sys.setEnv("TJ_NO_SPLASH", "1");
    const env_quiet = try support.spawnTjctlWithSplash(gpa, &.{
        support.tjctl, "--home", scratch.path(), "new", "env-quiet-demo", "--", "/bin/sh", "-c", "echo ENV_QUIET_STARTED",
    }, 24, 80);
    var env_quiet_out: std.ArrayList(u8) = .empty;
    defer env_quiet_out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), try env_quiet.finish(gpa, &env_quiet_out, support.timeout_ms));
    try std.testing.expect(std.mem.indexOf(u8, env_quiet_out.items, "Recording journal") == null);
    try std.testing.expect(std.mem.indexOf(u8, env_quiet_out.items, "ENV_QUIET_STARTED") != null);
    support.sys.setEnv("TJ_NO_SPLASH", "false");

    const seed_script =
        "printf '\\033]3110;CONTEXT;MTsxMTs0OzA7MDtzZWVkLXJlcGxheS90bXA=\\033\\\\" ++
        "\\033]133;C\\033\\\\REPLAY_ORDER_PAYLOAD\\n\\033]133;D;0\\033\\\\'";
    const seed = try support.spawnTjctlWithSplash(gpa, &.{
        support.tjctl, "--home", scratch.path(), "new", "replay-order", "--no-splash", "--", "/bin/sh", "-c", seed_script,
    }, 24, 80);
    var seed_out: std.ArrayList(u8) = .empty;
    defer seed_out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), try seed.finish(gpa, &seed_out, support.timeout_ms));

    const continued = try support.spawnTjctlWithSplash(gpa, &.{
        support.tjctl, "--home", scratch.path(), "use", "replay-order", "--", "/bin/sh", "-c", "printf 'FRESH_CHILD\n'",
    }, 24, 80);
    var continued_out: std.ArrayList(u8) = .empty;
    defer continued_out.deinit(gpa);
    try std.testing.expect(try continued.readUntil(gpa, &continued_out, "Press ENTER to continue", support.timeout_ms));
    try std.testing.expect(std.mem.indexOf(u8, continued_out.items, "REPLAY_ORDER_PAYLOAD") == null);
    try std.testing.expect(std.mem.indexOf(u8, continued_out.items, "FRESH_CHILD") == null);
    try continued.write("\r");
    try std.testing.expectEqual(@as(u8, 0), try continued.finish(gpa, &continued_out, support.timeout_ms));
    const replay_at = std.mem.indexOf(u8, continued_out.items, "REPLAY_ORDER_PAYLOAD") orelse return error.TestUnexpectedResult;
    const child_at = std.mem.indexOf(u8, continued_out.items, "FRESH_CHILD") orelse return error.TestUnexpectedResult;
    try std.testing.expect(replay_at < child_at);
}

test "journal writers manage terminal titles without changing recorded bytes" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    support.sys.setEnv("TJ_TITLE", "TJ | %3~");
    support.sys.setEnv("TJ_TITLE_BLINK", "1500");
    support.sys.setEnv("TJ_NO_SPLASH", "false");
    var scratch = try support.Scratch.open();
    defer scratch.close();

    // The TJ and OSC 133 markers create one entry without relying on a shell
    // plugin. The title itself uses ST so both bytes are exercised across the
    // PTY read boundary chosen by the kernel.
    const script =
        "printf '\\033]3110;CONTEXT;MTsxMDs0OzA7MDt0aXRsZS10ZXN0L3RtcA==\\033\\\\" ++
        "\\033]133;C\\033\\\\'; " ++
        "printf 'TITLE_OPTIONS=%s ' \"$TJ_TITLE\"; " ++
        "printf '\\033]2;~/Devel/\\033\\\\" ++
        "\\033]133;D;0\\033\\\\'";
    const child = try support.spawnTjctlWithSplash(gpa, &.{
        support.tjctl, "--home", scratch.path(), "new", "title-demo", "--no-splash", "--title", "TJ | $TJ_REF | $PWD", "--", "/bin/sh", "-c", script,
    }, 24, 80);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), try child.finish(gpa, &out, support.timeout_ms));

    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[22;0t") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "● title-demo\x1b\\") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "● ~/Devel/\x1b\\") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[23;0t") != null);

    const recorded = try scratch.tmp.dir.readFileAlloc(io, "title-demo/1/out", gpa, .limited(1024));
    defer gpa.free(recorded);
    try std.testing.expect(std.mem.indexOf(u8, recorded, "\x1b]2;~/Devel/\x1b\\") != null);
    try std.testing.expect(std.mem.indexOf(u8, recorded, "\x1b]0;title-demo\x1b\\") == null);
    try std.testing.expect(std.mem.indexOf(u8, recorded, "TITLE_OPTIONS=TJ | $TJ_REF | $PWD") != null);

    support.sys.setEnv("TJ_TITLE", "INHERITED:$TJ_REF:%1~");
    support.sys.setEnv("TJ_TITLE_BLINK", "250");
    const inherited = try support.spawnTjctlWithSplash(gpa, &.{
        support.tjctl,                                                       "--home", scratch.path(), "new", "inherited-title", "--no-splash", "--", "/bin/sh", "-c",
        "printf 'TITLE_OPTIONS=%s:%s\\n' \"$TJ_TITLE\" \"$TJ_TITLE_BLINK\"",
    }, 24, 80);
    var inherited_out: std.ArrayList(u8) = .empty;
    defer inherited_out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), try inherited.finish(gpa, &inherited_out, support.timeout_ms));
    try std.testing.expect(std.mem.indexOf(u8, inherited_out.items, "TITLE_OPTIONS=INHERITED:$TJ_REF:%1~:250") != null);

    const continued = try support.spawnTjctlWithSplash(gpa, &.{
        support.tjctl,                                                       "--home", scratch.path(), "use", "title-demo", "--no-replay", "--no-splash", "--", "/bin/sh", "-c",
        "printf 'TITLE_OPTIONS=%s:%s\\n' \"$TJ_TITLE\" \"$TJ_TITLE_BLINK\"",
    }, 24, 80);
    var continued_out: std.ArrayList(u8) = .empty;
    defer continued_out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), try continued.finish(gpa, &continued_out, support.timeout_ms));
    try std.testing.expect(std.mem.indexOf(u8, continued_out.items, "TITLE_OPTIONS=INHERITED:$TJ_REF:%1~:250") != null);

    const blinking = try support.spawnTjctlWithSplash(gpa, &.{
        support.tjctl, "--home", scratch.path(), "new", "blinking-title", "--no-splash", "--title-blink=20", "--", "/bin/sh", "-c", "sleep 0.08",
    }, 24, 80);
    var blinking_out: std.ArrayList(u8) = .empty;
    defer blinking_out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), try blinking.finish(gpa, &blinking_out, support.timeout_ms));
    try std.testing.expect(std.mem.indexOf(u8, blinking_out.items, "● blinking-title") != null);
    try std.testing.expect(std.mem.indexOf(u8, blinking_out.items, "○ blinking-title") != null);

    const static = try support.spawnTjctlWithSplash(gpa, &.{
        support.tjctl, "--home", scratch.path(), "new", "static-title", "--no-splash", "--title-blink=0", "--", "/bin/sh", "-c", "printf '\\033]2;application title\\007'",
    }, 24, 80);
    var static_out: std.ArrayList(u8) = .empty;
    defer static_out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), try static.finish(gpa, &static_out, support.timeout_ms));
    try std.testing.expect(std.mem.indexOf(u8, static_out.items, "\x1b]0;static-title\x1b\\") != null);
    try std.testing.expect(std.mem.indexOf(u8, static_out.items, "\x1b]2;application title\x07") != null);
    try std.testing.expect(std.mem.indexOf(u8, static_out.items, "●") == null);
    try std.testing.expect(std.mem.indexOf(u8, static_out.items, "○") == null);

    const plain = try support.spawnTjctlWithSplash(gpa, &.{
        support.tjctl,                                                                             "--home", scratch.path(), "new", "plain-title", "--no-splash", "--title", "none", "--", "/bin/sh", "-c",
        "printf 'TITLE_OPTIONS=%s:%s\\n\\033]2;untouched\\007' \"$TJ_TITLE\" \"$TJ_TITLE_BLINK\"",
    }, 24, 80);
    var plain_out: std.ArrayList(u8) = .empty;
    defer plain_out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), try plain.finish(gpa, &plain_out, support.timeout_ms));
    try std.testing.expect(std.mem.indexOf(u8, plain_out.items, "\x1b]2;untouched\x07") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain_out.items, "TJ | ") == null);
    try std.testing.expect(std.mem.indexOf(u8, plain_out.items, "\x1b[22;0t") == null);
    try std.testing.expect(std.mem.indexOf(u8, plain_out.items, "TITLE_OPTIONS=none:0") != null);
    support.sys.setEnv("TJ_TITLE", "TJ | %3~");
    support.sys.setEnv("TJ_TITLE_BLINK", "1500");
    support.sys.setEnv("TJ_NO_SPLASH", "false");
}
