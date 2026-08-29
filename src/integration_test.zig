//! End-to-end tests for the proxy. Each one drives the real `tj` binary
//! through a pty, the same way a terminal emulator does.
//!
//! The claim under test is transparency: a program running under `tj` must not
//! be able to tell, and the user's terminal must be handed back untouched.

const std = @import("std");
const posix = std.posix;
const harness = @import("harness.zig");
const noout = @import("noout.zig");
const plain = @import("plain.zig");
const ulid = @import("ulid.zig");

const options = @import("build_options");
const tj = options.tj_exe;

const timeout_ms = 5000;
const test_prompt = "TJ_TEST_PROMPT> ";
const journal_dir = "journal home *$'quoted";

/// Tests start real writer processes, each attached to a journal. Point every
/// child at a scratch one: a test run must not leave anything in the journal
/// the developer is actually using.
var journal_isolated = false;

fn isolateJournal() void {
    // Once only. Tests that set TJ_JOURNAL themselves, to make `@N` resolve
    // against a journal they built, must not have it taken away again.
    if (journal_isolated) return;
    journal_isolated = true;

    sys.setEnv("TJ_HOME", ".zig-cache/tj-test-home");
    // Inherited from the developer's environment otherwise, which would make
    // `@N` resolve against whatever journal they happen to be writing.
    sys.setEnv("TJ_JOURNAL", "");
    sys.setEnv("TJ_NEXT", "");
}

/// Tests share one process, so a test that selected a journal leaves
/// TJ_JOURNAL set for whatever runs next. Replay refuses to run inside a
/// journal writer, so its tests have to say they are outside one.
fn leaveJournal() void {
    isolateJournal();
    sys.setEnv("TJ_JOURNAL", "");
}

fn spawnTj(gpa: std.mem.Allocator, args: []const []const u8, rows: u16, cols: u16) !harness.PtyChild {
    isolateJournal();
    return harness.spawn(gpa, args, rows, cols);
}

fn run(gpa: std.mem.Allocator, args: []const []const u8, rows: u16, cols: u16) !struct {
    out: std.ArrayList(u8),
    code: u8,
} {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, tj);
    try argv.appendSlice(gpa, args);

    const child = try spawnTj(gpa, argv.items, rows, cols);
    var out: std.ArrayList(u8) = .empty;
    const code = try child.finish(gpa, &out, timeout_ms);
    return .{ .out = out, .code = code };
}

fn runNonTty(gpa: std.mem.Allocator, args: []const []const u8) !std.process.RunResult {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, tj);
    try argv.appendSlice(gpa, args);
    return std.process.run(gpa, std.testing.io, .{
        .argv = argv.items,
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
    });
}

fn runWithClosedStdout(gpa: std.mem.Allocator, args: []const []const u8) !struct {
    term: std.process.Child.Term,
    stderr: []u8,
} {
    isolateJournal();
    const io = std.testing.io;

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, tj);
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

fn runNonTtyInJournal(
    gpa: std.mem.Allocator,
    args: []const []const u8,
    journal: []const u8,
    next: []const u8,
) !std.process.RunResult {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, tj);
    try argv.appendSlice(gpa, args);
    var environ = try std.process.Environ.createMap(std.testing.environ, gpa);
    defer environ.deinit();
    try environ.put("TJ_JOURNAL", journal);
    try environ.put("TJ_NEXT", next);
    // The native command must not depend on the optional ripgrep companion.
    try environ.put("PATH", "");
    try environ.put("GREP_COLORS", "mt=01;31");
    return std.process.run(gpa, std.testing.io, .{
        .argv = argv.items,
        .environ_map = &environ,
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
    });
}

test "application and every command expose generated help" {
    const gpa = std.testing.allocator;
    leaveJournal();

    const root_cases = [_][]const []const u8{ &.{}, &.{"--help"} };
    for (root_cases) |args| {
        const result = try runNonTty(gpa, args);
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        try std.testing.expectEqual(@as(u8, 0), result.term.exited);
        try std.testing.expectEqualStrings("", result.stderr);
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Usage: tj [options] <command>") != null);
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Commands:") != null);
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, "hist, history") != null);
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, "--home <DIR>") != null);
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, "@pgsd.42/out") != null);
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, "source /path/to/tj.plugin.zsh") != null);
    }

    const command_names = [_][]const u8{
        "new",     "continue", "noout", "hist",   "usage",   "journal",
        "current", "last",     "cat",   "replay", "resolve", "complete",
        "name",    "tag",      "pin",   "rm",     "grep",
    };
    for (command_names) |name| {
        const result = try runNonTty(gpa, &.{ name, "--help" });
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        try std.testing.expectEqual(@as(u8, 0), result.term.exited);
        try std.testing.expectEqualStrings("", result.stderr);
        const usage = try std.fmt.allocPrint(gpa, "Usage: tj {s}", .{name});
        defer gpa.free(usage);
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, usage) != null);
    }

    const alias = try runNonTty(gpa, &.{ "history", "--help" });
    defer gpa.free(alias.stdout);
    defer gpa.free(alias.stderr);
    try std.testing.expectEqual(@as(u8, 0), alias.term.exited);
    try std.testing.expect(std.mem.indexOf(u8, alias.stdout, "Usage: tj hist") != null);

    const grep = try runNonTty(gpa, &.{ "grep", "--help" });
    defer gpa.free(grep.stdout);
    defer gpa.free(grep.stderr);
    try std.testing.expect(std.mem.indexOf(u8, grep.stdout, "Arguments:") != null);
    try std.testing.expect(std.mem.indexOf(u8, grep.stdout, "Options:") != null);
    try std.testing.expect(std.mem.indexOf(u8, grep.stdout, "--color, --colour <WHEN>") != null);
    try std.testing.expect(std.mem.indexOf(u8, grep.stdout, "choices: never, auto, always") != null);
    try std.testing.expect(std.mem.indexOf(u8, grep.stdout, "default: never") != null);
}

test "a closed stdout pipe exits quietly" {
    const gpa = std.testing.allocator;

    var scratch = try Scratch.open();
    defer scratch.close();
    const large = try gpa.alloc(u8, 1024 * 1024);
    defer gpa.free(large);
    @memset(large, 'x');
    large[0..6].* = "first\n".*;
    try scratch.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "large-output", .data = large });
    const large_path = try std.fmt.allocPrint(gpa, "{s}/large-output", .{scratch.path()});
    defer gpa.free(large_path);

    const cases = [_][]const []const u8{
        &.{"--help"},
        &.{"--version"},
        &.{ "hist", "--help" },
        &.{ "cat", "--raw", large_path },
    };
    for (cases) |args| {
        const result = try runWithClosedStdout(gpa, args);
        defer gpa.free(result.stderr);
        try std.testing.expectEqual(@as(u8, 0), result.term.exited);
        try std.testing.expectEqualStrings("", result.stderr);
    }
}

test "build-time completions expose cli grammar and journal references" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const bash = try Dir.cwd().readFileAlloc(io, options.bash_completion, gpa, .limited(1 << 20));
    defer gpa.free(bash);
    try std.testing.expect(std.mem.indexOf(u8, bash, "complete -F _tj tj") != null);
    try std.testing.expect(std.mem.indexOf(u8, bash, "_tj__cmd_hist()") != null);
    try std.testing.expect(std.mem.indexOf(u8, bash, "_tj__cmd_ls()") == null);
    try std.testing.expect(std.mem.indexOf(u8, bash, "--tag") != null);
    try std.testing.expect(std.mem.indexOf(u8, bash, "never\\nauto\\nalways") != null);

    const zsh = try Dir.cwd().readFileAlloc(io, options.zsh_completion, gpa, .limited(1 << 20));
    defer gpa.free(zsh);
    try std.testing.expect(std.mem.startsWith(u8, zsh, "#compdef tj\n"));
    try std.testing.expect(std.mem.indexOf(u8, zsh, "'hist:List entries with annotations, size, and date'") != null);
    try std.testing.expect(std.mem.indexOf(u8, zsh, "_tj__cmd_hist()") != null);
    try std.testing.expect(std.mem.indexOf(u8, zsh, "_tj__cmd_usage()") != null);
    try std.testing.expect(std.mem.indexOf(u8, zsh, "--chart[Show every entry") != null);
    try std.testing.expect(std.mem.indexOf(u8, zsh, "--bytes[List exact entry bytes") != null);
    try std.testing.expect(std.mem.indexOf(u8, zsh, "_tj__cmd_ls()") == null);
    try std.testing.expect(std.mem.indexOf(u8, zsh, "--tag=[") != null);
    try std.testing.expect(std.mem.indexOf(u8, zsh, "--pinned") != null);
    try std.testing.expect(std.mem.indexOf(u8, zsh, "--pin") != null);
    try std.testing.expect(std.mem.indexOf(u8, zsh, "--no-replay[") != null);
    try std.testing.expect(std.mem.indexOf(u8, zsh, "WHEN:(never auto always)") != null);
    try std.testing.expect(std.mem.indexOf(u8, zsh, ":ACTION:(list rm)") != null);

    const fish = try Dir.cwd().readFileAlloc(io, options.fish_completion, gpa, .limited(1 << 20));
    defer gpa.free(fish);
    try std.testing.expect(std.mem.startsWith(u8, fish, "# fish completion for tj\n"));
    try std.testing.expect(std.mem.indexOf(u8, fish, "-a 'hist' -d 'List entries with annotations, size, and date'") != null);
    try std.testing.expect(std.mem.indexOf(u8, fish, "-a 'ls'") == null);
    try std.testing.expect(std.mem.indexOf(u8, fish, "__tj_using_command hist history") != null);
    try std.testing.expect(std.mem.indexOf(u8, fish, "__tj_vals_cmd_grep_f_color") != null);
    try std.testing.expect(std.mem.indexOf(u8, fish, "__tj_vals_cmd_journal_a_ACTION") != null);

    // Positional entry-reference slots use the same runtime resolver as the
    // plugin's global shorthand completion.
    for ([_][]const u8{ bash, zsh, fish }) |script| {
        try std.testing.expect(std.mem.indexOf(u8, script, "'tj' 'complete'") != null);
    }
}

test "schema errors use status two and command help" {
    const gpa = std.testing.allocator;
    leaveJournal();

    const cases = [_]struct {
        args: []const []const u8,
        diagnostic: []const u8,
        usage: []const u8,
    }{
        .{ .args = &.{ "journal", "list", "extra" }, .diagnostic = "invalid arguments", .usage = "Usage: tj journal" },
        .{ .args = &.{ "rm", "--journal", "abcd" }, .diagnostic = "unknown option", .usage = "Usage: tj rm" },
        .{ .args = &.{ "grep", "--unknown", "x" }, .diagnostic = "unknown option", .usage = "Usage: tj grep" },
        .{ .args = &.{ "cat", "--head" }, .diagnostic = "requires <N>", .usage = "Usage: tj cat" },
        .{ .args = &.{"resolve"}, .diagnostic = "missing required argument", .usage = "Usage: tj resolve" },
        .{ .args = &.{ "complete", "@1", "@2" }, .diagnostic = "too many arguments", .usage = "Usage: tj complete" },
        .{ .args = &.{ "usage", "extra" }, .diagnostic = "too many arguments", .usage = "Usage: tj usage" },
        .{ .args = &.{ "grep", "--color=sometimes", "x" }, .diagnostic = "invalid value", .usage = "Usage: tj grep" },
    };
    for (cases) |case| {
        const result = try runNonTty(gpa, case.args);
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        try std.testing.expectEqual(@as(u8, 2), result.term.exited);
        try std.testing.expectEqualStrings("", result.stdout);
        try std.testing.expect(std.mem.indexOf(u8, result.stderr, case.diagnostic) != null);
        try std.testing.expect(std.mem.indexOf(u8, result.stderr, case.usage) != null);
    }
}

/// Drains a large PTY transcript without retaining bytes that precede its
/// final marker. This keeps the large-file regression honest about memory.
fn finishKeepingTail(
    gpa: std.mem.Allocator,
    child: harness.PtyChild,
    keep: usize,
    timeout: i32,
) !struct { tail: std.ArrayList(u8), total: u64, code: u8 } {
    var tail: std.ArrayList(u8) = .empty;
    errdefer tail.deinit(gpa);
    var total: u64 = 0;
    var remaining = timeout;
    var buf: [64 * 1024]u8 = undefined;

    while (remaining > 0) {
        var fds = [_]posix.pollfd{.{ .fd = child.master, .events = posix.POLL.IN, .revents = 0 }};
        const step: i32 = 100;
        const ready = posix.poll(&fds, step) catch break;
        if (ready == 0) {
            remaining -= step;
            continue;
        }
        const n = sys.read(child.master, &buf) catch 0;
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
    return .{ .tail = tail, .total = total, .code = sys.waitFor(child.pid).code };
}

test "exit status of the wrapped command is tj's exit status" {
    const gpa = std.testing.allocator;
    for ([_]u8{ 0, 3, 42 }) |want| {
        var script_buf: [32]u8 = undefined;
        const script = try std.fmt.bufPrint(&script_buf, "exit {d}", .{want});
        var r = try run(gpa, &.{ "new", "--", "/bin/sh", "-c", script }, 24, 80);
        defer r.out.deinit(gpa);
        try std.testing.expectEqual(want, r.code);
    }
}

test "a command killed by a signal reports 128+signal" {
    const gpa = std.testing.allocator;
    var r = try run(gpa, &.{ "new", "--", "/bin/sh", "-c", "kill -TERM $$" }, 24, 80);
    defer r.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 128 + 15), r.code);
}

test "the outer window size reaches the wrapped command" {
    const gpa = std.testing.allocator;
    var r = try run(gpa, &.{ "new", "--", "/bin/sh", "-c", "stty size" }, 31, 113);
    defer r.out.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, r.out.items, "31 113") != null);
}

test "the wrapped command sees a tty" {
    const gpa = std.testing.allocator;
    var r = try run(gpa, &.{ "new", "--", "/bin/sh", "-c", "test -t 0 && test -t 1 && echo ISTTY" }, 24, 80);
    defer r.out.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, r.out.items, "ISTTY") != null);
}

test "a command that cannot be executed exits 127" {
    const gpa = std.testing.allocator;
    var r = try run(gpa, &.{ "new", "--", "/nonexistent/program" }, 24, 80);
    defer r.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 127), r.code);
}

test "input typed at the outer terminal reaches the shell" {
    const gpa = std.testing.allocator;
    const child = try spawnTj(gpa, &.{ tj, "new", "--", "/bin/sh" }, 24, 80);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    try child.write("echo ROUNDTRIP-$((6*7))\n");
    _ = try child.readUntil(gpa, &out, "ROUNDTRIP-42", timeout_ms);
    try child.write("exit\n");
    _ = try child.finish(gpa, &out, timeout_ms);

    try std.testing.expect(std.mem.indexOf(u8, out.items, "ROUNDTRIP-42") != null);
}

test "resizing the outer terminal resizes the inner one" {
    const gpa = std.testing.allocator;
    const child = try spawnTj(
        gpa,
        &.{ tj, "new", "--", "/bin/sh", "-c", "trap 'stty size; exit 0' WINCH; echo READY; while :; do sleep 1; done" },
        24,
        80,
    );
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    try std.testing.expect(try child.readUntil(gpa, &out, "READY", timeout_ms));
    const from = out.items.len;
    try child.resize(40, 100);
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, "40 100", timeout_ms));
    _ = try child.finish(gpa, &out, timeout_ms);

    try std.testing.expect(std.mem.indexOf(u8, out.items, "40 100") != null);
}

test "signals sent to tj are forwarded to the shell" {
    const gpa = std.testing.allocator;
    const child = try spawnTj(
        gpa,
        &.{ tj, "new", "--", "/bin/sh", "-c", "trap 'echo GOTTERM; exit 9' TERM; echo READY; while :; do sleep 1; done" },
        24,
        80,
    );
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    try std.testing.expect(try child.readUntil(gpa, &out, "READY", timeout_ms));
    // A shell that defers traps until its foreground child finishes must not
    // need longer than the test budget to get there, so the shell sleeps in
    // short steps instead of one long one.
    const from = out.items.len;
    _ = std.c.kill(child.pid, posix.SIG.TERM);
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, "GOTTERM", timeout_ms));
    _ = try child.finish(gpa, &out, timeout_ms);
}

test "the terminal is raw while tj is active and restored afterwards" {
    const gpa = std.testing.allocator;
    const child = try spawnTj(gpa, &.{options.selftest_exe}, 24, 80);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const code = try child.finish(gpa, &out, timeout_ms);
    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "RAW=yes") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "RESTORED=yes") != null);
}

// --- recording --------------------------------------------------------------

const Io = std.Io;
const Dir = std.Io.Dir;
const sys = @import("sys.zig");

/// A zsh child process under tj, with the plugin loaded.
const Journal = struct {
    tmp: std.testing.TmpDir,
    // A length, not a slice: the struct is returned by value, and a slice into
    // its own buffer would point at the caller's dead stack frame.
    path_len: usize,
    path_buf: [std.fs.max_path_bytes]u8,

    fn path(self: *const Journal) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    fn open(_: std.mem.Allocator) !Journal {
        var self: Journal = .{
            .tmp = std.testing.tmpDir(.{}),
            .path_len = 0,
            .path_buf = undefined,
        };
        const io = std.testing.io;

        const len = try self.tmp.dir.realPath(io, &self.path_buf);

        try self.tmp.dir.createDirPath(io, journal_dir);

        self.path_len = len;
        return self;
    }

    /// Writes a fixture next to the journal and returns its absolute path.
    fn fixture(self: *const Journal, gpa: std.mem.Allocator, name: []const u8, bytes: []const u8) ![]const u8 {
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = bytes });
        return std.fmt.allocPrint(gpa, "{s}/{s}", .{ self.path(), name });
    }

    fn homeArg(self: *const Journal, gpa: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(gpa, "{s}/{s}", .{ self.path(), journal_dir });
    }

    fn close(self: *Journal) void {
        self.tmp.cleanup();
    }

    /// The id of the single journal this writer created.
    fn journalName(self: *Journal, gpa: std.mem.Allocator) ![]u8 {
        const io = std.testing.io;
        var root = try self.tmp.dir.openDir(io, journal_dir, .{ .iterate = true });
        defer root.close(io);
        var it = root.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind == .directory and ulid.isValid(entry.name)) return gpa.dupe(u8, entry.name);
        }
        return error.NoJournal;
    }

    /// Makes `@N` and `@-` resolve against this journal.
    fn enter(self: *Journal, gpa: std.mem.Allocator) !void {
        const name = try self.journalName(gpa);
        defer gpa.free(name);
        var buf: [64]u8 = undefined;
        @memcpy(buf[0..name.len], name);
        buf[name.len] = 0;
        sys.setEnv("TJ_JOURNAL", buf[0..name.len :0]);
    }

    /// The single journal directory this writer created.
    fn journalDir(self: *Journal) !Dir {
        const io = std.testing.io;
        var root = try self.tmp.dir.openDir(io, journal_dir, .{ .iterate = true });
        defer root.close(io);
        var it = root.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind == .directory and ulid.isValid(entry.name)) return root.openDir(io, entry.name, .{});
        }
        return error.NoJournal;
    }

    fn read(self: *Journal, gpa: std.mem.Allocator, sub_path: []const u8) ![]u8 {
        var child = try self.journalDir();
        defer child.close(std.testing.io);
        return child.readFileAlloc(std.testing.io, sub_path, gpa, .limited(1 << 20));
    }
};

/// Starts zsh with every startup file disabled. The fixture loads exactly the
/// plugin it needs through the PTY, so system zsh configuration cannot change
/// the prompt or install competing hooks.
fn spawnJournalZsh(gpa: std.mem.Allocator, journal: *const Journal) !harness.PtyChild {
    const home = try journal.homeArg(gpa);
    defer gpa.free(home);
    return spawnTj(gpa, &.{ tj, "--home", home, "new", "--", "/bin/zsh", "-f", "-i" }, 24, 80);
}

fn spawnContinuedJournalZsh(
    gpa: std.mem.Allocator,
    journal: *const Journal,
    selector: []const u8,
) !harness.PtyChild {
    const home = try journal.homeArg(gpa);
    defer gpa.free(home);
    return spawnTj(gpa, &.{ tj, "--home", home, "continue", selector, "--", "/bin/zsh", "-f", "-i" }, 24, 80);
}

