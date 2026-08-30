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
    .{
        .name = "tag",
        .value = .string,
        .value_name = "TAG",
        .description = "Show entries having this tag (AND when repeated)",
        .repeatable = true,
    },
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
            .description = "Entry reference, numeric range, or @journal-name.",
            .repeatable = true,
            .completion = reference_completion,
        }},
        .extra_help = "With no targets, list the current journal. A trailing dot selects an entire journal: @release-build.\n",
    },
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
        .extra_help = "Pinned targets are skipped unless --force is present.\n",
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
        \\  @release-build.42/out        entry 42 of another journal
        \\  @build-failure/out  a named entry in this journal
        \\  @release-build.build-failure/out  a named entry in another journal
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
