//! The subcommands that read the journal.
//!
//! This file is the dispatcher. Each command group lives in its own module;
//! what they share lives in `context.zig` and `report.zig`.

const std = @import("std");
const Io = std.Io;
const zecli = @import("zecli");

const cli = @import("cli.zig");
const proxy = @import("proxy.zig");
const store = @import("store.zig");
const sys = @import("sys.zig");
const reference = @import("reference.zig");
const plain = @import("plain.zig");
const annotations = @import("annotations.zig");
const mutation_lock = @import("mutation_lock.zig");
const search = @import("search.zig");
const noout = @import("noout.zig");
const report = @import("report.zig");
const replay_engine = @import("replay.zig");
const context = @import("context.zig");
const cmd_grep = @import("cmd_grep.zig");
const cmd_history = @import("cmd_history.zig");
const cmd_reference = @import("cmd_reference.zig");
const cmd_annotate = @import("cmd_annotate.zig");
const cmd_remove = @import("cmd_remove.zig");
const cmd_cat = @import("cmd_cat.zig");
const cmd_replay = @import("cmd_replay.zig");

pub const Error = context.Error;

pub fn run(
    gpa: std.mem.Allocator,
    io: Io,
    command: cli.RoutedCommand,
    child: []const [:0]const u8,
    parsed: *const zecli.Parsed,
    out: *Io.Writer,
) !u8 {
    const home = command.root.home;
    switch (command.which) {
        .new => {
            const result = try proxy.run(gpa, io, .{
                .journal = .new,
                .argv = child,
                .keep_osc = command.root.keep_osc or parsed.present("keep-osc"),
                .home = parsed.last("home") orelse home,
            });
            return result.exit_code;
        },
        .@"continue" => {
            const result = try proxy.run(gpa, io, .{
                .journal = .{ .existing = parsed.positionals.items[0] },
                .argv = child,
                .keep_osc = command.root.keep_osc or parsed.present("keep-osc"),
                .replay_before_start = !parsed.present("no-replay"),
                .home = parsed.last("home") orelse home,
            });
            return result.exit_code;
        },
        .noout => {
            const result = try noout.run(gpa, child);
            return result.exit_code;
        },
        .current => try out.print("{s}\n", .{try context.currentJournal()}),
        .journal => try cmd_remove.journalCommand(gpa, io, home, parsed, out),
        .hist => try cmd_history.listInteractions(gpa, io, home, parsed, out),
        .usage => try cmd_history.usageCommand(gpa, io, home, parsed, out),
        .last => try cmd_history.printLast(gpa, io, home, out),
        .resolve => try cmd_reference.resolveReference(gpa, io, home, parsed, out),
        .complete => try cmd_reference.completeReference(gpa, io, home, parsed, out),
        .cat => try cmd_cat.catResource(gpa, io, home, parsed, out),
        .replay => try cmd_replay.replayJournal(gpa, io, home, parsed, out),
        .name => try cmd_annotate.nameCommand(gpa, io, home, parsed, out),
        .tag => try cmd_annotate.tagCommand(gpa, io, home, parsed, out),
        .pin => try cmd_annotate.pinCommand(gpa, io, home, parsed, out),
        .rm => try cmd_remove.removeCommand(gpa, io, home, parsed, out),
        .grep => return cmd_grep.grepCommand(gpa, io, home, parsed, out),
    }
    return 0;
}
