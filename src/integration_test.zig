//! End-to-end tests for the proxy. Each one drives the real `tj` binary
//! through a pty, the same way a terminal emulator does.
//!
//! The claim under test is transparency: a program running under `tj` must not
//! be able to tell, and the user's terminal must be handed back untouched.

const std = @import("std");
const posix = std.posix;
const harness = @import("harness.zig");

const options = @import("build_options");
const tj = options.tj_exe;

const timeout_ms = 5000;

/// Tests start real sessions, and a session writes a journal. Point every
/// child at a scratch one: a test run must not leave anything in the journal
/// the developer is actually using.
var journal_isolated = false;

fn isolateJournal() void {
    // Once only. Tests that set TJ_SESSION themselves, to make `@N` resolve
    // against a journal they built, must not have it taken away again.
    if (journal_isolated) return;
    journal_isolated = true;

    sys.setEnv("TJ_HOME", ".zig-cache/tj-test-home");
    // Inherited from the developer's environment otherwise, which would make
    // `@N` resolve against whatever session they happen to be sitting in.
    sys.setEnv("TJ_SESSION", "");
}

fn spawnTj(gpa: std.mem.Allocator, args: []const []const u8, rows: u16, cols: u16) !harness.Session {
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

    const session = try spawnTj(gpa, argv.items, rows, cols);
    var out: std.ArrayList(u8) = .empty;
    const code = try session.finish(gpa, &out, timeout_ms);
    return .{ .out = out, .code = code };
}

test "exit status of the wrapped command is tj's exit status" {
    const gpa = std.testing.allocator;
    for ([_]u8{ 0, 3, 42 }) |want| {
        var script_buf: [32]u8 = undefined;
        const script = try std.fmt.bufPrint(&script_buf, "exit {d}", .{want});
        var r = try run(gpa, &.{ "run", "--", "/bin/sh", "-c", script }, 24, 80);
        defer r.out.deinit(gpa);
        try std.testing.expectEqual(want, r.code);
    }
}

test "a command killed by a signal reports 128+signal" {
    const gpa = std.testing.allocator;
    var r = try run(gpa, &.{ "run", "--", "/bin/sh", "-c", "kill -TERM $$" }, 24, 80);
    defer r.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 128 + 15), r.code);
}

test "the outer window size reaches the wrapped command" {
    const gpa = std.testing.allocator;
    var r = try run(gpa, &.{ "run", "--", "/bin/sh", "-c", "stty size" }, 31, 113);
    defer r.out.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, r.out.items, "31 113") != null);
}

test "the wrapped command sees a tty" {
    const gpa = std.testing.allocator;
    var r = try run(gpa, &.{ "run", "--", "/bin/sh", "-c", "test -t 0 && test -t 1 && echo ISTTY" }, 24, 80);
    defer r.out.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, r.out.items, "ISTTY") != null);
}

test "a command that cannot be executed exits 127" {
    const gpa = std.testing.allocator;
    var r = try run(gpa, &.{ "run", "--", "/nonexistent/program" }, 24, 80);
    defer r.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 127), r.code);
}

test "input typed at the outer terminal reaches the shell" {
    const gpa = std.testing.allocator;
    const session = try spawnTj(gpa, &.{ tj, "run", "--", "/bin/sh" }, 24, 80);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    try session.write("echo ROUNDTRIP-$((6*7))\n");
    _ = try session.readUntil(gpa, &out, "ROUNDTRIP-42", timeout_ms);
    try session.write("exit\n");
    _ = try session.finish(gpa, &out, timeout_ms);

    try std.testing.expect(std.mem.indexOf(u8, out.items, "ROUNDTRIP-42") != null);
}

test "resizing the outer terminal resizes the inner one" {
    const gpa = std.testing.allocator;
    const session = try spawnTj(
        gpa,
        &.{ tj, "run", "--", "/bin/sh", "-c", "trap 'stty size; exit 0' WINCH; echo READY; sleep 5" },
        24,
        80,
    );
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    try std.testing.expect(try session.readUntil(gpa, &out, "READY", timeout_ms));
    try session.resize(40, 100);
    _ = try session.finish(gpa, &out, timeout_ms);

    try std.testing.expect(std.mem.indexOf(u8, out.items, "40 100") != null);
}