fn appendShellQuoted(gpa: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
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

fn setupJournalZshWithPrefix(
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

fn setupJournalZsh(gpa: std.mem.Allocator, child: harness.PtyChild, out: *std.ArrayList(u8)) !void {
    return setupJournalZshWithPrefix(gpa, child, out, "");
}

/// Cancels an editable ZLE line and proves that the shell accepted a new
/// command afterward. Waiting for the ordinary prompt is insufficient here:
/// completion redraws that same prompt before the cancellation is processed.
fn cancelZleLine(gpa: std.mem.Allocator, child: harness.PtyChild, out: *std.ArrayList(u8)) !void {
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

fn haveZsh() bool {
    const io = std.testing.io;
    const file = Dir.cwd().openFile(io, "/bin/zsh", .{}) catch return false;
    file.close(io);
    return true;
}

/// Runs `script` line by line in an interactive zsh under tj, then exits.
fn recordJournal(gpa: std.mem.Allocator, journal: *Journal, script: []const []const u8) !void {
    const child = try spawnJournalZsh(gpa, journal);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    try setupJournalZsh(gpa, child, &out);
    for (script) |line| {
        const from = out.items.len;
        try child.write(line);
        try child.write("\n");
        if (!try child.readUntilFrom(gpa, &out, from, test_prompt, timeout_ms)) return error.CommandDidNotFinish;
    }
    try child.write("exit 0\n");
    try std.testing.expectEqual(@as(u8, 0), try child.finish(gpa, &out, timeout_ms));
    const recorded = journal.journalName(gpa) catch |err| {
        std.debug.print("journal was not retained; transcript follows:\n{s}\n", .{out.items});
        return err;
    };
    gpa.free(recorded);
}

test "commands are recorded as cmd, out and rc" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try Journal.open(gpa);
    defer journal.close();

    try recordJournal(gpa, &journal, &.{ "echo hello-journal", "false" });

    const first_cmd = try journal.read(gpa, "1/cmd");
    defer gpa.free(first_cmd);
    try std.testing.expectEqualStrings("echo hello-journal", first_cmd);

    const first_out = try journal.read(gpa, "1/out");
    defer gpa.free(first_out);
    try std.testing.expect(std.mem.indexOf(u8, first_out, "hello-journal") != null);

    const first_rc = try journal.read(gpa, "1/rc");
    defer gpa.free(first_rc);
    try std.testing.expectEqualStrings("0\n", first_rc);

    const second_cmd = try journal.read(gpa, "2/cmd");
    defer gpa.free(second_cmd);
    try std.testing.expectEqualStrings("false", second_cmd);

    const second_rc = try journal.read(gpa, "2/rc");
    defer gpa.free(second_rc);
    try std.testing.expectEqualStrings("1\n", second_rc);
}

test "each entry records the fully rendered zsh prompt" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try Journal.open(gpa);
    defer journal.close();
    // GitHub Actions does not guarantee a useful inherited TERM. Start zsh
    // with a known terminal description so this test exercises RPROMPT rather
    // than legitimately having zsh omit it for a dumb terminal.
    const home = try journal.homeArg(gpa);
    defer gpa.free(home);
    const child = try spawnTj(gpa, &.{
        tj, "--home", home, "new", "--", "/usr/bin/env", "TERM=xterm-256color", "/bin/zsh", "-f", "-i",
    }, 24, 80);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try setupJournalZsh(gpa, child, &out);

    // This stands in for prompt engines such as Starship: command and
    // parameter substitutions run while zsh renders a coloured, multiline
    // prompt with a right-hand side. TJ must retain those terminal bytes, not
    // the PROMPT source text and not a later re-evaluation of it.
    var from = out.items.len;
    try child.write("setopt promptsubst; PROMPT='%F{magenta}TJ_DYNAMIC_$(print -rn -- STARSHIP_LIKE)_${TJ_NEXT}%f\nTJ_SECOND> '; RPROMPT='TJ_RIGHT'\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, "TJ_DYNAMIC_STARSHIP_LIKE_2", timeout_ms));
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, "TJ_RIGHT", timeout_ms));

    from = out.items.len;
    try child.write("echo PROMPT_CAPTURE_BODY\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, "PROMPT_CAPTURE_BODY", timeout_ms));
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, "TJ_DYNAMIC_STARSHIP_LIKE_3", timeout_ms));
    try child.write("exit 0\n");
    try std.testing.expectEqual(@as(u8, 0), try child.finish(gpa, &out, timeout_ms));

    // Interaction 1 changes the prompt; interaction 2 is the command entered
    // at the rendered dynamic prompt whose TJ_NEXT value was 2.
    const prompt = try journal.read(gpa, "2/prompt");
    defer gpa.free(prompt);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "TJ_DYNAMIC_STARSHIP_LIKE_2") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "TJ_SECOND> ") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "TJ_RIGHT") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "\x1b[35m") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "$(print") == null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "PROMPT_CAPTURE_BODY") == null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "133;B") == null);
}

test "continue appends to the same journal at its next unused number" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try Journal.open(gpa);
    defer journal.close();
    try recordJournal(gpa, &journal, &.{"echo original-entry"});

    const name = try journal.journalName(gpa);
    defer gpa.free(name);
    const child = try spawnContinuedJournalZsh(gpa, &journal, name);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try setupJournalZsh(gpa, child, &out);

    const from = out.items.len;
    try child.write("echo continued-entry\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, test_prompt, timeout_ms));

    const env_from = out.items.len;
    try child.write("printf 'JENV=%s SHORT=%s NEXT=%s\\n' \"$TJ_JOURNAL\" \"$TJ_JOURNAL_SHORT\" \"$TJ_NEXT\"; command \"$TJ\" current\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, env_from, name, timeout_ms));
    var short_buf: [16]u8 = undefined;
    const expected_short = try std.fmt.bufPrint(&short_buf, "SHORT={s}", .{name[name.len - 4 ..]});
    try std.testing.expect(std.mem.indexOf(u8, out.items[env_from..], expected_short) != null);
    try std.testing.expect(try child.readUntilFrom(gpa, &out, env_from, test_prompt, timeout_ms));

    try child.write("exit 0\n");
    try std.testing.expectEqual(@as(u8, 0), try child.finish(gpa, &out, timeout_ms));

    const first = try journal.read(gpa, "1/cmd");
    defer gpa.free(first);
    const unfinished = try journal.read(gpa, "2/cmd");
    defer gpa.free(unfinished);
    const continued = try journal.read(gpa, "3/cmd");
    defer gpa.free(continued);
    try std.testing.expectEqualStrings("echo original-entry", first);
    try std.testing.expectEqualStrings("exit 0", unfinished);
    try std.testing.expectEqualStrings("echo continued-entry", continued);

    const home = try journal.homeArg(gpa);
    defer gpa.free(home);
    var listed = try run(gpa, &.{ "--home", home, "journal", "list" }, 24, 80);
    defer listed.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), listed.code);
    try std.testing.expect(std.mem.indexOf(u8, listed.out.items, name) != null);
}

test "new exports journal variables and removes the old environment contract" {
    const gpa = std.testing.allocator;
    var scratch = try Scratch.open();
    defer scratch.close();

    var r = try run(gpa, &.{
        "--home",
        scratch.path(),
        "new",
        "--",
        "/bin/sh",
        "-c",
        "printf 'J=%s N=%s\\n' \"$TJ_JOURNAL\" \"$TJ_NEXT\"; env | grep '^TJ_' | sort",
    }, 24, 80);
    defer r.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.out.items, " N=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out.items, "SESS" ++ "ION") == null);
}

test "continue preserves unfinished numbers and gaps" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var scratch = try Scratch.open();
    defer scratch.close();

    const id = ulid.encode(20, .{8} ** 10);
    try scratch.makeJournal(id, &.{ "1", "3" });
    const child = try spawnTj(gpa, &.{ tj, "--home", scratch.path(), "continue", &id, "--", "/bin/zsh", "-f", "-i" }, 24, 80);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try setupJournalZsh(gpa, child, &out);
    const from = out.items.len;
    try child.write("echo after-gap\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, test_prompt, timeout_ms));
    try child.write("exit 0\n");
    try std.testing.expectEqual(@as(u8, 0), try child.finish(gpa, &out, timeout_ms));

    var dir = try scratch.tmp.dir.openDir(io, &id, .{});
    defer dir.close(io);
    const cmd = try dir.readFileAlloc(io, "4/cmd", gpa, .limited(1024));
    defer gpa.free(cmd);
    try std.testing.expectEqualStrings("echo after-gap", cmd);
    var unfinished = try dir.openDir(io, "3", .{});
    unfinished.close(io);
}

test "tj's own control sequences never reach the terminal" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try Journal.open(gpa);
    defer journal.close();

    const child = try spawnJournalZsh(gpa, &journal);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    try setupJournalZsh(gpa, child, &out);
    const from = out.items.len;
    try child.write("echo marker\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, test_prompt, timeout_ms));
    try child.write("exit\n");
    try std.testing.expectEqual(@as(u8, 0), try child.finish(gpa, &out, timeout_ms));

    try std.testing.expect(std.mem.indexOf(u8, out.items, "marker") != null);
    // The command line travels inside a 5107 sequence; none of it may be shown.
    try std.testing.expect(std.mem.indexOf(u8, out.items, "5107") == null);
    // OSC 133 is another matter: it is forwarded, because the outer terminal
    // may implement shell integration itself.
    try std.testing.expect(std.mem.indexOf(u8, out.items, "133;") != null);
}

test "a command line with shell metacharacters survives the round trip" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try Journal.open(gpa);
    defer journal.close();

    // Semicolons would split the control sequence if it were not encoded.
    const tricky = "echo 'a;b' \"c;d\" | cat # trailing;comment";
    try recordJournal(gpa, &journal, &.{tricky});

    const recorded = try journal.read(gpa, "1/cmd");
    defer gpa.free(recorded);
    try std.testing.expectEqualStrings(tricky, recorded);
}

test "an interrupted writer leaves the entry without an rc" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try Journal.open(gpa);
    defer journal.close();

    const child = try spawnJournalZsh(gpa, &journal);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    try setupJournalZsh(gpa, child, &out);
    const from = out.items.len;
    try child.write("sleep 30\n");
    // The echoed input arrives before preexec. Wait for the plugin's command
    // boundary so the proxy has opened the interaction before interrupting it.
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, "133;C", timeout_ms));
    _ = std.c.kill(child.pid, posix.SIG.TERM);
    _ = try child.finish(gpa, &out, timeout_ms);

    const cmd = try journal.read(gpa, "1/cmd");
    defer gpa.free(cmd);
    try std.testing.expectEqualStrings("sleep 30", cmd);

    // No rc: readers must treat this as aborted, never as success.
    var dir = try journal.journalDir();
    defer dir.close(std.testing.io);
    try std.testing.expectError(error.FileNotFound, dir.openFile(std.testing.io, "1/rc", .{}));
}

test "entries record cwd and tjcd changes zsh without expanding its reference" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var journal = try Journal.open(gpa);
    defer journal.close();
    try journal.tmp.dir.createDir(io, "cwd target", @enumFromInt(0o700));
    const target = try std.fmt.allocPrint(gpa, "{s}/cwd target", .{journal.path()});
    defer gpa.free(target);

    const child = try spawnJournalZsh(gpa, &journal);
    var transcript: std.ArrayList(u8) = .empty;
    defer transcript.deinit(gpa);
    try setupJournalZsh(gpa, child, &transcript);

    var cd_command: std.ArrayList(u8) = .empty;
    defer cd_command.deinit(gpa);
    try cd_command.appendSlice(gpa, "cd ");
    try appendShellQuoted(gpa, &cd_command, target);
    try cd_command.append(gpa, '\n');
    var from = transcript.items.len;
    try child.write(cd_command.items);
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, test_prompt, timeout_ms));

    from = transcript.items.len;
    try child.write("print -r -- CWD_CAPTURE_BODY\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, "CWD_CAPTURE_BODY", timeout_ms));
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, test_prompt, timeout_ms));

    from = transcript.items.len;
    try child.write("cd /\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, test_prompt, timeout_ms));

    from = transcript.items.len;
    try child.write("tjcd @2\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, test_prompt, timeout_ms));

    const expected = try std.fmt.allocPrint(gpa, "TJCD_PWD={s}", .{target});
    defer gpa.free(expected);
    from = transcript.items.len;
    try child.write("print -r -- \"TJCD_PWD=$PWD\"\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, expected, timeout_ms));
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, test_prompt, timeout_ms));

    from = transcript.items.len;
    try child.write("cd /\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, test_prompt, timeout_ms));

    const compound = "tjcd @2 && print -r -- \"TJCD_COMPOUND=$PWD\"";
    const compound_expected = try std.fmt.allocPrint(gpa, "TJCD_COMPOUND={s}", .{target});
    defer gpa.free(compound_expected);
    from = transcript.items.len;
    try child.write(compound ++ "\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, compound_expected, timeout_ms));
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, test_prompt, timeout_ms));

    from = transcript.items.len;
    try child.write("cd /; tjcd ~[@2]; print -r -- \"TJCD_CANONICAL=$PWD\"\n");
    const canonical_expected = try std.fmt.allocPrint(gpa, "TJCD_CANONICAL={s}", .{target});
    defer gpa.free(canonical_expected);
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, canonical_expected, timeout_ms));
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, test_prompt, timeout_ms));

    try child.write("exit 0\n");
    try std.testing.expectEqual(@as(u8, 0), try child.finish(gpa, &transcript, timeout_ms));

    const recorded_target = try journal.read(gpa, "2/cwd");
    defer gpa.free(recorded_target);
    try std.testing.expectEqualStrings(target, recorded_target);
    const tjcd_cmd = try journal.read(gpa, "4/cmd");
    defer gpa.free(tjcd_cmd);
    try std.testing.expectEqualStrings("tjcd @2", tjcd_cmd);
    const tjcd_start = try journal.read(gpa, "4/cwd");
    defer gpa.free(tjcd_start);
    try std.testing.expectEqualStrings("/", tjcd_start);
    const after_tjcd = try journal.read(gpa, "5/cwd");
    defer gpa.free(after_tjcd);
    try std.testing.expectEqualStrings(target, after_tjcd);
    const compound_cmd = try journal.read(gpa, "7/cmd");
    defer gpa.free(compound_cmd);
    try std.testing.expectEqualStrings(compound, compound_cmd);

    // The lightweight function is defined even when recording hooks are
    // inactive, so a qualified reference works from an ordinary zsh too.
    const id = try journal.journalName(gpa);
    defer gpa.free(id);
    const home = try journal.homeArg(gpa);
    defer gpa.free(home);
    var outside_script: std.ArrayList(u8) = .empty;
    defer outside_script.deinit(gpa);
    try outside_script.appendSlice(gpa, ". ");
    try appendShellQuoted(gpa, &outside_script, options.plugin);
    try outside_script.appendSlice(gpa, "; tjcd ");
    const qualified = try std.fmt.allocPrint(gpa, "@{s}.2", .{id});
    defer gpa.free(qualified);
    try appendShellQuoted(gpa, &outside_script, qualified);
    try outside_script.appendSlice(gpa, " || exit; print -r -- \"OUTSIDE_TJCD=$PWD\"");
    var environ = try std.process.Environ.createMap(std.testing.environ, gpa);
    defer environ.deinit();
    try environ.put("TJ_HOME", home);
    try environ.put("TJ_JOURNAL", "");
    try environ.put("TJ", tj);
    const outside = try std.process.run(gpa, io, .{
        .argv = &.{ "/bin/zsh", "-f", "-c", outside_script.items },
        .environ_map = &environ,
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
    });
    defer gpa.free(outside.stdout);
    defer gpa.free(outside.stderr);
    try std.testing.expectEqual(@as(u8, 0), outside.term.exited);
    const outside_expected = try std.fmt.allocPrint(gpa, "OUTSIDE_TJCD={s}\n", .{target});
    defer gpa.free(outside_expected);
    try std.testing.expectEqualStrings(outside_expected, outside.stdout);
    try std.testing.expectEqualStrings("", outside.stderr);
}

// --- the journal namespace --------------------------------------------------

test "the tj zle hooks preserve existing widgets and register once" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try Journal.open(gpa);
    defer journal.close();

    const child = try spawnJournalZsh(gpa, &journal);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const prefix =
        "typeset -gi TJ_PRIOR_ACCEPT_COUNT=0; " ++
        "typeset -gi TJ_PRIOR_LINE_INIT_COUNT=0; " ++
        "_tj_prior_accept_line() { (( TJ_PRIOR_ACCEPT_COUNT++ )); zle .accept-line; }; " ++
        "_tj_prior_line_init() { (( TJ_PRIOR_LINE_INIT_COUNT++ )); }; " ++
        "zle -N accept-line _tj_prior_accept_line; " ++
        "zle -N zle-line-init _tj_prior_line_init";
    try setupJournalZshWithPrefix(gpa, child, &out, prefix);

    // Sourcing TJ again must neither replace the saved widget nor make TJ's
    // wrapper save and invoke itself recursively.
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(gpa);
    try source.appendSlice(gpa, ". ");
    try appendShellQuoted(gpa, &source, options.plugin);
    try source.append(gpa, '\n');
    var from = out.items.len;
    try child.write(source.items);
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, test_prompt, timeout_ms));

    from = out.items.len;
    try child.write("print -r -- TJ_PRIOR_ACCEPT_COUNT=$TJ_PRIOR_ACCEPT_COUNT TJ_PRIOR_LINE_INIT_COUNT=$TJ_PRIOR_LINE_INIT_COUNT\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, "TJ_PRIOR_ACCEPT_COUNT=2", timeout_ms));
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, "TJ_PRIOR_LINE_INIT_COUNT=2", timeout_ms));
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, test_prompt, timeout_ms));

    try child.write("exit 0\n");
    try std.testing.expectEqual(@as(u8, 0), try child.finish(gpa, &out, timeout_ms));
}

test "zsh preexec precedes dynamic named-directory expansion" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try Journal.open(gpa);
    defer journal.close();

    const child = try spawnJournalZsh(gpa, &journal);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try setupJournalZsh(gpa, child, &out);

    const from = out.items.len;
    try child.write("_tj_probe_directory_name() { if [[ $1 == n && $2 == @probe ]]; then print -r -- TJ_PROBE_DIRECTORY; typeset -ga reply; reply=(/tmp/tj-probe); return 0; fi; return 1; }; typeset -ga zsh_directory_name_functions; zsh_directory_name_functions+=(_tj_probe_directory_name)\n");
    try child.write("_tj_probe_preexec() { print -r -- \"TJ_PROBE_1=<$1>\"; print -r -- \"TJ_PROBE_2=<$2>\"; print -r -- \"TJ_PROBE_3=<$3>\"; }; add-zsh-hook preexec _tj_probe_preexec; alias tj_probe_alias='print -r --'\n");
    try child.write("tj_probe_alias ~[@probe]/out\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, "/tmp/tj-probe/out", timeout_ms));

    const transcript = out.items[from..];
    try std.testing.expect(std.mem.indexOf(u8, transcript, "TJ_PROBE_1=<tj_probe_alias ~[@probe]/out>") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "TJ_PROBE_2=<print -r -- ~[@probe]/out>") != null);
    const preexec_full = std.mem.indexOf(u8, transcript, "TJ_PROBE_3=<print -r -- ~[@probe]/out>") orelse return error.MissingPreexecProbe;
    const directory_call = std.mem.lastIndexOf(u8, transcript, "TJ_PROBE_DIRECTORY") orelse return error.MissingDirectoryProbe;
    try std.testing.expect(preexec_full < directory_call);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "/tmp/tj-probe/out") != null);

    try child.write("exit 0\n");
    try std.testing.expectEqual(@as(u8, 0), try child.finish(gpa, &out, timeout_ms));
}

test "the tj dynamic-directory handler composes and registers once" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try Journal.open(gpa);
    defer journal.close();

    const child = try spawnJournalZsh(gpa, &journal);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const prefix =
        "zsh_directory_name() { [[ $1 == n && $2 == @standalone ]] || return 1; typeset -ga reply; reply=(/tmp/standalone); }; " ++
        "_tj_existing_directory_name() { [[ $1 == n && $2 == @array ]] || return 1; typeset -ga reply; reply=(/tmp/array); }; " ++
        "typeset -ga zsh_directory_name_functions=(_tj_existing_directory_name)";
    try setupJournalZshWithPrefix(gpa, child, &out, prefix);

    var command: std.ArrayList(u8) = .empty;
    defer command.deinit(gpa);
    try command.appendSlice(gpa, ". ");
    try appendShellQuoted(gpa, &command, options.plugin);
    try command.appendSlice(
        gpa,
        "; typeset -i tj_handler_count=0; " ++
            "for tj_handler in \"${zsh_directory_name_functions[@]}\"; do [[ $tj_handler == _tj_directory_name ]] && (( tj_handler_count++ )); done; " ++
            "print -r -- \"TJ_HANDLERS=${(j:,:)zsh_directory_name_functions}\"; " ++
            "print -r -- \"TJ_HANDLER_COUNT=$tj_handler_count\"; " ++
            "print -rn -- TJ_STANDALONE=; print -r -- ~[@standalone]; " ++
            "print -rn -- TJ_ARRAY=; print -r -- ~[@array]; " ++
            "_tj_directory_name d /tmp; print -r -- \"TJ_D_STATUS=$?\"\n",
    );

    const from = out.items.len;
    try child.write(command.items);
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, "TJ_D_STATUS=1", timeout_ms));
    const transcript = out.items[from..];
    try std.testing.expect(std.mem.indexOf(u8, transcript, "TJ_HANDLERS=_tj_existing_directory_name,_tj_directory_name") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "TJ_HANDLER_COUNT=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "TJ_STANDALONE=/tmp/standalone") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "TJ_ARRAY=/tmp/array") != null);

    try child.write("exit 0\n");
    try std.testing.expectEqual(@as(u8, 0), try child.finish(gpa, &out, timeout_ms));
}

