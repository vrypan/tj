const zecli = @import("zecli");

const reference_completion = zecli.CompletionKind{ .external = .{
    .executable = "tj",
    .arguments = &.{"complete"},
} };

const home_flag = zecli.FlagSpec{
    .name = "home",
    .value = .string,
    .value_name = "DIR",
    .description = "Journal location (default: $TJ_HOME, else ~/.tj)",
    .completion = .directories,
};

const keep_osc_flag = zecli.FlagSpec{
    .name = "keep-osc",
    .description = "Forward TJ's own control sequences instead of stripping them",
};

const new_flags = [_]zecli.FlagSpec{ home_flag, keep_osc_flag };

const continue_flags = [_]zecli.FlagSpec{
    home_flag,
    keep_osc_flag,
    .{ .name = "no-replay", .description = "Start without replaying the existing journal" },
};

const root_flags = [_]zecli.FlagSpec{
    home_flag,
    keep_osc_flag,
    .{ .name = "version", .short = 'V', .description = "Print version" },
};

const hist_flags = [_]zecli.FlagSpec{
    .{
        .name = "pinned",
        .aliases = &.{"pin"},
        .description = "Show only pinned entries",
    },
    .{
        .name = "tag",
        .value = .string,
        .value_name = "TAG",
        .description = "Show entries having this tag (AND when repeated)",
        .repeatable = true,
    },
};

const usage_flags = [_]zecli.FlagSpec{
    .{ .name = "chart", .description = "Show every entry's size as a terminal-width chart" },
    .{ .name = "bytes", .description = "List exact entry bytes, or use exact values in the chart" },
};

