//! The subcommands that read the journal.
//!
//! This file is the dispatcher. Each command group lives in its own module;
//! what they share lives in `context.zig` and `report.zig`.

const std = @import("std");
const Io = std.Io;
const zecli = @import("zecli");

const cli = @import("../cli/tj.zig");
const cmd_filter = @import("filter.zig");
const context = @import("context.zig");
const cmd_grep = @import("grep.zig");
const cmd_history = @import("history.zig");
const cmd_reference = @import("reference.zig");
const cmd_pin = @import("pin.zig");
const cmd_remove = @import("remove.zig");
const cmd_cat = @import("cat.zig");
const cmd_tui = @import("tui.zig");

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
        .filter => return cmd_filter.run(gpa, io, parsed, child, out),
        .hist => try cmd_history.listInteractions(gpa, io, home, parsed, out),
        .last => try cmd_history.printLast(gpa, io, home, out),
        .resolve => try cmd_reference.resolveReference(gpa, io, home, parsed, out),
        .complete => try cmd_reference.completeReference(gpa, io, home, parsed, out),
        .cat => try cmd_cat.catResource(gpa, io, home, parsed, out),
        .pin => try cmd_pin.pinCommand(gpa, io, home, parsed, out),
        .rm => try cmd_remove.removeCommand(gpa, io, home, parsed, out),
        .grep => return cmd_grep.grepCommand(gpa, io, home, parsed, out),
    }
    return 0;
}
