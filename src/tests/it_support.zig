//! Fixtures shared by the integration suites: the pty harness wrappers, an
//! isolated journal home, and the recording helpers each suite builds on.

const std = @import("std");
const posix = std.posix;
const harness = @import("harness.zig");
const plain = @import("../plain.zig");
const journal_name = @import("../journal_name.zig");

const options = @import("build_options");
pub const tj = options.tj_exe;
pub const tjctl = options.tjctl_exe;

pub const timeout_ms = 5000;

pub const test_prompt = "TJ_TEST_PROMPT> ";

pub const journal_dir = "journal home *$'quoted";

/// Tests start real writer processes, each attached to a journal. Point every
/// child at a scratch one: a test run must not leave anything in the journal
/// the developer is actually using.
pub var journal_isolated = false;

pub fn isolateJournal() void {
    // Once only. Tests that set TJ_JOURNAL themselves, to make `@N` resolve
    // against a journal they built, must not have it taken away again.
    if (journal_isolated) return;
    journal_isolated = true;

    sys.setEnv("TJ_HOME", ".zig-cache/tj-test-home");
    // Fixtures invoke tjctl by its absolute installed path. A normal install
    // places tj alongside it on PATH, so make child shells see that same
    // layout. This is required for canonical `$(tj @REF)` and Fish `(tj @REF)`
    // forms, not just the zsh convenience rewrite.
    if (std.fs.path.dirname(tj)) |bin_dir| {
        const inherited_path = sys.env("PATH") orelse "";
        const path = std.heap.page_allocator.allocSentinel(u8, inherited_path.len + 1 + bin_dir.len, 0) catch unreachable;
        defer std.heap.page_allocator.free(path);
        _ = std.fmt.bufPrint(path, "{s}:{s}", .{ inherited_path, bin_dir }) catch unreachable;
        sys.setEnv("PATH", path);
    }
    // Inherited from the developer's environment otherwise, which would make
    // `@N` resolve against whatever journal they happen to be writing.
    sys.setEnv("TJ_JOURNAL", "");
    sys.setEnv("TJ_NEXT", "");
}

/// Tests share one process, so a test that selected a journal leaves
/// TJ_JOURNAL set for whatever runs next. Replay refuses to run inside a
/// journal writer, so its tests have to say they are outside one.
pub fn leaveJournal() void {
    isolateJournal();
    sys.setEnv("TJ_JOURNAL", "");
}

/// Restores process environment variables when a fixture leaves scope. Zig's
/// test runner executes many tests in one process, so a failed assertion must
/// not silently configure whichever test happens to run next.
pub const EnvGuard = struct {
    const Saved = struct {
        name: [*:0]const u8,
        value: ?[:0]u8,
        was_present: bool,
    };

    gpa: std.mem.Allocator,
    saved: std.ArrayList(Saved),

    pub fn init(gpa: std.mem.Allocator, names: []const [*:0]const u8) !EnvGuard {
        var self: EnvGuard = .{ .gpa = gpa, .saved = .empty };
        errdefer self.deinit();
        for (names) |name| {
            const present = sys.envPresent(name);
            const value = if (present) try gpa.dupeZ(u8, sys.env(name) orelse "") else null;
            try self.saved.append(gpa, .{
                .name = name,
                .value = value,
                .was_present = present,
            });
        }
        return self;
    }

    pub fn deinit(self: *EnvGuard) void {
        var index = self.saved.items.len;
        while (index > 0) {
            index -= 1;
            const saved = self.saved.items[index];
            if (saved.was_present) {
                sys.setEnv(saved.name, saved.value.?.ptr);
            } else {
                sys.unsetEnv(saved.name);
            }
            if (saved.value) |value| self.gpa.free(value);
        }
        self.saved.deinit(self.gpa);
    }
};

const Program = enum {
    tj,
    tjctl,

    fn executable(self: Program) []const u8 {
        return switch (self) {
            .tj => tj,
            .tjctl => tjctl,
        };
    }
};