test "references resolve to paths inside the journal" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try Journal.open(gpa);
    defer journal.close();
    try recordJournal(gpa, &journal, &.{ "echo first", "echo second" });
    try journal.enter(gpa);

    const home = try journal.homeArg(gpa);
    defer gpa.free(home);

    var ok = try run(gpa, &.{ "--home", home, "resolve", "@1/out" }, 24, 80);
    defer ok.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), ok.code);
    try std.testing.expect(std.mem.indexOf(u8, ok.out.items, "/1/out") != null);
    try std.testing.expect(std.mem.startsWith(u8, ok.out.items, "/"));
}

test "a malformed reference and a missing one are told apart" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try Journal.open(gpa);
    defer journal.close();
    try recordJournal(gpa, &journal, &.{"echo only"});
    try journal.enter(gpa);

    const home = try journal.homeArg(gpa);
    defer gpa.free(home);

    // A valid interaction name that has not been assigned.
    var bad = try run(gpa, &.{ "--home", home, "resolve", "@nope" }, 24, 80);
    defer bad.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 2), bad.code);

    // Well formed, but there is no interaction 999.
    var missing = try run(gpa, &.{ "--home", home, "resolve", "@999/out" }, 24, 80);
    defer missing.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 2), missing.code);
}

test "names tags pins and tagged history use journal-local annotations" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try Journal.open(gpa);
    defer journal.close();
    try recordJournal(gpa, &journal, &.{ "echo first-entry", "false # second-entry" });
    try journal.enter(gpa);
    const home = try journal.homeArg(gpa);
    defer gpa.free(home);

    var named = try run(gpa, &.{ "--home", home, "name", "@1", "build-failure" }, 24, 100);
    defer named.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), named.code);

    var tagged = try run(gpa, &.{ "--home", home, "tag", "@1", "BUG", "parser", "bug" }, 24, 100);
    defer tagged.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), tagged.code);
    var second_tagged = try run(gpa, &.{ "--home", home, "tag", "@2", "bug" }, 24, 100);
    defer second_tagged.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), second_tagged.code);

    var pinned = try run(gpa, &.{ "--home", home, "pin", "@1" }, 24, 100);
    defer pinned.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), pinned.code);

    var names = try run(gpa, &.{ "--home", home, "name" }, 24, 100);
    defer names.out.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, names.out.items, "build-failure  @1") != null);

    var tags = try run(gpa, &.{ "--home", home, "tag", "@1" }, 24, 100);
    defer tags.out.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, tags.out.items, "@1  bug  parser") != null);

    var pins = try run(gpa, &.{ "--home", home, "pin" }, 24, 100);
    defer pins.out.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, pins.out.items, "@1") != null);

    var resolved = try run(gpa, &.{ "--home", home, "resolve", "@build-failure/out" }, 24, 100);
    defer resolved.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), resolved.code);
    try std.testing.expect(std.mem.indexOf(u8, resolved.out.items, "/1/out") != null);

    var completed = try run(gpa, &.{ "--home", home, "complete", "@build" }, 24, 100);
    defer completed.out.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, completed.out.items, "@build-failure") != null);

    var filtered = try run(gpa, &.{ "--home", home, "hist", "--tag", "bug", "--tag=parser" }, 24, 120);
    defer filtered.out.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, filtered.out.items, "first-entry") != null);
    try std.testing.expect(std.mem.indexOf(u8, filtered.out.items, "second-entry") == null);
    try std.testing.expect(std.mem.indexOf(u8, filtered.out.items, "@build-failure") != null);
    try std.testing.expect(std.mem.indexOf(u8, filtered.out.items, "*@#") != null);
    try std.testing.expect(std.mem.indexOf(u8, filtered.out.items, "#bug #parser") != null);
    try std.testing.expect(std.mem.indexOf(u8, filtered.out.items, "!1") == null);

    var history = try run(gpa, &.{ "--home", home, "hist" }, 24, 120);
    defer history.out.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, history.out.items, "false # second-entry") != null);
    try std.testing.expect(std.mem.indexOf(u8, history.out.items, "#bug") != null);
    try std.testing.expect(std.mem.indexOf(u8, history.out.items, "!1") != null);

    var pinned_hist = try run(gpa, &.{ "--home", home, "hist", "--pinned" }, 24, 120);
    defer pinned_hist.out.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, pinned_hist.out.items, "first-entry") != null);
    try std.testing.expect(std.mem.indexOf(u8, pinned_hist.out.items, "second-entry") == null);
    var pin_alias = try run(gpa, &.{ "--home", home, "hist", "--pin", "--tag", "bug" }, 24, 120);
    defer pin_alias.out.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, pin_alias.out.items, "first-entry") != null);
    try std.testing.expect(std.mem.indexOf(u8, pin_alias.out.items, "second-entry") == null);

    var duplicate = try run(gpa, &.{ "--home", home, "name", "@2", "build-failure" }, 24, 100);
    defer duplicate.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), duplicate.code);

    var untag = try run(gpa, &.{ "--home", home, "tag", "--remove", "@1", "missing", "parser" }, 24, 100);
    defer untag.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), untag.code);
    var unpin = try run(gpa, &.{ "--home", home, "pin", "--remove", "@1" }, 24, 100);
    defer unpin.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), unpin.code);
}

test "history wraps to terminal width and pipes remain one entry per line" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const command = "echo one two three four five six seven eight nine ten eleven twelve";

    var journal = try Journal.open(gpa);
    defer journal.close();
    try recordJournal(gpa, &journal, &.{command});
    try journal.enter(gpa);
    const home = try journal.homeArg(gpa);
    defer gpa.free(home);

    var wrapped = try run(gpa, &.{ "--home", home, "hist" }, 24, 48);
    defer wrapped.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), wrapped.code);
    const begin_at = std.mem.indexOf(u8, wrapped.out.items, noout.begin_marker) orelse return error.TestUnexpectedResult;
    const content_start = begin_at + noout.begin_marker.len;
    const end_at = std.mem.indexOfPos(u8, wrapped.out.items, content_start, noout.end_marker) orelse
        return error.TestUnexpectedResult;
    const visible = wrapped.out.items[content_start..end_at];
    try std.testing.expect(std.mem.indexOf(u8, visible, "\r\n") != null);
    var physical_lines = std.mem.splitScalar(u8, visible, '\n');
    while (physical_lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (line.len != 0) try std.testing.expect(line.len <= 48);
    }

    var empty = try run(gpa, &.{ "--home", home, "hist", "--tag", "not-present" }, 24, 48);
    defer empty.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), empty.code);
    try std.testing.expect(std.mem.indexOf(u8, empty.out.items, noout.begin_marker) == null);

    const id = try journal.journalName(gpa);
    defer gpa.free(id);
    const piped = try runNonTtyInJournal(gpa, &.{ "--home", home, "hist" }, id, "3");
    defer gpa.free(piped.stdout);
    defer gpa.free(piped.stderr);
    try std.testing.expectEqual(@as(u8, 0), piped.term.exited);
    try std.testing.expect(std.mem.indexOf(u8, piped.stdout, command) != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, piped.stdout, 0x1b) == null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.countScalar(u8, piped.stdout, '\n'));
    try std.testing.expect(std.mem.indexOf(u8, piped.stdout, noout.begin_marker) == null);
}

test "terminal history omits its listing while piped history remains recordable" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var journal = try Journal.open(gpa);
    defer journal.close();

    const child = try spawnJournalZsh(gpa, &journal);
    var transcript: std.ArrayList(u8) = .empty;
    defer transcript.deinit(gpa);
    try setupJournalZsh(gpa, child, &transcript);

    var from = transcript.items.len;
    try child.write("printf 'HIST_NOOUT_PAYLOAD_012\\n'\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, test_prompt, timeout_ms));

    from = transcript.items.len;
    try child.write("command \"$TJ\" hist\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, "HIST_NOOUT_PAYLOAD_012", timeout_ms));
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, test_prompt, timeout_ms));

    from = transcript.items.len;
    try child.write("command \"$TJ\" hist | cat\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, "HIST_NOOUT_PAYLOAD_012", timeout_ms));
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, test_prompt, timeout_ms));
    try child.write("exit 0\n");
    try std.testing.expectEqual(@as(u8, 0), try child.finish(gpa, &transcript, timeout_ms));

    const direct_out = try journal.read(gpa, "2/out");
    defer gpa.free(direct_out);
    try std.testing.expect(std.mem.indexOf(u8, direct_out, "<tj:noout>") != null);
    try std.testing.expect(std.mem.indexOf(u8, direct_out, "HIST_NOOUT_PAYLOAD_012") == null);
    try std.testing.expect(std.mem.indexOf(u8, direct_out, "5107;tj") == null);

    const piped_out = try journal.read(gpa, "3/out");
    defer gpa.free(piped_out);
    try std.testing.expect(std.mem.indexOf(u8, piped_out, "HIST_NOOUT_PAYLOAD_012") != null);
    try std.testing.expect(std.mem.indexOf(u8, piped_out, "<tj:noout>") == null);
    try std.testing.expect(std.mem.indexOf(u8, piped_out, "5107;tj") == null);
}

test "history shows positional annotation flags size UTC date and wrapped commands" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var journal = try Journal.open(gpa);
    defer journal.close();
    try recordJournal(gpa, &journal, &.{
        "printf 1234567890 # alpha beta gamma delta epsilon",
        "false",
    });
    try journal.enter(gpa);
    const home = try journal.homeArg(gpa);
    defer gpa.free(home);

    for ([_][]const []const u8{
        &.{ "name", "@1", "display-name" },
        &.{ "tag", "@1", "bug" },
        &.{ "pin", "@1" },
        &.{ "tag", "@2", "failure" },
    }) |command_args| {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.appendSlice(gpa, &.{ "--home", home });
        try argv.appendSlice(gpa, command_args);
        var result = try run(gpa, argv.items, 24, 100);
        defer result.out.deinit(gpa);
        try std.testing.expectEqual(@as(u8, 0), result.code);
    }

    var dir = try journal.journalDir();
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = "1/out", .data = "1234567890" });
    try dir.writeFile(io, .{ .sub_path = "2/out", .data = "" });
    try dir.writeFile(io, .{
        .sub_path = "1/meta.json",
        .data = "{\"v\":1,\"started\":\"2001-08-29T10:14:00.000Z\",\"ended\":\"2001-08-29T10:15:00.000Z\"}\n",
    });
    try dir.writeFile(io, .{
        .sub_path = "2/meta.json",
        .data = "{\"v\":1,\"started\":\"2002-03-14T09:00:00.000Z\",\"ended\":\"2002-03-14T09:01:00.000Z\"}\n",
    });

    const id = try journal.journalName(gpa);
    defer gpa.free(id);
    const plain_result = try runNonTtyInJournal(gpa, &.{ "--home", home, "hist" }, id, "4");
    defer gpa.free(plain_result.stdout);
    defer gpa.free(plain_result.stderr);
    try std.testing.expectEqual(@as(u8, 0), plain_result.term.exited);
    try std.testing.expect(std.mem.indexOf(u8, plain_result.stdout, "*@#  1   10b Aug 29  2001 printf 1234567890 # alpha beta gamma delta epsilon @display-name #bug\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain_result.stdout, "  #! 2    0b Mar 14  2002 false #failure !1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain_result.stdout, noout.begin_marker) == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, plain_result.stdout, 0x1b) == null);

    const terminal_child = try spawnTj(gpa, &.{
        "/usr/bin/env", "-u", "NO_COLOR", "TERM=xterm-256color", tj, "--home", home, "hist",
    }, 24, 48);
    var terminal: std.ArrayList(u8) = .empty;
    defer terminal.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), try terminal_child.finish(gpa, &terminal, timeout_ms));
    const begin_at = std.mem.indexOf(u8, terminal.items, noout.begin_marker) orelse return error.TestUnexpectedResult;
    const content_start = begin_at + noout.begin_marker.len;
    const end_at = std.mem.indexOfPos(u8, terminal.items, content_start, noout.end_marker) orelse
        return error.TestUnexpectedResult;
    const visible = terminal.items[content_start..end_at];
    try std.testing.expect(std.mem.indexOf(u8, visible, "*@#  \x1b[33m1\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, visible, "  #\x1b[31m!\x1b[0m \x1b[33m2\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, visible, "\x1b[33m1\x1b[0m   \x1b[32m10b\x1b[0m \x1b[34mAug 29  2001\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, visible, "\x1b[32m@display-name\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, visible, "\x1b[32m#bug\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, visible, "\x1b[31m!1\x1b[0m") != null);
    const first_wrap = std.mem.indexOf(u8, visible, "\r\n") orelse return error.TestUnexpectedResult;
    const continuation = first_wrap + 2;
    try std.testing.expect(visible.len >= continuation + 23);
    for (visible[continuation .. continuation + 23]) |byte| try std.testing.expectEqual(@as(u8, ' '), byte);

    const pinned = try runNonTtyInJournal(gpa, &.{ "--home", home, "hist", "--pinned" }, id, "4");
    defer gpa.free(pinned.stdout);
    defer gpa.free(pinned.stderr);
    try std.testing.expect(std.mem.indexOf(u8, pinned.stdout, "display-name") != null);
    try std.testing.expect(std.mem.indexOf(u8, pinned.stdout, "false") == null);

    // Columns are fixed rather than fitted to whatever a filter matched, so a
    // narrowed listing lines up with the full one instead of shifting left.
    const whole_line = "*@#  1   10b Aug 29  2001 printf";
    try std.testing.expect(std.mem.indexOf(u8, plain_result.stdout, whole_line) != null);
    for ([_][]const []const u8{
        &.{ "--home", home, "hist", "--pinned" },
        &.{ "--home", home, "hist", "@1" },
        &.{ "--home", home, "hist", "@1..@1" },
    }) |args| {
        const narrowed = try runNonTtyInJournal(gpa, args, id, "4");
        defer gpa.free(narrowed.stdout);
        defer gpa.free(narrowed.stderr);
        try std.testing.expect(std.mem.indexOf(u8, narrowed.stdout, whole_line) != null);
    }
}

test "history accepts ordered entry ranges and trailing-dot journal selectors" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var journal = try Journal.open(gpa);
    defer journal.close();
    try recordJournal(gpa, &journal, &.{
        "echo HIST_TARGET_ONE",
        "echo HIST_TARGET_TWO",
        "echo HIST_TARGET_THREE",
        "echo HIST_TARGET_FOUR",
    });
    try journal.enter(gpa);
    const home = try journal.homeArg(gpa);
    defer gpa.free(home);
    const id = try journal.journalName(gpa);
    defer gpa.free(id);

    var removed = try run(gpa, &.{ "--home", home, "rm", "@3" }, 24, 100);
    defer removed.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), removed.code);

    const selected = try runNonTtyInJournal(
        gpa,
        &.{ "--home", home, "hist", "@4", "@1..@3" },
        id,
        "5",
    );
    defer gpa.free(selected.stdout);
    defer gpa.free(selected.stderr);
    try std.testing.expectEqual(@as(u8, 0), selected.term.exited);
    const four_at = std.mem.indexOf(u8, selected.stdout, "HIST_TARGET_FOUR") orelse return error.TestUnexpectedResult;
    const one_at = std.mem.indexOf(u8, selected.stdout, "HIST_TARGET_ONE") orelse return error.TestUnexpectedResult;
    const two_at = std.mem.indexOf(u8, selected.stdout, "HIST_TARGET_TWO") orelse return error.TestUnexpectedResult;
    try std.testing.expect(four_at < one_at and one_at < two_at);
    try std.testing.expect(std.mem.indexOf(u8, selected.stdout, "HIST_TARGET_THREE") == null);

    const foreign = ulid.encode(std.math.maxInt(u48), .{0} ** 10);
    var root = try journal.tmp.dir.openDir(io, journal_dir, .{});
    defer root.close(io);
    try root.createDir(io, &foreign, @enumFromInt(0o700));
    var foreign_dir = try root.openDir(io, &foreign, .{});
    defer foreign_dir.close(io);
    try foreign_dir.createDir(io, "1", @enumFromInt(0o700));
    var foreign_entry = try foreign_dir.openDir(io, "1", .{});
    defer foreign_entry.close(io);
    try foreign_entry.writeFile(io, .{ .sub_path = "cmd", .data = "echo HIST_TARGET_FOREIGN" });
    try foreign_entry.writeFile(io, .{ .sub_path = "out", .data = "HIST_TARGET_FOREIGN\n" });
    try foreign_entry.writeFile(io, .{ .sub_path = "rc", .data = "0\n" });

    const suffix = foreign[foreign.len - 4 ..];
    const journal_selector = try std.fmt.allocPrint(gpa, "@{s}.", .{suffix});
    defer gpa.free(journal_selector);
    const mixed = try runNonTtyInJournal(
        gpa,
        &.{ "--home", home, "hist", "@2", journal_selector, "@1" },
        id,
        "5",
    );
    defer gpa.free(mixed.stdout);
    defer gpa.free(mixed.stderr);
    try std.testing.expectEqual(@as(u8, 0), mixed.term.exited);
    const mixed_two = std.mem.indexOf(u8, mixed.stdout, "HIST_TARGET_TWO") orelse return error.TestUnexpectedResult;
    const mixed_foreign = std.mem.indexOf(u8, mixed.stdout, "HIST_TARGET_FOREIGN") orelse return error.TestUnexpectedResult;
    const mixed_one = std.mem.indexOf(u8, mixed.stdout, "HIST_TARGET_ONE") orelse return error.TestUnexpectedResult;
    try std.testing.expect(mixed_two < mixed_foreign and mixed_foreign < mixed_one);
    const qualified = try std.fmt.allocPrint(gpa, "@{s}.1", .{suffix});
    defer gpa.free(qualified);
    try std.testing.expect(std.mem.indexOf(u8, mixed.stdout, qualified) != null);

    const bare = try runNonTtyInJournal(gpa, &.{ "--home", home, "hist", suffix }, id, "5");
    defer gpa.free(bare.stdout);
    defer gpa.free(bare.stderr);
    try std.testing.expectEqual(@as(u8, 1), bare.term.exited);
    try std.testing.expect(std.mem.indexOf(u8, bare.stderr, "not a journal reference") != null);
}