test "signals sent to tj are forwarded to the shell" {
    const gpa = std.testing.allocator;
    const session = try spawnTj(
        gpa,
        &.{ tj, "run", "--", "/bin/sh", "-c", "trap 'echo GOTTERM; exit 9' TERM; echo READY; sleep 5" },
        24,
        80,
    );
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    try std.testing.expect(try session.readUntil(gpa, &out, "READY", timeout_ms));
    _ = std.c.kill(session.pid, posix.SIG.TERM);
    _ = try session.finish(gpa, &out, timeout_ms);

    try std.testing.expect(std.mem.indexOf(u8, out.items, "GOTTERM") != null);
}

test "the terminal is raw while tj runs and restored afterwards" {
    const gpa = std.testing.allocator;
    const session = try spawnTj(gpa, &.{options.selftest_exe}, 24, 80);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const code = try session.finish(gpa, &out, timeout_ms);
    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "RAW=yes") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "RESTORED=yes") != null);
}

// --- recording --------------------------------------------------------------

const Io = std.Io;
const Dir = std.Io.Dir;
const sys = @import("sys.zig");

/// A zsh session under tj, with the plugin loaded and a journal of its own.
const Journal = struct {
    tmp: std.testing.TmpDir,
    root: Dir,
    // A length, not a slice: the struct is returned by value, and a slice into
    // its own buffer would point at the caller's dead stack frame.
    path_len: usize,
    path_buf: [std.fs.max_path_bytes]u8,

    fn path(self: *const Journal) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    fn open(gpa: std.mem.Allocator) !Journal {
        var self: Journal = .{
            .tmp = std.testing.tmpDir(.{}),
            .root = undefined,
            .path_len = 0,
            .path_buf = undefined,
        };
        const io = std.testing.io;

        const len = try self.tmp.dir.realPath(io, &self.path_buf);
        const base = self.path_buf[0..len];

        // zsh only loads our plugin if it reads a .zshrc we control.
        var rc: std.ArrayList(u8) = .empty;
        defer rc.deinit(gpa);
        try rc.appendSlice(gpa, "PS1='%% '\nsource ");
        try rc.appendSlice(gpa, options.plugin);
        try rc.append(gpa, '\n');
        try self.tmp.dir.writeFile(io, .{ .sub_path = ".zshrc", .data = rc.items });

        try self.tmp.dir.createDirPath(io, "journal");
        self.root = try self.tmp.dir.openDir(io, "journal", .{});

        var zdotdir: [std.fs.max_path_bytes]u8 = undefined;
        @memcpy(zdotdir[0..base.len], base);
        zdotdir[base.len] = 0;
        sys.setEnv("ZDOTDIR", zdotdir[0..base.len :0]);

        self.path_len = len;
        return self;
    }

    fn homeArg(self: *const Journal, gpa: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(gpa, "{s}/journal", .{self.path()});
    }

    fn close(self: *Journal) void {
        self.root.close(std.testing.io);
        self.tmp.cleanup();
    }

    /// The id of the single session this run created.
    fn sessionName(self: *Journal, gpa: std.mem.Allocator) ![]u8 {
        const io = std.testing.io;
        var it = self.root.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind == .directory) return gpa.dupe(u8, entry.name);
        }
        return error.NoSession;
    }

    /// Makes `@N` and `@-` resolve against this journal's session.
    fn enter(self: *Journal, gpa: std.mem.Allocator) !void {
        const name = try self.sessionName(gpa);
        defer gpa.free(name);
        var buf: [64]u8 = undefined;
        @memcpy(buf[0..name.len], name);
        buf[name.len] = 0;
        sys.setEnv("TJ_SESSION", buf[0..name.len :0]);
    }

    /// The single session directory this run created.
    fn sessionDir(self: *Journal) !Dir {
        const io = std.testing.io;
        var it = self.root.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind == .directory) return self.root.openDir(io, entry.name, .{});
        }
        return error.NoSession;
    }

    fn read(self: *Journal, gpa: std.mem.Allocator, sub_path: []const u8) ![]u8 {
        var session = try self.sessionDir();
        defer session.close(std.testing.io);
        return session.readFileAlloc(std.testing.io, sub_path, gpa, .limited(1 << 20));
    }
};