const PtyRunResult = struct {
    out: std.ArrayList(u8),
    code: u8,
};

const ClosedStdoutResult = struct {
    term: std.process.Child.Term,
    stderr: []u8,
};

fn spawnProgram(
    gpa: std.mem.Allocator,
    program: Program,
    args: []const []const u8,
    rows: u16,
    cols: u16,
    quiet_lifecycle: bool,
) !harness.PtyChild {
    isolateJournal();
    if (program != .tjctl or !quiet_lifecycle) return harness.spawn(gpa, args, rows, cols);

    // Most integration tests exercise the writer or its child rather than the
    // deliberate startup pause. Keep those fixtures non-interactive; splash
    // tests call spawnTjctlWithSplash directly.
    var adjusted: std.ArrayList([]const u8) = .empty;
    defer adjusted.deinit(gpa);
    var inserted = false;
    var skip_value = false;
    for (args) |arg| {
        try adjusted.append(gpa, arg);
        if (inserted) continue;
        if (skip_value) {
            skip_value = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "--home")) {
            skip_value = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) continue;
        if (std.mem.eql(u8, arg, "new") or std.mem.eql(u8, arg, "use")) {
            try adjusted.append(gpa, "--no-splash");
            try adjusted.append(gpa, "--title");
            try adjusted.append(gpa, "none");
            inserted = true;
        }
    }
    return harness.spawn(gpa, adjusted.items, rows, cols);
}

pub fn spawnTj(gpa: std.mem.Allocator, args: []const []const u8, rows: u16, cols: u16) !harness.PtyChild {
    return spawnProgram(gpa, .tj, args, rows, cols, false);
}

pub fn spawnTjctl(gpa: std.mem.Allocator, args: []const []const u8, rows: u16, cols: u16) !harness.PtyChild {
    return spawnProgram(gpa, .tjctl, args, rows, cols, true);
}

pub fn spawnTjctlWithSplash(gpa: std.mem.Allocator, args: []const []const u8, rows: u16, cols: u16) !harness.PtyChild {
    return spawnProgram(gpa, .tjctl, args, rows, cols, false);
}

fn runPty(gpa: std.mem.Allocator, program: Program, args: []const []const u8, rows: u16, cols: u16) !PtyRunResult {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, program.executable());
    try argv.appendSlice(gpa, args);

    const child = try spawnProgram(gpa, program, argv.items, rows, cols, true);
    var out: std.ArrayList(u8) = .empty;
    const code = try child.finish(gpa, &out, timeout_ms);
    return .{ .out = out, .code = code };
}

pub fn run(gpa: std.mem.Allocator, args: []const []const u8, rows: u16, cols: u16) !PtyRunResult {
    return runPty(gpa, .tj, args, rows, cols);
}

pub fn runTjctl(gpa: std.mem.Allocator, args: []const []const u8, rows: u16, cols: u16) !PtyRunResult {
    return runPty(gpa, .tjctl, args, rows, cols);
}

fn runNonTtyProgram(gpa: std.mem.Allocator, program: Program, args: []const []const u8) !std.process.RunResult {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, program.executable());
    try argv.appendSlice(gpa, args);
    return std.process.run(gpa, std.testing.io, .{
        .argv = argv.items,
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
    });
}

pub fn runNonTty(gpa: std.mem.Allocator, args: []const []const u8) !std.process.RunResult {
    return runNonTtyProgram(gpa, .tj, args);
}

pub fn runTjctlNonTty(gpa: std.mem.Allocator, args: []const []const u8) !std.process.RunResult {
    return runNonTtyProgram(gpa, .tjctl, args);
}

