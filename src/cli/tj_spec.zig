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

const root_flags = [_]zecli.FlagSpec{
    home_flag,
    .{ .name = "version", .short = 'V', .description = "Print version" },
};

const hist_flags = [_]zecli.FlagSpec{
    .{
        .name = "pinned",
        .aliases = &.{"pin"},
        .description = "Show only pinned entries",
    },
    .{ .name = "numbers", .description = "Print only entry numbers" },
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

const pin_flags = [_]zecli.FlagSpec{
    .{ .name = "remove", .description = "Unpin the selected entry" },
    .{ .name = "numbers", .description = "Print only pinned entry numbers" },
};

const force_flag = [_]zecli.FlagSpec{
    .{ .name = "force", .description = "Override pin protection" },
};

const grep_flags = [_]zecli.FlagSpec{
    .{ .name = "all", .description = "Search across all journals" },
    .{ .name = "numbers", .description = "Print only matching entry numbers" },
    .{ .name = "cmd", .description = "Search command lines" },
    .{ .name = "out", .description = "Search command output" },
    .{ .name = "ignore-case", .short = 'i', .description = "Case-insensitive search (only ASCII)" },
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

const filter_flags = [_]zecli.FlagSpec{
    .{ .name = "noout", .description = "Keep visible bytes out of recorded output" },
    .{ .name = "fence", .description = "Publish triple-backtick blocks as resources" },
};

const commands = [_]zecli.CommandSpec{
    .{
        .name = "tui",
        .aliases = &.{"t"},
        .description = "Browse, inspect, pin, and delete entries",
        .usage = "tj tui [TARGET...]",
        .arguments = &.{.{
            .name = "TARGET",
            .description = "Entry reference or numeric range",
            .repeatable = true,
            .completion = reference_completion,
        }},
        .double_dash = .positionals,
        .extra_help = "With redirected standard input, show only the space-separated entry numbers it contains.\n",
    },
    .{
        .name = "filter",
        .description = "Filter input or a command's output for a journal",
        .usage = "tj filter (--noout | --fence) [-- COMMAND...]",
        .flags = &filter_flags,
        .extra_help =
        \\Without `-- COMMAND`, filter standard input and write it to standard output.
        \\`--noout` and `--fence` are mutually exclusive.
        ++ "\n",
    },
    .{
        .name = "history",
        .aliases = &.{"h"},
        .description = "List entries with pin status, size, and date",
        .usage = "tj history [options] [TARGET...]",
        .flags = &hist_flags,
        .arguments = &.{.{
            .name = "TARGET",
            .description = "Entry reference, numeric range, or @journal-name.",
            .repeatable = true,
            .completion = reference_completion,
        }},
        .double_dash = .positionals,
        .extra_help = "With no targets, list the current journal. A trailing dot selects an entire journal: @release-build.\n",
    },
    .{ .name = "last", .description = "Print the last completed entry number", .usage = "tj last", .double_dash = .positionals },
    .{
        .name = "cat",
        .aliases = &.{"c"},
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
        .double_dash = .positionals,
    },
    .{
        .name = "resolve",
        .description = "Print the filesystem path named by a reference",
        .usage = "tj resolve <REF>",
        .arguments = &.{.{ .name = "REF", .description = "Journal reference", .required = true, .completion = reference_completion }},
        .double_dash = .positionals,
    },
    .{
        .name = "complete",
        .description = "Print candidates for a partial journal reference",
        .usage = "tj complete [REF]",
        .arguments = &.{.{ .name = "REF", .description = "Partial journal reference", .completion = reference_completion }},
        .double_dash = .positionals,
    },
    .{
        .name = "pin",
        .description = "Pin, unpin, or list pinned entries",
        .usage = "tj pin [--remove] [TARGET...]",
        .flags = &pin_flags,
        .arguments = &.{.{ .name = "TARGET", .description = "Entry reference or numeric range", .repeatable = true, .completion = reference_completion }},
        .double_dash = .positionals,
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
        .double_dash = .positionals,
        .extra_help = "Pinned targets are skipped unless --force is present.\n",
    },
    .{
        .name = "grep",
        .description = "Search journal commands and output for a literal",
        .usage = "tj grep [options] <PATTERN> [TARGET...]",
        .flags = &grep_flags,
        .arguments = &.{
            .{ .name = "PATTERN", .description = "One non-empty literal byte string", .required = true },
            .{ .name = "TARGET", .description = "Entry reference, numeric range, or @journal-name.", .repeatable = true, .completion = reference_completion },
        },
        .double_dash = .positionals,
    },
};

pub const application = application: {
    @setEvalBranchQuota(10_000);
    break :application zecli.comptimeValidated(.{
        .name = "tj",
        .prefix = "TJ",
        .description = "tj - Terminal Journal",
        .usage = "tj [options] <command|@REF>",
        .flags = &root_flags,
        .commands = &commands,
        .extra_help =
        \\References name previous computations the way paths name files:
        \\  @42/out             entry 42 of this journal
        \\  @-/out              the last entry that completed
        \\  @release-build.42/out        entry 42 of another journal
        \\  tj @42/out           print a reference's filesystem path (tj resolve shorthand)
        \\
        \\Recording needs a shell plugin; zsh also expands bare references:
        \\  source /path/to/tj.plugin.zsh   # ~/.zshrc
        \\  source /path/to/tj.plugin.fish  # ~/.config/fish/config.fish
        ++ "\n",
    });
};

pub fn findCommand(name: []const u8) ?zecli.CommandSpec {
    return zecli.findCommand(application, name);
}