test "tag pin and cat ranges are inclusive and skip numbering holes" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try Journal.open(gpa);
    defer journal.close();
    try recordJournal(gpa, &journal, &.{
        "echo RANGE_ONE",
        "echo RANGE_TWO",
        "echo RANGE_THREE",
        "echo RANGE_FOUR",
        "echo RANGE_FIVE",
    });
    try journal.enter(gpa);
    const home = try journal.homeArg(gpa);
    defer gpa.free(home);

    var hole = try run(gpa, &.{ "--home", home, "rm", "@3" }, 24, 100);
    defer hole.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), hole.code);

    var tagged = try run(gpa, &.{ "--home", home, "tag", "@2..@4", "BATCH", "extra" }, 24, 100);
    defer tagged.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), tagged.code);
    var queried = try run(gpa, &.{ "--home", home, "tag", "@2..@4" }, 24, 100);
    defer queried.out.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, queried.out.items, "@2  batch  extra") != null);
    try std.testing.expect(std.mem.indexOf(u8, queried.out.items, "@4  batch  extra") != null);
    try std.testing.expect(std.mem.indexOf(u8, queried.out.items, "@3") == null);

    var untagged = try run(gpa, &.{ "--home", home, "tag", "--remove", "@3..@4", "extra" }, 24, 100);
    defer untagged.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), untagged.code);
    var fourth_tags = try run(gpa, &.{ "--home", home, "tag", "@4" }, 24, 100);
    defer fourth_tags.out.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, fourth_tags.out.items, "@4  batch") != null);
    try std.testing.expect(std.mem.indexOf(u8, fourth_tags.out.items, "extra") == null);

    var pinned = try run(gpa, &.{ "--home", home, "pin", "@1..@4" }, 24, 100);
    defer pinned.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), pinned.code);
    var unpinned = try run(gpa, &.{ "--home", home, "pin", "--remove", "@2..@3" }, 24, 100);
    defer unpinned.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), unpinned.code);
    var pins = try run(gpa, &.{ "--home", home, "pin" }, 24, 100);
    defer pins.out.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, pins.out.items, "@1\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, pins.out.items, "@4\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, pins.out.items, "@2\r\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, pins.out.items, "@3\r\n") == null);

    var concatenated = try run(gpa, &.{ "--home", home, "cat", "--plain", "@2..@4" }, 24, 100);
    defer concatenated.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), concatenated.code);
    const second = std.mem.indexOf(u8, concatenated.out.items, "RANGE_TWO") orelse return error.TestUnexpectedResult;
    const fourth = std.mem.indexOf(u8, concatenated.out.items, "RANGE_FOUR") orelse return error.TestUnexpectedResult;
    try std.testing.expect(second < fourth);
    try std.testing.expect(std.mem.indexOf(u8, concatenated.out.items, "RANGE_THREE") == null);

    var empty = try run(gpa, &.{ "--home", home, "tag", "@20..@30", "missing" }, 24, 100);
    defer empty.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 2), empty.code);

    // A broad cat range inside the writer would otherwise read and append to
    // its own `out` indefinitely. Reject it before any resource is emitted.
    const id = try journal.journalName(gpa);
    defer gpa.free(id);
    const recursive = try runNonTtyInJournal(gpa, &.{ "--home", home, "cat", "@1..@999" }, id, "7");
    defer gpa.free(recursive.stdout);
    defer gpa.free(recursive.stderr);
    try std.testing.expectEqual(@as(u8, 1), recursive.term.exited);
    try std.testing.expectEqualStrings("", recursive.stdout);
    try std.testing.expect(std.mem.indexOf(u8, recursive.stderr, "currently running entry") != null);
}

test "tag accepts leading target lists before multiple tags" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var journal = try Journal.open(gpa);
    defer journal.close();
    try recordJournal(gpa, &journal, &.{
        "echo one",
        "echo two",
        "echo three",
        "echo four",
    });
    try journal.enter(gpa);
    const home = try journal.homeArg(gpa);
    defer gpa.free(home);
    const id = try journal.journalName(gpa);
    defer gpa.free(id);

    // Real zsh expands the first two shorthand references into journal paths;
    // the range remains @ syntax. Both forms must stay in the leading target
    // sequence, with BUG and parser recognized as tags.
    const child = try spawnContinuedJournalZsh(gpa, &journal, id);
    var transcript: std.ArrayList(u8) = .empty;
    defer transcript.deinit(gpa);
    try setupJournalZsh(gpa, child, &transcript);
    const from = transcript.items.len;
    try child.write("command \"$TJ\" tag @1 @2 @3..@4 BUG parser\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, test_prompt, timeout_ms));
    try child.write("exit 0\n");
    try std.testing.expectEqual(@as(u8, 0), try child.finish(gpa, &transcript, timeout_ms));

    var queried = try run(gpa, &.{ "--home", home, "tag", "@1", "@2", "@3..@4" }, 24, 120);
    defer queried.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), queried.code);
    for (1..5) |number| {
        var expected_buf: [64]u8 = undefined;
        const expected = try std.fmt.bufPrint(&expected_buf, "@{d}  bug  parser", .{number});
        try std.testing.expect(std.mem.indexOf(u8, queried.out.items, expected) != null);
    }

    var removed = try run(gpa, &.{ "--home", home, "tag", "--remove", "@1", "@3..@4", "parser" }, 24, 120);
    defer removed.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), removed.code);
    var after = try run(gpa, &.{ "--home", home, "tag", "@1", "@2", "@3", "@4" }, 24, 120);
    defer after.out.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, after.out.items, "@1  bug\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, after.out.items, "@2  bug  parser") != null);
    try std.testing.expect(std.mem.indexOf(u8, after.out.items, "@3  bug\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, after.out.items, "@4  bug\r\n") != null);
}

test "entry mutations reject qualified journals while reads still work" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var journal = try Journal.open(gpa);
    defer journal.close();
    try recordJournal(gpa, &journal, &.{"echo current"});
    try journal.enter(gpa);
    const home = try journal.homeArg(gpa);
    defer gpa.free(home);

    const foreign = ulid.encode(999, .{7} ** 10);
    var root = try journal.tmp.dir.openDir(io, journal_dir, .{ .iterate = true });
    try root.createDir(io, &foreign, @enumFromInt(0o700));
    var foreign_dir = try root.openDir(io, &foreign, .{});
    try foreign_dir.createDir(io, "1", @enumFromInt(0o700));
    var interaction = try foreign_dir.openDir(io, "1", .{});
    try interaction.writeFile(io, .{ .sub_path = "cmd", .data = "foreign" });
    try interaction.writeFile(io, .{ .sub_path = "out", .data = "foreign-output\n" });
    try interaction.writeFile(io, .{ .sub_path = "rc", .data = "0\n" });
    try interaction.writeFile(io, .{ .sub_path = "meta.json", .data = "{\"v\":1}\n" });
    interaction.close(io);
    foreign_dir.close(io);
    root.close(io);

    const qualified = try std.fmt.allocPrint(gpa, "@{s}.1", .{foreign});
    defer gpa.free(qualified);
    var resolved = try run(gpa, &.{ "--home", home, "resolve", qualified }, 24, 100);
    defer resolved.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), resolved.code);

    for ([_][]const []const u8{
        &.{ "name", qualified, "forbidden" },
        &.{ "tag", qualified, "forbidden" },
        &.{ "pin", qualified },
        &.{ "rm", qualified },
    }) |command_args| {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.appendSlice(gpa, &.{ "--home", home });
        try argv.appendSlice(gpa, command_args);
        var result = try run(gpa, argv.items, 24, 100);
        defer result.out.deinit(gpa);
        try std.testing.expectEqual(@as(u8, 1), result.code);
    }

    var check_root = try journal.tmp.dir.openDir(io, journal_dir, .{});
    defer check_root.close(io);
    var annotations_path_buf: [64]u8 = undefined;
    const annotations_path = try std.fmt.bufPrint(&annotations_path_buf, "{s}/journal.sqlite3", .{foreign});
    try std.testing.expectError(error.FileNotFound, check_root.openFile(io, annotations_path, .{}));
    var interaction_path_buf: [64]u8 = undefined;
    const interaction_path = try std.fmt.bufPrint(&interaction_path_buf, "{s}/1", .{foreign});
    var still_there = try check_root.openDir(io, interaction_path, .{});
    still_there.close(io);
}

test "output and entry removal clean data without reusing numbers" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var journal = try Journal.open(gpa);
    defer journal.close();
    try recordJournal(gpa, &journal, &.{ "echo first", "echo second", "echo third" });
    try journal.enter(gpa);
    const home = try journal.homeArg(gpa);
    defer gpa.free(home);

    for ([_][]const []const u8{
        &.{ "name", "@1", "kept-name" },
        &.{ "name", "@2", "removed-name" },
        &.{ "tag", "@2", "old" },
        &.{ "pin", "@1" },
        &.{ "pin", "@2" },
    }) |command_args| {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.appendSlice(gpa, &.{ "--home", home });
        try argv.appendSlice(gpa, command_args);
        var result = try run(gpa, argv.items, 24, 100);
        defer result.out.deinit(gpa);
        try std.testing.expectEqual(@as(u8, 0), result.code);
    }

    // Pins protect both the complete interaction and output-only removal.
    var skipped_out = try run(gpa, &.{ "--home", home, "rm", "@1/out" }, 24, 100);
    defer skipped_out.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), skipped_out.code);
    try std.testing.expect(std.mem.indexOf(u8, skipped_out.out.items, "skipped pinned entry @1") != null);
    var skipped_interaction = try run(gpa, &.{ "--home", home, "rm", "@2" }, 24, 100);
    defer skipped_interaction.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), skipped_interaction.code);
    try std.testing.expect(std.mem.indexOf(u8, skipped_interaction.out.items, "skipped pinned entry @2") != null);

    var protected_dir = try journal.journalDir();
    var protected_out = try protected_dir.openFile(io, "1/out", .{});
    protected_out.close(io);
    var protected_two = try protected_dir.openDir(io, "2", .{});
    protected_two.close(io);
    protected_dir.close(io);

    for ([_][]const []const u8{
        &.{ "rm", "--force", "@1/out" },
        &.{ "rm", "--force", "@2" },
    }) |command_args| {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.appendSlice(gpa, &.{ "--home", home });
        try argv.appendSlice(gpa, command_args);
        var result = try run(gpa, argv.items, 24, 100);
        defer result.out.deinit(gpa);
        try std.testing.expectEqual(@as(u8, 0), result.code);
    }

    var dir = try journal.journalDir();
    defer dir.close(io);
    try std.testing.expectError(error.FileNotFound, dir.openFile(io, "1/out", .{}));
    var cmd = try dir.openFile(io, "1/cmd", .{});
    cmd.close(io);
    var marker = try dir.openFile(io, "1/out.removed", .{});
    marker.close(io);
    try std.testing.expectError(error.FileNotFound, dir.openDir(io, "2", .{}));

    var names = try run(gpa, &.{ "--home", home, "name" }, 24, 100);
    defer names.out.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, names.out.items, "kept-name  @1") != null);
    try std.testing.expect(std.mem.indexOf(u8, names.out.items, "removed-name") == null);

    const id = try journal.journalName(gpa);
    defer gpa.free(id);
    const child = try spawnContinuedJournalZsh(gpa, &journal, id);
    var continued: std.ArrayList(u8) = .empty;
    defer continued.deinit(gpa);
    try setupJournalZsh(gpa, child, &continued);
    const from = continued.items.len;
    try child.write("echo after-hole\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &continued, from, test_prompt, timeout_ms));
    try child.write("exit 0\n");
    try std.testing.expectEqual(@as(u8, 0), try child.finish(gpa, &continued, timeout_ms));
    var after = try journal.journalDir();
    defer after.close(io);
    const next_cmd = try after.readFileAlloc(io, "5/cmd", gpa, .limited(4096));
    defer gpa.free(next_cmd);
    try std.testing.expectEqualStrings("echo after-hole", next_cmd);
}

test "entry ranges remove existing entries across holes and reject the running boundary" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var journal = try Journal.open(gpa);
    defer journal.close();
    try recordJournal(gpa, &journal, &.{
        "echo one",
        "echo two",
        "echo three",
        "echo four",
        "echo five",
    });
    try journal.enter(gpa);
    const home = try journal.homeArg(gpa);
    defer gpa.free(home);

    for ([_][]const []const u8{
        &.{ "name", "@2", "range-name" },
        &.{ "tag", "@3", "range-tag" },
        &.{ "pin", "@4" },
    }) |command_args| {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.appendSlice(gpa, &.{ "--home", home });
        try argv.appendSlice(gpa, command_args);
        var result = try run(gpa, argv.items, 24, 100);
        defer result.out.deinit(gpa);
        try std.testing.expectEqual(@as(u8, 0), result.code);
    }

    // recordJournal leaves its `exit` interaction as the protected highest
    // directory. A range containing it must fail before removing @2.
    var protected = try run(gpa, &.{ "--home", home, "rm", "@2..@6" }, 24, 120);
    defer protected.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), protected.code);
    try std.testing.expect(std.mem.indexOf(u8, protected.out.items, "currently running") != null);
    var before = try journal.journalDir();
    var still_two = try before.openDir(io, "2", .{});
    still_two.close(io);
    before.close(io);

    // Make a pre-existing hole inside the successful interval.
    var hole = try run(gpa, &.{ "--home", home, "rm", "@3" }, 24, 100);
    defer hole.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), hole.code);

    // Drive the range through real zsh: its shorthand canonicalizer must leave
    // the range word intact for the rm-specific parser. @4 is pinned, so the
    // ordinary range leaves it in place while removing the other members.
    const id = try journal.journalName(gpa);
    defer gpa.free(id);
    const child = try spawnContinuedJournalZsh(gpa, &journal, id);
    var transcript: std.ArrayList(u8) = .empty;
    defer transcript.deinit(gpa);
    try setupJournalZsh(gpa, child, &transcript);
    const from = transcript.items.len;
    try child.write("command \"$TJ\" rm @2..@5\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, test_prompt, timeout_ms));
    try child.write("exit 0\n");
    try std.testing.expectEqual(@as(u8, 0), try child.finish(gpa, &transcript, timeout_ms));

    var dir = try journal.journalDir();
    defer dir.close(io);
    for ([_][]const u8{ "2", "3", "5" }) |number| {
        try std.testing.expectError(error.FileNotFound, dir.openDir(io, number, .{}));
    }
    for ([_][]const u8{ "1", "4", "6", "7" }) |number| {
        var kept = try dir.openDir(io, number, .{});
        kept.close(io);
    }
    const range_cmd = try dir.readFileAlloc(io, "7/cmd", gpa, .limited(4096));
    defer gpa.free(range_cmd);
    try std.testing.expectEqualStrings("command \"$TJ\" rm @2..@5", range_cmd);

    var remaining_names = try run(gpa, &.{ "--home", home, "name" }, 24, 100);
    defer remaining_names.out.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, remaining_names.out.items, "range-name") == null);
    var remaining_tags = try run(gpa, &.{ "--home", home, "tag" }, 24, 100);
    defer remaining_tags.out.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, remaining_tags.out.items, "range-tag") == null);
    var remaining_pins = try run(gpa, &.{ "--home", home, "pin" }, 24, 100);
    defer remaining_pins.out.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, remaining_pins.out.items, "@4") != null);

    var forced = try run(gpa, &.{ "--home", home, "rm", "--force", "@4" }, 24, 100);
    defer forced.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), forced.code);
    try std.testing.expectError(error.FileNotFound, dir.openDir(io, "4", .{}));
}

test "rm accepts mixed target lists and applies force to every target" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var journal = try Journal.open(gpa);
    defer journal.close();
    try recordJournal(gpa, &journal, &.{
        "echo one",
        "echo two",
        "echo three",
        "echo four",
        "echo five",
        "echo six",
    });
    try journal.enter(gpa);
    const home = try journal.homeArg(gpa);
    defer gpa.free(home);

    var pinned = try run(gpa, &.{ "--home", home, "pin", "@3" }, 24, 100);
    defer pinned.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), pinned.code);

    var mixed = try run(gpa, &.{
        "--home", home, "rm", "@1", "@2/out", "@3", "@4..@5",
    }, 24, 120);
    defer mixed.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), mixed.code);
    try std.testing.expect(std.mem.indexOf(u8, mixed.out.items, "skipped pinned entry @3") != null);

    var dir = try journal.journalDir();
    defer dir.close(io);
    try std.testing.expectError(error.FileNotFound, dir.openDir(io, "1", .{}));
    try std.testing.expectError(error.FileNotFound, dir.openFile(io, "2/out", .{}));
    var two_cmd = try dir.openFile(io, "2/cmd", .{});
    two_cmd.close(io);
    var removed_marker = try dir.openFile(io, "2/out.removed", .{});
    removed_marker.close(io);
    var three = try dir.openDir(io, "3", .{});
    three.close(io);
    try std.testing.expectError(error.FileNotFound, dir.openDir(io, "4", .{}));
    try std.testing.expectError(error.FileNotFound, dir.openDir(io, "5", .{}));
    var six = try dir.openDir(io, "6", .{});
    six.close(io);

    var forced = try run(gpa, &.{ "--home", home, "rm", "--force", "@3", "@6" }, 24, 100);
    defer forced.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), forced.code);
    try std.testing.expectError(error.FileNotFound, dir.openDir(io, "3", .{}));
    try std.testing.expectError(error.FileNotFound, dir.openDir(io, "6", .{}));
}

test "concurrent annotation commands preserve every update" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var journal = try Journal.open(gpa);
    defer journal.close();
    try recordJournal(gpa, &journal, &.{"echo concurrent"});
    try journal.enter(gpa);
    const home = try journal.homeArg(gpa);
    defer gpa.free(home);

    const tags = [_][]const u8{ "alpha", "beta", "gamma", "delta", "epsilon", "zeta" };
    var children: [tags.len]harness.PtyChild = undefined;
    for (tags, 0..) |tag, i| {
        children[i] = try spawnTj(gpa, &.{ tj, "--home", home, "tag", "@1", tag }, 24, 80);
    }
    for (children) |child| {
        var transcript: std.ArrayList(u8) = .empty;
        defer transcript.deinit(gpa);
        const status = try child.finish(gpa, &transcript, timeout_ms);
        if (status != 0) std.debug.print("concurrent annotation child failed ({d}): {s}\n", .{ status, transcript.items });
        try std.testing.expectEqual(@as(u8, 0), status);
    }

    var listed = try run(gpa, &.{ "--home", home, "tag", "@1" }, 24, 120);
    defer listed.out.deinit(gpa);
    for (tags) |tag| try std.testing.expect(std.mem.indexOf(u8, listed.out.items, tag) != null);

    const first = try spawnTj(gpa, &.{ tj, "--home", home, "name", "@1", "first-name" }, 24, 80);
    const second = try spawnTj(gpa, &.{ tj, "--home", home, "name", "@1", "second-name" }, 24, 80);
    var first_out: std.ArrayList(u8) = .empty;
    defer first_out.deinit(gpa);
    var second_out: std.ArrayList(u8) = .empty;
    defer second_out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), try first.finish(gpa, &first_out, timeout_ms));
    try std.testing.expectEqual(@as(u8, 0), try second.finish(gpa, &second_out, timeout_ms));

    var named = try run(gpa, &.{ "--home", home, "name", "@1" }, 24, 100);
    defer named.out.deinit(gpa);
    const first_won = std.mem.indexOf(u8, named.out.items, "first-name") != null;
    const second_won = std.mem.indexOf(u8, named.out.items, "second-name") != null;
    try std.testing.expect(first_won != second_won);
}

test "whole-journal removal is outside-writer only and refuses active journals" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var journal = try Journal.open(gpa);
    defer journal.close();
    try recordJournal(gpa, &journal, &.{"echo removable"});
    const home = try journal.homeArg(gpa);
    defer gpa.free(home);
    const id = try journal.journalName(gpa);
    defer gpa.free(id);

    // A journal environment, even without an active writer in this test
    // process, is sufficient to reject the lifecycle operation.
    try journal.enter(gpa);
    var pinned = try run(gpa, &.{ "--home", home, "pin", "@1" }, 24, 100);
    defer pinned.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), pinned.code);
    var inside = try run(gpa, &.{ "--home", home, "journal", "rm", id, "--force" }, 24, 100);
    defer inside.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), inside.code);

    leaveJournal();
    const non_tty = try runNonTty(gpa, &.{ "--home", home, "journal", "rm", id });
    defer gpa.free(non_tty.stdout);
    defer gpa.free(non_tty.stderr);
    try std.testing.expectEqual(@as(u8, 1), non_tty.term.exited);
    try std.testing.expect(std.mem.indexOf(u8, non_tty.stderr, "pinned entry protected") != null);
    try std.testing.expect(std.mem.indexOf(u8, non_tty.stderr, "use --force") != null);

    const writer = try spawnTj(gpa, &.{ tj, "--home", home, "continue", id, "--", "/bin/sh", "-c", "echo READY; sleep 30" }, 24, 80);
    var writer_out: std.ArrayList(u8) = .empty;
    defer writer_out.deinit(gpa);
    try std.testing.expect(try writer.readUntil(gpa, &writer_out, "READY", timeout_ms));

    var active = try run(gpa, &.{ "--home", home, "journal", "rm", id, "--force" }, 24, 100);
    defer active.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), active.code);
    try std.testing.expect(std.mem.indexOf(u8, active.out.items, "while it is being written") != null);
    _ = std.c.kill(writer.pid, posix.SIG.TERM);
    _ = try writer.finish(gpa, &writer_out, timeout_ms);

    var removed = try run(gpa, &.{ "--home", home, "journal", "rm", id, "--force" }, 24, 100);
    defer removed.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), removed.code);
    var root = try journal.tmp.dir.openDir(std.testing.io, journal_dir, .{});
    defer root.close(std.testing.io);
    try std.testing.expectError(error.FileNotFound, root.openDir(std.testing.io, id, .{}));
}