fn runWithClosedStdoutProgram(gpa: std.mem.Allocator, program: Program, args: []const []const u8) !ClosedStdoutResult {
    isolateJournal();
    const io = std.testing.io;

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, program.executable());
    try argv.appendSlice(gpa, args);

    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);

    // Model a downstream command such as `head` exiting before tj flushes.
    child.stdout.?.close(io);
    child.stdout = null;

    const stderr_file = child.stderr.?;
    var stderr_reader: Io.File.Reader = .initStreaming(stderr_file, io, &.{});
    const stderr = try stderr_reader.interface.allocRemaining(gpa, .limited(1 << 20));
    stderr_file.close(io);
    child.stderr = null;

    return .{
        .term = try child.wait(io),
        .stderr = stderr,
    };
}

pub fn runWithClosedStdout(gpa: std.mem.Allocator, args: []const []const u8) !ClosedStdoutResult {
    return runWithClosedStdoutProgram(gpa, .tj, args);
}

pub fn runTjctlWithClosedStdout(gpa: std.mem.Allocator, args: []const []const u8) !ClosedStdoutResult {
    return runWithClosedStdoutProgram(gpa, .tjctl, args);
}

fn runNonTtyInJournalProgram(
    gpa: std.mem.Allocator,
    program: Program,
    args: []const []const u8,
    journal: []const u8,
    next: []const u8,
) !std.process.RunResult {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, program.executable());
    try argv.appendSlice(gpa, args);
    var environ = try std.process.Environ.createMap(std.testing.environ, gpa);
    defer environ.deinit();
    try environ.put("TJ_JOURNAL", journal);
    try environ.put("TJ_NEXT", next);
    if (program == .tj) {
        // The native command must not depend on the optional ripgrep
        // companion.
        try environ.put("PATH", "");
        try environ.put("GREP_COLORS", "mt=01;31");
    }
    return std.process.run(gpa, std.testing.io, .{
        .argv = argv.items,
        .environ_map = &environ,
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
    });
}

pub fn runNonTtyInJournal(
    gpa: std.mem.Allocator,
    args: []const []const u8,
    journal: []const u8,
    next: []const u8,
) !std.process.RunResult {
    return runNonTtyInJournalProgram(gpa, .tj, args, journal, next);
}

pub fn runTjctlNonTtyInJournal(
    gpa: std.mem.Allocator,
    args: []const []const u8,
    journal: []const u8,
    next: []const u8,
) !std.process.RunResult {
    return runNonTtyInJournalProgram(gpa, .tjctl, args, journal, next);
}

/// Drains a large PTY transcript without retaining bytes that precede its
/// final marker. This keeps the large-file regression honest about memory.
pub fn finishKeepingTail(
    gpa: std.mem.Allocator,
    child: harness.PtyChild,
    keep: usize,
    timeout: i32,
) !struct { tail: std.ArrayList(u8), total: u64, code: u8 } {
    var tail: std.ArrayList(u8) = .empty;
    errdefer tail.deinit(gpa);
    var total: u64 = 0;
    const deadline = try harness.Deadline.init(timeout);
    var completed = false;
    var master_closed = false;
    defer if (!completed) {
        if (!master_closed) sys.close(child.master);
        child.killAndReap();
    };
    var buf: [64 * 1024]u8 = undefined;

    while (true) {
        const interval = try deadline.pollInterval(100) orelse return error.PtyTimeout;
        var fds = [_]posix.pollfd{.{ .fd = child.master, .events = posix.POLL.IN, .revents = 0 }};
        const ready = try posix.poll(&fds, interval);
        if (ready == 0) continue;
        const n = try sys.read(child.master, &buf);
        if (n == 0) break;
        total += @intCast(n);

        const bytes = buf[0..n];
        if (bytes.len >= keep) {
            tail.clearRetainingCapacity();
            try tail.appendSlice(gpa, bytes[bytes.len - keep ..]);
        } else {
            if (tail.items.len + bytes.len > keep) {
                const drop = tail.items.len + bytes.len - keep;
                const retained = tail.items.len - drop;
                std.mem.copyForwards(u8, tail.items[0..retained], tail.items[drop..]);
                tail.items.len = retained;
            }
            try tail.appendSlice(gpa, bytes);
        }
    }

    sys.close(child.master);
    master_closed = true;
    while (true) {
        if (sys.tryWaitFor(child.pid)) |wait| {
            completed = true;
            return .{ .tail = tail, .total = total, .code = wait.code };
        }
        const interval = try deadline.pollInterval(10) orelse return error.PtyTimeout;
        sys.sleepMs(@intCast(interval));
    }
}

