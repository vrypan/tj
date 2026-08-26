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

fn run(gpa: std.mem.Allocator, args: []const []const u8, rows: u16, cols: u16) !struct {
    out: std.ArrayList(u8),
    code: u8,
} {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, tj);
    try argv.appendSlice(gpa, args);

    const session = try harness.spawn(gpa, argv.items, rows, cols);
    var out: std.ArrayList(u8) = .empty;
    const code = try session.finish(gpa, &out, timeout_ms);
    return .{ .out = out, .code = code };
}

test "exit status of the wrapped command is tj's exit status" {
    const gpa = std.testing.allocator;
    for ([_]u8{ 0, 3, 42 }) |want| {
        var script_buf: [32]u8 = undefined;
        const script = try std.fmt.bufPrint(&script_buf, "exit {d}", .{want});
        var r = try run(gpa, &.{ "--", "/bin/sh", "-c", script }, 24, 80);
        defer r.out.deinit(gpa);
        try std.testing.expectEqual(want, r.code);
    }
}

test "a command killed by a signal reports 128+signal" {
    const gpa = std.testing.allocator;
    var r = try run(gpa, &.{ "--", "/bin/sh", "-c", "kill -TERM $$" }, 24, 80);
    defer r.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 128 + 15), r.code);
}

test "the outer window size reaches the wrapped command" {
    const gpa = std.testing.allocator;
    var r = try run(gpa, &.{ "--", "/bin/sh", "-c", "stty size" }, 31, 113);
    defer r.out.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, r.out.items, "31 113") != null);
}

test "the wrapped command sees a tty" {
    const gpa = std.testing.allocator;
    var r = try run(gpa, &.{ "--", "/bin/sh", "-c", "test -t 0 && test -t 1 && echo ISTTY" }, 24, 80);
    defer r.out.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, r.out.items, "ISTTY") != null);
}

test "a command that cannot be executed exits 127" {
    const gpa = std.testing.allocator;
    var r = try run(gpa, &.{ "--", "/nonexistent/program" }, 24, 80);
    defer r.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 127), r.code);
}

test "input typed at the outer terminal reaches the shell" {
    const gpa = std.testing.allocator;
    const session = try harness.spawn(gpa, &.{ tj, "--", "/bin/sh" }, 24, 80);
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
    const session = try harness.spawn(
        gpa,
        &.{ tj, "--", "/bin/sh", "-c", "trap 'stty size; exit 0' WINCH; echo READY; sleep 5" },
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
    const session = try harness.spawn(
        gpa,
        &.{ tj, "--", "/bin/sh", "-c", "trap 'echo GOTTERM; exit 9' TERM; echo READY; sleep 5" },
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
    const session = try harness.spawn(gpa, &.{options.selftest_exe}, 24, 80);
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

    const session = try harness.spawn(gpa, &.{ tj, "--home", home, "--", "/bin/zsh", "-i" }, 24, 80);
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

    const session = try harness.spawn(gpa, &.{ tj, "--home", home, "--", "/bin/zsh", "-i" }, 24, 80);
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

    const session = try harness.spawn(gpa, &.{ tj, "--home", home, "--", "/bin/zsh", "-i" }, 24, 80);
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
