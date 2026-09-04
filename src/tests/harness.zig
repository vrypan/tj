//! Test support: run a program under a pty we control, so tj can be exercised
//! the way a terminal emulator drives it.

const std = @import("std");
const posix = std.posix;
const c = std.c;
const sys = @import("../sys.zig");

pub const Deadline = struct {
    expires_ms: i64,

    pub fn init(timeout_ms: i32) !Deadline {
        return .{
            .expires_ms = try monotonicMillis() +
                @as(i64, @intCast(@max(timeout_ms, 0))),
        };
    }

    /// Returns the next bounded poll interval, or null once time is up.
    pub fn pollInterval(self: Deadline, maximum_ms: i32) !?i32 {
        const remaining = self.expires_ms - try monotonicMillis();
        if (remaining <= 0) return null;
        return @intCast(@min(remaining, maximum_ms));
    }
};

fn monotonicMillis() !i64 {
    var now: c.timespec = undefined;
    if (c.clock_gettime(.MONOTONIC, &now) != 0) return error.ClockFailed;
    return @as(i64, @intCast(now.sec)) * std.time.ms_per_s +
        @divTrunc(@as(i64, @intCast(now.nsec)), std.time.ns_per_ms);
}

pub const PtyChild = struct {
    master: sys.Fd,
    pid: c.pid_t,

    pub fn write(self: PtyChild, bytes: []const u8) !void {
        try sys.writeAll(self.master, bytes);
    }

    pub fn resize(self: PtyChild, rows: u16, cols: u16) !void {
        const ws: posix.winsize = .{ .row = rows, .col = cols, .xpixel = 0, .ypixel = 0 };
        try sys.setWinsize(self.master, &ws);
        posix.kill(self.pid, posix.SIG.WINCH) catch {};
    }

    /// Reads until `marker` appears or the deadline passes. Returns everything
    /// read so far either way, so callers can assert on partial output.
    pub fn readUntil(
        self: PtyChild,
        gpa: std.mem.Allocator,
        out: *std.ArrayList(u8),
        marker: []const u8,
        timeout_ms: i32,
    ) !bool {
        return self.readUntilFrom(gpa, out, 0, marker, timeout_ms);
    }

    /// Like readUntil, but only accepts a marker received after `from`.
    /// This makes a prompt already in the transcript unable to acknowledge a
    /// command that was written later.
    pub fn readUntilFrom(
        self: PtyChild,
        gpa: std.mem.Allocator,
        out: *std.ArrayList(u8),
        from: usize,
        marker: []const u8,
        timeout_ms: i32,
    ) !bool {
        const deadline = try Deadline.init(timeout_ms);
        var buf: [4096]u8 = undefined;
        while (true) {
            if (std.mem.indexOf(u8, out.items[from..], marker) != null) return true;
            const interval = try deadline.pollInterval(100) orelse break;
            var fds = [_]posix.pollfd{.{ .fd = self.master, .events = posix.POLL.IN, .revents = 0 }};
            const ready = try posix.poll(&fds, interval);
            if (ready == 0) continue;
            const n = try sys.read(self.master, &buf);
            if (n == 0) break;
            try out.appendSlice(gpa, buf[0..n]);
        }
        return std.mem.indexOf(u8, out.items[from..], marker) != null;
    }

    /// Drains to end of output, then reaps the child.
    pub fn finish(self: PtyChild, gpa: std.mem.Allocator, out: *std.ArrayList(u8), timeout_ms: i32) !u8 {
        const drain_deadline = try Deadline.init(timeout_ms);
        var closed = false;
        var reaped = false;
        errdefer {
            if (!closed) sys.close(self.master);
            if (!reaped) self.killAndReap();
        }

        var buf: [4096]u8 = undefined;
        while (true) {
            const interval = try drain_deadline.pollInterval(100) orelse break;
            var fds = [_]posix.pollfd{.{ .fd = self.master, .events = posix.POLL.IN, .revents = 0 }};
            const ready = try posix.poll(&fds, interval);
            if (ready == 0) continue;
            const n = try sys.read(self.master, &buf);
            if (n == 0) break;
            try out.appendSlice(gpa, buf[0..n]);
        }
        sys.close(self.master);
        closed = true;

        // Closing the terminal is part of the fixture's normal shutdown. It
        // also gives a process group which left the slave open (for example an
        // interrupted shell command) a chance to react to the hangup.
        const reap_deadline = try Deadline.init(timeout_ms);
        while (true) {
            if (sys.tryWaitFor(self.pid)) |wait| {
                reaped = true;
                return wait.code;
            }
            const interval = try reap_deadline.pollInterval(10) orelse return error.PtyTimeout;
            sys.sleepMs(std.testing.io, @intCast(interval));
        }
    }

    pub fn killAndReap(self: PtyChild) void {
        sys.killGroup(self.pid, .KILL);
        posix.kill(self.pid, .KILL) catch {};
        _ = sys.waitFor(self.pid);
    }
};

pub fn spawn(gpa: std.mem.Allocator, argv: []const []const u8, rows: u16, cols: u16) !PtyChild {
    // Keep the owning slices around rather than recovering their lengths from
    // the C pointers later: an argument containing a NUL would then be freed
    // at the wrong length.
    const owned = try gpa.alloc([:0]u8, argv.len);
    const cargv = try gpa.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, 0..) |word, i| {
        owned[i] = try gpa.dupeZ(u8, word);
        cargv[i] = owned[i].ptr;
    }

    const ws: posix.winsize = .{ .row = rows, .col = cols, .xpixel = 0, .ypixel = 0 };
    const pty = try sys.openPty(null, &ws);

    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        // The child got its own copy of cargv at fork; the parent frees below.
        sys.close(pty.master);
        _ = c.setsid();
        sys.setControllingTty(pty.slave) catch {};
        _ = c.dup2(pty.slave, 0);
        _ = c.dup2(pty.slave, 1);
        _ = c.dup2(pty.slave, 2);
        if (pty.slave > 2) sys.close(pty.slave);
        _ = sys.execvp(cargv[0].?, cargv.ptr);
        c._exit(127);
    }

    sys.close(pty.slave);
    for (owned) |word| gpa.free(word);
    gpa.free(owned);
    gpa.free(cargv);
    return .{ .master = pty.master, .pid = pid };
}
