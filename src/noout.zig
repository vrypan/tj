//! Runs one command inside an OSC 5107 noout region.
//!
//! Markers go to the controlling terminal, independently of the child's
//! standard streams. The child otherwise inherits the caller's process and
//! terminal context unchanged.

const std = @import("std");
const posix = std.posix;
const c = std.c;
const sys = @import("sys.zig");

pub const begin_marker = "\x1b]5107;tj;noout\x1b\\";
pub const end_marker = "\x1b]5107;tj;end\x1b\\";

pub const Result = struct { exit_code: u8 };

pub fn run(gpa: std.mem.Allocator, argv_words: []const []const u8) !Result {
    if (sys.env("TJ_JOURNAL") == null) return error.NotInJournal;

    const flags: posix.O = .{ .ACCMODE = .WRONLY, .CLOEXEC = true };
    const tty_fd = posix.openatZ(posix.AT.FDCWD, "/dev/tty", flags, 0) catch
        return error.NoControllingTerminal;
    defer sys.close(tty_fd);

    const argv = try buildArgv(gpa, argv_words);
    defer freeArgv(gpa, argv);
    try sys.writeAll(tty_fd, begin_marker);

    const pid = c.fork();
    if (pid < 0) {
        sys.writeAll(tty_fd, end_marker) catch {};
        return error.ForkFailed;
    }
    if (pid == 0) childExec(tty_fd, argv);

    const result = sys.waitFor(pid);
    // Once the begin marker is visible, always make a best effort to close it.
    // A marker write failure must not replace the command's exit status.
    sys.writeAll(tty_fd, end_marker) catch {};
    return .{ .exit_code = result.code };
}

fn buildArgv(gpa: std.mem.Allocator, words: []const []const u8) ![:null]const ?[*:0]const u8 {
    const argv = try gpa.allocSentinel(?[*:0]const u8, words.len, null);
    var duplicated: usize = 0;
    errdefer {
        for (argv[0..duplicated]) |word| gpa.free(std.mem.span(word.?));
        gpa.free(argv);
    }
    for (words, 0..) |word, i| {
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

fn childExec(tty_fd: sys.Fd, argv: [:null]const ?[*:0]const u8) noreturn {
    sys.close(tty_fd);
    _ = sys.execvp(argv[0].?, argv.ptr);

    const name = std.mem.span(argv[0].?);
    _ = c.write(2, "tj: cannot execute ", 19);
    _ = c.write(2, name.ptr, name.len);
    _ = c.write(2, "\r\n", 2);
    c._exit(127);
}

test "protocol markers are exact" {
    try std.testing.expectEqualStrings("\x1b]5107;tj;noout\x1b\\", begin_marker);
    try std.testing.expectEqualStrings("\x1b]5107;tj;end\x1b\\", end_marker);
}