test "named shorthand expands only after a name is assigned" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var journal = try Journal.open(gpa);
    defer journal.close();

    const child = try spawnJournalZsh(gpa, &journal);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try setupJournalZsh(gpa, child, &out);

    for ([_][]const u8{
        "echo seed",
        "command \"$TJ\" name @1 build-failure",
        "printf 'NAMED=%s\\n' @build-failure/out",
        "printf 'HANDLE=%s\\n' @someone",
    }) |line| {
        const from = out.items.len;
        try child.write(line);
        try child.write("\n");
        try std.testing.expect(try child.readUntilFrom(gpa, &out, from, test_prompt, timeout_ms));
    }
    try child.write("exit 0\n");
    try std.testing.expectEqual(@as(u8, 0), try child.finish(gpa, &out, timeout_ms));

    try std.testing.expect(std.mem.indexOf(u8, out.items, "NAMED=") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "/1/out") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "HANDLE=@someone") != null);
    const typed = try journal.read(gpa, "3/cmd");
    defer gpa.free(typed);
    try std.testing.expect(std.mem.indexOf(u8, typed, "@build-failure/out") != null);
}

test "a reference cannot escape its entry directory" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try Journal.open(gpa);
    defer journal.close();
    try recordJournal(gpa, &journal, &.{"echo only"});
    try journal.enter(gpa);

    const home = try journal.homeArg(gpa);
    defer gpa.free(home);

    for ([_][]const u8{ "@1/../../../etc/passwd", "@1//etc/passwd", "@1/./out" }) |attempt| {
        var r = try run(gpa, &.{ "--home", home, "resolve", attempt }, 24, 80);
        defer r.out.deinit(gpa);
        try std.testing.expectEqual(@as(u8, 1), r.code);
        try std.testing.expect(std.mem.indexOf(u8, r.out.items, "/etc/passwd") == null);
    }
}

test "completion offers resources but never tj's own bookkeeping" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try Journal.open(gpa);
    defer journal.close();
    try recordJournal(gpa, &journal, &.{"echo one"});
    try journal.enter(gpa);

    const home = try journal.homeArg(gpa);
    defer gpa.free(home);

    var r = try run(gpa, &.{ "--home", home, "complete", "@1/" }, 24, 80);
    defer r.out.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, r.out.items, "@1/cmd") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out.items, "@1/cwd") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out.items, "@1/out") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out.items, "@1/prompt") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out.items, "@1/rc") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out.items, "meta.json") == null);
}

test "shorthand and canonical references become paths" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try Journal.open(gpa);
    defer journal.close();

    try recordJournal(gpa, &journal, &.{
        "printf 'alpha-marker\\n'",
        "cat @1/out",
        "cat ~[@1]/out",
        "cat @-/out",
        "test -d @1 && printf 'directory-marker\\n'",
        "grep alpha-marker < @1/out | cat",
        "cmp @1/out @1/out && printf 'multiple-marker\\n'",
        "alias tj_show='cat'",
        "tj_show @1/out",
        "cat @0001/out",
    });

    const second_out = try journal.read(gpa, "2/out");
    defer gpa.free(second_out);
    try std.testing.expect(std.mem.indexOf(u8, second_out, "alpha-marker") != null);

    const canonical_out = try journal.read(gpa, "3/out");
    defer gpa.free(canonical_out);
    try std.testing.expect(std.mem.indexOf(u8, canonical_out, "alpha-marker") != null);

    const previous_out = try journal.read(gpa, "4/out");
    defer gpa.free(previous_out);
    try std.testing.expect(std.mem.indexOf(u8, previous_out, "alpha-marker") != null);

    const directory_out = try journal.read(gpa, "5/out");
    defer gpa.free(directory_out);
    try std.testing.expect(std.mem.indexOf(u8, directory_out, "directory-marker") != null);

    const pipeline_out = try journal.read(gpa, "6/out");
    defer gpa.free(pipeline_out);
    try std.testing.expect(std.mem.indexOf(u8, pipeline_out, "alpha-marker") != null);

    const multiple_out = try journal.read(gpa, "7/out");
    defer gpa.free(multiple_out);
    try std.testing.expect(std.mem.indexOf(u8, multiple_out, "multiple-marker") != null);

    const alias_out = try journal.read(gpa, "9/out");
    defer gpa.free(alias_out);
    try std.testing.expect(std.mem.indexOf(u8, alias_out, "alpha-marker") != null);

    // The journal records what was typed, not what ran.
    const second_cmd = try journal.read(gpa, "2/cmd");
    defer gpa.free(second_cmd);
    try std.testing.expectEqualStrings("cat @1/out", second_cmd);

    const canonical_cmd = try journal.read(gpa, "3/cmd");
    defer gpa.free(canonical_cmd);
    try std.testing.expectEqualStrings("cat ~[@1]/out", canonical_cmd);

    // ...and what ran is kept alongside it.
    const meta = try journal.read(gpa, "2/meta.json");
    defer gpa.free(meta);
    try std.testing.expect(std.mem.indexOf(u8, meta, "expanded_cmd") != null);
    try std.testing.expect(std.mem.indexOf(u8, meta, "/1/out") != null);

    const canonical_meta = try journal.read(gpa, "3/meta.json");
    defer gpa.free(canonical_meta);
    try std.testing.expect(std.mem.indexOf(u8, canonical_meta, "expanded_cmd") != null);
    try std.testing.expect(std.mem.indexOf(u8, canonical_meta, "/1/out") != null);

    const alias_cmd = try journal.read(gpa, "9/cmd");
    defer gpa.free(alias_cmd);
    try std.testing.expectEqualStrings("tj_show @1/out", alias_cmd);
    const alias_meta = try journal.read(gpa, "9/meta.json");
    defer gpa.free(alias_meta);
    try std.testing.expect(std.mem.indexOf(u8, alias_meta, "cat ") != null);
    try std.testing.expect(std.mem.indexOf(u8, alias_meta, "/1/out") != null);

    const leading_zero_out = try journal.read(gpa, "10/out");
    defer gpa.free(leading_zero_out);
    try std.testing.expect(std.mem.indexOf(u8, leading_zero_out, "alpha-marker") != null);
}

test "qualified shorthand resolves through a continued journal" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try Journal.open(gpa);
    defer journal.close();
    try recordJournal(gpa, &journal, &.{"echo qualified-marker"});

    const name = try journal.journalName(gpa);
    defer gpa.free(name);
    const suffix = name[name.len - 4 ..];
    const command = try std.fmt.allocPrint(gpa, "cat @{s}.1/out", .{suffix});
    defer gpa.free(command);

    const child = try spawnContinuedJournalZsh(gpa, &journal, name);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try setupJournalZsh(gpa, child, &out);

    const from = out.items.len;
    try child.write(command);
    try child.write("\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, "qualified-marker", timeout_ms));
    try child.write("exit 0\n");
    try std.testing.expectEqual(@as(u8, 0), try child.finish(gpa, &out, timeout_ms));

    // The first writer's unfinished `exit` consumed 2, so continuation starts
    // at 3 rather than reusing it.
    const recorded = try journal.read(gpa, "3/cmd");
    defer gpa.free(recorded);
    try std.testing.expectEqualStrings(command, recorded);
    const meta = try journal.read(gpa, "3/meta.json");
    defer gpa.free(meta);
    try std.testing.expect(std.mem.indexOf(u8, meta, "/1/out") != null);
}

test "history is canonical while journal metadata keeps shorthand and paths" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try Journal.open(gpa);
    defer journal.close();
    const child = try spawnJournalZsh(gpa, &journal);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try setupJournalZsh(gpa, child, &out);

    var from = out.items.len;
    try child.write("echo history-marker\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, test_prompt, timeout_ms));

    from = out.items.len;
    try child.write("cat @1/out >/dev/null\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, test_prompt, timeout_ms));
    const accepted = out.items[from..];
    var visible: std.ArrayList(u8) = .empty;
    defer visible.deinit(gpa);
    var visible_writer = Io.Writer.Allocating.fromArrayList(gpa, &visible);
    try plain.render(gpa, accepted, &visible_writer.writer);
    visible = visible_writer.toArrayList();
    try std.testing.expect(std.mem.indexOf(u8, visible.items, "~[@1]/out") != null);
    const home = try journal.homeArg(gpa);
    defer gpa.free(home);
    try std.testing.expect(std.mem.indexOf(u8, accepted, home) == null);

    from = out.items.len;
    try child.write("fc -ln -1\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, "cat ~[@1]/out >/dev/null", timeout_ms));
    try child.write("exit 0\n");
    try std.testing.expectEqual(@as(u8, 0), try child.finish(gpa, &out, timeout_ms));

    const command = try journal.read(gpa, "2/cmd");
    defer gpa.free(command);
    try std.testing.expectEqualStrings("cat @1/out >/dev/null", command);
    const meta = try journal.read(gpa, "2/meta.json");
    defer gpa.free(meta);
    try std.testing.expect(std.mem.indexOf(u8, meta, "/1/out") != null);
}

test "quoted references and addresses are left alone" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try Journal.open(gpa);
    defer journal.close();
    try recordJournal(gpa, &journal, &.{
        "echo start",
        "echo 'literal @1/out here'",
        "echo user@host",
        "echo 'literal ~[@1]/out here'",
        "echo \"literal ~[@1]/out here\"",
        "echo @0 @4294967296 @not-a-reference",
    });

    const quoted = try journal.read(gpa, "2/out");
    defer gpa.free(quoted);
    try std.testing.expect(std.mem.indexOf(u8, quoted, "literal @1/out here") != null);

    const address = try journal.read(gpa, "3/out");
    defer gpa.free(address);
    try std.testing.expect(std.mem.indexOf(u8, address, "user@host") != null);

    const malformed = try journal.read(gpa, "6/out");
    defer gpa.free(malformed);
    try std.testing.expect(std.mem.indexOf(u8, malformed, "@0 @4294967296 @not-a-reference") != null);

    // None of these lines contains an eligible unquoted shell-word reference.
    for ([_][]const u8{ "2/meta.json", "3/meta.json", "4/meta.json", "5/meta.json", "6/meta.json" }) |path| {
        const meta = try journal.read(gpa, path);
        defer gpa.free(meta);
        try std.testing.expect(std.mem.indexOf(u8, meta, "expanded_cmd") == null);
    }
}

// --- full-screen programs and reading resources -----------------------------

test "a full-screen program leaves nothing in the journal" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try Journal.open(gpa);
    defer journal.close();

    // The sequences a pager or editor sends, without the unpredictability of
    // driving a real one.
    try recordJournal(gpa, &journal, &.{
        "printf 'BEFORE\\n\\033[?1049hHIDDEN-PAINTING\\033[?1049lAFTER\\n'",
    });

    const out = try journal.read(gpa, "1/out");
    defer gpa.free(out);

    // What the terminal keeps in scrollback is kept; the rest is not.
    try std.testing.expect(std.mem.indexOf(u8, out, "BEFORE") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "AFTER") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "HIDDEN-PAINTING") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "1049") == null);

    // A near-empty `out` should be explainable from the metadata alone.
    const meta = try journal.read(gpa, "1/meta.json");
    defer gpa.free(meta);
    try std.testing.expect(std.mem.indexOf(u8, meta, "\"fullscreen\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, meta, "\"regions\":1") != null);
}

test "the terminal still sees the full-screen program" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try Journal.open(gpa);
    defer journal.close();

    const child = try spawnJournalZsh(gpa, &journal);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    try setupJournalZsh(gpa, child, &out);
    const from = out.items.len;
    try child.write("printf '\\033[?1049hHIDDEN-PAINTING\\033[?1049l'\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, test_prompt, timeout_ms));
    try child.write("exit\n");
    try std.testing.expectEqual(@as(u8, 0), try child.finish(gpa, &out, timeout_ms));

    // Filtering applies to the journal only: the program must render exactly
    // as it would without tj.
    try std.testing.expect(std.mem.indexOf(u8, out.items, "HIDDEN-PAINTING") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[?1049h") != null);
}

test "tj cat renders recorded output as readable text" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try Journal.open(gpa);
    defer journal.close();
    try recordJournal(gpa, &journal, &.{"printf '\\033[31mred\\033[0m\\r\\n10%%\\r100%% done\\r\\n'"});
    try journal.enter(gpa);

    const home = try journal.homeArg(gpa);
    defer gpa.free(home);

    var rendered = try run(gpa, &.{ "--home", home, "cat", "--plain", "@1" }, 24, 80);
    defer rendered.out.deinit(gpa);

    // Colours gone, and only what survived the carriage returns.
    try std.testing.expect(std.mem.indexOf(u8, rendered.out.items, "red") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.out.items, "\x1b[31m") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.out.items, "100% done") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.out.items, "10%\r") == null);
}

test "tj cat --raw gives back exactly what was recorded" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try Journal.open(gpa);
    defer journal.close();
    try recordJournal(gpa, &journal, &.{"printf '\\033[31mred\\033[0m\\n'"});
    try journal.enter(gpa);

    const home = try journal.homeArg(gpa);
    defer gpa.free(home);

    var raw = try run(gpa, &.{ "--home", home, "cat", "--raw", "@1" }, 24, 80);
    defer raw.out.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, raw.out.items, "\x1b[31m") != null);
}

test "tj cat defaults to the output and reads other resources by name" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try Journal.open(gpa);
    defer journal.close();
    try recordJournal(gpa, &journal, &.{"echo marker-text"});
    try journal.enter(gpa);

    const home = try journal.homeArg(gpa);
    defer gpa.free(home);

    var output = try run(gpa, &.{ "--home", home, "cat", "@1" }, 24, 80);
    defer output.out.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, output.out.items, "marker-text") != null);

    var command = try run(gpa, &.{ "--home", home, "cat", "@1/cmd" }, 24, 80);
    defer command.out.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, command.out.items, "echo marker-text") != null);

    var missing = try run(gpa, &.{ "--home", home, "cat", "@1/nope" }, 24, 80);
    defer missing.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), missing.code);
}

test "tj cat takes the path a named directory expanded to, as well as the reference" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try Journal.open(gpa);
    defer journal.close();
    try recordJournal(gpa, &journal, &.{"echo path-or-ref"});
    try journal.enter(gpa);

    const home = try journal.homeArg(gpa);
    defer gpa.free(home);

    // Inside the zsh integration, shorthand becomes `~[@1]` and zsh expands
    // that dynamic named directory before tj executes. This is the resulting
    // form tj actually receives there.
    var resolved = try run(gpa, &.{ "--home", home, "resolve", "@1" }, 24, 80);
    defer resolved.out.deinit(gpa);
    const path = std.mem.trim(u8, resolved.out.items, " \r\n");

    var by_path = try run(gpa, &.{ "--home", home, "cat", path }, 24, 80);
    defer by_path.out.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, by_path.out.items, "path-or-ref") != null);

    var by_ref = try run(gpa, &.{ "--home", home, "cat", "@1" }, 24, 80);
    defer by_ref.out.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, by_ref.out.items, "path-or-ref") != null);

    // A word shaped like a reference but invalid is still reported as one,
    // rather than being tried as a filename.
    var malformed = try run(gpa, &.{ "--home", home, "cat", "@0" }, 24, 80);
    defer malformed.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), malformed.code);
}

test "cat windows and replay stream output beyond sixty-four mibibytes" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const beyond_old_limit = 64 * 1024 * 1024 + 4096;

    var journal = try Journal.open(gpa);
    defer journal.close();
    try recordJournal(gpa, &journal, &.{"echo replace-this-output"});

    var selected_dir = try journal.journalDir();
    defer selected_dir.close(io);
    var file = try selected_dir.createFile(io, "1/out", .{});
    try file.writePositionalAll(io, "FIRST-LINE\n", 0);
    try file.setLength(io, beyond_old_limit);
    try file.writePositionalAll(io, "\nTAIL-A\nREPLAY-BEYOND-LIMIT\n", beyond_old_limit);
    file.close(io);

    try journal.enter(gpa);
    const home = try journal.homeArg(gpa);
    defer gpa.free(home);

    var head = try run(gpa, &.{ "--home", home, "cat", "--raw", "--head", "1", "@1" }, 24, 80);
    defer head.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), head.code);
    try std.testing.expect(std.mem.indexOf(u8, head.out.items, "FIRST-LINE") != null);
    try std.testing.expect(std.mem.indexOf(u8, head.out.items, "REPLAY-BEYOND-LIMIT") == null);
    try std.testing.expect(std.mem.indexOf(u8, head.out.items, "showing 1 of 4 lines") != null);

    var tail = try run(gpa, &.{ "--home", home, "cat", "--plain", "--tail", "2", "@1" }, 24, 80);
    defer tail.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), tail.code);
    try std.testing.expect(std.mem.indexOf(u8, tail.out.items, "FIRST-LINE") == null);
    try std.testing.expect(std.mem.indexOf(u8, tail.out.items, "TAIL-A") != null);
    try std.testing.expect(std.mem.indexOf(u8, tail.out.items, "REPLAY-BEYOND-LIMIT") != null);
    try std.testing.expect(std.mem.indexOf(u8, tail.out.items, "showing 2 of 4 lines") != null);

    leaveJournal();
    const replay = try spawnTj(gpa, &.{
        tj, "--home", home, "replay", "--typing", "0", "--max-pause", "0", "--prompt", "",
    }, 24, 80);
    var replayed = try finishKeepingTail(gpa, replay, 8192, 30_000);
    defer replayed.tail.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), replayed.code);
    try std.testing.expect(replayed.total > 64 * 1024 * 1024);
    try std.testing.expect(std.mem.indexOf(u8, replayed.tail.items, "REPLAY-BEYOND-LIMIT") != null);
}

// --- journals that recorded nothing ------------------------------------------

/// A journal directory with no shell integration pointed at it, for testing
/// what a new journal writer leaves behind.
const Scratch = struct {
    tmp: std.testing.TmpDir,
    path_len: usize,
    path_buf: [std.fs.max_path_bytes]u8,

    fn open() !Scratch {
        var self: Scratch = .{
            .tmp = std.testing.tmpDir(.{ .iterate = true }),
            .path_len = 0,
            .path_buf = undefined,
        };
        self.path_len = try self.tmp.dir.realPath(std.testing.io, &self.path_buf);
        return self;
    }

    fn path(self: *const Scratch) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    fn close(self: *Scratch) void {
        self.tmp.cleanup();
    }

    fn makeJournal(self: *Scratch, id: ulid.Ulid, entries: []const []const u8) !void {
        const io = std.testing.io;
        try self.tmp.dir.createDir(io, &id, @enumFromInt(0o700));
        var dir = try self.tmp.dir.openDir(io, &id, .{});
        defer dir.close(io);
        for (entries) |entry| try dir.createDir(io, entry, @enumFromInt(0o700));
    }

    /// How many journal directories the root holds.
    fn journals(self: *Scratch) !usize {
        var count: usize = 0;
        var it = self.tmp.dir.iterate();
        while (try it.next(std.testing.io)) |entry| {
            if (entry.kind == .directory and ulid.isValid(entry.name)) count += 1;
        }
        return count;
    }
};

test "legacy and corrupt journal metadata fail with explicit diagnostics" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var scratch = try Scratch.open();
    defer scratch.close();

    const legacy = ulid.encode(37, .{2} ** 10);
    const corrupt = ulid.encode(38, .{3} ** 10);
    try scratch.makeJournal(legacy, &.{"1"});
    try scratch.makeJournal(corrupt, &.{"1"});
    var legacy_dir = try scratch.tmp.dir.openDir(io, &legacy, .{});
    defer legacy_dir.close(io);
    try legacy_dir.writeFile(io, .{ .sub_path = "annotations.json", .data = "{}\n" });
    var corrupt_dir = try scratch.tmp.dir.openDir(io, &corrupt, .{});
    defer corrupt_dir.close(io);
    try corrupt_dir.writeFile(io, .{ .sub_path = "journal.sqlite3", .data = "not sqlite" });

    for ([_]struct { id: ulid.Ulid, diagnostic: []const u8 }{
        .{ .id = legacy, .diagnostic = "legacy annotations.json is unsupported" },
        .{ .id = corrupt, .diagnostic = "invalid or incompatible journal.sqlite3" },
    }) |case| {
        const result = try runNonTtyInJournal(gpa, &.{ "--home", scratch.path(), "name" }, &case.id, "2");
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        try std.testing.expectEqual(@as(u8, 1), result.term.exited);
        try std.testing.expectEqualStrings("", result.stdout);
        try std.testing.expect(std.mem.indexOf(u8, result.stderr, case.diagnostic) != null);
    }
}

