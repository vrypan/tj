const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const zecli = @import("zecli");

const cli = @import("cli.zig");
const cli_spec = @import("cli_spec.zig");
const proxy = @import("proxy.zig");
const commands = @import("commands.zig");

pub const version = "0.3.0";

pub const panic = std.debug.FullPanic(onPanic);

fn onPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    proxy.restoreOnPanic();
    std.debug.defaultPanic(msg, first_trace_addr);
}

/// Leak detection for the command allocator, active only in debug builds so
/// the test suite fails on a leak that a release build would never notice.
var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

const leak_checked = builtin.mode == .Debug;

/// Commands run on a real allocator, not on `init.arena`. Listing a journal
/// frees each entry's scratch as it goes, and an arena cannot honor that:
/// its `free` is a no-op, so peak memory would grow with the entry count.
/// The arena still owns argv and parsed CLI state, which live for the whole
/// process by design.
fn commandAllocator() std.mem.Allocator {
    return if (leak_checked) debug_allocator.allocator() else std.heap.smp_allocator;
}

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const gpa = commandAllocator();
    defer if (leak_checked) {
        if (debug_allocator.deinit() == .leak) @panic("tj leaked memory in a command path");
    };
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
            zecli.printApplicationHelp(arena, stdout, cli_spec.application) catch |err| {
                if (isBrokenPipe(&stdout_file, err)) return 0;
                return err;
            };
            return flushStdout(&stdout_file, 0);
        },
        .version => {
            stdout.writeAll("tj " ++ version ++ "\n") catch |err| {
                if (isBrokenPipe(&stdout_file, err)) return 0;
                return err;
            };
            return flushStdout(&stdout_file, 0);
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
                zecli.printCommandHelp(arena, stdout, spec) catch |err| {
                    if (isBrokenPipe(&stdout_file, err)) return 0;
                    return err;
                };
                return flushStdout(&stdout_file, 0);
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

            const status = commands.run(gpa, init.io, command, parts.child, &parsed, stdout) catch |err| {
                if (isBrokenPipe(&stdout_file, err)) return 0;
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
            return flushStdout(&stdout_file, status);
        },
    }
}

fn isBrokenPipe(stdout_file: *const Io.File.Writer, err: anyerror) bool {
    if (err != error.WriteFailed) return false;
    if (stdout_file.err) |write_err| return write_err == error.BrokenPipe;
    return false;
}

fn flushStdout(stdout_file: *Io.File.Writer, status: u8) !u8 {
    stdout_file.interface.flush() catch |err| {
        if (isBrokenPipe(stdout_file, err)) return 0;
        return err;
    };
    return status;
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
        error.JournalFull => "tj: journal has no entry numbers left\n",
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
        error.NoSuchInteraction => "tj: no such entry\n",
        error.NoSuchResource => "tj: no such resource or file\n",
        error.InsideJournal => "tj: cannot replay inside a live journal writer, because it would record the replay; run it from a shell that is not under tj\n",
        error.CrossJournalMutation => "tj: writes and entry deletion are limited to the current journal\n",
        error.InvalidName => "tj: invalid entry name\n",
        error.InvalidTag => "tj: invalid tag\n",
        error.NameTaken => "tj: that entry name is already in use\n",
        error.LegacyAnnotationsUnsupported => "tj: legacy annotations.json is unsupported; remove the old journal before using this version\n",
        error.InvalidAnnotationDatabase => "tj: invalid or incompatible journal.sqlite3; refusing to overwrite it\n",
        error.AnnotationBusy => "tj: journal metadata remained busy for 5 seconds\n",
        error.AnnotationConstraint => "tj: journal metadata violates its schema\n",
        error.AnnotationDatabaseFailure => "tj: cannot access journal metadata\n",
        error.UnsupportedRemoval => "tj: only an entry or its out may be removed\n",
        error.InvalidRange => "tj: invalid entry range; use ascending numeric references such as @2..@10\n",
        error.CurrentInteraction => if (which == .cat)
            "tj: cannot read the currently running entry as part of a range\n"
        else
            "tj: cannot remove the currently running entry\n",
        error.PinnedInteraction => "tj: pinned entry protected; use --force to remove it\n",
        error.ActiveJournal => "tj: cannot remove a journal while it is being written\n",
        error.AmbiguousJournal => "tj: journal suffix is ambiguous\n",
        error.ConfirmationRequired => "tj: use --force to remove a journal non-interactively\n",
        error.Cancelled => "tj: journal removal cancelled\n",
        error.BadArguments => "tj: invalid arguments for this subcommand\n",
        error.InvalidMetadata => "tj: invalid entry metadata; refusing partial removal\n",
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
    _ = @import("report.zig");
    _ = @import("sqlite.zig");
    _ = @import("mutation_lock.zig");
    _ = commands;
}
