const std = @import("std");
const Io = std.Io;
const zecli = @import("zecli");

const cli = @import("cli.zig");
const cli_spec = @import("cli_spec.zig");
const proxy = @import("proxy.zig");
const commands = @import("commands.zig");

pub const version = "0.2.1";

pub const panic = std.debug.FullPanic(onPanic);

fn onPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    proxy.restoreOnPanic();
    std.debug.defaultPanic(msg, first_trace_addr);
}

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [4096]u8 = undefined;
    var stdout_file: Io.File.Writer = .init(.stdout(), init.io, &stdout_buf);
    var stderr_file: Io.File.Writer = .init(.stderr(), init.io, &stderr_buf);
    const stdout = &stdout_file.interface;
    const stderr = &stderr_file.interface;

    const routed = cli.parse(arena, args[1..]) catch |err| {
        try stderr.writeAll(rootErrorMessage(err));
        try zecli.printApplicationHelp(arena, stderr, cli_spec.application);
        try stderr.flush();
        return 2;
    };

    switch (routed) {
        .help => {
            try zecli.printApplicationHelp(arena, stdout, cli_spec.application);
            try stdout.flush();
            return 0;
        },
        .version => {
            try stdout.writeAll("tj " ++ version ++ "\n");
            try stdout.flush();
            return 0;
        },
        .command => |command| {
            const spec = command.which.spec();
            const parts = cli.splitCommandArgs(command) catch |err| {
                try stderr.writeAll(rootErrorMessage(err));
                try zecli.printCommandHelp(arena, stderr, spec);
                try stderr.flush();
                return 2;
            };

            if (zecli.helpRequested(parts.owned)) {
                try zecli.printCommandHelp(arena, stdout, spec);
                try stdout.flush();
                return 0;
            }

            cli.preflightCommandArgs(command.which, parts.owned) catch {
                try stderr.writeAll("tj: invalid arguments for this subcommand\n\n");
                try zecli.printCommandHelp(arena, stderr, spec);
                try stderr.flush();
                return 2;
            };

            var parsed = zecli.parseCommand(arena, stderr, parts.owned, spec) catch |err| {
                if (err == error.ReportedCliError) {
                    try stderr.flush();
                    return 2;
                }
                return err;
            };
            defer parsed.deinit(arena);

            const status = commands.run(arena, init.io, command, parts.child, &parsed, stdout) catch |err| {
                stdout.flush() catch {};
                try stderr.writeAll(commandErrorMessage(command.which, err));
                if (isUsageError(err)) {
                    try stderr.writeByte('\n');
                    try zecli.printCommandHelp(arena, stderr, spec);
                }
                try stderr.flush();
                if (isUsageError(err) or err == error.NoSuchInteraction) return 2;
                return 1;
            };
            try stdout.flush();
            return status;
        },
    }
}

fn rootErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.UnknownFlag => "tj: unrecognised flag\n\n",
        error.MissingFlagValue => "tj: --home needs a directory\n\n",
        error.UnknownSubcommand => "tj: unknown subcommand\n\n",
        error.MissingLifecycle => "tj: choose a subcommand before the command\n\n",
        error.MissingNooutSeparator => "tj: noout requires `--` before the command\n\n",
        error.MissingNooutCommand => "tj: noout needs a command after `--`\n\n",
        else => "tj: invalid command line\n\n",
    };
}

fn isUsageError(err: anyerror) bool {
    return switch (err) {
        error.MissingArgument,
        error.BadCount,
        error.BadReplayOption,
        error.BadArguments,
        error.UnknownFlag,
        error.MissingFlagValue,
        => true,
        else => false,
    };
}

fn commandErrorMessage(which: cli.CommandName, err: anyerror) []const u8 {
    if (which == .noout) return switch (err) {
        error.NotInJournal => "tj: noout must run inside a tj journal writer\n",
        error.NoControllingTerminal => "tj: noout needs a controlling terminal\n",
        error.ForkFailed => "tj: cannot fork\n",
        else => "tj: cannot start noout command\n",
    };
    if (which == .new or which == .@"continue") return switch (err) {
        error.NoSuchJournal => "tj: no journal matches that id\n",
        error.AmbiguousJournal => "tj: journal suffix is ambiguous\n",
        error.JournalLocked => "tj: journal is already being written\n",
        error.JournalFull => "tj: journal has no interaction numbers left\n",
        error.ForkFailed => "tj: cannot fork\n",
        error.Syscall => "tj: cannot allocate a pseudo-terminal\n",
        else => "tj: cannot open the journal\n",
    };
    return switch (err) {
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
    };
}

test {
    _ = cli;
    _ = cli_spec;
    _ = @import("ulid.zig");
    _ = @import("scanner.zig");
    _ = @import("reference.zig");
    _ = @import("altscreen.zig");
    _ = @import("plain.zig");
    _ = @import("store.zig");
    _ = @import("search.zig");
    _ = commands;
}
