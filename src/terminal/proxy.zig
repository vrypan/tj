//! The semantic PTY proxy.
//!
//!     terminal emulator
//!         |
//!        tj      <- allocates the pty, forwards both directions
//!         |
//!        interactive shell
//!
//! Input is forwarded byte for byte and never inspected. Output passes through
//! the scanner, which strips tj's own control sequences, reports command
//! boundaries, and hands the rest to both the terminal and the journal.

const std = @import("std");
const posix = std.posix;
const c = std.c;
const sys = @import("../sys.zig");
const tty = @import("tty.zig");
const scanner = @import("../protocol/scanner.zig");
const journal_store = @import("../journal/store.zig");
const Store = journal_store.Store;
const replay = @import("replay.zig");
const splash = @import("splash.zig");
const terminal_title = @import("title.zig");
const handoff = @import("../protocol/handoff.zig");
const report = @import("../presentation/report.zig");

const io_buf_size = 64 * 1024;
const pending_input_capacity = 64 * 1024;
const max_protocol_error_log_bytes = 384;

/// How often a running command's buffered output reaches the disk.
const flush_interval_ms = 200;
const nothing_recorded_message = "tjctl: nothing was recorded - is a TJ shell plugin loaded?";

const stdin_fd: sys.Fd = 0;
const stdout_fd: sys.Fd = 1;
const stderr_fd: sys.Fd = 2;

const FlushSchedule = struct {
    deadline_ms: ?i64 = null,

    fn timeout(self: *FlushSchedule, recording: bool, now_ms: i64) c_int {
        if (!recording) {
            self.deadline_ms = null;
            return -1;
        }
        if (self.deadline_ms == null) self.deadline_ms = now_ms + flush_interval_ms;
        const remaining = @max(self.deadline_ms.? - now_ms, 0);
        return @intCast(@min(remaining, std.math.maxInt(c_int)));
    }

    fn consume(self: *FlushSchedule, recording: bool, now_ms: i64) bool {
        if (!recording) {
            self.deadline_ms = null;
            return false;
        }
        if (self.deadline_ms == null) {
            self.deadline_ms = now_ms + flush_interval_ms;
            return false;
        }
        if (now_ms < self.deadline_ms.?) return false;
        self.deadline_ms = now_ms + flush_interval_ms;
        return true;
    }
};

/// A fixed-capacity queue between the outer terminal and the child pty. The
/// pump stops polling stdin while this is full, applying backpressure without
/// ever blocking the output and signal paths on a master write.
const PendingInput = struct {
    bytes: [pending_input_capacity]u8 = undefined,
    start: usize = 0,
    len: usize = 0,

    fn isEmpty(self: *const PendingInput) bool {
        return self.len == 0;
    }

    fn isFull(self: *const PendingInput) bool {
        return self.len == self.bytes.len;
    }

    fn pending(self: *const PendingInput) []const u8 {
        return self.bytes[self.start .. self.start + @min(self.len, self.bytes.len - self.start)];
    }

    fn writable(self: *PendingInput) []u8 {
        if (self.isFull()) return self.bytes[0..0];
        const end = (self.start + self.len) % self.bytes.len;
        const available = if (end < self.start)
            self.start - end
        else
            self.bytes.len - end;
        return self.bytes[end .. end + available];
    }

    fn commit(self: *PendingInput, count: usize) void {
        std.debug.assert(count <= self.bytes.len - self.len);
        self.len += count;
    }

    fn consume(self: *PendingInput, count: usize) void {
        std.debug.assert(count <= self.len);
        self.start = (self.start + count) % self.bytes.len;
        self.len -= count;
        if (self.len == 0) self.start = 0;
    }
};

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
    terminal_title.restoreFromSignal(stdout_fd);
    if (panic_restore) |saved| tty.restore(saved);
}

pub const Result = struct {
    exit_code: u8,
};

pub const JournalSelection = union(enum) {
    new: ?[]const u8,
    existing: []const u8,
};

pub const Options = struct {
    journal: JournalSelection,
    argv: []const []const u8 = &.{},
    keep_osc: bool = false,
    replay_before_start: bool = false,
    splash: bool = false,
    title: []const u8 = "none",
    home: ?[]const u8 = null,
    temporary: bool = false,
    out_limit_bytes: u64 = journal_store.default_out_limit,
};