test "usage sums logical journal bytes and charts every entry in number order" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var scratch = try Scratch.open();
    defer scratch.close();

    const id = ulid.encode(39, .{1} ** 10);
    try scratch.makeJournal(id, &.{ "1", "3", "10" });
    var journal = try scratch.tmp.dir.openDir(io, &id, .{});
    defer journal.close(io);

    try journal.writeFile(io, .{ .sub_path = "journal.sqlite3", .data = &([_]u8{'a'} ** 100) });
    try journal.writeFile(io, .{ .sub_path = "journal.sqlite3-wal", .data = &([_]u8{'w'} ** 11) });
    try journal.writeFile(io, .{ .sub_path = "journal.sqlite3-shm", .data = &([_]u8{'s'} ** 13) });
    try journal.writeFile(io, .{ .sub_path = "log", .data = &([_]u8{'l'} ** 105) });

    var one = try journal.openDir(io, "1", .{});
    defer one.close(io);
    try one.writeFile(io, .{ .sub_path = "cmd", .data = "cmd" });
    try one.createDir(io, "files", @enumFromInt(0o700));
    var files = try one.openDir(io, "files", .{});
    defer files.close(io);
    try files.writeFile(io, .{ .sub_path = "blob", .data = &([_]u8{'x'} ** 1021) });

    var three = try journal.openDir(io, "3", .{});
    defer three.close(io);
    try three.writeFile(io, .{ .sub_path = "cmd", .data = "four" });
    try three.writeFile(io, .{ .sub_path = "out", .data = &([_]u8{'y'} ** 2044) });

    const total = try runNonTtyInJournal(gpa, &.{ "--home", scratch.path(), "usage" }, &id, "11");
    defer gpa.free(total.stdout);
    defer gpa.free(total.stderr);
    try std.testing.expectEqual(@as(u8, 0), total.term.exited);
    try std.testing.expectEqualStrings("3.2k\n", total.stdout);
    try std.testing.expectEqualStrings("", total.stderr);

    const bytes = try runNonTtyInJournal(gpa, &.{ "--home", scratch.path(), "usage", "--bytes" }, &id, "11");
    defer gpa.free(bytes.stdout);
    defer gpa.free(bytes.stderr);
    try std.testing.expectEqual(@as(u8, 0), bytes.term.exited);
    try std.testing.expectEqualStrings("@1 1024\n@3 2048\n@10 0\n", bytes.stdout);
    try std.testing.expectEqualStrings("", bytes.stderr);

    const chart = try runNonTtyInJournal(gpa, &.{ "--home", scratch.path(), "usage", "--chart" }, &id, "11");
    defer gpa.free(chart.stdout);
    defer gpa.free(chart.stderr);
    try std.testing.expectEqual(@as(u8, 0), chart.term.exited);
    try std.testing.expect(std.mem.startsWith(u8, chart.stdout, "Total 3.2k\n\nEntry Size Chart\n"));
    const one_at = std.mem.indexOf(u8, chart.stdout, " @1 1.0k ") orelse return error.TestUnexpectedResult;
    const three_at = std.mem.indexOf(u8, chart.stdout, " @3 2.0k ") orelse return error.TestUnexpectedResult;
    const ten_at = std.mem.indexOf(u8, chart.stdout, "@10   0b\n") orelse return error.TestUnexpectedResult;
    try std.testing.expect(one_at < three_at and three_at < ten_at);
    try std.testing.expectEqual(@as(usize, 107), std.mem.count(u8, chart.stdout, "█"));
    try std.testing.expect(std.mem.indexOfScalar(u8, chart.stdout, 0x1b) == null);
    try std.testing.expectEqualStrings("", chart.stderr);

    const exact_chart = try runNonTtyInJournal(
        gpa,
        &.{ "--home", scratch.path(), "usage", "--chart", "--bytes" },
        &id,
        "11",
    );
    defer gpa.free(exact_chart.stdout);
    defer gpa.free(exact_chart.stderr);
    try std.testing.expectEqual(@as(u8, 0), exact_chart.term.exited);
    try std.testing.expect(std.mem.startsWith(u8, exact_chart.stdout, "Total 3301\n\nEntry Size Chart\n"));
    try std.testing.expect(std.mem.indexOf(u8, exact_chart.stdout, " @1 1024 ") != null);
    try std.testing.expect(std.mem.indexOf(u8, exact_chart.stdout, " @3 2048 ") != null);
    try std.testing.expect(std.mem.indexOf(u8, exact_chart.stdout, "@10    0\n") != null);
    try std.testing.expectEqual(@as(usize, 107), std.mem.count(u8, exact_chart.stdout, "█"));
    try std.testing.expectEqualStrings("", exact_chart.stderr);

    var id_buf: [id.len + 1]u8 = undefined;
    @memcpy(id_buf[0..id.len], &id);
    id_buf[id.len] = 0;
    sys.setEnv("TJ_JOURNAL", id_buf[0..id.len :0]);
    defer leaveJournal();
    const terminal_child = try spawnTj(gpa, &.{
        "/usr/bin/env", "-u",           "NO_COLOR", "TERM=xterm-256color", tj,
        "--home",       scratch.path(), "usage",    "--chart",
    }, 24, 40);
    var terminal: std.ArrayList(u8) = .empty;
    defer terminal.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), try terminal_child.finish(gpa, &terminal, timeout_ms));
    try std.testing.expect(std.mem.indexOf(u8, terminal.items, noout.begin_marker) != null);
    try std.testing.expect(std.mem.indexOf(u8, terminal.items, noout.end_marker) != null);
    try std.testing.expect(std.mem.indexOf(u8, terminal.items, "\x1b[33m@1\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, terminal.items, "\x1b[32m1.0k\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, terminal.items, "\x1b[34m") == null);
    try std.testing.expectEqual(@as(usize, 47), std.mem.count(u8, terminal.items, "█"));
}

test "a new journal that recorded nothing leaves nothing behind" {
    const gpa = std.testing.allocator;

    var scratch = try Scratch.open();
    defer scratch.close();

    // /bin/sh loads no tj integration, so no command boundaries are ever
    // reported and the new journal records nothing.
    var r = try run(gpa, &.{ "--home", scratch.path(), "new", "--", "/bin/sh", "-c", "true" }, 24, 80);
    defer r.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), r.code);

    try std.testing.expectEqual(@as(usize, 0), try scratch.journals());
}

test "new and continue leave child help flags after the argv boundary" {
    const gpa = std.testing.allocator;
    var scratch = try Scratch.open();
    defer scratch.close();

    var created = try run(gpa, &.{
        "--home",                          scratch.path(), "new",    "--", "/bin/sh", "-c",
        "printf 'NEW-CHILD:%s\\n' \"$1\"", "sh",           "--help",
    }, 24, 80);
    defer created.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), created.code);
    try std.testing.expect(std.mem.indexOf(u8, created.out.items, "NEW-CHILD:--help") != null);

    const id = ulid.encode(40, .{2} ** 10);
    try scratch.makeJournal(id, &.{});
    var continued = try run(gpa, &.{
        "--home",                               scratch.path(), "continue", &id, "--", "/bin/sh", "-c",
        "printf 'CONTINUE-CHILD:%s\\n' \"$1\"", "sh",           "--help",
    }, 24, 80);
    defer continued.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), continued.code);
    try std.testing.expect(std.mem.indexOf(u8, continued.out.items, "CONTINUE-CHILD:--help") != null);
}

test "a new journal that recorded something is kept" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try Journal.open(gpa);
    defer journal.close();
    try recordJournal(gpa, &journal, &.{"echo kept"});

    const cmd = try journal.read(gpa, "1/cmd");
    defer gpa.free(cmd);
    try std.testing.expectEqualStrings("echo kept", cmd);
}

test "a new journal that could not record but said why is kept" {
    const gpa = std.testing.allocator;

    var scratch = try Scratch.open();
    defer scratch.close();

    // A malformed tj sequence: no interaction is opened, but the journal log
    // records that something was ignored, and that is worth keeping.
    var r = try run(gpa, &.{
        "--home",                                scratch.path(),
        "new",                                   "--",
        "/bin/sh",                               "-c",
        "printf '\\033]5107;tj;bogus\\033\\\\'",
    }, 24, 80);
    defer r.out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), try scratch.journals());
}

test "continue rejects missing ambiguous and full journals before exec" {
    const gpa = std.testing.allocator;
    var scratch = try Scratch.open();
    defer scratch.close();

    const first = ulid.encode(30, .{0} ** 10);
    const second = ulid.encode(31, .{0} ** 10);
    const full = ulid.encode(32, .{1} ** 10);
    try scratch.makeJournal(first, &.{});
    try scratch.makeJournal(second, &.{});
    try scratch.makeJournal(full, &.{"4294967295"});

    var missing = try run(gpa, &.{ "--home", scratch.path(), "continue", "does-not-exist", "--", "/bin/sh", "-c", "echo CHILD-RAN" }, 24, 80);
    defer missing.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), missing.code);
    try std.testing.expect(std.mem.indexOf(u8, missing.out.items, "no journal matches") != null);
    try std.testing.expect(std.mem.indexOf(u8, missing.out.items, "CHILD-RAN") == null);

    var ambiguous = try run(gpa, &.{ "--home", scratch.path(), "continue", "0000", "--", "/bin/sh", "-c", "echo CHILD-RAN" }, 24, 80);
    defer ambiguous.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), ambiguous.code);
    try std.testing.expect(std.mem.indexOf(u8, ambiguous.out.items, "suffix is ambiguous") != null);
    try std.testing.expect(std.mem.indexOf(u8, ambiguous.out.items, "CHILD-RAN") == null);

    var exhausted = try run(gpa, &.{ "--home", scratch.path(), "continue", &full, "--", "/bin/sh", "-c", "echo CHILD-RAN" }, 24, 80);
    defer exhausted.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), exhausted.code);
    try std.testing.expect(std.mem.indexOf(u8, exhausted.out.items, "no entry numbers left") != null);
    try std.testing.expect(std.mem.indexOf(u8, exhausted.out.items, "CHILD-RAN") == null);
}

test "an empty continue preserves its journal" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var scratch = try Scratch.open();
    defer scratch.close();

    const id = ulid.encode(40, .{2} ** 10);
    try scratch.makeJournal(id, &.{});
    var r = try run(gpa, &.{ "--home", scratch.path(), "continue", id[id.len - 6 ..], "--", "/bin/sh", "-c", "true" }, 24, 80);
    defer r.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), r.code);
    var dir = try scratch.tmp.dir.openDir(io, &id, .{});
    dir.close(io);
}

test "continue replays the journal immediately unless no-replay is set" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var scratch = try Scratch.open();
    defer scratch.close();

    const id = ulid.encode(45, .{2} ** 10);
    try scratch.makeJournal(id, &.{ "1", "2", "3" });
    var journal = try scratch.tmp.dir.openDir(io, &id, .{});
    defer journal.close(io);

    const entries = [_]struct {
        number: []const u8,
        command: []const u8,
        output: []const u8,
        meta: []const u8,
    }{
        .{ .number = "1", .command = "first-command", .output = "\x1b]11;?\x1b\\\x1b[6nREPLAY-FIRST\r\n", .meta = "{\"started\":\"2026-01-01T00:00:00.000Z\",\"ended\":\"2026-01-01T01:00:00.000Z\"}\n" },
        .{ .number = "2", .command = "second-command", .output = "REPLAY-SECOND\r\n", .meta = "{\"started\":\"2026-01-02T00:00:00.000Z\",\"ended\":\"2026-01-02T01:00:00.000Z\"}\n" },
        .{ .number = "3", .command = "third-command", .output = "REPLAY-THIRD\r\n", .meta = "{\"started\":\"2026-01-03T00:00:00.000Z\",\"ended\":\"2026-01-03T01:00:00.000Z\"}\n" },
    };
    for (entries) |entry| {
        var dir = try journal.openDir(io, entry.number, .{});
        defer dir.close(io);
        try dir.writeFile(io, .{ .sub_path = "cmd", .data = entry.command });
        try dir.writeFile(io, .{ .sub_path = "out", .data = entry.output });
        try dir.writeFile(io, .{ .sub_path = "meta.json", .data = entry.meta });
        if (std.mem.eql(u8, entry.number, "1")) {
            try dir.writeFile(io, .{ .sub_path = "prompt", .data = "CONTINUE-CAPTURED> " });
        }
    }

    // The recorded hour-long commands and day-long gaps must not delay
    // continuation. Its transcript appears before the fresh child output.
    var replayed = try run(gpa, &.{
        "--home", scratch.path(), "continue", &id, "--", "/bin/sh", "-c", "printf 'FRESH-CHILD\\n'",
    }, 24, 80);
    defer replayed.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), replayed.code);
    const first = std.mem.indexOf(u8, replayed.out.items, "REPLAY-FIRST") orelse return error.TestUnexpectedResult;
    const first_prompt = std.mem.indexOf(u8, replayed.out.items, "CONTINUE-CAPTURED> first-command") orelse return error.TestUnexpectedResult;
    const third = std.mem.indexOf(u8, replayed.out.items, "REPLAY-THIRD") orelse return error.TestUnexpectedResult;
    const child = std.mem.indexOf(u8, replayed.out.items, "FRESH-CHILD") orelse return error.TestUnexpectedResult;
    try std.testing.expect(first_prompt < first);
    try std.testing.expect(first < third);
    try std.testing.expect(third < child);
    try std.testing.expect(std.mem.indexOf(u8, replayed.out.items, "\x1b]11;?") == null);
    try std.testing.expect(std.mem.indexOf(u8, replayed.out.items, "\x1b[6n") == null);

    var skipped = try run(gpa, &.{
        "--home", scratch.path(), "continue", "--no-replay", &id, "--", "/bin/sh", "-c", "printf 'NO-REPLAY-CHILD\\n'",
    }, 24, 80);
    defer skipped.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), skipped.code);
    try std.testing.expect(std.mem.indexOf(u8, skipped.out.items, "NO-REPLAY-CHILD") != null);
    try std.testing.expect(std.mem.indexOf(u8, skipped.out.items, "REPLAY-FIRST") == null);
    try std.testing.expect(std.mem.indexOf(u8, skipped.out.items, "first-command") == null);
}

test "only one process writes a journal and descendants do not retain its lock" {
    const gpa = std.testing.allocator;
    var scratch = try Scratch.open();
    defer scratch.close();

    const id = ulid.encode(50, .{3} ** 10);
    try scratch.makeJournal(id, &.{"1"});
    const holder = try spawnTj(gpa, &.{ tj, "--home", scratch.path(), "continue", &id, "--", "/bin/sh", "-c", "echo LOCK-READY; sleep 30" }, 24, 80);
    var holder_out: std.ArrayList(u8) = .empty;
    defer holder_out.deinit(gpa);
    try std.testing.expect(try holder.readUntil(gpa, &holder_out, "LOCK-READY", timeout_ms));

    var blocked = try run(gpa, &.{ "--home", scratch.path(), "continue", &id, "--", "/bin/sh", "-c", "echo SECOND-RAN" }, 24, 80);
    defer blocked.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), blocked.code);
    try std.testing.expect(std.mem.indexOf(u8, blocked.out.items, "already being written") != null);
    try std.testing.expect(std.mem.indexOf(u8, blocked.out.items, "SECOND-RAN") == null);

    _ = std.c.kill(holder.pid, posix.SIG.TERM);
    _ = try holder.finish(gpa, &holder_out, timeout_ms);

    var background = try run(gpa, &.{ "--home", scratch.path(), "continue", &id, "--", "/bin/sh", "-c", "(sleep 3) </dev/null >/dev/null 2>&1 &" }, 24, 80);
    defer background.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), background.code);

    var after = try run(gpa, &.{ "--home", scratch.path(), "continue", &id, "--", "/bin/sh", "-c", "true" }, 24, 80);
    defer after.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), after.code);
}

test "continue starts from the caller state instead of restoring writer state" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var scratch = try Scratch.open();
    defer scratch.close();

    const id = ulid.encode(60, .{4} ** 10);
    try scratch.makeJournal(id, &.{});
    var prior = try run(gpa, &.{ "--home", scratch.path(), "continue", &id, "--", "/bin/zsh", "-f", "-c", "cd /; export PRIOR_WRITER_STATE=secret; setopt extendedglob; prior_fn() { :; }; sleep 2 </dev/null >/dev/null 2>&1 &" }, 24, 80);
    defer prior.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), prior.code);

    var fresh = try run(gpa, &.{ "--home", scratch.path(), "continue", &id, "--", "/bin/zsh", "-f", "-c", "printf 'PWD=%s PRIOR=%s OPT=%s FUNC=%s JOBS=%s\\n' \"$PWD\" \"${PRIOR_WRITER_STATE-unset}\" \"${options[extendedglob]}\" \"${+functions[prior_fn]}\" \"${#jobstates}\"" }, 24, 80);
    defer fresh.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), fresh.code);
    try std.testing.expect(std.mem.indexOf(u8, fresh.out.items, "PRIOR=unset") != null);
    try std.testing.expect(std.mem.indexOf(u8, fresh.out.items, "OPT=off FUNC=0 JOBS=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, fresh.out.items, "PWD=/ PR") == null);
}

// --- resources published by programs ----------------------------------------

/// Emits the OSC 5107 sequences a cooperating program would, from a plain sh
/// script, so the test does not depend on any program that happens to.
fn publisher(gpa: std.mem.Allocator, body: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "printf '{s}'", .{body});
}

test "a noout OSC region stays visible but is replaced in out" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try Journal.open(gpa);
    defer journal.close();
    const producer = try journal.fixture(
        gpa,
        "noout-producer.sh",
        "printf 'ordinary-before\\n'\n" ++
            "printf '\\033]5107;tj;noout\\033\\\\'\n" ++
            "printf 'VISIBLE-BUT-OMITTED\\n'\n" ++
            "printf '\\033]5107;tj;end\\033\\\\'\n" ++
            "printf 'ordinary-after\\n'\n",
    );
    defer gpa.free(producer);

    const child = try spawnJournalZsh(gpa, &journal);
    var transcript: std.ArrayList(u8) = .empty;
    defer transcript.deinit(gpa);
    try setupJournalZsh(gpa, child, &transcript);
    const command = try std.fmt.allocPrint(gpa, "/bin/sh '{s}'", .{producer});
    defer gpa.free(command);
    const from = transcript.items.len;
    try child.write(command);
    try child.write("\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, test_prompt, timeout_ms));
    try child.write("exit 0\n");
    try std.testing.expectEqual(@as(u8, 0), try child.finish(gpa, &transcript, timeout_ms));

    const visible = transcript.items[from..];
    try std.testing.expect(std.mem.indexOf(u8, visible, "VISIBLE-BUT-OMITTED") != null);
    try std.testing.expect(std.mem.indexOf(u8, visible, "5107;tj") == null);

    const out = try journal.read(gpa, "1/out");
    defer gpa.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "ordinary-before") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<tj:noout>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "ordinary-after") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "VISIBLE-BUT-OMITTED") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "5107;tj") == null);

    const meta = try journal.read(gpa, "1/meta.json");
    defer gpa.free(meta);
    try std.testing.expect(std.mem.indexOf(u8, meta, "noout") == null);
    try std.testing.expect(std.mem.indexOf(u8, meta, "VISIBLE-BUT-OMITTED") == null);
}

test "an unfinished noout OSC region cannot suppress the next entry" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try Journal.open(gpa);
    defer journal.close();
    const producer = try journal.fixture(
        gpa,
        "unfinished-noout.sh",
        "printf '\\033]5107;tj;noout\\033\\\\'\n" ++
            "printf 'OMITTED-UNTIL-BOUNDARY\\n'\n",
    );
    defer gpa.free(producer);
    const first = try std.fmt.allocPrint(gpa, "/bin/sh '{s}'", .{producer});
    defer gpa.free(first);
    try recordJournal(gpa, &journal, &.{ first, "printf 'NEXT-INTERACTION-RECORDED\\n'" });

    const first_out = try journal.read(gpa, "1/out");
    defer gpa.free(first_out);
    try std.testing.expect(std.mem.indexOf(u8, first_out, "<tj:noout>") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_out, "OMITTED-UNTIL-BOUNDARY") == null);
    const second_out = try journal.read(gpa, "2/out");
    defer gpa.free(second_out);
    try std.testing.expect(std.mem.indexOf(u8, second_out, "NEXT-INTERACTION-RECORDED") != null);
}

