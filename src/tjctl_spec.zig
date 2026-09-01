const zecli = @import("zecli");

const journal_completion = zecli.CompletionKind{ .external = .{
    .executable = "tjctl",
    .arguments = &.{"complete"},
} };

const home_flag = zecli.FlagSpec{
    .name = "home",
    .value = .string,
    .value_name = "DIR",
    .description = "Journal location (default: $TJ_HOME, else ~/.tj)",
    .completion = .directories,
};
const keep_osc = zecli.FlagSpec{ .name = "keep-osc", .description = "Forward TJ protocol control sequences" };
const no_splash = zecli.FlagSpec{ .name = "no-splash", .description = "Start without the recording splash" };
const title = zecli.FlagSpec{
    .name = "title",
    .short = 't',
    .value = .string,
    .value_name = "FORMAT",
    .description = "Override the shell-evaluated terminal-title format, or use none",
    .default_value = "TJ | %3~",
};
const title_blink = zecli.FlagSpec{
    .name = "title-blink",
    .value = .string,
    .value_name = "MS",
    .description = "Alternate the title recording marker every MS (0 disables)",
    .default_value = "1500",
};
const lifecycle_flags = [_]zecli.FlagSpec{ home_flag, keep_osc, no_splash, title, title_blink };
const use_flags = [_]zecli.FlagSpec{ home_flag, keep_osc, no_splash, title, title_blink, .{ .name = "no-replay", .description = "Start without replaying the journal" } };
const force_flags = [_]zecli.FlagSpec{.{ .name = "force", .description = "Skip confirmation or override pin protection" }};
const ls_flags = [_]zecli.FlagSpec{
    .{ .name = "long", .short = 'l', .description = "Show activity details" },
    .{
        .name = "number",
        .short = 'n',
        .value = .string,
        .value_name = "NUMBER",
        .description = "Show at most NUMBER journals",
    },
};
const du_flags = [_]zecli.FlagSpec{
    .{ .name = "chart", .description = "Show every entry's size as a chart" },
    .{ .name = "bytes", .description = "Show exact byte counts" },
};
const replay_flags = [_]zecli.FlagSpec{
    .{ .name = "speed", .value = .string, .value_name = "X", .description = "Divide recorded delays by X", .default_value = "1" },
    .{ .name = "typing", .value = .string, .value_name = "MS", .description = "Delay per command character", .default_value = "35" },
    .{ .name = "max-pause", .value = .string, .value_name = "MS", .description = "Cap each recorded pause", .default_value = "2000" },
    .{ .name = "prompt", .value = .string, .value_name = "TEXT", .description = "Override captured prompts", .default_value = "$ " },
    .{ .name = "from", .value = .string, .value_name = "N", .description = "Start at entry N", .default_value = "1" },
    .{ .name = "to", .value = .string, .value_name = "N", .description = "Stop after entry N" },
    .{ .name = "duration", .description = "Print replay duration instead of playing it" },
};

const commands = [_]zecli.CommandSpec{
    .{
        .name = "new",
        .description = "Create and write a new journal",
        .usage = "tjctl new [options] [NAME] [-- COMMAND...]",
        .flags = &lifecycle_flags,
        .arguments = &.{.{ .name = "NAME", .description = "Canonical journal name" }},
        .extra_help = "A child command must follow `--`; otherwise $SHELL is started.\n",
    },
    .{
        .name = "use",
        .description = "Append to an existing journal with a fresh shell or command",
        .usage = "tjctl use [options] JOURNAL [-- COMMAND...]",
        .flags = &use_flags,
        .arguments = &.{.{ .name = "JOURNAL", .description = "Exact name or unambiguous suffix", .required = true, .completion = journal_completion }},
    },
    .{ .name = "ls", .description = "List journals", .usage = "tjctl ls [-l] [-n NUMBER]", .flags = &ls_flags },
    .{
        .name = "mv",
        .description = "Rename an inactive journal",
        .usage = "tjctl mv JOURNAL NEW-NAME",
        .arguments = &.{
            .{ .name = "JOURNAL", .description = "Exact name or unambiguous suffix", .required = true, .completion = journal_completion },
            .{ .name = "NEW-NAME", .description = "New canonical journal name", .required = true },
        },
    },
    .{
        .name = "rm",
        .description = "Remove an inactive journal",
        .usage = "tjctl rm JOURNAL [--force]",
        .flags = &force_flags,
        .arguments = &.{.{ .name = "JOURNAL", .description = "Exact name or unambiguous suffix", .required = true, .completion = journal_completion }},
    },
    .{
        .name = "du",
        .description = "Show a journal's logical storage size",
        .usage = "tjctl du [JOURNAL] [--chart] [--bytes]",
        .flags = &du_flags,
        .arguments = &.{.{ .name = "JOURNAL", .description = "Exact name or unambiguous suffix", .completion = journal_completion }},
    },
    .{
        .name = "replay",
        .description = "Play a journal back into the terminal",
        .usage = "tjctl replay JOURNAL [options]",
        .flags = &replay_flags,
        .arguments = &.{.{ .name = "JOURNAL", .description = "Exact name or unambiguous suffix", .required = true, .completion = journal_completion }},
    },
    .{ .name = "current", .description = "Print the current journal name", .usage = "tjctl current" },
    .{
        .name = "complete",
        .description = "Print canonical journal-name candidates",
        .usage = "tjctl complete [PREFIX]",
        .arguments = &.{.{ .name = "PREFIX", .description = "Journal-name prefix" }},
    },
};

const root_flags = [_]zecli.FlagSpec{
    home_flag,
    .{ .name = "version", .short = 'V', .description = "Print version" },
};

pub const application = application: {
    @setEvalBranchQuota(10_000);
    break :application zecli.comptimeValidated(.{
        .name = "tjctl",
        .prefix = "TJ",
        .description = "tjctl - Terminal Journal control",
        .usage = "tjctl [options] <command>",
        .flags = &root_flags,
        .commands = &commands,
    });
};

pub fn findCommand(name: []const u8) ?zecli.CommandSpec {
    return zecli.findCommand(application, name);
}
