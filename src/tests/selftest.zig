//! Test-only helper. Runs a `tjctl` writer as a child and reports what happened to the
//! terminal settings it inherited: they must be raw while tj is running and
//! identical to the originals once it exits.
//!
//! This lives in its own binary because the check has to observe a tj process
//! from the outside while sharing its terminal.

const std = @import("std");
const posix = std.posix;
const c = std.c;
const sys = @import("sys");

const tjctl = std.fmt.comptimePrint("{s}", .{@import("build_options").tjctl_exe});

pub fn main(init: std.process.Init) !u8 {
    sys.initEnvironment(init.environ_map);
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 2 and std.mem.eql(u8, args[1], "pressure")) return pressure(init.io);

    const before = posix.tcgetattr(0) catch return 1;

    const argv = [_][]const u8{ tjctl, "new", "--no-splash", "--title", "none", "--", "/bin/sh", "-c", "sleep 1" };
    var executable = try sys.Exec.init(init.gpa, &argv, init.environ_map);
    defer executable.deinit();
    const pid = c.fork();
    if (pid < 0) return 1;
    if (pid == 0) {
        executable.exec();
        c._exit(127);
    }

    sys.sleepMs(init.io, 400);
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
    try std.Io.File.stdout().writeStreamingAll(init.io, msg);

    return if (raw and restored) 0 else 1;
}

const pressure_output_bytes = 1024 * 1024;
const pressure_input_bytes = 256 * 1024;

/// Produces enough output to fill a pty before consuming a large input. A
/// transparent proxy must drain and feed the two directions concurrently.
fn pressure(io: std.Io) !u8 {
    var raw = posix.tcgetattr(0) catch return 1;
    raw.iflag.IGNBRK = false;
    raw.iflag.BRKINT = false;
    raw.iflag.PARMRK = false;
    raw.iflag.ISTRIP = false;
    raw.iflag.INLCR = false;
    raw.iflag.IGNCR = false;
    raw.iflag.ICRNL = false;
    raw.iflag.IXON = false;
    raw.oflag.OPOST = false;
    raw.lflag.ECHO = false;
    raw.lflag.ECHONL = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;
    raw.cflag.PARENB = false;
    raw.cflag.CSIZE = .CS8;
    raw.cc[@intFromEnum(posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(posix.V.TIME)] = 0;
    posix.tcsetattr(0, .NOW, raw) catch return 1;

    try std.Io.File.stdout().writeStreamingAll(io, "PRESSURE-READY\n");
    var output: [16 * 1024]u8 = .{'O'} ** (16 * 1024);
    var remaining: usize = pressure_output_bytes;
    while (remaining > 0) {
        const n = @min(remaining, output.len);
        try std.Io.File.stdout().writeStreamingAll(io, output[0..n]);
        remaining -= n;
    }

    var input: [16 * 1024]u8 = undefined;
    var received: usize = 0;
    var valid = true;
    while (received < pressure_input_bytes) {
        const n = try sys.read(0, input[0..@min(input.len, pressure_input_bytes - received)]);
        if (n == 0) return 1;
        for (input[0..n]) |byte| valid = valid and byte == 'I';
        received += n;
    }

    var message: [64]u8 = undefined;
    const size = sys.getWinsize(0) catch return 1;
    const done = try std.fmt.bufPrint(&message, "\nPRESSURE-DONE {d} {d} {d}\n", .{ received, size.row, size.col });
    try std.Io.File.stdout().writeStreamingAll(io, done);
    return if (valid) 0 else 1;
}

/// PENDIN is transient line discipline state - the kernel raises it on any
/// switch back from raw mode, whoever performs it - so it says nothing about
/// whether the settings were restored.
fn settings(term: posix.termios) posix.termios {
    var normalized = term;
    normalized.lflag.PENDIN = false;
    return normalized;
}
