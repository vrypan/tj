const std = @import("std");
const Io = std.Io;
const zecli = @import("zecli");

const frontend = @import("frontend.zig");
const cli = @import("tjctl_cli.zig");
const cli_spec = @import("tjctl_spec.zig");
const commands = @import("journal_commands.zig");
const proxy = @import("proxy.zig");
const zooi = @import("zooi");

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
    defer frontend.deinitAllocator("tjctl");
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [4096]u8 = undefined;
    var stdout_file: Io.File.Writer = .init(.stdout(), init.io, &stdout_buf);
    var stderr_file: Io.File.Writer = .init(.stderr(), init.io, &stderr_buf);
    const stdout = &stdout_file.interface;
    const stderr = &stderr_file.interface;

    var invocation = zecli.Invocation.init(arena, stderr, cli_spec.application, args[1..], init.environ_map) catch |err| {
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
        stdout.print("tjctl {s}\n", .{frontend.version}) catch |err| {
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
    const command_spec = command.spec;

    var child: []const [:0]const u8 = &.{};
    if (which == .new or which == .use) {
        if (command.passthrough()) |passthrough| {
            if (passthrough.len == 0) {
                try stderr.writeAll(rootErrorMessage(error.MissingChildCommand));
                try zecli.printCommandHelp(arena, stderr, command_spec);
                try stderr.flush();
                return 2;
            }
            child = passthrough;
        }
    } else if (command.passthrough() != null) {
        try stderr.writeAll("tjctl: invalid arguments for this subcommand\n\n");
        try zecli.printCommandHelp(arena, stderr, command_spec);
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
        try stderr.writeAll(commandErrorMessage(err));
        try stderr.flush();
        return if (isUsageError(err)) 2 else 1;
    };
    return frontend.flushStdout(&stdout_file, status);
}

fn rootErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.MissingChildCommand => "tjctl: a command is required after `--`\n\n",
        else => "tjctl: invalid command line\n\n",
    };
}

fn isUsageError(err: anyerror) bool {
    return switch (err) {
        error.MissingArgument, error.BadReplayOption, error.BadTitleBlink, error.BadArguments => true,
        else => false,
    };
}

fn commandErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.NotInJournal => "tjctl: not inside a tj journal writer\n",
        error.NoSuchJournal => "tjctl: no journal matches that name\n",
        error.AmbiguousJournal => "tjctl: journal suffix is ambiguous\n",
        error.InvalidJournalName => "tjctl: invalid journal name\n",
        error.JournalExists => "tjctl: a journal with that name already exists\n",
        error.JournalLocked, error.ActiveJournal => "tjctl: journal is already being written\n",
        error.InsideJournalRename => "tjctl: cannot rename a journal from inside a writer\n",
        error.InsideJournalRemoval => "tjctl: remove a whole journal only from outside a writer\n",
        error.PinnedInteraction => "tjctl: pinned entries protected; use --force to remove the journal\n",
        error.ConfirmationRequired => "tjctl: use --force to remove a journal non-interactively\n",
        error.Cancelled => "tjctl: journal removal cancelled\n",
        error.StartupCancelled => "tjctl: journal start cancelled\n",
        error.InsideJournal => "tjctl: cannot replay inside a live journal writer\n",
        error.MissingArgument => "tjctl: this subcommand needs an argument\n",
        error.BadReplayOption => "tjctl: invalid replay numeric option\n",
        error.BadTitleBlink => "tjctl: --title-blink needs milliseconds from 0 through 2147483647\n",
        error.JournalFull => "tjctl: journal has no entry numbers left\n",
        error.ForkFailed => "tjctl: cannot fork\n",
        error.Syscall => "tjctl: cannot allocate a pseudo-terminal\n",
        else => "tjctl: cannot access the journal\n",
    };
}

test {
    _ = @import("journal_name.zig");
    _ = cli;
    _ = cli_spec;
    _ = commands;
}
