//! Build-time shell completion generator.
//!
//! This executable is built for and run on the build host. It is deliberately
//! not installed: users receive the generated completion scripts, while the
//! runtime `tj` binary keeps only dynamic journal-reference completion.

const std = @import("std");
const Io = std.Io;
const completion = @import("completion");
const cli_spec = @import("cli_spec.zig");

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [512]u8 = undefined;
    var stdout_file: Io.File.Writer = .init(.stdout(), init.io, &stdout_buf);
    var stderr_file: Io.File.Writer = .init(.stderr(), init.io, &stderr_buf);
    const stdout = &stdout_file.interface;
    const stderr = &stderr_file.interface;

    if (args.len != 2) {
        try stderr.writeAll("usage: tj-completion <bash|zsh|fish>\n");
        try stderr.flush();
        return 2;
    }

    const shell = args[1];
    if (std.mem.eql(u8, shell, "bash")) {
        try completion.generateBash(stdout, cli_spec.application);
    } else if (std.mem.eql(u8, shell, "zsh")) {
        try completion.generateZsh(stdout, cli_spec.application);
    } else if (std.mem.eql(u8, shell, "fish")) {
        try completion.generateFish(stdout, cli_spec.application);
    } else {
        try stderr.print("tj-completion: unsupported shell: {s}\n", .{shell});
        try stderr.flush();
        return 2;
    }

    try stdout.flush();
    return 0;
}
