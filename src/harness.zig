//! Test support: run a program under a pty we control, so tj can be exercised
//! the way a terminal emulator drives it.

const std = @import("std");
const posix = std.posix;
const c = std.c;
const sys = @import("sys.zig");

pub const PtyChild = struct {
    master: sys.Fd,
    pid: c.pid_t,

    pub fn write(self: PtyChild, bytes: []const u8) !void {
        try sys.writeAll(self.master, bytes);
    }

    pub fn resize(self: PtyChild, rows: u16, cols: u16) !void {
        const ws: posix.winsize = .{ .row = rows, .col = cols, .xpixel = 0, .ypixel = 0 };
        try sys.setWinsize(self.master, &ws);
        _ = c.kill(self.pid, posix.SIG.WINCH);
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
        var remaining = timeout_ms;
        var buf: [4096]u8 = undefined;
        while (remaining > 0) {
            if (std.mem.indexOf(u8, out.items, marker) != null) return true;
            var fds = [_]posix.pollfd{.{ .fd = self.master, .events = posix.POLL.IN, .revents = 0 }};
            const step: i32 = 100;
            const ready = posix.poll(&fds, step) catch return false;
            if (ready == 0) {
                remaining -= step;
                continue;
            }
            const n = sys.read(self.master, &buf) catch 0;
            if (n == 0) break;
            try out.appendSlice(gpa, buf[0..n]);
        }
        return std.mem.indexOf(u8, out.items, marker) != null;
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
        var remaining = timeout_ms;
        var buf: [4096]u8 = undefined;
        while (remaining > 0) {
            if (std.mem.indexOf(u8, out.items[from..], marker) != null) return true;
            var fds = [_]posix.pollfd{.{ .fd = self.master, .events = posix.POLL.IN, .revents = 0 }};
            const step: i32 = 100;
            const ready = posix.poll(&fds, step) catch return false;
            if (ready == 0) {
                remaining -= step;
                continue;
            }
            const n = sys.read(self.master, &buf) catch 0;
            if (n == 0) break;
            try out.appendSlice(gpa, buf[0..n]);
        }
        return std.mem.indexOf(u8, out.items[from..], marker) != null;
    }

    /// Drains to end of output, then reaps the child.
    pub fn finish(self: PtyChild, gpa: std.mem.Allocator, out: *std.ArrayList(u8), timeout_ms: i32) !u8 {
        var remaining = timeout_ms;
        var buf: [4096]u8 = undefined;
        while (remaining > 0) {
            var fds = [_]posix.pollfd{.{ .fd = self.master, .events = posix.POLL.IN, .revents = 0 }};
            const step: i32 = 100;
            const ready = posix.poll(&fds, step) catch break;
            if (ready == 0) {
                remaining -= step;
                continue;
            }
            const n = sys.read(self.master, &buf) catch 0;
            if (n == 0) break;
            try out.appendSlice(gpa, buf[0..n]);
        }
        sys.close(self.master);
        return sys.waitFor(self.pid).code;
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
