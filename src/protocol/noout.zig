//! Runs one command inside an OSC ELLO NOOUT region.
//!
//! Markers go to the controlling terminal, independently of the child's
//! standard streams. The child otherwise inherits the caller's process and
//! terminal context unchanged.

const std = @import("std");
const posix = std.posix;
const c = std.c;
const sys = @import("../sys.zig");

pub const begin_marker = "\x1b]3110;NOOUT\x1b\\";
pub const end_marker = "\x1b]3110;END\x1b\\";

pub const Result = struct { exit_code: u8 };

pub fn run(gpa: std.mem.Allocator, io: std.Io, argv_words: []const []const u8) !Result {
    if (sys.env("TJ_JOURNAL") == null) return error.NotInJournal;

    const flags: posix.O = .{ .ACCMODE = .WRONLY, .CLOEXEC = true };
    const tty_fd = posix.openatZ(posix.AT.FDCWD, "/dev/tty", flags, 0) catch
        return error.NoControllingTerminal;
    defer sys.close(io, tty_fd);

    var executable = try sys.Exec.init(gpa, argv_words, sys.environMap());
    defer executable.deinit();
    try sys.writeAll(io, tty_fd, begin_marker);

    const pid = c.fork();
    if (pid < 0) {
        sys.writeAll(io, tty_fd, end_marker) catch {};
        return error.ForkFailed;
    }
    if (pid == 0) childExec(tty_fd, &executable);

    const result = sys.waitFor(pid);
    // Once the begin marker is visible, always make a best effort to close it.
    // A marker write failure must not replace the command's exit status.
    sys.writeAll(io, tty_fd, end_marker) catch {};
    return .{ .exit_code = result.code };
}

fn childExec(tty_fd: sys.Fd, executable: *sys.Exec) noreturn {
    _ = c.close(tty_fd);
    executable.exec();

    const name = std.mem.span(executable.argv[0].?);
    _ = c.write(2, "tj: cannot execute ", 19);
    _ = c.write(2, name.ptr, name.len);
    _ = c.write(2, "\r\n", 2);
    c._exit(127);
}

test "protocol markers are exact" {
    try std.testing.expectEqualStrings("\x1b]3110;NOOUT\x1b\\", begin_marker);
    try std.testing.expectEqualStrings("\x1b]3110;END\x1b\\", end_marker);
}
