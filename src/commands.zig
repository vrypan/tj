//! The subcommands that read the journal.

const std = @import("std");
const Io = std.Io;

const cli = @import("cli.zig");
const store = @import("store.zig");
const sys = @import("sys.zig");

/// The parsed subcommand, exactly as `cli` produced it.
const Subcommand = @FieldType(cli.Command, "subcommand");

pub const Error = error{
    NotInSession,
    NoSuchSession,
    NothingRecorded,
};

pub fn run(
    gpa: std.mem.Allocator,
    io: Io,
    sub: Subcommand,
    out: *Io.Writer,
) !void {
    switch (sub.which) {
        .current => try out.print("{s}\n", .{try currentSession()}),
        .sessions => try listSessions(gpa, io, sub.home, out),
        .list => try listInteractions(gpa, io, sub.home, sub.args, out),
        .last => try printLast(gpa, io, sub.home, out),
        // Reference resolution and completion arrive with the `@` namespace.
        .resolve, .complete => return error.NotImplemented,
    }
}

fn currentSession() Error![]const u8 {
    return sys.env("TJ_SESSION") orelse error.NotInSession;
}

fn listSessions(gpa: std.mem.Allocator, io: Io, home: ?[]const u8, out: *Io.Writer) !void {
    var root = try store.openRoot(io, home);
    defer root.close(io);

    const sessions = try store.listSessions(gpa, io, root);
    defer {
        for (sessions) |name| gpa.free(name);
        gpa.free(sessions);
    }

    const current = sys.env("TJ_SESSION");
    for (sessions) |name| {
        const interactions = store.listInteractions(gpa, io, root, name) catch continue;
        defer {
            for (interactions) |info| info.deinit(gpa);
            gpa.free(interactions);
        }
        const marker = if (current != null and std.mem.eql(u8, current.?, name)) "*" else " ";
        try out.print("{s} {s}  {d} interaction{s}\n", .{
            marker,
            name,
            interactions.len,
            if (interactions.len == 1) "" else "s",
        });
    }
}

fn listInteractions(gpa: std.mem.Allocator, io: Io, home: ?[]const u8, args: []const []const u8, out: *Io.Writer) !void {
    const session = if (args.len > 0) args[0] else try currentSession();

    var root = try store.openRoot(io, home);
    defer root.close(io);

    const interactions = store.listInteractions(gpa, io, root, session) catch |err| switch (err) {
        error.FileNotFound => return error.NoSuchSession,
        else => return err,
    };
    defer {
        for (interactions) |info| info.deinit(gpa);
        gpa.free(interactions);
    }

    for (interactions) |info| {
        // A missing status means the interaction never finished; it must not
        // be shown as if it succeeded.
        var status_buf: [8]u8 = undefined;
        const status = if (info.exit_code) |code|
            std.fmt.bufPrint(&status_buf, "{d}", .{code}) catch "?"
        else
            "-";
        try out.print("{d: >5}  {s: <3}  {s}\n", .{ info.number, status, firstLine(info.command) });
    }
}

fn printLast(gpa: std.mem.Allocator, io: Io, home: ?[]const u8, out: *Io.Writer) !void {
    const session = try currentSession();

    var root = try store.openRoot(io, home);
    defer root.close(io);

    const number = try store.lastCompleted(gpa, io, root, session) orelse
        return error.NothingRecorded;
    try out.print("{d}\n", .{number});
}

/// Multi-line commands are real; a listing shows only the first line of one.
fn firstLine(text: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, text, '\n') orelse return text;
    return text[0..end];
}

test "firstLine stops at the first newline" {
    try std.testing.expectEqualStrings("git status", firstLine("git status"));
    try std.testing.expectEqualStrings("for f in *; do", firstLine("for f in *; do\n  echo $f\ndone"));
    try std.testing.expectEqualStrings("", firstLine(""));
}