test "tj noout preserves output argv and child statuses while omitting bytes" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try Journal.open(gpa);
    defer journal.close();
    const producer = try journal.fixture(
        gpa,
        "wrapper-producer.sh",
        "printf 'WRAPPER-STDOUT:%s|%s|%s|%s\\n' \"$1\" \"$2\" \"$3\" \"$4\"\n" ++
            "printf 'WRAPPER-STDERR\\n' >&2\n" ++
            "printf 'WRAPPER-CONTEXT:%s|%s|' \"$PWD\" \"$NOOUT_TEST_ENV\"\n" ++
            "if test -t 0 && test -t 1 && test -t 2; then printf 'tty\\n'; else printf 'not-tty\\n'; fi\n",
    );
    defer gpa.free(producer);

    const child = try spawnJournalZsh(gpa, &journal);
    var transcript: std.ArrayList(u8) = .empty;
    defer transcript.deinit(gpa);
    try setupJournalZsh(gpa, child, &transcript);
    const command = try std.fmt.allocPrint(
        gpa,
        "cd /; NOOUT_TEST_ENV=preserved command \"$TJ\" noout -- /bin/sh '{s}' 'two words' '*' --flag --help",
        .{producer},
    );
    defer gpa.free(command);
    const visible_from = transcript.items.len;
    var from = visible_from;
    try child.write(command);
    try child.write("\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, test_prompt, timeout_ms));
    from = transcript.items.len;
    try child.write("command \"$TJ\" noout -- /bin/sh -c 'exit 7'\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, test_prompt, timeout_ms));
    from = transcript.items.len;
    try child.write("command \"$TJ\" noout -- /bin/sh -c 'kill -TERM $$'\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, test_prompt, timeout_ms));
    from = transcript.items.len;
    try child.write("command \"$TJ\" noout -- /definitely/not/a/tj-command\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, test_prompt, timeout_ms));
    try child.write("exit 0\n");
    try std.testing.expectEqual(@as(u8, 0), try child.finish(gpa, &transcript, timeout_ms));

    const visible = transcript.items[visible_from..];
    try std.testing.expect(std.mem.indexOf(u8, visible, "WRAPPER-STDOUT:two words|*|--flag|--help") != null);
    try std.testing.expect(std.mem.indexOf(u8, visible, "WRAPPER-STDERR") != null);
    try std.testing.expect(std.mem.indexOf(u8, visible, "WRAPPER-CONTEXT:/|preserved|tty") != null);
    try std.testing.expect(std.mem.indexOf(u8, visible, "5107;tj") == null);

    const first_out = try journal.read(gpa, "1/out");
    defer gpa.free(first_out);
    try std.testing.expect(std.mem.indexOf(u8, first_out, "<tj:noout>") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_out, "WRAPPER-STDOUT") == null);
    try std.testing.expect(std.mem.indexOf(u8, first_out, "WRAPPER-STDERR") == null);
    for ([_]struct { path: []const u8, want: []const u8 }{
        .{ .path = "1/rc", .want = "0\n" },
        .{ .path = "2/rc", .want = "7\n" },
        .{ .path = "3/rc", .want = "143\n" },
        .{ .path = "4/rc", .want = "127\n" },
    }) |case| {
        const rc = try journal.read(gpa, case.path);
        defer gpa.free(rc);
        try std.testing.expectEqualStrings(case.want, rc);
    }
}

test "tj noout syntax and journal preconditions fail without emitting OSC" {
    const gpa = std.testing.allocator;
    leaveJournal();

    const missing_separator = try runNonTty(gpa, &.{ "noout", "/bin/true" });
    defer gpa.free(missing_separator.stdout);
    defer gpa.free(missing_separator.stderr);
    try std.testing.expectEqual(@as(u8, 2), missing_separator.term.exited);
    try std.testing.expect(std.mem.indexOf(u8, missing_separator.stdout, "5107;tj") == null);
    try std.testing.expect(std.mem.indexOf(u8, missing_separator.stderr, "requires `--`") != null);

    const outside = try runNonTty(gpa, &.{ "noout", "--", "/bin/true" });
    defer gpa.free(outside.stdout);
    defer gpa.free(outside.stderr);
    try std.testing.expectEqual(@as(u8, 1), outside.term.exited);
    try std.testing.expect(std.mem.indexOf(u8, outside.stdout, "5107;tj") == null);
    try std.testing.expect(std.mem.indexOf(u8, outside.stderr, "inside a tj journal writer") != null);
}

test "native grep searches literal command and output lines with stable statuses" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var journal = try Journal.open(gpa);
    defer journal.close();
    const producer = try journal.fixture(gpa, "grep-producer.sh", "printf 'OUTPUT_LITERAL_012\\nMixedAscii012\\n'\n");
    defer gpa.free(producer);
    const producer_command = try std.fmt.allocPrint(gpa, "/bin/sh '{s}'", .{producer});
    defer gpa.free(producer_command);
    try recordJournal(gpa, &journal, &.{ ": COMMAND_LITERAL_012", producer_command, ": '[x].*'", "printf 'BOTH_LITERAL_012\\n'" });
    try journal.enter(gpa);
    defer leaveJournal();
    sys.setEnv("TJ_NEXT", "");
    const home = try journal.homeArg(gpa);
    defer gpa.free(home);
    const id = try journal.journalName(gpa);
    defer gpa.free(id);

    const command_only = try runNonTtyInJournal(gpa, &.{ "--home", home, "grep", "--cmd", "COMMAND_LITERAL_012" }, id, "");
    defer gpa.free(command_only.stdout);
    defer gpa.free(command_only.stderr);
    try std.testing.expectEqual(@as(u8, 0), command_only.term.exited);
    try std.testing.expectEqualStrings("     1 > : COMMAND_LITERAL_012\n", command_only.stdout);
    try std.testing.expectEqualStrings("", command_only.stderr);

    const automatic_pipe = try runNonTtyInJournal(gpa, &.{ "--home", home, "grep", "--cmd", "--color", "auto", "COMMAND_LITERAL_012" }, id, "");
    defer gpa.free(automatic_pipe.stdout);
    defer gpa.free(automatic_pipe.stderr);
    try std.testing.expectEqualStrings(command_only.stdout, automatic_pipe.stdout);

    const forced_color = try runNonTtyInJournal(gpa, &.{ "--home", home, "grep", "--cmd", "--color=always", "COMMAND_LITERAL_012" }, id, "");
    defer gpa.free(forced_color.stdout);
    defer gpa.free(forced_color.stderr);
    try std.testing.expectEqualStrings("     1 > :\x1b[01;31m COMMAND_LITERAL_012\x1b[m\n", forced_color.stdout);

    const disabled_color = try runNonTtyInJournal(gpa, &.{ "--home", home, "grep", "--cmd", "--color=never", "COMMAND_LITERAL_012" }, id, "");
    defer gpa.free(disabled_color.stdout);
    defer gpa.free(disabled_color.stderr);
    try std.testing.expectEqualStrings(command_only.stdout, disabled_color.stdout);

    const output_only = try runNonTtyInJournal(gpa, &.{ "--home", home, "grep", "--out", "OUTPUT_LITERAL_012" }, id, "");
    defer gpa.free(output_only.stdout);
    defer gpa.free(output_only.stderr);
    try std.testing.expectEqual(@as(u8, 0), output_only.term.exited);
    try std.testing.expectEqualStrings("     2 < OUTPUT_LITERAL_012\n", output_only.stdout);

    const folded = try runNonTtyInJournal(gpa, &.{ "--home", home, "grep", "-i", "mixedascii012" }, id, "");
    defer gpa.free(folded.stdout);
    defer gpa.free(folded.stderr);
    try std.testing.expectEqual(@as(u8, 0), folded.term.exited);
    try std.testing.expect(std.mem.indexOf(u8, folded.stdout, "     2 < MixedAscii012") != null);

    const literal = try runNonTtyInJournal(gpa, &.{ "--home", home, "grep", "--cmd", "[x].*" }, id, "");
    defer gpa.free(literal.stdout);
    defer gpa.free(literal.stderr);
    try std.testing.expectEqual(@as(u8, 0), literal.term.exited);
    try std.testing.expectEqualStrings("     3 > : '[x].*'\n", literal.stdout);

    const missing = try runNonTtyInJournal(gpa, &.{ "--home", home, "grep", "absent-literal-012" }, id, "");
    defer gpa.free(missing.stdout);
    defer gpa.free(missing.stderr);
    try std.testing.expectEqual(@as(u8, 1), missing.term.exited);
    try std.testing.expectEqualStrings("", missing.stdout);
    try std.testing.expectEqualStrings("", missing.stderr);

    const bad = try runNonTtyInJournal(gpa, &.{ "--home", home, "grep", "--unknown", "x" }, id, "");
    defer gpa.free(bad.stdout);
    defer gpa.free(bad.stderr);
    try std.testing.expectEqual(@as(u8, 2), bad.term.exited);
    try std.testing.expect(std.mem.indexOf(u8, bad.stderr, "Usage: tj grep") != null);

    const leading = try runNonTtyInJournal(gpa, &.{ "--home", home, "grep", "--", "-not-present" }, id, "");
    defer gpa.free(leading.stdout);
    defer gpa.free(leading.stderr);
    try std.testing.expectEqual(@as(u8, 1), leading.term.exited);

    const both = try runNonTtyInJournal(gpa, &.{ "--home", home, "grep", "--cmd", "--out", "BOTH_LITERAL_012" }, id, "");
    defer gpa.free(both.stdout);
    defer gpa.free(both.stderr);
    try std.testing.expectEqual(@as(u8, 0), both.term.exited);
    try std.testing.expect(std.mem.indexOf(u8, both.stdout, "     4 >") != null);
    try std.testing.expect(std.mem.indexOf(u8, both.stdout, "     4 <") != null);

    const outside = try runNonTtyInJournal(gpa, &.{ "--home", home, "grep", "x" }, "", "");
    defer gpa.free(outside.stdout);
    defer gpa.free(outside.stderr);
    try std.testing.expectEqual(@as(u8, 2), outside.term.exited);
    try std.testing.expectEqualStrings("tj grep: no current journal; use --all\n", outside.stderr);

    const help = try runNonTtyInJournal(gpa, &.{ "grep", "--help" }, "", "");
    defer gpa.free(help.stdout);
    defer gpa.free(help.stderr);
    try std.testing.expectEqual(@as(u8, 0), help.term.exited);
    try std.testing.expect(std.mem.indexOf(u8, help.stdout, "Usage: tj grep") != null);

    var dir = try journal.journalDir();
    defer dir.close(io);
    try dir.deleteFile(io, "2/out");
    try dir.deleteTree(io, "3");
    const removed = try runNonTtyInJournal(gpa, &.{ "--home", home, "grep", "OUTPUT_LITERAL_012" }, id, "");
    defer gpa.free(removed.stdout);
    defer gpa.free(removed.stderr);
    try std.testing.expectEqual(@as(u8, 1), removed.term.exited);
}

test "native grep all qualifies journal suffixes and orders newest first" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var journal = try Journal.open(gpa);
    defer journal.close();
    try recordJournal(gpa, &journal, &.{": SHARED_GREP_012"});
    const older = try journal.journalName(gpa);
    defer gpa.free(older);
    const newest = ulid.encode(std.math.maxInt(u48), .{0} ** 10);

    var root = try journal.tmp.dir.openDir(io, journal_dir, .{});
    defer root.close(io);
    try root.createDir(io, &newest, @enumFromInt(0o700));
    var newest_dir = try root.openDir(io, &newest, .{});
    defer newest_dir.close(io);
    try newest_dir.createDir(io, "1", @enumFromInt(0o700));
    var interaction = try newest_dir.openDir(io, "1", .{});
    defer interaction.close(io);
    try interaction.writeFile(io, .{ .sub_path = "cmd", .data = ": SHARED_GREP_012" });
    try interaction.writeFile(io, .{ .sub_path = "out", .data = "SHARED_GREP_012\n" });
    try interaction.writeFile(io, .{ .sub_path = "rc", .data = "0\n" });

    leaveJournal();
    const home = try journal.homeArg(gpa);
    defer gpa.free(home);
    const result = try runNonTtyInJournal(gpa, &.{ "--home", home, "grep", "--all", "SHARED_GREP_012" }, "", "");
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
    const expected = try std.fmt.allocPrint(
        gpa,
        "     @{s}.1 > : SHARED_GREP_012\n" ++
            "     @{s}.1 < SHARED_GREP_012\n" ++
            "     @{s}.1 > : SHARED_GREP_012\n",
        .{ newest[newest.len - 4 ..], newest[newest.len - 4 ..], older[older.len - 4 ..] },
    );
    defer gpa.free(expected);
    try std.testing.expectEqualStrings(expected, result.stdout);
}

test "history and grep never replay stored terminal controls" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var scratch = try Scratch.open();
    defer scratch.close();

    const id = ulid.encode(48, .{8} ** 10);
    try scratch.makeJournal(id, &.{"1"});
    var journal = try scratch.tmp.dir.openDir(io, &id, .{});
    defer journal.close(io);
    const dangerous = "needle before\x1b[2J\x1b[Hneedle after\rneedle title\x1b]0;PWNED\x07 tail\x01";
    try journal.writeFile(io, .{ .sub_path = "1/cmd", .data = dangerous });
    try journal.writeFile(io, .{ .sub_path = "1/out", .data = dangerous ++ "\n" });
    try journal.writeFile(io, .{ .sub_path = "1/rc", .data = "0\n" });

    const history = try runNonTtyInJournal(gpa, &.{ "--home", scratch.path(), "hist" }, &id, "3");
    defer gpa.free(history.stdout);
    defer gpa.free(history.stderr);
    try std.testing.expectEqual(@as(u8, 0), history.term.exited);
    try expectSafeStoredReport(history.stdout);
    try std.testing.expect(std.mem.indexOf(u8, history.stdout, "needle beforeneedle after needle title tail") != null);

    const grep = try runNonTtyInJournal(gpa, &.{ "--home", scratch.path(), "grep", "needle" }, &id, "3");
    defer gpa.free(grep.stdout);
    defer gpa.free(grep.stderr);
    try std.testing.expectEqual(@as(u8, 0), grep.term.exited);
    try expectSafeStoredReport(grep.stdout);
    try std.testing.expect(std.mem.indexOf(u8, grep.stdout, "needle beforeneedle after needle title tail") != null);

    const colored = try runNonTtyInJournal(
        gpa,
        &.{ "--home", scratch.path(), "grep", "--color", "always", "needle" },
        &id,
        "3",
    );
    defer gpa.free(colored.stdout);
    defer gpa.free(colored.stderr);
    try std.testing.expectEqual(@as(u8, 0), colored.term.exited);
    try std.testing.expect(std.mem.indexOf(u8, colored.stdout, "\x1b[01;31mneedle\x1b[m") != null);
    try std.testing.expect(std.mem.indexOf(u8, colored.stdout, "\x1b[2J") == null);
    try std.testing.expect(std.mem.indexOf(u8, colored.stdout, "\x1b]0;") == null);
    try std.testing.expect(std.mem.indexOf(u8, colored.stdout, "PWNED") == null);
}

fn expectSafeStoredReport(bytes: []const u8) !void {
    try std.testing.expect(std.mem.indexOfScalar(u8, bytes, 0x1b) == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, bytes, '\r') == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, bytes, 0x01) == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, bytes, 0x7f) == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, bytes, 0x9b) == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "PWNED") == null);
}

test "terminal native grep omits its results while redirected output stays plain" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var journal = try Journal.open(gpa);
    defer journal.close();
    const producer = try journal.fixture(
        gpa,
        "native-grep-producer.sh",
        "printf '  NOOUT_GREP_PAYLOAD_012    padded\\tresult  \\n'\n",
    );
    defer gpa.free(producer);
    const redirected_path = try journal.fixture(gpa, "redirected-grep", "");
    defer gpa.free(redirected_path);

    const child = try spawnJournalZsh(gpa, &journal);
    var transcript: std.ArrayList(u8) = .empty;
    defer transcript.deinit(gpa);
    try setupJournalZsh(gpa, child, &transcript);
    const command = try std.fmt.allocPrint(gpa, "/bin/sh '{s}'", .{producer});
    defer gpa.free(command);
    var from = transcript.items.len;
    try child.write(command);
    try child.write("\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, test_prompt, timeout_ms));

    // Grep rows share history's entry annotation and failure markers.
    var journal_dir_handle = try journal.journalDir();
    defer journal_dir_handle.close(std.testing.io);
    try journal_dir_handle.writeFile(std.testing.io, .{ .sub_path = "1/rc", .data = "7\n" });
    try journal.enter(gpa);
    defer leaveJournal();
    const home = try journal.homeArg(gpa);
    defer gpa.free(home);
    for ([_][]const []const u8{
        &.{ "--home", home, "name", "@1", "grep-hit" },
        &.{ "--home", home, "tag", "@1", "bug", "parser" },
        &.{ "--home", home, "pin", "@1" },
    }) |annotation_args| {
        var result = try run(gpa, annotation_args, 24, 100);
        defer result.out.deinit(gpa);
        try std.testing.expectEqual(@as(u8, 0), result.code);
    }

    from = transcript.items.len;
    try child.write("env -u NO_COLOR TERM=xterm-256color GREP_COLORS='mt=4;32' \"$TJ\" grep --color auto --out NOOUT_GREP_PAYLOAD_012\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, "*@#\x1b[31m!\x1b[0m \x1b[33m1\x1b[0m \x1b[2m<\x1b[0m", timeout_ms));
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, "\x1b[4;32mNOOUT_GREP_PAYLOAD_012\x1b[m", timeout_ms));
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, "\x1b[32m@grep-hit #bug #parser\x1b[0m", timeout_ms));
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, "\x1b[31m!7\x1b[0m", timeout_ms));
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, test_prompt, timeout_ms));

    from = transcript.items.len;
    try child.write("command \"$TJ\" grep --out NOOUT_GREP_PAYLOAD_012\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, test_prompt, timeout_ms));

    const redirect_command = try std.fmt.allocPrint(
        gpa,
        "command \"$TJ\" grep --out NOOUT_GREP_PAYLOAD_012 >'{s}'",
        .{redirected_path},
    );
    defer gpa.free(redirect_command);
    from = transcript.items.len;
    try child.write(redirect_command);
    try child.write("\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, test_prompt, timeout_ms));

    from = transcript.items.len;
    try child.write("command \"$TJ\" grep --cmd SELF_ONLY_GREP_012; printf 'SELF-STATUS=%s\\n' $?\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, "SELF-STATUS=1", timeout_ms));
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, test_prompt, timeout_ms));
    try child.write("exit 0\n");
    try std.testing.expectEqual(@as(u8, 0), try child.finish(gpa, &transcript, timeout_ms));

    for ([_][]const u8{ "2/out", "3/out" }) |path| {
        const recorded = try journal.read(gpa, path);
        defer gpa.free(recorded);
        try std.testing.expect(std.mem.indexOf(u8, recorded, "<tj:noout>") != null);
        try std.testing.expect(std.mem.indexOf(u8, recorded, "NOOUT_GREP_PAYLOAD_012") == null);
        try std.testing.expect(std.mem.indexOf(u8, recorded, "5107;tj") == null);
    }
    const redirected = try journal.tmp.dir.readFileAlloc(std.testing.io, "redirected-grep", gpa, .limited(4096));
    defer gpa.free(redirected);
    try std.testing.expectEqualStrings(
        "*@#! 1 < NOOUT_GREP_PAYLOAD_012 padded result @grep-hit #bug #parser !7\n",
        redirected,
    );
    const redirected_out = try journal.read(gpa, "4/out");
    defer gpa.free(redirected_out);
    try std.testing.expect(std.mem.indexOf(u8, redirected_out, "<tj:noout>") == null);
    try std.testing.expect(std.mem.indexOf(u8, redirected_out, "5107;tj") == null);
    const self_out = try journal.read(gpa, "5/out");
    defer gpa.free(self_out);
    try std.testing.expect(std.mem.indexOf(u8, self_out, "SELF-STATUS=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, self_out, "<tj:noout>") == null);
}

test "a program can publish parts of its output as named resources" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try Journal.open(gpa);
    defer journal.close();

    const script = try publisher(gpa, "before\\n" ++
        "\\033]5107;tj;begin;files/data.csv;text/csv\\033\\\\" ++
        "date,amount\\n2026-08-01,12.50\\n" ++
        "\\033]5107;tj;end\\033\\\\" ++
        "after\\n");
    defer gpa.free(script);
    try recordJournal(gpa, &journal, &.{script});

    const resource = try journal.read(gpa, "1/files/data.csv");
    defer gpa.free(resource);
    try std.testing.expectEqualStrings("date,amount\n2026-08-01,12.50\n", resource);

    // The resource is a span of the output, not a replacement for it.
    const out = try journal.read(gpa, "1/out");
    defer gpa.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "2026-08-01,12.50") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "before") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "after") != null);
    // The markers themselves are protocol, not output.
    try std.testing.expect(std.mem.indexOf(u8, out, "5107") == null);

    const meta = try journal.read(gpa, "1/meta.json");
    defer gpa.free(meta);
    try std.testing.expect(std.mem.indexOf(u8, meta, "\"files/data.csv\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, meta, "\"text/csv\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, meta, "\"truncated\":false") != null);
}

