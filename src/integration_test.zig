//! End-to-end tests for the proxy. Each one drives the real `tj` binary
//! through a pty, the same way a terminal emulator does.
//!
//! The claim under test is transparency: a program running under `tj` must not
//! be able to tell, and the user's terminal must be handed back untouched.

const std = @import("std");
const posix = std.posix;
const harness = @import("harness.zig");
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
        &.{ tj, "new", "--", "/bin/sh", "-c", "trap 'echo GOTTERM; exit 9' TERM; echo READY; sleep 5" },
        24,
        80,
    );
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    try std.testing.expect(try child.readUntil(gpa, &out, "READY", timeout_ms));
    _ = std.c.kill(child.pid, posix.SIG.TERM);
    _ = try child.finish(gpa, &out, timeout_ms);

    try std.testing.expect(std.mem.indexOf(u8, out.items, "GOTTERM") != null);
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

fn setupJournalZsh(gpa: std.mem.Allocator, child: harness.PtyChild, out: *std.ArrayList(u8)) !void {
    var command: std.ArrayList(u8) = .empty;
    defer command.deinit(gpa);
    // `source -- file` is not portable across the zsh versions used by the
    // native CI runners. The POSIX dot builtin accepts the quoted pathname.
    try command.appendSlice(gpa, ". ");
    try appendShellQuoted(gpa, &command, options.plugin);
    try command.appendSlice(gpa, " || exit; PS1='TJ_TEST_PROMPT> '\n");
    try child.write(command.items);
    if (!try child.readUntil(gpa, out, test_prompt, timeout_ms)) return error.ShellNotReady;
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
    var listed = try run(gpa, &.{ "--home", home, "journals" }, 24, 80);
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

test "an interrupted writer leaves the interaction without an rc" {
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

// --- the @ namespace --------------------------------------------------------

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

    // Not a reference at all.
    var bad = try run(gpa, &.{ "--home", home, "resolve", "@nope" }, 24, 80);
    defer bad.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), bad.code);

    // Well formed, but there is no interaction 999.
    var missing = try run(gpa, &.{ "--home", home, "resolve", "@999/out" }, 24, 80);
    defer missing.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 2), missing.code);
}

test "a reference cannot escape its interaction directory" {
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
    try std.testing.expect(std.mem.indexOf(u8, r.out.items, "@1/out") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out.items, "@1/rc") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out.items, "meta.json") == null);
}

test "an unquoted reference on a command line becomes a path" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try Journal.open(gpa);
    defer journal.close();

    // The second command reads the first one's output through the journal.
    try recordJournal(gpa, &journal, &.{ "echo alpha-marker", "cat @1/out" });

    const second_out = try journal.read(gpa, "2/out");
    defer gpa.free(second_out);
    try std.testing.expect(std.mem.indexOf(u8, second_out, "alpha-marker") != null);

    // The journal records what was typed, not what ran.
    const second_cmd = try journal.read(gpa, "2/cmd");
    defer gpa.free(second_cmd);
    try std.testing.expectEqualStrings("cat @1/out", second_cmd);

    // ...and what ran is kept alongside it.
    const meta = try journal.read(gpa, "2/meta.json");
    defer gpa.free(meta);
    try std.testing.expect(std.mem.indexOf(u8, meta, "expanded_cmd") != null);
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
    });

    const quoted = try journal.read(gpa, "2/out");
    defer gpa.free(quoted);
    try std.testing.expect(std.mem.indexOf(u8, quoted, "literal @1/out here") != null);

    const address = try journal.read(gpa, "3/out");
    defer gpa.free(address);
    try std.testing.expect(std.mem.indexOf(u8, address, "user@host") != null);

    // Neither line was rewritten, so neither has an expansion recorded.
    for ([_][]const u8{ "2/meta.json", "3/meta.json" }) |path| {
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

test "tj cat takes the path a reference expanded to, as well as the reference" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try Journal.open(gpa);
    defer journal.close();
    try recordJournal(gpa, &journal, &.{"echo path-or-ref"});
    try journal.enter(gpa);

    const home = try journal.homeArg(gpa);
    defer gpa.free(home);

    // The shell integration rewrites `@1` before tj executes, so
    // this is the form tj actually receives there.
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
    try std.testing.expect(std.mem.indexOf(u8, exhausted.out.items, "no interaction numbers left") != null);
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

test "a resource name cannot escape the interaction or overwrite tj's own files" {
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
        "special-resource-content\\033]5107;tj;end\\033\\\\");
    defer gpa.free(publish);
    var from = out.items.len;
    try child.write(publish);
    try child.write("\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, test_prompt, timeout_ms));

    from = out.items.len;
    try child.write("autoload -Uz compinit; compinit -D; _tj_register_completion\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, test_prompt, timeout_ms));

    from = out.items.len;
    try child.write("cat @1/files/note");
    try child.write("\t");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, "file.txt", timeout_ms));
    try child.write("\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, "special-resource-content", timeout_ms));

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

        try std.testing.expectEqual(@as(u8, 1), r.code);
        try std.testing.expect(std.mem.indexOf(u8, r.out.items, "invalid replay numeric option") != null);
        try std.testing.expect(std.mem.indexOf(u8, r.out.items, "panic") == null);
        try std.testing.expect(std.mem.indexOf(u8, r.out.items, "error return trace") == null);
    }
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

    // The synthesised prompt appears, since the journal never recorded one.
    try std.testing.expect(std.mem.indexOf(u8, r.out.items, "% ") != null);
}

test "replay can be narrowed to a range of interactions" {
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