fn haveZsh() bool {
    const io = std.testing.io;
    const file = Dir.cwd().openFile(io, "/bin/zsh", .{}) catch return false;
    file.close(io);
    return true;
}

/// Runs `script` line by line in an interactive zsh under tj, then exits.
fn recordSession(gpa: std.mem.Allocator, journal: *Journal, script: []const []const u8) !void {
    const home = try journal.homeArg(gpa);
    defer gpa.free(home);

    const session = try spawnTj(gpa, &.{ tj, "--home", home, "run", "--", "/bin/zsh", "-i" }, 24, 80);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    // Wait for the first prompt so the plugin's hooks are installed.
    _ = try session.readUntil(gpa, &out, "%", timeout_ms);
    for (script) |line| {
        try session.write(line);
        try session.write("\n");
        // Let the command finish before sending the next one, so interaction
        // numbers are predictable.
        sys.sleepMs(300);
    }
    try session.write("exit\n");
    _ = try session.finish(gpa, &out, timeout_ms);
}

test "commands are recorded as cmd, out and rc" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try Journal.open(gpa);
    defer journal.close();

    try recordSession(gpa, &journal, &.{ "echo hello-journal", "false" });

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

test "tj's own control sequences never reach the terminal" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try Journal.open(gpa);
    defer journal.close();

    const home = try journal.homeArg(gpa);
    defer gpa.free(home);

    const session = try spawnTj(gpa, &.{ tj, "--home", home, "run", "--", "/bin/zsh", "-i" }, 24, 80);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    _ = try session.readUntil(gpa, &out, "%", timeout_ms);
    try session.write("echo marker\n");
    sys.sleepMs(300);
    try session.write("exit\n");
    _ = try session.finish(gpa, &out, timeout_ms);

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
    try recordSession(gpa, &journal, &.{tricky});

    const recorded = try journal.read(gpa, "1/cmd");
    defer gpa.free(recorded);
    try std.testing.expectEqualStrings(tricky, recorded);
}

test "an interrupted session leaves the interaction without an rc" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try Journal.open(gpa);
    defer journal.close();

    const home = try journal.homeArg(gpa);
    defer gpa.free(home);

    const session = try spawnTj(gpa, &.{ tj, "--home", home, "run", "--", "/bin/zsh", "-i" }, 24, 80);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    _ = try session.readUntil(gpa, &out, "%", timeout_ms);
    try session.write("sleep 30\n");
    sys.sleepMs(400);
    _ = std.c.kill(session.pid, posix.SIG.TERM);
    _ = try session.finish(gpa, &out, timeout_ms);

    const cmd = try journal.read(gpa, "1/cmd");
    defer gpa.free(cmd);
    try std.testing.expectEqualStrings("sleep 30", cmd);

    // No rc: readers must treat this as aborted, never as success.
    var dir = try journal.sessionDir();
    defer dir.close(std.testing.io);
    try std.testing.expectError(error.FileNotFound, dir.openFile(std.testing.io, "1/rc", .{}));
}

// --- the @ namespace --------------------------------------------------------

