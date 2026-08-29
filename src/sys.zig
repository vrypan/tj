//! The system calls the proxy needs.
//!
//! Everything that Zig 0.16's `std.posix` provides is used from there. What is
//! left - process control, ioctl, and the pty grant/unlock dance - has no std
//! equivalent in this release, so it is declared against libc directly. Only
//! plain libc symbols are used, no libutil or other add-on library, which keeps
//! `zig build -Dtarget=...` working for every supported target with nothing
//! installed on the host.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;

pub const Fd = c.fd_t;

// --- declarations std does not provide at all ------------------------------
//
// Everything else in this file goes through std.posix or std.c. These six have
// no declaration anywhere in std, as of 0.17-dev: the pty allocation sequence,
// PATH-searching exec, and setenv.

extern "c" fn posix_openpt(oflag: c_int) c_int;
extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname(fd: c_int) ?[*:0]const u8;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

pub extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

/// std.posix.T only carries the terminal ioctl numbers on some targets, so the
/// ones tj needs are spelled out here.
pub const Ioctl = switch (builtin.os.tag) {
    .linux => struct {
        pub const GWINSZ = posix.T.IOCGWINSZ;
        pub const SWINSZ = posix.T.IOCSWINSZ;
        pub const SCTTY = posix.T.IOCSCTTY;
    },
    .macos, .ios, .tvos, .watchos, .visionos => struct {
        pub const GWINSZ = 0x40087468;
        pub const SWINSZ = 0x80087467;
        pub const SCTTY = 0x20007461;
    },
    else => @compileError("tj supports macOS and Linux"),
};

/// ioctl request numbers are unsigned constants that do not always fit in the
/// signed c_int the variadic prototype takes.
pub fn request(comptime value: comptime_int) c_int {
    return @bitCast(@as(u32, value));
}

pub const Error = error{Syscall};

// --- terminals -------------------------------------------------------------

pub const Pty = struct {
    master: Fd,
    slave: Fd,
};

/// Allocates a pty pair, seeding the slave with the given terminal settings and
/// window size so the child starts out matching the outer terminal.
pub fn openPty(term: ?*const posix.termios, size: ?*const posix.winsize) Error!Pty {
    const flags: posix.O = .{ .ACCMODE = .RDWR, .NOCTTY = true };
    const master = posix_openpt(@bitCast(@as(u32, @bitCast(flags))));
    if (master < 0) return error.Syscall;
    errdefer close(master);

    if (grantpt(master) != 0) return error.Syscall;
    if (unlockpt(master) != 0) return error.Syscall;
    const name = ptsname(master) orelse return error.Syscall;

    const slave = posix.openatZ(posix.AT.FDCWD, name, flags, 0) catch return error.Syscall;
    errdefer close(slave);

    if (term) |t| posix.tcsetattr(slave, .NOW, t.*) catch {};
    if (size) |ws| try setWinsize(slave, ws);

    return .{ .master = master, .slave = slave };
}

pub fn getWinsize(fd: Fd) Error!posix.winsize {
    var ws: posix.winsize = undefined;
    if (c.ioctl(fd, request(Ioctl.GWINSZ), &ws) != 0) return error.Syscall;
    return ws;
}

pub fn setWinsize(fd: Fd, ws: *const posix.winsize) Error!void {
    if (c.ioctl(fd, request(Ioctl.SWINSZ), ws) != 0) return error.Syscall;
}

pub fn setControllingTty(fd: Fd) Error!void {
    if (c.ioctl(fd, request(Ioctl.SCTTY), @as(c_int, 0)) != 0) return error.Syscall;
}

/// Asked before any terminal query, because std's tcgetattr treats ENOTTY as
/// an unexpected error and dumps a stack trace for it in debug builds.
pub fn isTty(fd: Fd) bool {
    return c.isatty(fd) == 1;
}

// --- descriptors -----------------------------------------------------------