pub fn run(gpa: std.mem.Allocator, io: std.Io, opts: Options) !Result {
    // Lifecycle acquisition is strict: selection, numbering, and locking all
    // complete before a pty or child process exists.
    var store = switch (opts.journal) {
        .new => |name| try Store.createNamedJournal(gpa, io, opts.home, name, opts.temporary),
        .existing => |selector| try Store.continueJournal(gpa, io, opts.home, selector),
    };
    store.setOutputLimit(opts.out_limit_bytes);
    defer {
        const saved_temporary = store.saved_temporary;
        const journal = store.journalId();
        if (saved_temporary) warnStartup(io, "tjctl: saved journal {s}\n", .{journal});
        store.close();
    }

    const title_enabled = !std.mem.eql(u8, opts.title, "none") and sys.isTty(io, stdout_fd);
    defer if (title_enabled) terminal_title.pop(io, stdout_fd);

    // Confirm the selected journal before the fresh child takes ownership of
    // the terminal. Zooi restores the exact screen contents on exit, after
    // which a continuation reconstructs its transcript without hiding any of
    // it behind the splash. Redirected and otherwise non-interactive starts
    // never wait for input.
    if (opts.splash and sys.isTty(io, stdin_fd)) {
        const choice = splash.show(gpa, store.journalId(), store.next_number.?) catch blk: {
            warnStartup(io, "tjctl: recording journal {s}; next entry @{d}\r\n", .{ store.journalId(), store.next_number.? });
            break :blk splash.Choice.proceed;
        };
        if (choice == .cancel) return error.StartupCancelled;
    }

    // Continuation reconstructs the journal's visible transcript after the
    // splash and before a fresh child starts. Write directly to the outer
    // terminal so replayed shell-integration sequences never pass through this
    // writer's scanner.
    if (opts.replay_before_start) {
        var root = try journal_store.openRoot(io, opts.home);
        defer root.close(io);
        var stdout_buffer: [io_buf_size]u8 = undefined;
        var stdout_file: std.Io.File.Writer = .initStreaming(.stdout(), io, &stdout_buffer);
        try replay.play(gpa, io, root, store.journalId(), .{
            .typing_ms = 0,
            .max_pause_ms = 0,
        }, &stdout_file.interface);
        try stdout_file.interface.flush();
    }
    // Seed the inner pty with the outer terminal's settings so programs that
    // query them (line width, control characters) see the truth from the start.
    // With a redirected stdin there is no outer terminal to copy or restore;
    // the proxy still runs, the pty just starts with the system defaults.
    const on_tty = sys.isTty(io, stdin_fd);
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
        io,
        if (have_term) &outer_term else null,
        if (have_ws) &outer_ws else null,
    );
    errdefer {
        sys.close(io, pty.master);
        sys.close(io, pty.slave);
    }
    // The slave retains ordinary blocking semantics. Only the proxy's master
    // is nonblocking, so its single pump can keep servicing both directions.
    try sys.setNonBlocking(pty.master, true);

    const sig_fds = try sys.selfPipe(io);
    errdefer {
        sig_pipe_w.store(-1, .monotonic);
        sys.close(io, sig_fds[0]);
        sys.close(io, sig_fds[1]);
    }
    const handoff_fds = try sys.socketPair();
    errdefer {
        sys.close(io, handoff_fds[0]);
        sys.close(io, handoff_fds[1]);
    }
    sig_pipe_w.store(sig_fds[1], .monotonic);

    installSignalHandlers();
    // Activate only after fatal signals are under proxy control. Unsupported
    // terminals harmlessly ignore the xterm title-stack request.
    if (title_enabled) {
        terminal_title.push(io, stdout_fd);
        terminal_title.writeInitialTitle(io, stdout_fd, store.journalId());
    }
    // A fresh random token per writer, exported so `tjctl` inside the session
    // can authenticate SAVE and HANDOFF requests. Untrusted bytes that merely
    // pass through the terminal - a hostile file, a compromised ssh peer -
    // never learn it, so they cannot steer the proxy's own control protocol.
    const session_token = generateSessionToken(io);
    var child_environment = try sys.environMap().clone(gpa);
    defer child_environment.deinit();
    try exportEnvironment(&child_environment, &store, opts.title, opts.out_limit_bytes, handoff_fds[1], &session_token);
    const default_argv = [_][]const u8{sys.env("SHELL") orelse "/bin/zsh"};
    var executable = try sys.Exec.init(gpa, if (opts.argv.len == 0) &default_argv else opts.argv, &child_environment);
    defer executable.deinit();

    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) childExec(pty, &executable);

    sys.close(io, pty.slave);
    sys.close(io, handoff_fds[1]);

    var raw: ?tty.Saved = null;
    if (have_term) {
        raw = tty.enterRaw(stdin_fd) catch null;
        panic_restore = raw;
    }
    defer {
        panic_restore = null;
        if (raw) |saved| tty.restore(saved);
    }

    var recorder: Recorder = .{
        .store = &store,
        .title_enabled = title_enabled,
        .handoff_reply_fd = handoff_fds[0],
        .session_token = &session_token,
    };
    var output: scanner.Scanner = .{ .keep_osc = opts.keep_osc };
    pump(gpa, io, opts.home, pty.master, sig_fds[0], pid, &recorder, &output) catch {};
    // Nothing may stay withheld inside the scanner once the stream is over.
    output.flush(&recorder);

    sys.close(io, pty.master);
    sys.close(io, sig_fds[0]);
    sig_pipe_w.store(-1, .monotonic);
    sys.close(io, sig_fds[1]);
    sys.close(io, handoff_fds[0]);

    const child_result = sys.waitFor(pid);
    if (!store.hasRecordedEntry()) warnNothingRecorded(io);
    return .{ .exit_code = child_result.code };
}

