const std = @import("std");
const Io = std.Io;

const cli = @import("cli.zig");
const proxy = @import("proxy.zig");
const commands = @import("commands.zig");
const noout = @import("noout.zig");

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
    \\  tj noout -- command ...                   show output but omit it from out
    \\  tj <subcommand> [args ...]               work with what was recorded
    \\
    \\Subcommands:
    \\  new            run $SHELL, or a command, writing a new journal
    \\  continue ID    run a fresh shell or command, appending to one journal
    \\  noout -- CMD   run a command whose visible output is omitted from out
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
    \\  name [@ref [name] | --remove name]
    \\                  name, query, remove, or list interaction names
    \\  tag [@ref [tag ...] | --remove @ref tag ...]
    \\                  tag, query, remove, or list interaction tags
    \\  pin [@ref | --remove @ref]
    \\                  pin, unpin, or list pinned interactions
    \\  rm <@ref | @ref/out | @N..@M>
    \\  rm --journal <id> [--force]
    \\                  remove recorded data or an inactive journal
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
    \\  @build-failure/out  a named interaction in this journal
    \\  @pgsd.build-failure/out  a named interaction in another journal
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
            error.MissingNooutSeparator => "tj: noout requires `--` before the command\n\n",
            error.MissingNooutCommand => "tj: noout needs a command after `--`\n\n",
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
        .noout => |argv| {
            const result = noout.run(arena, argv) catch |err| {
                try write(init.io, .stderr(), switch (err) {
                    error.NotInJournal => "tj: noout must run inside a tj journal writer\n",
                    error.NoControllingTerminal => "tj: noout needs a controlling terminal\n",
                    error.ForkFailed => "tj: cannot fork\n",
                    else => "tj: cannot start noout command\n",
                });
                return 1;
            };
            return result.exit_code;
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
                    error.CrossJournalMutation => "tj: writes and interaction deletion are limited to the current journal\n",
                    error.InvalidName => "tj: invalid interaction name\n",
                    error.InvalidTag => "tj: invalid tag\n",
                    error.NameTaken => "tj: that interaction name is already in use\n",
                    error.InvalidAnnotations => "tj: invalid annotations.json; refusing to overwrite it\n",
                    error.UnsupportedRemoval => "tj: only an interaction or its out may be removed\n",
                    error.InvalidRange => "tj: invalid interaction range; use ascending numeric references such as @2..@10\n",
                    error.CurrentInteraction => "tj: cannot remove the currently running interaction\n",
                    error.ActiveJournal => "tj: cannot remove a journal while it is being written\n",
                    error.AmbiguousJournal => "tj: journal suffix is ambiguous\n",
                    error.ConfirmationRequired => "tj: use --force to remove a journal non-interactively\n",
                    error.Cancelled => "tj: journal removal cancelled\n",
                    error.BadArguments => "tj: invalid arguments for this subcommand\n",
                    error.InvalidMetadata => "tj: invalid interaction metadata; refusing partial removal\n",
                    error.InsideJournalRemoval => "tj: remove a whole journal only from outside a tj writer\n",
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
    _ = noout;
}