/// A pipe a signal handler can write to in order to wake the poll loop. Both
/// ends are non-blocking, because a handler that blocked on a full pipe would
/// deadlock the process it is meant to be steering, and close-on-exec, so they
/// never reach the shell.
pub fn selfPipe() Error![2]Fd {
    var fds: [2]c_int = undefined;
    if (c.pipe(&fds) != 0) return error.Syscall;
    for (fds) |fd| {
        const flags = c.fcntl(fd, posix.F.GETFL, @as(c_int, 0));
        if (flags < 0 or
            c.fcntl(fd, posix.F.SETFL, flags | O_NONBLOCK) < 0 or
            c.fcntl(fd, posix.F.SETFD, FD_CLOEXEC) < 0)
        {
            close(fds[0]);
            close(fds[1]);
            return error.Syscall;
        }
    }
    return .{ fds[0], fds[1] };
}

const O_NONBLOCK: c_int = @bitCast(@as(u32, @bitCast(posix.O{ .NONBLOCK = true })));
const FD_CLOEXEC: c_int = 1;

pub fn close(fd: Fd) void {
    _ = c.close(fd);
}

/// Returns 0 at end of stream. EIO on a pty master means the slave side is
/// gone, which is the same thing as far as the proxy is concerned.
pub fn read(fd: Fd, buf: []u8) Error!usize {
    return posix.read(fd, buf) catch |err| switch (err) {
        error.InputOutput => 0,
        else => error.Syscall,
    };
}

/// Writes the whole slice, retrying on interruption and short writes.
pub fn writeAll(fd: Fd, buf: []const u8) Error!void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = c.write(fd, buf.ptr + off, buf.len - off);
        if (n > 0) {
            off += @intCast(n);
            continue;
        }
        if (n == 0) return error.Syscall;
        switch (posix.errno(n)) {
            .INTR => continue,
            else => return error.Syscall,
        }
    }
}

// --- processes -------------------------------------------------------------

pub const Wait = struct {
    /// Command exit status, or 128+signal when it died from a signal, matching
    /// the convention shells themselves use for `$?`.
    code: u8,
};

pub fn waitFor(pid: c.pid_t) Wait {
    var status: c_int = 0;
    while (true) {
        const r = c.waitpid(pid, &status, 0);
        if (r < 0) {
            if (posix.errno(r) == .INTR) continue;
            return .{ .code = 1 };
        }
        break;
    }
    const raw: u32 = @bitCast(status);
    if (raw & 0x7f == 0) return .{ .code = @truncate((raw >> 8) & 0xff) };
    const sig: u8 = @truncate(raw & 0x7f);
    return .{ .code = 128 +| sig };
}

pub fn killGroup(pid: c.pid_t, sig: posix.SIG) void {
    posix.kill(-pid, sig) catch {};
}

pub fn sleepMs(ms: u64) void {
    var req: c.timespec = .{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    var rem: c.timespec = undefined;
    while (c.nanosleep(&req, &rem) != 0) {
        if (posix.errno(@as(c_int, -1)) != .INTR) return;
        req = rem;
    }
}

// --- environment -----------------------------------------------------------

pub fn env(name: [*:0]const u8) ?[]const u8 {
    const value = c.getenv(name) orelse return null;
    const slice = std.mem.span(value);
    return if (slice.len == 0) null else slice;
}

/// Unlike `env`, this distinguishes an empty value from an unset variable.
/// NO_COLOR uses presence, not contents, as its opt-out signal.
pub fn envPresent(name: [*:0]const u8) bool {
    return c.getenv(name) != null;
}

pub fn setEnv(name: [*:0]const u8, value: [*:0]const u8) void {
    _ = setenv(name, value, 1);
}

/// Absolute path of the running binary, so the shell plugin can invoke exactly
/// the build that started the journal writer.
pub fn selfExePath(buf: []u8) ?[]const u8 {
    switch (builtin.os.tag) {
        .linux => {
            const n = c.readlink("/proc/self/exe", buf.ptr, buf.len);
            if (n <= 0 or @as(usize, @intCast(n)) >= buf.len) return null;
            return buf[0..@intCast(n)];
        },
        else => {
            var size: u32 = @intCast(buf.len);
            if (c._NSGetExecutablePath(buf.ptr, &size) != 0) return null;
            return std.mem.sliceTo(buf, 0);
        },
    }
}
