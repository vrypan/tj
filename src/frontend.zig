//! Process-wide behavior shared by the `tj` and `tjctl` frontends.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const proxy = @import("terminal/proxy.zig");

pub const version = build_options.version;
pub const panic = std.debug.FullPanic(onPanic);

fn onPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    proxy.restoreOnPanic();
    std.debug.defaultPanic(msg, first_trace_addr);
}

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
const leak_checked = builtin.mode == .Debug;

pub fn commandAllocator() std.mem.Allocator {
    return if (leak_checked) debug_allocator.allocator() else std.heap.smp_allocator;
}

pub fn deinitAllocator(comptime binary: []const u8) void {
    if (leak_checked and debug_allocator.deinit() == .leak) @panic(binary ++ " leaked memory in a command path");
}

pub fn isBrokenPipe(stdout_file: *const std.Io.File.Writer, err: anyerror) bool {
    if (err != error.WriteFailed) return false;
    if (stdout_file.err) |write_err| return write_err == error.BrokenPipe;
    return false;
}

pub fn flushStdout(stdout_file: *std.Io.File.Writer, status: u8) !u8 {
    stdout_file.interface.flush() catch |err| {
        if (isBrokenPipe(stdout_file, err)) return 0;
        return err;
    };
    return status;
}