pub const Io = std.Io;

pub const Dir = std.Io.Dir;

pub const sys = @import("../sys.zig");

/// A zsh child process under tj, with the plugin loaded.
pub const Journal = struct {
    tmp: std.testing.TmpDir,
    // A length, not a slice: the struct is returned by value, and a slice into
    // its own buffer would point at the caller's dead stack frame.
    path_len: usize,
    path_buf: [std.fs.max_path_bytes]u8,
    env_guard: ?EnvGuard,

    pub fn path(self: *const Journal) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    pub fn open(_: std.mem.Allocator) !Journal {
        var self: Journal = .{
            .tmp = std.testing.tmpDir(.{}),
            .path_len = 0,
            .path_buf = undefined,
            .env_guard = null,
        };
        const io = std.testing.io;

        const len = try self.tmp.dir.realPath(io, &self.path_buf);

        try self.tmp.dir.createDirPath(io, journal_dir);

        self.path_len = len;
        return self;
    }

    /// Writes a fixture next to the journal and returns its absolute path.
    pub fn fixture(self: *const Journal, gpa: std.mem.Allocator, name: []const u8, bytes: []const u8) ![]const u8 {
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = bytes });
        return std.fmt.allocPrint(gpa, "{s}/{s}", .{ self.path(), name });
    }

    pub fn homeArg(self: *const Journal, gpa: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(gpa, "{s}/{s}", .{ self.path(), journal_dir });
    }

    pub fn close(self: *Journal) void {
        if (self.env_guard) |*guard| guard.deinit();
        self.tmp.cleanup();
    }

    /// The id of the single journal this writer created.
    pub fn journalName(self: *Journal, gpa: std.mem.Allocator) ![]u8 {
        const io = std.testing.io;
        var root = try self.tmp.dir.openDir(io, journal_dir, .{ .iterate = true });
        defer root.close(io);
        var it = root.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind == .directory and journal_name.isValid(entry.name)) return gpa.dupe(u8, entry.name);
        }
        return error.NoJournal;
    }

    /// Makes `@N` and `@-` resolve against this journal.
    pub fn enter(self: *Journal, gpa: std.mem.Allocator) !void {
        if (self.env_guard == null) {
            self.env_guard = try EnvGuard.init(gpa, &.{ "TJ_JOURNAL", "TJ_NEXT" });
        }
        const name = try self.journalName(gpa);
        defer gpa.free(name);
        var buf: [64]u8 = undefined;
        @memcpy(buf[0..name.len], name);
        buf[name.len] = 0;
        sys.setEnv("TJ_JOURNAL", buf[0..name.len :0]);
    }

    /// The single journal directory this writer created.
    pub fn journalDir(self: *Journal) !Dir {
        const io = std.testing.io;
        var root = try self.tmp.dir.openDir(io, journal_dir, .{ .iterate = true });
        defer root.close(io);
        var it = root.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind == .directory and journal_name.isValid(entry.name)) return root.openDir(io, entry.name, .{});
        }
        return error.NoJournal;
    }

    pub fn read(self: *Journal, gpa: std.mem.Allocator, sub_path: []const u8) ![]u8 {
        var child = try self.journalDir();
        defer child.close(std.testing.io);
        return child.readFileAlloc(std.testing.io, sub_path, gpa, .limited(1 << 20));
    }
};

