//! The semantic PTY proxy.
//!
//!     terminal emulator
//!         |
//!        tj      <- allocates the pty, forwards both directions
//!         |
//!        zsh
//!
//! The proxy is currently purely transparent: bytes are copied in both
//! directions unchanged. Recording, OSC 5107 extraction and command boundary
//! detection hook into the output path later, which is why output already
//! flows through a single choke point in `pumpOutput`.

const std = @import("std");
const posix = std.posix;
const c = std.c;
const sys = @import("sys.zig");
const tty = @import("tty.zig");
const cli = @import("cli.zig");

const io_buf_size = 64 * 1024;

const stdin_fd: sys.Fd = 0;
const stdout_fd: sys.Fd = 1;
const stderr_fd: sys.Fd = 2;

/// Write end of the self-pipe, read by the poll loop. Signal handlers may only
/// touch async-signal-safe state, so this is the one thing they write to.
var sig_pipe_w: std.atomic.Value(c_int) = .init(-1);

/// The terminal settings to put back if the process dies unexpectedly.
var panic_restore: ?tty.Saved = null;

const forwarded_signals = [_]posix.SIG{ .TERM, .HUP, .INT, .QUIT };

fn onSignal(sig: posix.SIG) callconv(.c) void {
    const saved_errno = c._errno().*;
    const w = sig_pipe_w.load(.monotonic);
    if (w >= 0) {
        const byte = [1]u8{@truncate(@intFromEnum(sig))};
        _ = c.write(w, &byte, 1);
    }
    c._errno().* = saved_errno;
}

/// Restores the terminal from a panic handler. Zig does not run deferred code
/// on panic, so without this a crash would leave the user in raw mode.
pub fn restoreOnPanic() void {
    if (panic_restore) |saved| tty.restore(saved);
}

pub const Result = struct { exit_code: u8 };

pub fn run(gpa: std.mem.Allocator, opts: cli.Proxy) !Result {
    const argv = try buildArgv(gpa, opts.argv);

    // Seed the inner pty with the outer terminal's settings so programs that
    // query them (line width, control characters) see the truth from the start.
    // With a redirected stdin there is no outer terminal to copy or restore;
    // the proxy still runs, the pty just starts with the system defaults.
    const on_tty = sys.isTty(stdin_fd);
    var outer_term: posix.termios = undefined;
    var outer_ws: posix.winsize = undefined;
    const have_term = on_tty and blk: {
        outer_term = posix.tcgetattr(stdin_fd) catch break :blk false;
        break :blk true;
    };
    const have_ws = on_tty and blk: {
        outer_ws = sys.getWinsize(stdin_fd) catch break :blk false;
        break :blk true;
    };

    const pty = try sys.openPty(
        if (have_term) &outer_term else null,
        if (have_ws) &outer_ws else null,
    );

    const sig_fds = try sys.selfPipe();
    sig_pipe_w.store(sig_fds[1], .monotonic);

    installSignalHandlers();
    exportEnvironment();

    const pid = c.fork();
    if (pid < 0) {
        sys.close(pty.master);
        sys.close(pty.slave);
        return error.ForkFailed;
    }
    if (pid == 0) childExec(pty, argv);

    sys.close(pty.slave);

    var raw: ?tty.Saved = null;
    if (have_term) {
        raw = tty.enterRaw(stdin_fd) catch null;
        panic_restore = raw;
    }
    defer {
        panic_restore = null;
        if (raw) |saved| tty.restore(saved);
    }

    pump(pty.master, sig_fds[0], pid) catch {};

    sys.close(pty.master);
    sys.close(sig_fds[0]);
    sig_pipe_w.store(-1, .monotonic);
    sys.close(sig_fds[1]);

    return .{ .exit_code = sys.waitFor(pid).code };
}

/// Resolves the command to run: what the user asked for, else their shell.
fn buildArgv(gpa: std.mem.Allocator, requested: []const []const u8) ![:null]const ?[*:0]const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    defer words.deinit(gpa);

    if (requested.len > 0) {
        try words.appendSlice(gpa, requested);
    } else {
        try words.append(gpa, sys.env("SHELL") orelse "/bin/zsh");
    }

    const argv = try gpa.allocSentinel(?[*:0]const u8, words.items.len, null);
    for (words.items, 0..) |word, i| argv[i] = try gpa.dupeZ(u8, word);
    return argv;
}

