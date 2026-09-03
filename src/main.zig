const std = @import("std");
const Io = std.Io;
const zecli = @import("zecli");

const cli = @import("cli.zig");
const cli_spec = @import("cli_spec.zig");
const proxy = @import("proxy.zig");
const commands = @import("commands.zig");
const frontend = @import("frontend.zig");
const zooi = @import("zooi");

pub const version = frontend.version;
pub const panic = std.debug.FullPanic(struct {
    fn restoreThenPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
        zooi.restore();
        proxy.restoreOnPanic();
        std.debug.defaultPanic(msg, first_trace_addr);
    }
}.restoreThenPanic);

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const gpa = frontend.commandAllocator();
    defer frontend.deinitAllocator("tj");
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [4096]u8 = undefined;
    var stdout_file: Io.File.Writer = .init(.stdout(), init.io, &stdout_buf);
    var stderr_file: Io.File.Writer = .init(.stderr(), init.io, &stderr_buf);
    const stdout = &stdout_file.interface;
    const stderr = &stderr_file.interface;

    const command_args = try cli.routeBareReference(arena, args[1..]);
    var invocation = zecli.Invocation.init(arena, stderr, cli_spec.application, command_args, init.environ_map) catch |err| {
        if (err == error.ReportedCliError) {
            try stderr.flush();
            return 2;
        }
        return err;
    };
    defer invocation.deinit(arena);

    const help_printed = invocation.printHelpIfRequested(arena, stdout) catch |err| {
        if (frontend.isBrokenPipe(&stdout_file, err)) return 0;
        return err;
    };
    if (help_printed) return frontend.flushStdout(&stdout_file, 0);

    if (invocation.enabled("version")) {
        stdout.writeAll("tj " ++ version ++ "\n") catch |err| {
            if (frontend.isBrokenPipe(&stdout_file, err)) return 0;
            return err;
        };
        return frontend.flushStdout(&stdout_file, 0);
    }

    const command = invocation.getCommand() orelse {
        zecli.printApplicationHelp(arena, stdout, cli_spec.application) catch |err| {
            if (frontend.isBrokenPipe(&stdout_file, err)) return 0;
            return err;
        };
        return frontend.flushStdout(&stdout_file, 0);
    };
    const which = try command.as(cli.CommandName);
    const spec = command.spec;

    cli.validateRemoveOrdering(which, command_args) catch {
        try stderr.writeAll("tj: invalid arguments for this subcommand\n\n");
        try zecli.printCommandHelp(arena, stderr, spec);
        try stderr.flush();
        return 2;
    };

    var child: []const [:0]const u8 = &.{};
    if (which == .filter) {
        if (command.positionals().len != 0) {
            try stderr.writeAll("tj: filter commands must follow `--`\n\n");
            try zecli.printCommandHelp(arena, stderr, spec);
            try stderr.flush();
            return 2;
        }
        child = command.passthrough() orelse &.{};
    } else if (which != .grep and command.passthrough() != null) {
        try stderr.writeAll("tj: invalid arguments for this subcommand\n\n");
        try zecli.printCommandHelp(arena, stderr, spec);
        try stderr.flush();
        return 2;
    }

    const status = commands.run(
        gpa,
        init.io,
        which,
        invocation.getValue([]const u8, "home"),
        child,
        &command.parsed,
        stdout,
    ) catch |err| {
        if (frontend.isBrokenPipe(&stdout_file, err)) return 0;
        stdout.flush() catch {};
        try stderr.writeAll(commandErrorMessage(which, err));
        if (isUsageError(err)) {
            try stderr.writeByte('\n');
            try zecli.printCommandHelp(arena, stderr, spec);
        }
        try stderr.flush();
        if (isUsageError(err) or err == error.NoSuchInteraction) return 2;
        return 1;
    };
    return frontend.flushStdout(&stdout_file, status);
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
    if (which == .tui) return switch (err) {
        error.NotInJournal => "tj: tui must run inside a tj journal writer\n",
        error.NoControllingTerminal, error.NotATerminal => "tj: tui needs an interactive terminal\n",
        error.TerminalSetupFailed, error.ReadFailed, error.PollFailed => "tj: tui terminal session failed\n",
        else => "tj: cannot open the journal browser\n",
    };
    if (which == .filter) return switch (err) {
        error.NotInJournal => "tj: filter --noout must run inside a tj journal writer\n",
        error.NoControllingTerminal => "tj: filter --noout needs a controlling terminal\n",
        error.ForkFailed => "tj: cannot fork\n",
        else => "tj: cannot run filter\n",
    };
    if (which == .grep) switch (err) {
        error.NoControllingTerminal, error.NotATerminal => return "tj: grep --tui needs an interactive terminal\n",
        error.TerminalSetupFailed, error.ReadFailed, error.PollFailed => return "tj: grep --tui terminal session failed\n",
        else => {},
    };
    return switch (err) {
        error.NotInJournal => "tj: not inside a tj journal writer\n",
        error.NoSuchJournal => "tj: no journal matches that name\n",
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
    _ = @import("journal_name.zig");
    _ = @import("scanner.zig");
    _ = @import("reference.zig");
    _ = @import("altscreen.zig");
    _ = @import("plain.zig");
    _ = @import("store.zig");
    _ = @import("search.zig");
    _ = @import("report.zig");
    _ = @import("context.zig");
    _ = @import("cmd_grep.zig");
    _ = @import("cmd_history.zig");
    _ = @import("cmd_journal_report.zig");
    _ = @import("cmd_reference.zig");
    _ = @import("cmd_annotate.zig");
    _ = @import("cmd_remove.zig");
    _ = @import("cmd_cat.zig");
    _ = @import("cmd_replay.zig");
    _ = @import("sqlite.zig");
    _ = @import("mutation_lock.zig");
    _ = @import("handoff.zig");
    _ = commands;
}
