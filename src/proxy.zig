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
const scanner = @import("scanner.zig");
const journal_store = @import("store.zig");
const Store = journal_store.Store;
const replay = @import("replay.zig");
const splash = @import("splash.zig");
const terminal_title = @import("terminal_title.zig");

const io_buf_size = 64 * 1024;
const max_protocol_error_log_bytes = 384;

/// How often a running command's buffered output reaches the disk.
const flush_interval_ms = 200;
const nothing_recorded_message = "tjctl: nothing was recorded - is tj.plugin.zsh sourced in your ~/.zshrc?";

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
    terminal_title.restoreFromSignal(stdout_fd);
    if (panic_restore) |saved| tty.restore(saved);
}

pub const Result = struct { exit_code: u8 };

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
    title_blink_ms: u32 = 1500,
    home: ?[]const u8 = null,
};

pub fn run(gpa: std.mem.Allocator, io: std.Io, opts: Options) !Result {
    const argv = try buildArgv(gpa, opts.argv);
    defer freeArgv(gpa, argv);

    // Panes and multiplexers make nesting legitimate. A new writer shadows
    // the outer journal environment; continuing it fails on the lock.
    if (sys.env("TJ_JOURNAL")) |outer| {
        warnStartup("tj: starting another journal writer inside {s}\r\n", .{outer});
    }

    // Lifecycle acquisition is strict: selection, numbering, and locking all
    // complete before a pty or child process exists.
    var store = switch (opts.journal) {
        .new => |name| try Store.createNamedJournal(gpa, io, opts.home, name),
        .existing => |selector| try Store.continueJournal(gpa, io, opts.home, selector),
    };
    defer store.close();

    const title_enabled = !std.mem.eql(u8, opts.title, "none") and sys.isTty(stdout_fd);
    defer if (title_enabled) terminal_title.pop(stdout_fd);

    const title_env = try gpa.dupeZ(u8, opts.title);
    defer gpa.free(title_env);

    // Confirm the selected journal before the fresh child takes ownership of
    // the terminal. Zooi restores the exact screen contents on exit, after
    // which a continuation reconstructs its transcript without hiding any of
    // it behind the splash. Redirected and otherwise non-interactive starts
    // never wait for input.
    if (opts.splash and sys.isTty(stdin_fd)) {
        const choice = splash.show(gpa, store.journalId(), store.next_number.?) catch blk: {
            warnStartup("tjctl: recording journal {s}; next entry @{d}\r\n", .{ store.journalId(), store.next_number.? });
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
        var stdout_file: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
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
    // Activate only after fatal signals are under proxy control. Unsupported
    // terminals harmlessly ignore the xterm title-stack request.
    var blinker_storage: terminal_title.Blinker = undefined;
    var blinker: ?*terminal_title.Blinker = null;
    if (title_enabled) {
        terminal_title.push(stdout_fd);
        if (opts.title_blink_ms == 0) {
            terminal_title.writeFallback(stdout_fd, store.journalId());
        } else {
            const now_ms = std.Io.Clock.now(.awake, io).toMilliseconds();
            blinker_storage = .init(stdout_fd, opts.title_blink_ms, now_ms);
            blinker = &blinker_storage;
            blinker_storage.startJournal(store.journalId()) catch {};
        }
    }
    exportEnvironment(&store, title_env, opts.title_blink_ms);

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

    var recorder: Recorder = .{ .store = &store, .blinker = blinker };
    var output: scanner.Scanner = .{ .keep_osc = opts.keep_osc };
    pump(io, pty.master, sig_fds[0], pid, &recorder, &output) catch {};
    // Nothing may stay withheld inside the scanner once the stream is over.
    output.flush(&recorder);
    if (blinker) |active| active.flush() catch {};

    sys.close(pty.master);
    sys.close(sig_fds[0]);
    sig_pipe_w.store(-1, .monotonic);
    sys.close(sig_fds[1]);

    const child_result = sys.waitFor(pid);
    if (!store.hasRecordedEntry()) warnNothingRecorded();
    return .{ .exit_code = child_result.code };
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
    var duplicated: usize = 0;
    errdefer {
        for (argv[0..duplicated]) |word| gpa.free(std.mem.span(word.?));
        gpa.free(argv);
    }
    for (words.items, 0..) |word, i| {
        argv[i] = try gpa.dupeZ(u8, word);
        duplicated += 1;
    }
    return argv;
}

/// Safe to call once the child has been forked: the child received its own
/// copy of this memory, so releasing the parent's has no effect on the exec.
fn freeArgv(gpa: std.mem.Allocator, argv: [:null]const ?[*:0]const u8) void {
    for (argv) |word| gpa.free(std.mem.span(word.?));
    gpa.free(argv);
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
fn exportEnvironment(store: *Store, title: [:0]const u8, title_blink_ms: u32) void {
    var journal: [journal_name.max_len + 1]u8 = undefined;
    @memcpy(journal[0..store.journal.len], store.journal);
    journal[store.journal.len] = 0;
    sys.setEnv("TJ_JOURNAL", journal[0..store.journal.len :0]);

    var next: [16]u8 = undefined;
    const next_text = std.fmt.bufPrint(next[0 .. next.len - 1], "{d}", .{store.next_number.?}) catch return;
    next[next_text.len] = 0;
    sys.setEnv("TJ_NEXT", next[0..next_text.len :0]);

    sys.setEnv("TJ_TITLE", title.ptr);
    var blink: [16]u8 = undefined;
    const blink_text = std.fmt.bufPrint(&blink, "{d}", .{title_blink_ms}) catch unreachable;
    blink[blink_text.len] = 0;
    sys.setEnv("TJ_TITLE_BLINK", blink[0..blink_text.len :0]);
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
    if (path.len < value_buf.len) {
        @memcpy(value_buf[0..path.len], path);
        value_buf[path.len] = 0;
        sys.setEnv("TJCTL", value_buf[0..path.len :0]);
    }

    const sibling = siblingEntryPath(path, &value_buf);
    var fallback: [3:0]u8 = .{ 't', 'j', 0 };
    if (sibling) |entry_path| sibling_found: {
        std.Io.Dir.accessAbsolute(store.io, entry_path, .{}) catch break :sibling_found;
        value_buf[entry_path.len] = 0;
        sys.setEnv("TJ", value_buf[0..entry_path.len :0]);
        return;
    }
    sys.setEnv("TJ", fallback[0..2 :0]);
}

const journal_name = @import("journal_name.zig");

fn siblingEntryPath(self_path: []const u8, buf: []u8) ?[]const u8 {
    if (!std.mem.eql(u8, std.fs.path.basename(self_path), "tjctl")) return null;
    const dir = std.fs.path.dirname(self_path) orelse return null;
    return std.fmt.bufPrint(buf, "{s}/tj", .{dir}) catch null;
}

fn warnStartup(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
    sys.writeAll(stderr_fd, text) catch {};
}

fn warnNothingRecorded() void {
    sys.writeAll(stderr_fd, nothing_recorded_message) catch return;
    sys.writeAll(stderr_fd, if (sys.isTty(stderr_fd)) "\r\n" else "\n") catch {};
}

/// Turns scanner events into journal entries and forwards every byte the
/// terminal is meant to see. This is the only place the two jobs meet.
const Recorder = struct {
    store: *Store,
    blinker: ?*terminal_title.Blinker = null,
    /// The command line arrives just before the "command is running" boundary,
    /// so it waits here until the interaction actually opens.
    command: [scanner.max_osc]u8 = undefined,
    command_len: usize = 0,
    has_command: bool = false,
    warned_missing_command: bool = false,
    /// Executable shell text after canonical TJ named-directory tokens were
    /// resolved to paths for metadata, when the integration reports any.
    expanded: [scanner.max_osc]u8 = undefined,
    expanded_len: usize = 0,
    has_expanded: bool = false,
    /// Absolute logical working directory reported at the same boundary.
    cwd: [scanner.max_osc]u8 = undefined,
    cwd_len: usize = 0,
    has_cwd: bool = false,
    /// Set when the terminal can no longer be written to; the pump then stops.
    broken: bool = false,

    /// Bytes for the terminal that also belong in `out`.
    pub fn data(self: *Recorder, bytes: []const u8) void {
        self.store.append(bytes);
        if (self.blinker) |active| {
            active.feed(bytes) catch {
                self.broken = true;
            };
        } else {
            self.forward(bytes);
        }
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
            .command_end => |code| self.store.finish(code),
            // Ends whatever is still open, then captures the prompt which
            // will belong to the next command that actually runs.
            .prompt_start => self.store.promptStart(),
            .prompt_end => self.store.promptEnd(),
            .resource_begin => |r| self.store.beginResource(r.path, r.mime),
            .noout_begin => self.store.beginNoout(),
            .region_end => self.store.endRegion(),
            .protocol_error => |payload| {
                const shown = payload[0..@min(payload.len, max_protocol_error_log_bytes)];
                if (shown.len == payload.len) {
                    self.store.warn("ignored tj sequence: {s}", .{shown});
                } else {
                    self.store.warn("ignored tj sequence (truncated): {s}", .{shown});
                }
            },
        }
    }
};

fn pump(io: std.Io, master: sys.Fd, sig_r: sys.Fd, pid: c.pid_t, recorder: *Recorder, output: *scanner.Scanner) !void {
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
        const before_poll_ms = std.Io.Clock.now(.awake, io).toMilliseconds();
        var timeout: c_int = if (recording) flush_interval_ms else -1;
        if (recorder.blinker) |active| {
            const title_timeout = active.timeout(before_poll_ms);
            if (timeout < 0 or title_timeout < timeout) timeout = title_timeout;
        }
        _ = posix.poll(&fds, timeout) catch return;

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

        if (recorder.blinker) |active| {
            const now_ms = std.Io.Clock.now(.awake, io).toMilliseconds();
            active.tick(now_ms) catch {
                recorder.broken = true;
            };
            if (recorder.broken) return;
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