/// Everything here runs between fork and exec, so it stays within the set of
/// calls that are safe in a forked child.
fn childExec(pty: sys.Pty, executable: *sys.Exec) noreturn {
    _ = c.close(pty.master);

    // Become a POSIX session leader and adopt the pty as controlling terminal,
    // so job control, Ctrl-C and SIGWINCH all work inside the child.
    _ = c.setsid();
    sys.setControllingTty(pty.slave) catch {};

    _ = c.dup2(pty.slave, stdin_fd);
    _ = c.dup2(pty.slave, stdout_fd);
    _ = c.dup2(pty.slave, stderr_fd);
    if (pty.slave > stderr_fd) _ = c.close(pty.slave);

    // exec resets handled signals on its own, but an ignored disposition
    // survives it, and a shell that inherits SIGPIPE ignored misbehaves.
    resetSignal(.PIPE);

    executable.exec();

    const name = std.mem.span(executable.argv[0].?);
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

fn generateSessionToken(io: std.Io) [handoff.session_len]u8 {
    var raw: [handoff.session_len / 2]u8 = undefined;
    io.random(&raw);
    var token: [handoff.session_len]u8 = undefined;
    const digits = "0123456789abcdef";
    for (raw, 0..) |byte, i| {
        token[i * 2] = digits[byte >> 4];
        token[i * 2 + 1] = digits[byte & 0xf];
    }
    return token;
}

/// Build the shell's environment without changing the proxy's own snapshot.
fn exportEnvironment(environment: *std.process.Environ.Map, store: *Store, title: []const u8, out_limit_bytes: u64, handoff_fd: sys.Fd, session_token: *const [handoff.session_len]u8) !void {
    try environment.put("TJ_JOURNAL", store.journal);
    var number: [32]u8 = undefined;
    try environment.put("TJ_NEXT", try std.fmt.bufPrint(&number, "{d}", .{store.next_number.?}));
    try environment.put("TJ_TITLE", title);
    try environment.put("TJ_OUT_LIMIT", try std.fmt.bufPrint(&number, "{d}", .{out_limit_bytes}));
    try environment.put("TJ_HANDOFF_FD", try std.fmt.bufPrint(&number, "{d}", .{handoff_fd}));
    try environment.put("TJ_SESSION_ID", session_token);
    if (store.temporary) {
        try environment.put("TJ_TEMPORARY", "1");
    } else {
        _ = environment.swapRemove("TJ_TEMPORARY");
    }
    var root: [std.fs.max_path_bytes]u8 = undefined;
    if (store.root.realPath(store.io, &root)) |len| {
        try environment.put("TJ_HOME", root[0..len]);
    } else |_| {}

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = sys.selfExePath(store.io, &path_buf) orelse return;
    try environment.put("TJCTL", path);
    var sibling_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (siblingEntryPath(path, &sibling_buf)) |entry_path| sibling_found: {
        std.Io.Dir.accessAbsolute(store.io, entry_path, .{}) catch break :sibling_found;
        try environment.put("TJ", entry_path);
        return;
    }
    try environment.put("TJ", "tj");
}

const journal_name = @import("../journal/name.zig");

fn siblingEntryPath(self_path: []const u8, buf: []u8) ?[]const u8 {
    if (!std.mem.eql(u8, std.fs.path.basename(self_path), "tjctl")) return null;
    const dir = std.fs.path.dirname(self_path) orelse return null;
    return std.fmt.bufPrint(buf, "{s}/tj", .{dir}) catch null;
}

fn warnStartup(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
    sys.writeAll(io, stderr_fd, text) catch {};
}

fn warnNothingRecorded(io: std.Io) void {
    sys.writeAll(io, stderr_fd, nothing_recorded_message) catch return;
    sys.writeAll(io, stderr_fd, if (sys.isTty(io, stderr_fd)) "\r\n" else "\n") catch {};
}

/// Turns scanner events into journal entries and forwards every byte the
/// terminal is meant to see. This is the only place the two jobs meet.
const Recorder = struct {
    store: *Store,
    title_enabled: bool = false,
    /// The command line arrives just before the "command is running" boundary,
    /// so it waits here until the interaction actually opens.
    command: [scanner.max_osc]u8 = undefined,
    command_len: usize = 0,
    has_command: bool = false,
    warned_missing_command: bool = false,
    /// Executable shell text after zsh has expanded aliases, when the
    /// integration reports a form that differs from what the user typed.
    expanded: [scanner.max_osc]u8 = undefined,
    expanded_len: usize = 0,
    has_expanded: bool = false,
    /// Absolute logical working directory reported at the same boundary.
    cwd: [scanner.max_osc]u8 = undefined,
    cwd_len: usize = 0,
    has_cwd: bool = false,
    /// Set when the terminal can no longer be written to; the pump then stops.
    broken: bool = false,
    handoff: ?handoff.Request = null,
    handoff_reply_fd: ?sys.Fd = null,
    /// Expected `TJ_SESSION_ID` value. SAVE and HANDOFF requests carrying a
    /// different token are forgeries from displayed content and are dropped
    /// without a reply: no legitimate `tjctl` is waiting on one, and a stray
    /// reply byte would poison the acknowledgement of a later real request.
    session_token: []const u8 = "",

    /// Bytes for the terminal that also belong in `out`.
    pub fn data(self: *Recorder, bytes: []const u8) void {
        self.store.append(bytes);
        self.forward(bytes);
    }

    /// Bytes for the terminal only: tj's own sequences under `--keep-osc`,
    /// which are protocol, not output.
    pub fn control(self: *Recorder, bytes: []const u8) void {
        self.forward(bytes);
    }

    fn forward(self: *Recorder, bytes: []const u8) void {
        sys.writeAll(self.store.io, stdout_fd, bytes) catch {
            self.broken = true;
        };
    }

    pub fn event(self: *Recorder, ev: scanner.Event) void {
        switch (ev) {
            .command_line => |line| {
                const n = @min(line.len, self.command.len);
                @memcpy(self.command[0..n], line[0..n]);
                self.command_len = n;
                self.has_command = true;
            },
            .command_expanded => |line| {
                const n = @min(line.len, self.expanded.len);
                @memcpy(self.expanded[0..n], line[0..n]);
                self.expanded_len = n;
                self.has_expanded = true;
            },
            .working_directory => |path| {
                const n = @min(path.len, self.cwd.len);
                @memcpy(self.cwd[0..n], path[0..n]);
                self.cwd_len = n;
                self.has_cwd = true;
            },
            .command_run => {
                if (!self.has_command and !self.warned_missing_command) {
                    self.store.warn("command boundary received without a TJ command line", .{});
                    self.warned_missing_command = true;
                }
                self.store.begin(
                    self.command[0..self.command_len],
                    if (self.has_expanded) self.expanded[0..self.expanded_len] else null,
                    if (self.has_cwd) self.cwd[0..self.cwd_len] else null,
                );
                self.command_len = 0;
                self.has_command = false;
                self.expanded_len = 0;
                self.has_expanded = false;
                self.cwd_len = 0;
                self.has_cwd = false;
            },
            .command_end => |code| {
                if (self.store.finishReporting(code)) |notice| {
                    var size_buf: [24]u8 = undefined;
                    var message_buf: [128]u8 = undefined;
                    const message = std.fmt.bufPrint(
                        &message_buf,
                        "tj: @{d} output recording stopped at {s}\r\n",
                        .{ notice.number, report.formatHumanSize(notice.limit_bytes, &size_buf) },
                    ) catch return;
                    self.forward(message);
                }
            },
            // Ends whatever is still open, then captures the prompt which
            // will belong to the next command that actually runs.
            .prompt_start => self.store.promptStart(),
            .prompt_end => self.store.promptEnd(),
            .resource_begin => |r| self.store.beginResource(r.path, r.mime),
            .noout_begin => self.store.beginNoout(),
            .region_end => self.store.endRegion(),
            .handoff => |encoded| {
                const request = handoff.decode(encoded) catch {
                    self.store.warn("ignored invalid ELLO handoff request", .{});
                    return;
                };
                if (!std.mem.eql(u8, request.sessionSlice(), self.session_token)) {
                    self.store.warn("ignored ELLO handoff with a wrong session token", .{});
                    return;
                }
                self.handoff = request;
                // The marker comes from the active `tjctl new/use` command.
                // Close its interaction before terminating the source shell.
                if (self.store.isRecording()) self.store.finish(0);
            },
            .save => |token| {
                if (!std.mem.eql(u8, token, self.session_token)) {
                    self.store.warn("ignored ELLO SAVE with a wrong session token", .{});
                    return;
                }
                if (!self.store.saveTemporary()) {
                    self.store.warn("ignored ELLO SAVE outside a temporary journal", .{});
                    handoffReply(self, 1);
                    return;
                }
                handoffReply(self, 0);
            },
            .protocol_error => |payload| {
                const shown = payload[0..@min(payload.len, max_protocol_error_log_bytes)];
                if (shown.len == payload.len) {
                    self.store.warn("ignored ELLO sequence: {s}", .{shown});
                } else {
                    self.store.warn("ignored ELLO sequence (truncated): {s}", .{shown});
                }
            },
        }
    }
};

fn pump(gpa: std.mem.Allocator, io: std.Io, home: ?[]const u8, master: sys.Fd, sig_r: sys.Fd, pid: c.pid_t, recorder: *Recorder, output: *scanner.Scanner) !void {
    var out_buf: [io_buf_size]u8 = undefined;
    var pending_input: PendingInput = .{};
    var stdin_open = true;

    var fds = [_]posix.pollfd{
        .{ .fd = stdin_fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = master, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = sig_r, .events = posix.POLL.IN, .revents = 0 },
    };
    const in = &fds[0];
    const out = &fds[1];
    const sig = &fds[2];
    var flush_schedule: FlushSchedule = .{};

    while (true) {
        in.fd = if (stdin_open and !pending_input.isFull()) stdin_fd else -1;
        out.events = posix.POLL.IN;
        if (!pending_input.isEmpty()) out.events |= posix.POLL.OUT;

        // While a command is running, wake up regularly to flush its output to
        // disk, so `tail -f` on `@N/out` shows progress.
        const recording = recorder.store.isRecording();
        const before_poll_ms = std.Io.Clock.now(.awake, io).toMilliseconds();
        const timeout = flush_schedule.timeout(recording, before_poll_ms);
        _ = posix.poll(&fds, timeout) catch return;

        if (sig.revents & (posix.POLL.IN | posix.POLL.HUP) != 0) {
            try drainSignals(sig_r, master, pid);
        }

        if (out.revents & (posix.POLL.IN | posix.POLL.HUP) != 0) {
            switch (sys.readNonBlocking(master, &out_buf) catch return) {
                .bytes => |n| {
                    output.feed(out_buf[0..n], recorder);
                    if (recorder.broken) return;
                    applyHandoff(gpa, io, home, recorder);
                },
                .would_block => {},
                .eof => return,
            }
        }

        const after_output_ms = std.Io.Clock.now(.awake, io).toMilliseconds();
        if (flush_schedule.consume(recorder.store.isRecording(), after_output_ms)) recorder.store.tick();

        if (!pending_input.isEmpty() and out.revents & posix.POLL.OUT != 0) {
            switch (sys.writeNonBlocking(master, pending_input.pending()) catch return) {
                .bytes => |n| pending_input.consume(n),
                .would_block => {},
            }
        }

        if (in.fd >= 0 and in.revents & (posix.POLL.IN | posix.POLL.HUP) != 0) {
            const writable = pending_input.writable();
            const n = sys.read(stdin_fd, writable) catch 0;
            if (n == 0) {
                // The user's input ended, but the child may still be talking.
                stdin_open = false;
            } else {
                pending_input.commit(n);
            }
        }

        if (in.fd >= 0 and in.revents & (posix.POLL.ERR | posix.POLL.NVAL) != 0) stdin_open = false;
        if (out.revents & (posix.POLL.ERR | posix.POLL.NVAL) != 0) return;
    }
}

test "pending input is bounded and preserves partial writes" {
    var queue: PendingInput = .{};
    try std.testing.expect(queue.isEmpty());
    try std.testing.expectEqual(@as(usize, pending_input_capacity), queue.writable().len);

    const first = queue.writable();
    for (first, 0..) |*byte, i| byte.* = @truncate(i);
    queue.commit(first.len);
    try std.testing.expect(queue.isFull());

    queue.consume(17);
    try std.testing.expect(!queue.isFull());
    try std.testing.expectEqual(@as(usize, pending_input_capacity - 17), queue.pending().len);
    const tail = queue.writable();
    try std.testing.expectEqual(@as(usize, 17), tail.len);
    @memset(tail, 0xa5);
    queue.commit(tail.len);
    try std.testing.expect(queue.isFull());
    for (queue.pending(), 0..) |byte, i| {
        try std.testing.expectEqual(@as(u8, @truncate(i + 17)), byte);
    }
    queue.consume(pending_input_capacity - 17);
    try std.testing.expectEqualSlices(u8, &.{0xa5} ** 17, queue.pending());

    queue.consume(17);
    try std.testing.expect(queue.isEmpty());
    try std.testing.expectEqual(@as(usize, pending_input_capacity), queue.writable().len);
}

test "output flush scheduling uses an elapsed deadline" {
    var schedule: FlushSchedule = .{};
    try std.testing.expectEqual(@as(c_int, -1), schedule.timeout(false, 1000));
    try std.testing.expectEqual(@as(c_int, flush_interval_ms), schedule.timeout(true, 1000));
    try std.testing.expectEqual(@as(c_int, 50), schedule.timeout(true, 1150));
    try std.testing.expect(!schedule.consume(true, 1199));
    try std.testing.expect(schedule.consume(true, 1200));
    try std.testing.expectEqual(@as(c_int, flush_interval_ms), schedule.timeout(true, 1200));
    try std.testing.expect(!schedule.consume(false, 1300));
    try std.testing.expectEqual(@as(?i64, null), schedule.deadline_ms);
}

fn applyHandoff(gpa: std.mem.Allocator, io: std.Io, home: ?[]const u8, recorder: *Recorder) void {
    const request = recorder.handoff orelse return;
    // Acquire the target before giving up the source lock. If it cannot be
    // acquired, the source writer remains active.
    var target = switch (request.operation) {
        .new => Store.createNamedJournal(gpa, io, home, if (request.selector_len == 0) null else request.selectorSlice(), request.temporary),
        .use => Store.continueJournal(gpa, io, home, request.selectorSlice()),
    } catch {
        recorder.store.warn("journal handoff target could not be acquired", .{});
        recorder.handoff = null;
        handoffReply(recorder, 1);
        return;
    };
    target.setOutputLimit(recorder.store.out_limit_bytes);
    if (request.replay_before_start) {
        var stdout_buffer: [io_buf_size]u8 = undefined;
        var stdout_file: std.Io.File.Writer = .initStreaming(.stdout(), io, &stdout_buffer);
        replay.play(gpa, io, target.root, target.journalId(), .{
            .typing_ms = 0,
            .max_pause_ms = 0,
        }, &stdout_file.interface) catch {};
        stdout_file.interface.flush() catch {};
    }
    if (recorder.store.saved_temporary) warnStartup(io, "tjctl: saved journal {s}\n", .{recorder.store.journalId()});
    recorder.store.close();
    recorder.store.* = target;
    if (recorder.title_enabled) terminal_title.writeInitialTitle(io, stdout_fd, recorder.store.journalId());
    recorder.handoff = null;
    handoffReply(recorder, 0);
}

fn handoffReply(recorder: *Recorder, status: u8) void {
    if (recorder.handoff_reply_fd) |fd| sys.writeAll(recorder.store.io, fd, &[_]u8{status}) catch {};
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
