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
    \\  tj new [flags] [-- command ...]          create a journal and write to it
    \\  tj continue <id> [flags] [-- command ...] append to an existing journal
    \\  tj <subcommand> [args ...]               work with what was recorded
    \\
    \\Subcommands:
    \\  new            run $SHELL, or a command, writing a new journal
    \\  continue ID    run a fresh shell or command, appending to one journal
    \\  hist           the interactions of this journal (also: history)
    \\  journals       every journal, newest first
    \\  current        this journal's id
    \\  last           the last interaction that completed
    \\  cat <ref>...   print what a reference names
    \\                 (--raw / --plain, --head N / --tail N)
    \\  replay [id]    play a journal back into the terminal (outside a writer)
    \\                 (--speed X, --typing MS, --max-pause MS, --prompt S,
    \\                  --from N, --to N)
    \\  resolve <ref>  print the path a reference names
    \\  complete <ref> completion candidates for a partial reference
    \\
    \\Flags:
    \\  --home <dir>   journal location (default: $TJ_HOME, else ~/.tj)
    \\  --keep-osc     forward tj's own control sequences instead of stripping them
    \\  -h, --help     show this help
    \\  -V, --version  show the version
    \\
    \\References name previous computations the way paths name files:
    \\  @42/out        interaction 42 of this journal
    \\  @-/out         the last interaction that completed
    \\  @pgsd.42/out   interaction 42 of another journal, by a suffix of its id
    \\  ~[@42]/out     canonical zsh form; unquoted @42/out is shorthand
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
            error.UnknownFlag => "tj: unrecognised flag\n\n",
            error.MissingFlagValue => "tj: --home needs a directory\n\n",
            error.UnknownSubcommand => "tj: unknown subcommand\n\n",
            error.MissingLifecycle => "tj: choose `tj new` or `tj continue <id>` before the command\n\n",
            error.MissingJournal => "tj: continue needs a journal id or suffix\n\n",
        });
        try write(init.io, .stderr(), usage);
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
                    error.NotInJournal => "tj: not inside a tj journal writer\n",
                    error.NoSuchJournal => "tj: no journal matches that id\n",
                    error.NothingRecorded, error.NothingCompleted => "tj: nothing recorded yet\n",
                    error.MissingArgument => "tj: this subcommand needs an argument\n",
                    error.BadReference => "tj: not a journal reference\n",
                    error.BadCount => "tj: --head and --tail need a number of lines\n",
                    error.BadReplayOption => "tj: invalid replay numeric option\n",
                    error.NoSuchInteraction => "tj: no such interaction\n",
                    error.NoSuchResource => "tj: no such resource or file\n",
                    error.InsideJournal => "tj: cannot replay inside a live journal writer, because it would record the replay; run it from a shell that is not under tj\n",
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
                    error.NoSuchJournal => "tj: no journal matches that id\n",
                    error.AmbiguousJournal => "tj: journal suffix is ambiguous\n",
                    error.JournalLocked => "tj: journal is already being written\n",
                    error.JournalFull => "tj: journal has no interaction numbers left\n",
                    error.ForkFailed => "tj: cannot fork\n",
                    error.Syscall => "tj: cannot allocate a pseudo-terminal\n",
                    else => "tj: cannot open the journal\n",
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
    _ = @import("altscreen.zig");
    _ = @import("plain.zig");
    _ = @import("store.zig");
    _ = commands;
}