test "references resolve to paths inside the journal" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try Journal.open(gpa);
    defer journal.close();
    try recordSession(gpa, &journal, &.{ "echo first", "echo second" });
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
    try recordSession(gpa, &journal, &.{"echo only"});
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
    try recordSession(gpa, &journal, &.{"echo only"});
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
    try recordSession(gpa, &journal, &.{"echo one"});
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
    try recordSession(gpa, &journal, &.{ "echo alpha-marker", "cat @1/out" });

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
    try recordSession(gpa, &journal, &.{
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
    try recordSession(gpa, &journal, &.{
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

    const home = try journal.homeArg(gpa);
    defer gpa.free(home);

    const session = try spawnTj(gpa, &.{ tj, "--home", home, "run", "--", "/bin/zsh", "-i" }, 24, 80);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    _ = try session.readUntil(gpa, &out, "%", timeout_ms);
    try session.write("printf '\\033[?1049hHIDDEN-PAINTING\\033[?1049l'\n");
    sys.sleepMs(400);
    try session.write("exit\n");
    _ = try session.finish(gpa, &out, timeout_ms);

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
    try recordSession(gpa, &journal, &.{"printf '\\033[31mred\\033[0m\\r\\n10%%\\r100%% done\\r\\n'"});
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
    try recordSession(gpa, &journal, &.{"printf '\\033[31mred\\033[0m\\n'"});
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
    try recordSession(gpa, &journal, &.{"echo marker-text"});
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
    try recordSession(gpa, &journal, &.{"echo path-or-ref"});
    try journal.enter(gpa);

    const home = try journal.homeArg(gpa);
    defer gpa.free(home);

    // Inside a session the shell integration rewrites `@1` before tj runs, so
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

// --- sessions that recorded nothing ------------------------------------------

/// A journal directory with no shell integration pointed at it, for testing
/// what a session leaves behind.
const Scratch = struct {
    tmp: std.testing.TmpDir,
    path_len: usize,
    path_buf: [std.fs.max_path_bytes]u8,

    fn open() !Scratch {
        var self: Scratch = .{
            .tmp = std.testing.tmpDir(.{}),
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

    /// How many session directories the journal holds.
    fn sessions(self: *Scratch) !usize {
        var count: usize = 0;
        var it = self.tmp.dir.iterate();
        while (try it.next(std.testing.io)) |entry| {
            if (entry.kind == .directory) count += 1;
        }
        return count;
    }
};

test "a session that recorded nothing leaves nothing behind" {
    const gpa = std.testing.allocator;

    var scratch = try Scratch.open();
    defer scratch.close();

    // /bin/sh loads no tj integration, so no command boundaries are ever
    // reported and the session records nothing.
    var r = try run(gpa, &.{ "--home", scratch.path(), "run", "--", "/bin/sh", "-c", "true" }, 24, 80);
    defer r.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), r.code);

    try std.testing.expectEqual(@as(usize, 0), try scratch.sessions());
}

test "a session that recorded something is kept" {
    if (!haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try Journal.open(gpa);
    defer journal.close();
    try recordSession(gpa, &journal, &.{"echo kept"});

    const cmd = try journal.read(gpa, "1/cmd");
    defer gpa.free(cmd);
    try std.testing.expectEqualStrings("echo kept", cmd);
}

test "a session that could not record but said why is kept" {
    const gpa = std.testing.allocator;

    var scratch = try Scratch.open();
    defer scratch.close();

    // A malformed tj sequence: no interaction is opened, but the session log
    // records that something was ignored, and that is worth keeping.
    var r = try run(gpa, &.{
        "--home",                                scratch.path(),
        "run",                                   "--",
        "/bin/sh",                               "-c",
        "printf '\\033]5107;tj;bogus\\033\\\\'",
    }, 24, 80);
    defer r.out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), try scratch.sessions());
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
    try recordSession(gpa, &journal, &.{script});

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
    try recordSession(gpa, &journal, &.{script});

    // The one valid name is published.
    const kept = try journal.read(gpa, "1/ok/kept.txt");
    defer gpa.free(kept);
    try std.testing.expectEqualStrings("legit", kept);

    // The rest are refused, and `out` still holds what tj put there.
    var dir = try journal.sessionDir();
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
    try recordSession(gpa, &journal, &.{script});

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
    try recordSession(gpa, &journal, &.{script});
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