const cat_flags = [_]zecli.FlagSpec{
    .{ .name = "raw", .short = 'r', .description = "Write recorded bytes without rendering", .repeatable = true },
    .{ .name = "plain", .short = 'p', .description = "Render terminal output as plain text", .repeatable = true },
    .{
        .name = "head",
        .value = .int,
        .value_name = "N",
        .description = "Print the first N lines",
        .repeatable = true,
    },
    .{
        .name = "tail",
        .value = .int,
        .value_name = "N",
        .description = "Print the last N lines",
        .repeatable = true,
    },
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

const remove_flag = [_]zecli.FlagSpec{
    .{ .name = "remove", .description = "Remove the selected annotation" },
};

const force_flag = [_]zecli.FlagSpec{
    .{ .name = "force", .description = "Override pin protection or skip confirmation" },
};

const grep_flags = [_]zecli.FlagSpec{
    .{ .name = "all", .short = 'a', .description = "Search every journal" },
    .{ .name = "cmd", .description = "Search commands" },
    .{ .name = "out", .description = "Search output" },
    .{ .name = "ignore-case", .short = 'i', .description = "Fold ASCII letter case" },
    .{
        .name = "color",
        .aliases = &.{"colour"},
        .value = .string,
        .value_name = "WHEN",
        .description = "Highlight matches",
        .default_value = "never",
        .choices = &.{ "never", "auto", "always" },
    },
};

const commands = [_]zecli.CommandSpec{
    .{
        .name = "new",
        .description = "Run $SHELL, or a command, writing a new journal",
        .usage = "tj new [options] [-- COMMAND...]",
        .flags = &new_flags,
        .extra_help = "COMMAND may omit `--` when its executable does not begin with `-`.\n",
    },
    .{
        .name = "continue",
        .description = "Run a fresh shell or command, appending to one journal",
        .usage = "tj continue [options] <JOURNAL> [-- COMMAND...]",
        .flags = &continue_flags,
        .arguments = &.{.{
            .name = "JOURNAL",
            .description = "Existing journal ID or unambiguous suffix",
            .required = true,
        }},
        .extra_help = "Continuing does not restore paths, environment, shell state, or processes.\n",
    },
    .{
        .name = "noout",
        .description = "Run a command whose visible output is omitted from out",
        .usage = "tj noout -- COMMAND...",
        .extra_help = "The `--` separator and at least one command word are required.\n",
    },
    .{
        .name = "hist",
        .aliases = &.{"history"},
        .description = "List entries with annotations, size, and date",
        .usage = "tj hist [options] [TARGET...]",
        .flags = &hist_flags,
        .arguments = &.{.{
            .name = "TARGET",
            .description = "Entry reference, numeric range, or @journal-suffix.",
            .repeatable = true,
            .completion = reference_completion,
        }},
        .extra_help = "With no targets, list the current journal. A trailing dot selects an entire journal: @8wpc.\n",
    },
    .{
        .name = "usage",
        .description = "Show the current journal's logical storage size",
        .usage = "tj usage [--chart] [--bytes]",
        .flags = &usage_flags,
        .extra_help = "Sizes sum file lengths, not filesystem allocation blocks. --bytes alone prints @ENTRY BYTES; with --chart it selects exact numeric sizes.\n",
    },
    .{
        .name = "journal",
        .description = "List journals or remove an inactive journal",
        .usage = "tj journal <list|rm> [JOURNAL] [--force]",
        .flags = &force_flag,
        .arguments = &.{
            .{ .name = "ACTION", .description = "Journal operation", .required = true, .completion = .{ .values = &.{ "list", "rm" } } },
            .{ .name = "JOURNAL", .description = "Journal ID or unambiguous suffix" },
        },
        .extra_help = "`list` takes no JOURNAL or options. `rm` refuses active and pinned journals; --force overrides pins and confirmation.\n",
    },
    .{ .name = "current", .description = "Print the current journal ID", .usage = "tj current" },
    .{ .name = "last", .description = "Print the last completed entry", .usage = "tj last" },
    .{
        .name = "cat",
        .description = "Print what one or more references name",
        .usage = "tj cat [options] <REF>...",
        .flags = &cat_flags,
        .arguments = &.{.{
            .name = "REF",
            .description = "Journal reference, numeric range, or resolved path",
            .required = true,
            .repeatable = true,
            .completion = reference_completion,
        }},
    },
    .{
        .name = "replay",
        .description = "Play a journal back into the terminal",
        .usage = "tj replay [options] [JOURNAL]",
        .flags = &replay_flags,
        .arguments = &.{.{ .name = "JOURNAL", .description = "Journal ID or suffix" }},
    },
    .{
        .name = "resolve",
        .description = "Print the filesystem path named by a reference",
        .usage = "tj resolve <REF>",
        .arguments = &.{.{ .name = "REF", .description = "Journal reference", .required = true, .completion = reference_completion }},
    },
    .{
        .name = "complete",
        .description = "Print candidates for a partial journal reference",
        .usage = "tj complete [REF]",
        .arguments = &.{.{ .name = "REF", .description = "Partial journal reference", .completion = reference_completion }},
    },
    .{
        .name = "name",
        .description = "Name, query, remove, or list entry names",
        .usage = "tj name [--remove] [REF [NAME]]",
        .flags = &remove_flag,
        .arguments = &.{
            .{ .name = "REF", .description = "Entry reference or assigned name", .completion = reference_completion },
            .{ .name = "NAME", .description = "New entry name" },
        },
    },
    .{
        .name = "tag",
        .description = "Tag, query, remove, or list entry tags",
        .usage = "tj tag [--remove] [TARGET... [TAG...]]",
        .flags = &remove_flag,
        .arguments = &.{
            .{ .name = "TARGET", .description = "First entry reference or numeric range", .completion = reference_completion },
            .{
                .name = "TARGET_OR_TAG",
                .description = "Additional targets, then journal-local tags",
                .repeatable = true,
                .completion = reference_completion,
            },
        },
        .extra_help = "Targets must precede tags. With no tags, the selected targets are queried.\n",
    },
    .{
        .name = "pin",
        .description = "Pin, unpin, or list pinned entries",
        .usage = "tj pin [--remove] [REF]",
        .flags = &remove_flag,
        .arguments = &.{.{ .name = "REF", .description = "Entry reference or numeric range", .completion = reference_completion }},
    },
    .{
        .name = "rm",
        .description = "Remove recorded entry data",
        .usage = "tj rm [--force] <TARGET>...",
        .flags = &force_flag,
        .arguments = &.{.{
            .name = "TARGET",
            .description = "Entry, out resource, or numeric range",
            .required = true,
            .repeatable = true,
            .completion = reference_completion,
        }},
        .extra_help = "Pinned targets are skipped unless --force is present. Use `tj journal rm ID` to remove a whole journal.\n",
    },
    .{
        .name = "grep",
        .description = "Search journal commands and output for a literal",
        .usage = "tj grep [options] [--] <PATTERN>",
        .flags = &grep_flags,
        .arguments = &.{.{ .name = "PATTERN", .description = "One non-empty literal byte string", .required = true }},
    },
};

pub const application = application: {
    @setEvalBranchQuota(10_000);
    break :application zecli.comptimeValidated(.{
        .name = "tj",
        .description = "tj - Terminal Journal",
        .usage = "tj [options] <command>",
        .flags = &root_flags,
        .commands = &commands,
        .extra_help =
        \\References name previous computations the way paths name files:
        \\  @42/out             entry 42 of this journal
        \\  @-/out              the last entry that completed
        \\  @pgsd.42/out        entry 42 of another journal
        \\  @build-failure/out  a named entry in this journal
        \\  @pgsd.build-failure/out  a named entry in another journal
        \\  ~[@42]/out          canonical zsh form; unquoted @42/out is shorthand
        \\
        \\Recording and reference expansion need the shell integration:
        \\  source /path/to/tj.plugin.zsh   # in ~/.zshrc
        ++ "\n",
    });
};

pub fn findCommand(name: []const u8) ?zecli.CommandSpec {
    return zecli.findCommand(application, name);
}