/// Starts zsh with every startup file disabled. The fixture loads exactly the
/// plugin it needs through the PTY, so system zsh configuration cannot change
/// the prompt or install competing hooks.
pub fn spawnJournalZsh(gpa: std.mem.Allocator, journal: *const Journal) !harness.PtyChild {
    // A preceding test may have selected a journal to exercise reference
    // resolution. This fixture starts a fresh outer writer, never a handoff,
    // so it must not inherit that process-global test state.
    leaveJournal();
    const home = try journal.homeArg(gpa);
    defer gpa.free(home);
    return spawnTjctl(gpa, &.{ tjctl, "--home", home, "new", "--", "/bin/zsh", "-f", "-i" }, 24, 80);
}

pub fn spawnContinuedJournalZsh(
    gpa: std.mem.Allocator,
    journal: *const Journal,
    selector: []const u8,
) !harness.PtyChild {
    // The parent test may use TJ_JOURNAL for direct `tj` invocations after
    // this child returns. Do not leak that synthetic state into a fresh
    // `tjctl use`, where it would correctly be interpreted as a nested writer.
    var environment = try EnvGuard.init(gpa, &.{"TJ_JOURNAL"});
    defer environment.deinit();
    sys.setEnv("TJ_JOURNAL", "");
    const home = try journal.homeArg(gpa);
    defer gpa.free(home);
    return spawnTjctl(gpa, &.{ tjctl, "--home", home, "use", selector, "--", "/bin/zsh", "-f", "-i" }, 24, 80);
}

pub fn appendShellQuoted(gpa: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    try out.append(gpa, '\'');
    for (text) |byte| {
        if (byte == '\'') {
            try out.appendSlice(gpa, "'\\''");
        } else {
            try out.append(gpa, byte);
        }
    }
    try out.append(gpa, '\'');
}

/// Owns a PTY child and its transcript. Tests can still use the lower-level
/// harness for signal and resize assertions, while ordinary interactive tests
/// get consistent prompt waits, diagnostics, and failure cleanup.
pub const TerminalSession = struct {
    gpa: std.mem.Allocator,
    child: harness.PtyChild,
    transcript: std.ArrayList(u8) = .empty,
    finished: bool = false,

    pub fn init(gpa: std.mem.Allocator, child: harness.PtyChild) TerminalSession {
        return .{ .gpa = gpa, .child = child };
    }

    pub fn deinit(self: *TerminalSession) void {
        if (!self.finished) {
            sys.close(self.child.master);
            self.child.killAndReap();
        }
        self.transcript.deinit(self.gpa);
    }

    pub fn mark(self: *const TerminalSession) usize {
        return self.transcript.items.len;
    }

    pub fn write(self: *TerminalSession, bytes: []const u8) !void {
        try self.child.write(bytes);
    }

    pub fn expectFrom(self: *TerminalSession, from: usize, marker: []const u8) !void {
        if (try self.child.readUntilFrom(self.gpa, &self.transcript, from, marker, timeout_ms)) return;
        std.debug.print("terminal did not produce {s}; transcript follows:\n{s}\n", .{ marker, self.transcript.items[from..] });
        return error.TerminalMarkerMissing;
    }

    pub fn command(self: *TerminalSession, line: []const u8) !void {
        const from = self.mark();
        try self.write(line);
        try self.write("\n");
        try self.expectFrom(from, test_prompt);
    }

    pub fn finish(self: *TerminalSession) !u8 {
        const code = self.child.finish(self.gpa, &self.transcript, timeout_ms) catch |err| {
            // PtyChild.finish closes and reaps on every error path.
            self.finished = true;
            return err;
        };
        self.finished = true;
        return code;
    }
};

pub fn setupJournalZshWithPrefix(
    gpa: std.mem.Allocator,
    child: harness.PtyChild,
    out: *std.ArrayList(u8),
    prefix: []const u8,
) !void {
    var command: std.ArrayList(u8) = .empty;
    defer command.deinit(gpa);
    // `source -- file` is not portable across the zsh versions used by the
    // native CI runners. The POSIX dot builtin accepts the quoted pathname.
    if (prefix.len > 0) {
        try command.appendSlice(gpa, prefix);
        try command.appendSlice(gpa, "; ");
    }
    try command.appendSlice(gpa, ". ");
    try appendShellQuoted(gpa, &command, options.plugin);
    // Keep the literal marker out of the echoed setup command, so waiting for
    // it can only match the real prompt after the plugin finished loading.
    try command.appendSlice(gpa, " || exit; PS1='TJ_TEST_'PROMPT'> '\n");
    try child.write(command.items);
    if (!try child.readUntil(gpa, out, test_prompt, timeout_ms)) return error.ShellNotReady;
}

