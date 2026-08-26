//! The subcommands that read the journal.

const std = @import("std");
const Io = std.Io;

const cli = @import("cli.zig");
const store = @import("store.zig");
const sys = @import("sys.zig");
const reference = @import("reference.zig");

/// The parsed subcommand, exactly as `cli` produced it.
const Subcommand = @FieldType(cli.Command, "subcommand");

pub const Error = error{
    NotInSession,
    NoSuchSession,
    NothingRecorded,
    MissingArgument,
    BadReference,
    NoSuchInteraction,
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
        .resolve => try resolveReference(gpa, io, sub.home, sub.args, out),
        .complete => try completeReference(gpa, io, sub.home, sub.args, out),
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

// --- the `@` namespace -----------------------------------------------------

/// Prints the path a reference names. The shell integration calls this for
/// every `@`-word on a command line, so it has to be quiet and quick.
fn resolveReference(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    args: []const []const u8,
    out: *Io.Writer,
) !void {
    if (args.len == 0) return error.MissingArgument;
    const ref = reference.parse(args[0]) catch return error.BadReference;

    var root = try store.openRoot(io, home);
    defer root.close(io);

    const found = try store.locate(gpa, io, root, sys.env("TJ_SESSION"), ref);
    defer found.deinit(gpa);

    // The resource inside may not exist yet, but the interaction must, or the
    // caller would be handed a path to nothing.
    if (!found.exists) return error.NoSuchInteraction;
    try out.print("{s}\n", .{found.path});
}

/// Candidate words for a partially typed reference, one per line. Kept lenient
/// on purpose: the input is mid-typing and mostly will not parse.
fn completeReference(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    args: []const []const u8,
    out: *Io.Writer,
) !void {
    const partial = if (args.len > 0) args[0] else "@";
    if (partial.len == 0 or partial[0] != '@') return;

    var root = store.openRoot(io, home) catch return;
    defer root.close(io);

    const rest = partial[1..];
    if (std.mem.lastIndexOfScalar(u8, rest, '/')) |slash| {
        try completeResources(gpa, io, root, rest[0..slash], rest[slash + 1 ..], out);
    } else {
        try completeInteractions(gpa, io, root, rest, out);
    }
}

/// `@4<TAB>` and `@pgsd.<TAB>` - which interactions exist.
fn completeInteractions(
    gpa: std.mem.Allocator,
    io: Io,
    root: store.Dir,
    body: []const u8,
    out: *Io.Writer,
) !void {
    var prefix = body;
    var qualifier: []const u8 = "";
    var session_owned: ?[]u8 = null;
    defer if (session_owned) |name| gpa.free(name);

    const session: []const u8 = if (std.mem.lastIndexOfScalar(u8, body, '.')) |dot| blk: {
        qualifier = body[0 .. dot + 1];
        prefix = body[dot + 1 ..];
        session_owned = try store.findSession(gpa, io, root, body[0..dot]) orelse return;
        break :blk session_owned.?;
    } else sys.env("TJ_SESSION") orelse return;

    // A body being typed as a session suffix has no numbers to offer yet.
    for (prefix) |char| if (!std.ascii.isDigit(char)) return;

    const numbers = store.listNumbers(gpa, io, root, session) catch return;
    defer gpa.free(numbers);

    for (numbers) |number| {
        var buf: [16]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d}", .{number}) catch continue;
        if (!std.mem.startsWith(u8, text, prefix)) continue;
        try out.print("@{s}{s}\n", .{ qualifier, text });
    }
}

/// `@42/<TAB>` and `@42/files/<TAB>` - what the interaction holds.
fn completeResources(
    gpa: std.mem.Allocator,
    io: Io,
    root: store.Dir,
    body: []const u8,
    prefix: []const u8,
    out: *Io.Writer,
) !void {
    // Everything before the last slash is settled; only the last segment is
    // still being typed.
    const cut = std.mem.indexOfScalar(u8, body, '/') orelse body.len;
    const ref = reference.parse(std.fmt.allocPrint(gpa, "@{s}", .{body[0..cut]}) catch return) catch return;
    const directory = if (cut < body.len) body[cut + 1 ..] else "";

    const found = store.locate(gpa, io, root, sys.env("TJ_SESSION"), ref) catch return;
    defer found.deinit(gpa);
    if (!found.exists) return;

    const names = if (directory.len == 0)
        store.listResources(gpa, io, root, found.session, found.number) catch return
    else
        listWithin(gpa, io, root, found.session, found.number, directory) catch return;
    defer {
        for (names) |name| gpa.free(name);
        gpa.free(names);
    }

    for (names) |name| {
        if (!std.mem.startsWith(u8, name, prefix)) continue;
        try out.print("@{s}/{s}\n", .{ body, name });
    }
}

fn listWithin(
    gpa: std.mem.Allocator,
    io: Io,
    root: store.Dir,
    session: []const u8,
    number: u32,
    directory: []const u8,
) ![][]u8 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const sub = try std.fmt.bufPrint(&path_buf, "{s}/{d}/{s}", .{ session, number, directory });

    var dir = try root.openDir(io, sub, .{});
    defer dir.close(io);

    var found: std.ArrayList([]u8) = .empty;
    errdefer {
        for (found.items) |name| gpa.free(name);
        found.deinit(gpa);
    }

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const name = if (entry.kind == .directory)
            try std.fmt.allocPrint(gpa, "{s}/", .{entry.name})
        else
            try gpa.dupe(u8, entry.name);
        try found.append(gpa, name);
    }
    return found.toOwnedSlice(gpa);
}