/// Everything here runs between fork and exec, so it stays within the set of
/// calls that are safe in a forked child.
fn childExec(pty: sys.Pty, argv: [:null]const ?[*:0]const u8) noreturn {
    sys.close(pty.master);

    // Become a session leader and adopt the pty as controlling terminal, so
    // job control, Ctrl-C and SIGWINCH all work inside the session.
    _ = c.setsid();
    sys.setControllingTty(pty.slave) catch {};

    _ = c.dup2(pty.slave, stdin_fd);
    _ = c.dup2(pty.slave, stdout_fd);
    _ = c.dup2(pty.slave, stderr_fd);
    if (pty.slave > stderr_fd) sys.close(pty.slave);

    // exec resets handled signals on its own, but an ignored disposition
    // survives it, and a shell that inherits SIGPIPE ignored misbehaves.
    resetSignal(.PIPE);

    _ = sys.execvp(argv[0].?, argv.ptr);

    const name = std.mem.span(argv[0].?);
    _ = c.write(stderr_fd, "tj: cannot execute ", 19);
    _ = c.write(stderr_fd, name.ptr, name.len);
    _ = c.write(stderr_fd, "\r\n", 2);
    c._exit(127);
}

fn resetSignal(sig: posix.SIG) void {
    const act: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.DFL },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(sig, &act, null);
}

fn installSignalHandlers() void {
    const act: posix.Sigaction = .{
        .handler = .{ .handler = onSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(.WINCH, &act, null);
    for (forwarded_signals) |sig| posix.sigaction(sig, &act, null);

    // A dead pty must surface as a write error in the pump loop, not as a
    // sudden death that skips terminal restoration.
    const ignore: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(.PIPE, &ignore, null);
}

fn exportEnvironment() void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var value_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path = sys.selfExePath(&path_buf) orelse return;
    if (path.len >= value_buf.len) return;
    @memcpy(value_buf[0..path.len], path);
    value_buf[path.len] = 0;
    sys.setEnv("TJ", value_buf[0..path.len :0]);
}

fn pump(master: sys.Fd, sig_r: sys.Fd, pid: c.pid_t) !void {
    var in_buf: [io_buf_size]u8 = undefined;
    var out_buf: [io_buf_size]u8 = undefined;

    var fds = [_]posix.pollfd{
        .{ .fd = stdin_fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = master, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = sig_r, .events = posix.POLL.IN, .revents = 0 },
    };
    const in = &fds[0];
    const out = &fds[1];
    const sig = &fds[2];

    while (true) {
        _ = posix.poll(&fds, -1) catch return;

        if (sig.revents & (posix.POLL.IN | posix.POLL.HUP) != 0) {
            try drainSignals(sig_r, master, pid);
        }

        if (out.revents & (posix.POLL.IN | posix.POLL.HUP) != 0) {
            const n = sys.read(master, &out_buf) catch return;
            if (n == 0) return;
            try pumpOutput(out_buf[0..n]);
        }

        if (in.fd >= 0 and in.revents & (posix.POLL.IN | posix.POLL.HUP) != 0) {
            const n = sys.read(stdin_fd, &in_buf) catch 0;
            if (n == 0) {
                // The user's input ended, but the child may still be talking.
                in.fd = -1;
            } else {
                sys.writeAll(master, in_buf[0..n]) catch return;
            }
        }

        if (in.fd >= 0 and in.revents & (posix.POLL.ERR | posix.POLL.NVAL) != 0) in.fd = -1;
        if (out.revents & (posix.POLL.ERR | posix.POLL.NVAL) != 0) return;
    }
}

/// The single choke point for shell-to-terminal bytes. The recording scanner
/// goes here; today it forwards verbatim.
fn pumpOutput(bytes: []const u8) !void {
    try sys.writeAll(stdout_fd, bytes);
}

fn drainSignals(sig_r: sys.Fd, master: sys.Fd, pid: c.pid_t) !void {
    var buf: [64]u8 = undefined;
    const n = sys.read(sig_r, &buf) catch return;
    for (buf[0..n]) |raw| {
        const sig: posix.SIG = @enumFromInt(raw);
        if (sig == .WINCH) {
            const ws = sys.getWinsize(stdin_fd) catch continue;
            sys.setWinsize(master, &ws) catch {};
        } else {
            sys.killGroup(pid, sig);
        }
    }
}