pub fn setupJournalZsh(gpa: std.mem.Allocator, child: harness.PtyChild, out: *std.ArrayList(u8)) !void {
    return setupJournalZshWithPrefix(gpa, child, out, "");
}

/// Cancels an editable ZLE line and proves that the shell accepted a new
/// command afterward. Waiting for the ordinary prompt is insufficient here:
/// completion redraws that same prompt before the cancellation is processed.
pub fn cancelZleLine(gpa: std.mem.Allocator, child: harness.PtyChild, out: *std.ArrayList(u8)) !void {
    const from = out.items.len;
    // Clear the line with a plain ZLE binding rather than Ctrl-C. While the
    // completion system is running the shell's terminal still raises SIGINT,
    // and the interrupt discards bytes zsh has already read - including the
    // first character of the command typed right behind it.
    try child.write("\x15");
    // Split the marker in the typed command so terminal echo cannot satisfy
    // the wait; only the executed print produces the contiguous text.
    try child.write("print -r -- TJ_ZLE_CANCEL_\"\"READY\n");
    if (!try child.readUntilFrom(gpa, out, from, "TJ_ZLE_CANCEL_READY", timeout_ms)) {
        std.debug.print("ZLE cancellation did not execute its readiness command; transcript follows:\n{s}\n", .{out.items[from..]});
        return error.ZleCancellationDidNotFinish;
    }
    if (!try child.readUntilFrom(gpa, out, from, test_prompt, timeout_ms)) {
        std.debug.print("ZLE cancellation did not return a prompt; transcript follows:\n{s}\n", .{out.items[from..]});
        return error.ZleCancellationPromptMissing;
    }
}

pub fn haveZsh() bool {
    const io = std.testing.io;
    const file = Dir.cwd().openFile(io, "/bin/zsh", .{}) catch return false;
    file.close(io);
    return true;
}

pub fn fishExecutable() ?[]const u8 {
    const io = std.testing.io;
    for ([_][]const u8{ "/usr/bin/fish", "/usr/local/bin/fish", "/opt/homebrew/bin/fish" }) |path| {
        const file = Dir.cwd().openFile(io, path, .{}) catch continue;
        file.close(io);
        return path;
    }
    return null;
}

pub fn fishSupportsNativeMarkers() bool {
    const fish = fishExecutable() orelse return false;
    const result = std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = &.{ fish, "--version" },
        .stdout_limit = .limited(256),
        .stderr_limit = .limited(256),
    }) catch return false;
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return false;

    const prefix = "fish, version ";
    if (!std.mem.startsWith(u8, result.stdout, prefix)) return false;
    const version = std.mem.trim(u8, result.stdout[prefix.len..], " \r\n");
    const dot = std.mem.indexOfScalar(u8, version, '.') orelse return false;
    const major = std.fmt.parseInt(u32, version[0..dot], 10) catch return false;
    return major >= 4;
}

pub fn spawnJournalFish(gpa: std.mem.Allocator, journal: *const Journal) !harness.PtyChild {
    const fish = fishExecutable() orelse return error.FishNotFound;
    leaveJournal();
    const home = try journal.homeArg(gpa);
    defer gpa.free(home);

    var init: std.ArrayList(u8) = .empty;
    defer init.deinit(gpa);
    try init.appendSlice(gpa, "source ");
    try appendFishQuoted(gpa, &init, options.fish_plugin);
    try init.appendSlice(gpa, "; function tj; command $TJ $argv; end; function fish_prompt; printf 'TJ_TEST_'PROMPT'> '; end");

    return spawnTjctl(gpa, &.{ tjctl, "--home", home, "new", "--", "/usr/bin/env", "TERM=xterm-256color", "fish_features=no-query-term", fish, "--no-config", "--interactive", "--init-command", init.items }, 24, 80);
}

