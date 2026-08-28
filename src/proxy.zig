//! The semantic PTY proxy.
//!
//!     terminal emulator
//!         |
//!        tj      <- allocates the pty, forwards both directions
//!         |
//!        zsh
//!
//! Input is forwarded byte for byte and never inspected. Output passes through
//! the scanner, which strips tj's own control sequences, reports command
//! boundaries, and hands the rest to both the terminal and the journal.

const std = @import("std");
const posix = std.posix;
const c = std.c;
const sys = @import("sys.zig");
const tty = @import("tty.zig");
const cli = @import("cli.zig");
const scanner = @import("scanner.zig");
const ulid = @import("ulid.zig");
const Store = @import("store.zig").Store;

const io_buf_size = 64 * 1024;

/// How often a running command's buffered output reaches the disk.
const flush_interval_ms = 200;

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

pub fn run(gpa: std.mem.Allocator, io: std.Io, opts: cli.Proxy) !Result {
    const argv = try buildArgv(gpa, opts.argv);

    // Panes and multiplexers make nesting legitimate. A new writer shadows
    // the outer journal environment; continuing it fails on the lock.
    if (sys.env("TJ_JOURNAL")) |outer| {
        warnStartup("tj: starting another journal writer inside {s}\r\n", .{outer});
    }

    // Lifecycle acquisition is strict: selection, numbering, and locking all
    // complete before a pty or child process exists.
    var store = switch (opts.journal) {
        .new => try Store.createJournal(gpa, io, opts.home),
        .existing => |selector| try Store.continueJournal(gpa, io, opts.home, selector),
    };
    defer store.close();

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
    exportEnvironment(&store);

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

    var recorder: Recorder = .{ .store = &store };
    var output: scanner.Scanner = .{ .keep_osc = opts.keep_osc };
    pump(pty.master, sig_fds[0], pid, &recorder, &output) catch {};
    // Nothing may stay withheld inside the scanner once the stream is over.
    output.flush(&recorder);

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

    // Become a POSIX session leader and adopt the pty as controlling terminal,
    // so job control, Ctrl-C and SIGWINCH all work inside the child.
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

/// Exported before the fork so the shell and its plugin inherit them.
fn exportEnvironment(store: *Store) void {
    var journal: [ulid.len + 1]u8 = undefined;
    @memcpy(journal[0..ulid.len], &store.journal);
    journal[ulid.len] = 0;
    sys.setEnv("TJ_JOURNAL", journal[0..ulid.len :0]);

    var next: [16]u8 = undefined;
    const next_text = std.fmt.bufPrint(next[0 .. next.len - 1], "{d}", .{store.next_number.?}) catch return;
    next[next_text.len] = 0;
    sys.setEnv("TJ_NEXT", next[0..next_text.len :0]);

    // Also when it came from --home: every `tj` invoked inside the writer has
    // to resolve references against the selected journal root.
    var root: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (store.root.realPath(store.io, root[0..std.fs.max_path_bytes])) |len| {
        root[len] = 0;
        sys.setEnv("TJ_HOME", root[0..len :0]);
    } else |_| {}

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var value_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path = sys.selfExePath(&path_buf) orelse return;
    if (path.len >= value_buf.len) return;
    @memcpy(value_buf[0..path.len], path);
    value_buf[path.len] = 0;
    sys.setEnv("TJ", value_buf[0..path.len :0]);
}

fn warnStartup(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
    sys.writeAll(stderr_fd, text) catch {};
}

/// Turns scanner events into journal entries and forwards every byte the
/// terminal is meant to see. This is the only place the two jobs meet.
const Recorder = struct {
    store: *Store,
    /// The command line arrives just before the "command is running" boundary,
    /// so it waits here until the interaction actually opens.
    command: [scanner.max_osc]u8 = undefined,
    command_len: usize = 0,
    /// Executable shell text after canonical TJ named-directory tokens were
    /// resolved to paths for metadata, when the integration reports any.
    expanded: [scanner.max_osc]u8 = undefined,
    expanded_len: usize = 0,
    has_expanded: bool = false,
    /// Set when the terminal can no longer be written to; the pump then stops.
    broken: bool = false,

    /// Bytes for the terminal that also belong in `out`.
    pub fn data(self: *Recorder, bytes: []const u8) void {
        self.forward(bytes);
        self.store.append(bytes);
    }

    /// Bytes for the terminal only: tj's own sequences under `--keep-osc`,
    /// which are protocol, not output.
    pub fn control(self: *Recorder, bytes: []const u8) void {
        self.forward(bytes);
    }

    fn forward(self: *Recorder, bytes: []const u8) void {
        sys.writeAll(stdout_fd, bytes) catch {
            self.broken = true;
        };
    }

    pub fn event(self: *Recorder, ev: scanner.Event) void {
        switch (ev) {
            .command_line => |line| {
                const n = @min(line.len, self.command.len);
                @memcpy(self.command[0..n], line[0..n]);
                self.command_len = n;
            },
            .command_expanded => |line| {
                const n = @min(line.len, self.expanded.len);
                @memcpy(self.expanded[0..n], line[0..n]);
                self.expanded_len = n;
                self.has_expanded = true;
            },
            .command_run => {
                self.store.begin(
                    self.command[0..self.command_len],
                    if (self.has_expanded) self.expanded[0..self.expanded_len] else null,
                );
                self.command_len = 0;
                self.expanded_len = 0;
                self.has_expanded = false;
            },
            .command_end => |code| self.store.finish(code),
            // Ends whatever is still open; a no-op right after `command_end`,
            // which is the usual case since the shell reports both at once.
            .prompt_start => self.store.finish(null),
            .resource_begin => |r| self.store.beginResource(r.path, r.mime),
            .resource_end => self.store.endResource(),
            .protocol_error => |payload| self.store.warn("ignored tj sequence: {s}", .{payload}),
        }
    }
};

fn pump(master: sys.Fd, sig_r: sys.Fd, pid: c.pid_t, recorder: *Recorder, output: *scanner.Scanner) !void {
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
        // While a command is running, wake up regularly to flush its output to
        // disk, so `tail -f` on `@N/out` shows progress.
        const recording = recorder.store.isRecording();
        _ = posix.poll(&fds, if (recording) flush_interval_ms else -1) catch return;

        if (sig.revents & (posix.POLL.IN | posix.POLL.HUP) != 0) {
            try drainSignals(sig_r, master, pid);
        }

        if (out.revents & (posix.POLL.IN | posix.POLL.HUP) != 0) {
            const n = sys.read(master, &out_buf) catch return;
            if (n == 0) return;
            output.feed(out_buf[0..n], recorder);
            if (recorder.broken) return;
        } else {
            recorder.store.tick();
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
