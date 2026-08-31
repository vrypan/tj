//! The subcommands that read the journal.
//!
//! This file is the dispatcher. Each command group lives in its own module;
//! what they share lives in `context.zig` and `report.zig`.

const std = @import("std");
const Io = std.Io;
const zecli = @import("zecli");

const cli = @import("cli.zig");
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
const cmd_tui = @import("cmd_tui.zig");

pub const Error = context.Error;

pub fn run(
    gpa: std.mem.Allocator,
    io: Io,
    which: cli.CommandName,
    home: ?[]const u8,
    child: []const [:0]const u8,
    parsed: *const zecli.Parsed,
    out: *Io.Writer,
) !u8 {
    switch (which) {
        .tui => try cmd_tui.run(gpa, io, home),
        .noout => {
            const result = try noout.run(gpa, child);
            return result.exit_code;
        },
        .hist => try cmd_history.listInteractions(gpa, io, home, parsed, out),
        .last => try cmd_history.printLast(gpa, io, home, out),
        .resolve => try cmd_reference.resolveReference(gpa, io, home, parsed, out),
        .complete => try cmd_reference.completeReference(gpa, io, home, parsed, out),
        .cat => try cmd_cat.catResource(gpa, io, home, parsed, out),
        .name => try cmd_annotate.nameCommand(gpa, io, home, parsed, out),
        .tag => try cmd_annotate.tagCommand(gpa, io, home, parsed, out),
        .pin => try cmd_annotate.pinCommand(gpa, io, home, parsed, out),
        .rm => try cmd_remove.removeCommand(gpa, io, home, parsed, out),
        .grep => return cmd_grep.grepCommand(gpa, io, home, parsed, out),
    }
    return 0;
}