pub fn appendFishQuoted(gpa: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    try out.append(gpa, '\'');
    for (text) |byte| {
        if (byte == '\'') try out.appendSlice(gpa, "\\'") else try out.append(gpa, byte);
    }
    try out.append(gpa, '\'');
}

pub fn setupJournalFish(gpa: std.mem.Allocator, child: harness.PtyChild, out: *std.ArrayList(u8)) !void {
    if (!try child.readUntil(gpa, out, test_prompt, timeout_ms)) {
        std.debug.print("Fish setup did not reach a prompt; transcript follows:\n{s}\n", .{out.items});
        return error.ShellNotReady;
    }
}

/// Runs `script` line by line in an interactive zsh under tj, then exits.
pub fn recordJournal(gpa: std.mem.Allocator, journal: *Journal, script: []const []const u8) !void {
    const child = try spawnJournalZsh(gpa, journal);
    var terminal = TerminalSession.init(gpa, child);
    defer terminal.deinit();

    try setupJournalZsh(gpa, child, &terminal.transcript);
    for (script) |line| try terminal.command(line);
    try terminal.write("exit 0\n");
    try std.testing.expectEqual(@as(u8, 0), try terminal.finish());
    const recorded = journal.journalName(gpa) catch |err| {
        std.debug.print("journal was not retained; transcript follows:\n{s}\n", .{terminal.transcript.items});
        return err;
    };
    gpa.free(recorded);
}

/// A journal directory with no shell integration pointed at it, for testing
/// what a new journal writer leaves behind.
pub const Scratch = struct {
    tmp: std.testing.TmpDir,
    path_len: usize,
    path_buf: [std.fs.max_path_bytes]u8,

    pub fn open() !Scratch {
        var self: Scratch = .{
            .tmp = std.testing.tmpDir(.{ .iterate = true }),
            .path_len = 0,
            .path_buf = undefined,
        };
        self.path_len = try self.tmp.dir.realPath(std.testing.io, &self.path_buf);
        return self;
    }

    pub fn path(self: *const Scratch) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    pub fn close(self: *Scratch) void {
        self.tmp.cleanup();
    }

    pub fn makeJournal(self: *Scratch, id: journal_name.Legacy, entries: []const []const u8) !void {
        return self.makeNamedJournal(&id, entries);
    }

    pub fn makeNamedJournal(self: *Scratch, name: []const u8, entries: []const []const u8) !void {
        const io = std.testing.io;
        try self.tmp.dir.createDir(io, name, @enumFromInt(0o700));
        var dir = try self.tmp.dir.openDir(io, name, .{});
        defer dir.close(io);
        for (entries) |entry| try dir.createDir(io, entry, @enumFromInt(0o700));
    }

    /// How many journal directories the root holds.
    pub fn journals(self: *Scratch) !usize {
        var count: usize = 0;
        var it = self.tmp.dir.iterate();
        while (try it.next(std.testing.io)) |entry| {
            if (entry.kind == .directory and journal_name.isValid(entry.name)) count += 1;
        }
        return count;
    }
};

/// Emits the OSC ELLO sequences a cooperating program would, from a plain sh
/// script, so the test does not depend on any program that happens to.
pub fn publisher(gpa: std.mem.Allocator, body: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "printf '{s}'", .{body});
}

pub fn expectSafeStoredReport(bytes: []const u8) !void {
    try std.testing.expect(std.mem.indexOfScalar(u8, bytes, 0x1b) == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, bytes, '\r') == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, bytes, 0x01) == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, bytes, 0x7f) == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, bytes, 0x9b) == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "PWNED") == null);
}
