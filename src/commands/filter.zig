//! `tj filter` - terminal-stream filters and command wrappers.

const std = @import("std");
const Io = std.Io;
const c = std.c;

const noout = @import("../protocol/noout.zig");
const fence = @import("../protocol/fence.zig");
const sys = @import("../sys.zig");
const zecli = @import("zecli");

const Mode = enum { noout, fence };

pub fn run(gpa: std.mem.Allocator, io: Io, parsed: *const zecli.Parsed, child: []const [:0]const u8, out: *Io.Writer) !u8 {
    const mode = try modeFromParsed(parsed);
    if (child.len == 0) {
        return switch (mode) {
            .noout => copyNoout(io, out),
            .fence => copyFence(gpa, io, Io.File.stdin(), out),
        };
    }
    return switch (mode) {
        .noout => (try noout.run(gpa, io, child)).exit_code,
        .fence => runFenceCommand(gpa, io, child, out),
    };
}

fn modeFromParsed(parsed: *const zecli.Parsed) !Mode {
    const omit = parsed.enabled("noout");
    const publish = parsed.enabled("fence");
    if (omit == publish) return error.BadArguments;
    return if (omit) .noout else .fence;
}

fn copyNoout(io: Io, out: *Io.Writer) !u8 {
    const enabled = sys.env("TJ_JOURNAL") != null and sys.isTty(io, 1);
    if (enabled) try out.writeAll(noout.begin_marker);
    defer if (enabled) out.writeAll(noout.end_marker) catch {};

    var reader_buffer: [4096]u8 = undefined;
    var bytes: [4096]u8 = undefined;
    var reader = Io.File.stdin().readerStreaming(io, &reader_buffer);
    while (true) {
        const n = try reader.interface.readSliceShort(&bytes);
        if (n == 0) break;
        try out.writeAll(bytes[0..n]);
    }
    return 0;
}

fn copyFence(gpa: std.mem.Allocator, io: Io, input: Io.File, out: *Io.Writer) !u8 {
    var reader_buffer: [4096]u8 = undefined;
    var bytes: [4096]u8 = undefined;
    var reader = input.readerStreaming(io, &reader_buffer);
    var filter = fence.Filter.init(gpa, out, sys.env("TJ_JOURNAL") != null and sys.isTty(io, 1));
    defer filter.deinit();
    while (true) {
        const n = try reader.interface.readSliceShort(&bytes);
        if (n == 0) break;
        try filter.feed(bytes[0..n]);
    }
    try filter.finish();
    return 0;
}

fn runFenceCommand(gpa: std.mem.Allocator, io: Io, words: []const []const u8, out: *Io.Writer) !u8 {
    var fds: [2]c_int = undefined;
    if (c.pipe(&fds) != 0) return error.Syscall;
    var read_open = true;
    var write_open = true;
    errdefer {
        if (read_open) sys.close(io, fds[0]);
        if (write_open) sys.close(io, fds[1]);
    }

    var executable = try sys.Exec.init(gpa, words, sys.environMap());
    defer executable.deinit();
    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) childExec(fds, &executable);

    sys.close(io, fds[1]);
    write_open = false;
    var filter = fence.Filter.init(gpa, out, sys.env("TJ_JOURNAL") != null and sys.isTty(io, 1));
    defer filter.deinit();
    var bytes: [4096]u8 = undefined;
    var failure: ?anyerror = null;
    while (true) {
        const n = sys.read(fds[0], &bytes) catch |err| {
            failure = err;
            break;
        };
        if (n == 0) break;
        filter.feed(bytes[0..n]) catch |err| {
            failure = err;
            break;
        };
    }
    if (failure == null) {
        filter.finish() catch |err| {
            failure = err;
        };
    }
    sys.close(io, fds[0]);
    read_open = false;
    const result = sys.waitFor(pid);
    if (failure) |err| return err;
    return result.code;
}

fn childExec(fds: [2]c_int, executable: *sys.Exec) noreturn {
    _ = c.close(fds[0]);
    if (c.dup2(fds[1], 1) < 0) c._exit(127);
    _ = c.close(fds[1]);
    executable.exec();

    const name = std.mem.span(executable.argv[0].?);
    _ = c.write(2, "tj: cannot execute ", 19);
    _ = c.write(2, name.ptr, name.len);
    _ = c.write(2, "\r\n", 2);
    c._exit(127);
}
