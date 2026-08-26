const std = @import("std");
const Io = std.Io;

const cli = @import("cli.zig");
const proxy = @import("proxy.zig");

pub const version = "0.1.0";

pub const panic = std.debug.FullPanic(onPanic);

fn onPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    proxy.restoreOnPanic();
    std.debug.defaultPanic(msg, first_trace_addr);
}

const usage =
    \\tj - Terminal Journal
    \\
    \\Usage:
    \\  tj [flags] [-- command ...]   run a shell (default: $SHELL) under the journal
    \\  tj <subcommand> [args ...]    query the journal
    \\
    \\Flags:
    \\  --home <dir>   journal location (default: $TJ_HOME, else ~/.tj)
    \\  --keep-osc     forward OSC 5107 sequences to the terminal instead of stripping them
    \\  -h, --help     show this help
    \\  -V, --version  show the version
    \\
    \\Subcommands:
    \\  resolve <ref>  print the path a journal reference resolves to
    \\  current        print the current session id
    \\  last           print the last completed interaction number
    \\  list [session] list the interactions of a session
    \\  sessions       list sessions, newest first
    \\  complete <ref> completion candidates for a partial reference
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    const command = cli.parse(args[1..]) catch |err| {
        try write(init.io, .stderr(), switch (err) {
            error.UnknownFlag => "tj: unrecognised argument (use `tj -- <command>` to run a program)\n",
            error.MissingFlagValue => "tj: --home needs a directory\n",
        });
        return 2;
    };

    switch (command) {
        .help => {
            try write(init.io, .stdout(), usage);
            return 0;
        },
        .version => {
            try write(init.io, .stdout(), "tj " ++ version ++ "\n");
            return 0;
        },
        .subcommand => {
            try write(init.io, .stderr(), "tj: the journal is not recorded yet, so this subcommand has nothing to read\n");
            return 2;
        },
        .proxy => |opts| {
            const result = proxy.run(arena, opts) catch |err| {
                try write(init.io, .stderr(), switch (err) {
                    error.ForkFailed => "tj: cannot fork\n",
                    error.Syscall => "tj: cannot allocate a pseudo-terminal\n",
                    else => "tj: startup failed\n",
                });
                return 1;
            };
            return result.exit_code;
        },
    }
}

fn write(io: Io, file: Io.File, text: []const u8) !void {
    var buf: [64]u8 = undefined;
    var writer: Io.File.Writer = .init(file, io, &buf);
    try writer.interface.writeAll(text);
    try writer.interface.flush();
}

test {
    _ = cli;
}