test "a resource name cannot escape the entry or overwrite tj's own files" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try Journal.open(gpa);
    defer journal.close();

    const script = try publisher(gpa, "\\033]5107;tj;begin;../../escape\\033\\\\PWNED\\033]5107;tj;end\\033\\\\" ++
        "\\033]5107;tj;begin;out\\033\\\\CLOBBER\\033]5107;tj;end\\033\\\\" ++
        "\\033]5107;tj;begin;/etc/passwd\\033\\\\ROOT\\033]5107;tj;end\\033\\\\" ++
        "\\033]5107;tj;begin;ok/kept.txt\\033\\\\legit\\033]5107;tj;end\\033\\\\");
    defer gpa.free(script);
    try recordJournal(gpa, &journal, &.{script});

    // The one valid name is published.
    const kept = try journal.read(gpa, "1/ok/kept.txt");
    defer gpa.free(kept);
    try std.testing.expectEqualStrings("legit", kept);

    // The rest are refused, and `out` still holds what tj put there.
    var dir = try journal.journalDir();
    defer dir.close(std.testing.io);
    try std.testing.expectError(error.FileNotFound, dir.openFile(std.testing.io, "1/escape", .{}));

    const out = try journal.read(gpa, "1/out");
    defer gpa.free(out);
    // Present as output, because the program printed it; not as the file.
    try std.testing.expect(std.mem.indexOf(u8, out, "CLOBBER") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "PWNED") != null);

    // And every refusal is on the record.
    const log = try journal.read(gpa, "log");
    defer gpa.free(log);
    try std.testing.expect(std.mem.indexOf(u8, log, "../../escape") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "refused resource name out") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "/etc/passwd") != null);
}

test "a resource the program never closed is flagged truncated" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try Journal.open(gpa);
    defer journal.close();

    const script = try publisher(gpa, "\\033]5107;tj;begin;partial\\033\\\\half a file");
    defer gpa.free(script);
    try recordJournal(gpa, &journal, &.{script});

    const resource = try journal.read(gpa, "1/partial");
    defer gpa.free(resource);
    try std.testing.expect(std.mem.indexOf(u8, resource, "half a file") != null);

    const meta = try journal.read(gpa, "1/meta.json");
    defer gpa.free(meta);
    try std.testing.expect(std.mem.indexOf(u8, meta, "\"truncated\":true") != null);
}

test "published resources are addressable and completable" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try Journal.open(gpa);
    defer journal.close();

    const script = try publisher(gpa, "\\033]5107;tj;begin;files/note.txt;text/plain\\033\\\\hello resource\\033]5107;tj;end\\033\\\\");
    defer gpa.free(script);
    try recordJournal(gpa, &journal, &.{script});
    try journal.enter(gpa);

    const home = try journal.homeArg(gpa);
    defer gpa.free(home);

    var read = try run(gpa, &.{ "--home", home, "cat", "@1/files/note.txt" }, 24, 80);
    defer read.out.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, read.out.items, "hello resource") != null);

    var offered = try run(gpa, &.{ "--home", home, "complete", "@1/files/" }, 24, 80);
    defer offered.out.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, offered.out.items, "@1/files/note.txt") != null);

    // `files/` shows up as a directory alongside the core resources.
    var top = try run(gpa, &.{ "--home", home, "complete", "@1/" }, 24, 80);
    defer top.out.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, top.out.items, "@1/files/") != null);
}

test "zsh completion keeps special resource names as one inert argument" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try Journal.open(gpa);
    defer journal.close();

    const child = try spawnJournalZsh(gpa, &journal);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try setupJournalZsh(gpa, child, &out);

    const publish = try publisher(gpa, "\\033]5107;tj;begin;files/note *$ file.txt;text/plain\\033\\\\" ++
        "special-resource-content\\033]5107;tj;end\\033\\\\" ++
        "\\033]5107;tj;begin;top *$ note.txt;text/plain\\033\\\\" ++
        "top-resource-content\\033]5107;tj;end\\033\\\\");
    defer gpa.free(publish);
    var from = out.items.len;
    try child.write(publish);
    try child.write("\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, test_prompt, timeout_ms));

    from = out.items.len;
    // `compinit` may otherwise stop for its insecure-directory question on a
    // CI image. This fixture tests TJ's completion functions, not compinit's
    // trust policy, so ignore insecure system entries instead of prompting.
    // Keep the readiness marker split in the typed command: terminal echo
    // must not satisfy the wait before setup actually reaches its end.
    var completion_setup: std.ArrayList(u8) = .empty;
    defer completion_setup.deinit(gpa);
    // Generated external completers invoke `tj complete`. Point that name at
    // the just-built binary instead of any older TJ installed on the host.
    try completion_setup.appendSlice(gpa, "tj() { command ");
    try appendShellQuoted(gpa, &completion_setup, tj);
    try completion_setup.appendSlice(gpa, " \"$@\"; }; autoload -Uz compinit && compinit -D -i && . ");
    try appendShellQuoted(gpa, &completion_setup, options.zsh_completion);
    try completion_setup.appendSlice(
        gpa,
        " && _tj_register_completion && print -r -- TJ_COMPINIT_\"\"READY\n",
    );
    try child.write(completion_setup.items);
    if (!try child.readUntilFrom(gpa, &out, from, "TJ_COMPINIT_READY", timeout_ms)) {
        std.debug.print("completion setup did not finish; transcript follows:\n{s}\n", .{out.items[from..]});
        return error.CompletionSetupDidNotFinish;
    }
    if (!try child.readUntilFrom(gpa, &out, from, test_prompt, timeout_ms)) {
        std.debug.print("completion setup did not return a prompt; transcript follows:\n{s}\n", .{out.items[from..]});
        return error.CompletionPromptMissing;
    }

    // Expose the exact editable buffer after completion without accepting it.
    from = out.items.len;
    try child.write(
        "_tj_test_buffer() { zle -M \"TJ_BUFFER=${(qqq)BUFFER} CURSOR=$CURSOR\"; }; " ++
            "zle -N _tj_test_buffer; " ++
            "bindkey -M emacs '^X^T' _tj_test_buffer; " ++
            "bindkey -M viins '^X^T' _tj_test_buffer\n",
    );
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, test_prompt, timeout_ms));

    // Zecli's generated script owns static command and option completion.
    from = out.items.len;
    try child.write("tj journa");
    try child.write("\t");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, "journal", timeout_ms));
    try cancelZleLine(gpa, child, &out);

    from = out.items.len;
    try child.write("tj hist --t");
    try child.write("\t");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, "--tag", timeout_ms));
    try cancelZleLine(gpa, child, &out);

    // A generated command completer must report success after adding matches.
    // Otherwise zsh retries it for every matcher and prints duplicate groups.
    from = out.items.len;
    try child.write(
        "zstyle ':completion:*' matcher-list '' " ++
            "'m:{a-zA-Z}={A-Za-z}' 'r:|[._-]=* r:|=*' 'l:|=* r:|=*'\n",
    );
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, test_prompt, timeout_ms));
    from = out.items.len;
    try child.write("tj grep -\t\x18\x14");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, "TJ_BUFFER=", timeout_ms));
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, out.items[from..], "Search every journal"),
    );
    try cancelZleLine(gpa, child, &out);

    from = out.items.len;
    try child.write("command \"$TJ\" name @1 build-failure\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, test_prompt, timeout_ms));

    // Expose preexec's exact command without changing the ZLE probe above.
    from = out.items.len;
    try child.write(
        "_tj_test_preexec() { print -r -- \"TJ_PREEXEC=${(qqq)1}\" > /dev/tty; }; " ++
            "add-zsh-hook preexec _tj_test_preexec\n",
    );
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, test_prompt, timeout_ms));

    // An unambiguous name gets its closing bracket and then behaves as a path.
    from = out.items.len;
    try child.write("cat ~[@1");
    try child.write("\t");
    if (!try child.readUntilFrom(gpa, &out, from, "~[@1]", timeout_ms)) {
        std.debug.print("numeric dynamic-directory completion failed; transcript follows:\n{s}\n", .{out.items[from..]});
        return error.NumericDirectoryCompletionMismatch;
    }
    try child.write("/out\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, "special-resource-content", timeout_ms));
    // Output can arrive before precmd has redrawn the prompt. Do not start the
    // next ZLE interaction until the shell is actually ready for input again.
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, test_prompt, timeout_ms));

    // Dynamic-directory name completion is offered inside ~[...].
    from = out.items.len;
    try child.write("cat ~[@");
    try child.write("\t");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, "@1", timeout_ms));
    try cancelZleLine(gpa, child, &out);

    // Assigned names participate in dynamic-directory name completion. First
    // inspect the completed path exactly as a user can with the probe widget.
    from = out.items.len;
    try child.write("cat ~[@build");
    try child.write("\t");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, "build-failure]", timeout_ms));
    try child.write("/out");
    try child.write("\x18\x14");
    if (!try child.readUntilFrom(
        gpa,
        &out,
        from,
        "TJ_BUFFER=\"cat ~[@build-failure]/out\" CURSOR=25",
        timeout_ms,
    )) {
        std.debug.print("named completion produced the wrong ZLE buffer; transcript follows:\n{s}\n", .{out.items[from..]});
        return error.NamedCompletionBufferMismatch;
    }
    try cancelZleLine(gpa, child, &out);

    // Repeat without the probe between completion and accept-line, then check
    // both what preexec received and what the resulting command produced.
    from = out.items.len;
    try child.write("cat ~[@build");
    try child.write("\t");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, "build-failure]", timeout_ms));
    try child.write("/out\n");
    if (!try child.readUntilFrom(
        gpa,
        &out,
        from,
        "TJ_PREEXEC=\"cat ~[@build-failure]/out\"",
        timeout_ms,
    )) {
        std.debug.print("named completion did not reach preexec intact; transcript follows:\n{s}\n", .{out.items[from..]});
        return error.NamedCompletionPreexecMismatch;
    }
    if (!try child.readUntilFrom(gpa, &out, from, "special-resource-content", timeout_ms)) {
        std.debug.print("named completion command produced no resource content; transcript follows:\n{s}\n", .{out.items[from..]});
        return error.NamedCompletionCommandFailed;
    }
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, test_prompt, timeout_ms));

    // Once the bracket is closed, ordinary filesystem completion lists the
    // interaction directory rather than going through the shorthand completer.
    from = out.items.len;
    try child.write("cat ~[@1]/");
    try child.write("\t");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, "files/", timeout_ms));
    try cancelZleLine(gpa, child, &out);

    from = out.items.len;
    try child.write("cat ~[@1]/files/note");
    try child.write("\t");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, "file.txt", timeout_ms));
    try child.write("\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, "special-resource-content", timeout_ms));
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, test_prompt, timeout_ms));

    // Shorthand resource completion works beneath a named interaction too.
    from = out.items.len;
    try child.write("cat @build-failure/files/note");
    try child.write("\t");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, "file.txt", timeout_ms));
    try child.write("\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, "special-resource-content", timeout_ms));
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, test_prompt, timeout_ms));

    from = out.items.len;
    try child.write("cat ~[@1]/top");
    try child.write("\t");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, "note.txt", timeout_ms));
    try child.write("\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, "top-resource-content", timeout_ms));
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, test_prompt, timeout_ms));

    // The original shorthand completion remains available.
    from = out.items.len;
    try child.write("cat @1/files/note");
    try child.write("\t");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, "file.txt", timeout_ms));
    try child.write("\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, "special-resource-content", timeout_ms));
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, test_prompt, timeout_ms));

    // Zecli's positional completion delegates back to `tj complete`, so TJ
    // commands get the same entry-resource candidates as arbitrary commands.
    // Keep this after the numeric dynamic-directory checks: cancelling a ZLE
    // line records a probe command and can create an otherwise-ambiguous @10.
    from = out.items.len;
    try child.write("tj cat @1/cw");
    try child.write("\t");
    if (!try child.readUntilFrom(gpa, &out, from, "@1/cwd", timeout_ms)) {
        std.debug.print("generated reference completion offered no cwd resource; transcript follows:\n{s}\n", .{out.items[from..]});
        return error.CommandReferenceCompletionMissing;
    }
    try child.write("\x18\x14");
    if (!try child.readUntilFrom(gpa, &out, from, "TJ_BUFFER=", timeout_ms)) {
        std.debug.print("generated reference completion produced the wrong ZLE buffer; transcript follows:\n{s}\n", .{out.items[from..]});
        return error.CommandReferenceCompletionMismatch;
    }
    try cancelZleLine(gpa, child, &out);

    try child.write("exit 0\n");
    try std.testing.expectEqual(@as(u8, 0), try child.finish(gpa, &out, timeout_ms));
}

test "a published resource survives arbitrary bytes" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try Journal.open(gpa);
    defer journal.close();

    // Everything that could plausibly be mistaken for control information:
    // a complete OSC, an unterminated one, the alternate screen switches,
    // every combination of CR and LF, tabs, and all 256 byte values.
    var blob: std.ArrayList(u8) = .empty;
    defer blob.deinit(gpa);
    try blob.appendSlice(gpa, "\x1b]0;title\x07");
    try blob.appendSlice(gpa, "\x1b]");
    try blob.appendSlice(gpa, &[_]u8{0} ** 8);
    try blob.appendSlice(gpa, "\x1b[?1049hpainted\x1b[?1049l");
    try blob.appendSlice(gpa, "\x1b]5107;other;x\x1b\\");
    try blob.appendSlice(gpa, "\r\n\n\r\r\n\t\t");
    for (0..256) |byte| try blob.append(gpa, @intCast(byte));

    const path = try journal.fixture(gpa, "blob.bin", blob.items);
    defer gpa.free(path);

    const script = try std.fmt.allocPrint(gpa, "printf '\\033]5107;tj;begin;files/blob.bin;application/octet-stream\\033\\\\'; " ++
        "cat {s}; " ++
        "printf '\\033]5107;tj;end\\033\\\\'", .{path});
    defer gpa.free(script);
    try recordJournal(gpa, &journal, &.{script});

    const recovered = try journal.read(gpa, "1/files/blob.bin");
    defer gpa.free(recovered);

    // The terminal's newline translation is undone exactly, so even a
    // carriage return the data really contained comes back.
    try std.testing.expectEqualSlices(u8, blob.items, recovered);
}

// --- replay -------------------------------------------------------------------

test "invalid replay numeric options exit cleanly" {
    const gpa = std.testing.allocator;
    leaveJournal();

    const cases = [_][]const []const u8{
        &.{ "replay", "--from", "4294967296" },
        &.{ "replay", "--speed", "nan" },
        &.{ "replay", "--typing", "18446744073709551616" },
    };
    for (cases) |args| {
        var r = try run(gpa, args, 24, 80);
        defer r.out.deinit(gpa);

        try std.testing.expectEqual(@as(u8, 2), r.code);
        try std.testing.expect(std.mem.indexOf(u8, r.out.items, "invalid replay numeric option") != null);
        try std.testing.expect(std.mem.indexOf(u8, r.out.items, "panic") == null);
        try std.testing.expect(std.mem.indexOf(u8, r.out.items, "error return trace") == null);
    }
}

test "replay prefers recorded prompts and permits an explicit override" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    leaveJournal();
    var scratch = try Scratch.open();
    defer scratch.close();

    const id = ulid.encode(44, .{7} ** 10);
    try scratch.makeJournal(id, &.{"1"});
    var journal = try scratch.tmp.dir.openDir(io, &id, .{});
    defer journal.close(io);
    var interaction = try journal.openDir(io, "1", .{});
    defer interaction.close(io);
    try interaction.writeFile(io, .{ .sub_path = "prompt", .data = "\x1b[36mCAPTURED-PROMPT> \x1b[0m" });
    try interaction.writeFile(io, .{ .sub_path = "cmd", .data = "recorded-command" });
    try interaction.writeFile(io, .{ .sub_path = "out", .data = "RECORDED-OUTPUT\r\n" });

    var recorded = try run(gpa, &.{
        "--home", scratch.path(), "replay", &id, "--typing", "0", "--max-pause", "0",
    }, 24, 80);
    defer recorded.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), recorded.code);
    const prompt_at = std.mem.indexOf(u8, recorded.out.items, "CAPTURED-PROMPT") orelse return error.TestUnexpectedResult;
    const command_at = std.mem.indexOf(u8, recorded.out.items, "recorded-command") orelse return error.TestUnexpectedResult;
    try std.testing.expect(prompt_at < command_at);
    try std.testing.expect(std.mem.indexOf(u8, recorded.out.items, "\x1b[36m") != null);

    var overridden = try run(gpa, &.{
        "--home", scratch.path(), "replay", &id, "--typing", "0", "--max-pause", "0", "--prompt", "OVERRIDE> ",
    }, 24, 80);
    defer overridden.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), overridden.code);
    try std.testing.expect(std.mem.indexOf(u8, overridden.out.items, "OVERRIDE> recorded-command") != null);
    try std.testing.expect(std.mem.indexOf(u8, overridden.out.items, "CAPTURED-PROMPT") == null);
}

test "a journal replays the commands and output it recorded" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try Journal.open(gpa);
    defer journal.close();
    try recordJournal(gpa, &journal, &.{ "echo first-marker", "echo second-marker" });
    leaveJournal();

    const home = try journal.homeArg(gpa);
    defer gpa.free(home);

    // No pacing: a test must not wait for a demo to play out.
    var r = try run(gpa, &.{
        "--home", home, "replay", "--typing", "0", "--max-pause", "0", "--prompt", "% ",
    }, 24, 80);
    defer r.out.deinit(gpa);

    // Each command is shown, then what it printed, in the order they ran.
    const first_cmd = std.mem.indexOf(u8, r.out.items, "echo first-marker") orelse return error.TestUnexpectedResult;
    const first_out = std.mem.indexOf(u8, r.out.items, "first-marker\r") orelse return error.TestUnexpectedResult;
    const second_cmd = std.mem.indexOf(u8, r.out.items, "echo second-marker") orelse return error.TestUnexpectedResult;
    try std.testing.expect(first_cmd < first_out);
    try std.testing.expect(first_out < second_cmd);

    // An explicit prompt replaces the captured one.
    try std.testing.expect(std.mem.indexOf(u8, r.out.items, "% ") != null);
}

test "replay can be narrowed to a range of entries" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try Journal.open(gpa);
    defer journal.close();
    try recordJournal(gpa, &journal, &.{ "echo alpha", "echo beta", "echo gamma" });
    leaveJournal();

    const home = try journal.homeArg(gpa);
    defer gpa.free(home);

    var r = try run(gpa, &.{
        "--home", home, "replay", "--typing", "0", "--max-pause", "0", "--from", "2", "--to", "2",
    }, 24, 80);
    defer r.out.deinit(gpa);

    try std.testing.expect(std.mem.indexOf(u8, r.out.items, "echo beta") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out.items, "alpha") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.out.items, "gamma") == null);
}

test "replay names a journal by suffix, like every other reference" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try Journal.open(gpa);
    defer journal.close();
    try recordJournal(gpa, &journal, &.{"echo by-suffix"});
    leaveJournal();

    const name = try journal.journalName(gpa);
    defer gpa.free(name);
    const home = try journal.homeArg(gpa);
    defer gpa.free(home);

    var r = try run(gpa, &.{
        "--home", home, "replay", name[name.len - 4 ..], "--typing", "0", "--max-pause", "0",
    }, 24, 80);
    defer r.out.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, r.out.items, "echo by-suffix") != null);
}

test "replay refuses to run inside a journal writer" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try Journal.open(gpa);
    defer journal.close();
    try recordJournal(gpa, &journal, &.{"echo recorded"});
    // Being inside a journal writer is exactly what TJ_JOURNAL means.
    try journal.enter(gpa);

    const home = try journal.homeArg(gpa);
    defer gpa.free(home);

    var refused = try run(gpa, &.{ "--home", home, "replay", "--typing", "0" }, 24, 80);
    defer refused.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), refused.code);
    // The recording must not have been replayed into the live writer.
    try std.testing.expect(std.mem.indexOf(u8, refused.out.items, "echo recorded") == null);

    // Asking only how long it would take prints no recording, so it is allowed:
    // tj-tape needs it, and is usually run from inside a writer.
    var duration = try run(gpa, &.{ "--home", home, "replay", "--duration" }, 24, 80);
    defer duration.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), duration.code);
}

test "replay with no journal named plays the most recent one" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try Journal.open(gpa);
    defer journal.close();
    try recordJournal(gpa, &journal, &.{"echo only-child"});
    leaveJournal();

    const home = try journal.homeArg(gpa);
    defer gpa.free(home);

    // Deliberately not inside a journal writer, which is the only way replay runs.
    var r = try run(gpa, &.{ "--home", home, "replay", "--typing", "0", "--max-pause", "0" }, 24, 80);
    defer r.out.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, r.out.items, "echo only-child") != null);
}
