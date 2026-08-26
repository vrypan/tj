const std = @import("std");
const Io = std.Io;

const cli = @import("cli.zig");
const proxy = @import("proxy.zig");
const commands = @import("commands.zig");

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
    \\  current        print the current session id
    \\  last           print the last completed interaction number
    \\  list [session] list the interactions of a session
    \\  sessions       list sessions, newest first
    \\  resolve <ref>  print the path a journal reference names
    \\  complete <ref> completion candidates for a partial reference
    \\
    \\References name previous computations the way paths name files:
    \\  @42/out        interaction 42 of this session
    \\  @-/out         the last interaction that completed
    \\  @pgsd.42/out   interaction 42 of another session, by a suffix of its id
    \\
    \\Recording and reference expansion need the shell integration:
    \\  source /path/to/tj.plugin.zsh   # in ~/.zshrc
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
        .subcommand => |sub| {
            var buf: [4096]u8 = undefined;
            var writer: Io.File.Writer = .init(.stdout(), init.io, &buf);
            commands.run(arena, init.io, sub, &writer.interface) catch |err| {
                writer.interface.flush() catch {};
                try write(init.io, .stderr(), switch (err) {
                    error.NotInSession => "tj: not inside a tj session\n",
                    error.NoSuchSession => "tj: no session matches that id\n",
                    error.NothingRecorded, error.NothingCompleted => "tj: nothing recorded yet\n",
                    error.MissingArgument => "tj: this subcommand needs an argument\n",
                    error.BadReference => "tj: not a journal reference\n",
                    error.NoSuchInteraction => "tj: no such interaction\n",
                    error.FileNotFound => "tj: no journal yet\n",
                    else => "tj: cannot read the journal\n",
                });
                // A reference that is well formed but names something absent
                // is worth telling apart from one that is simply wrong: the
                // shell integration expands the first and leaves the second.
                return if (err == error.NoSuchInteraction) 2 else 1;
            };
            try writer.interface.flush();
            return 0;
        },
        .proxy => |opts| {
            const result = proxy.run(arena, init.io, opts) catch |err| {
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
    _ = @import("ulid.zig");
    _ = @import("scanner.zig");
    _ = @import("reference.zig");
    _ = @import("store.zig");
    _ = commands;
}
