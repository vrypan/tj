//! Test-only helper. Runs `tj` as a child and reports what happened to the
//! terminal settings it inherited: they must be raw while tj is running and
//! identical to the originals once it exits.
//!
//! This lives in its own binary because the check has to observe a tj process
//! from the outside while sharing its terminal.

const std = @import("std");
const posix = std.posix;
const c = std.c;
const sys = @import("sys.zig");

const tj = std.fmt.comptimePrint("{s}", .{@import("build_options").tj_exe});

pub fn main(init: std.process.Init) !u8 {
    _ = init;

    const before = posix.tcgetattr(0) catch return 1;

    const argv = [_:null]?[*:0]const u8{ tj, "new", "--", "/bin/sh", "-c", "sleep 1" };
    const pid = c.fork();
    if (pid < 0) return 1;
    if (pid == 0) {
        _ = sys.execvp(argv[0].?, &argv);
        c._exit(127);
    }

    sys.sleepMs(400);
    const during = posix.tcgetattr(0) catch return 1;
    const raw = !during.lflag.ICANON and !during.lflag.ECHO;

    _ = sys.waitFor(pid);
    const after = posix.tcgetattr(0) catch return 1;
    const restored = std.meta.eql(settings(before), settings(after));

    var buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "RAW={s} RESTORED={s}\n", .{
        if (raw) "yes" else "no",
        if (restored) "yes" else "no",
    }) catch return 1;
    _ = c.write(1, msg.ptr, msg.len);

    return if (raw and restored) 0 else 1;
}

/// PENDIN is transient line discipline state - the kernel raises it on any
/// switch back from raw mode, whoever performs it - so it says nothing about
/// whether the settings were restored.
fn settings(term: posix.termios) posix.termios {
    var normalized = term;
    normalized.lflag.PENDIN = false;
    return normalized;
}
