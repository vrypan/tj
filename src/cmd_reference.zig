//! `tj resolve` and `tj complete` - the `@` namespace the shell integration
//! calls for every reference on a command line.

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

/// Prints the path a reference names. The shell integration calls this for
/// every `@`-word on a command line, so it has to be quiet and quick.
pub fn resolveReference(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    parsed: *const zecli.Parsed,
    out: *Io.Writer,
) !void {
    const ref = reference.parse(parsed.positionals.items[0]) catch return error.BadReference;

    var root = try store.openRoot(io, home);
    defer root.close(io);

    const found = try store.locate(gpa, io, root, sys.env("TJ_JOURNAL"), ref);
    defer found.deinit(gpa);

    // The resource inside may not exist yet, but the interaction must, or the
    // caller would be handed a path to nothing.
    if (!found.exists) return error.NoSuchInteraction;
    try out.print("{s}\n", .{found.path});
}

/// Candidate words for a partially typed reference, one per line. Kept lenient
/// on purpose: the input is mid-typing and mostly will not parse.
pub fn completeReference(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    parsed: *const zecli.Parsed,
    out: *Io.Writer,
) !void {
    const partial = if (parsed.positionals.items.len > 0) parsed.positionals.items[0] else "@";
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

/// `@4<TAB>` and `@release-build.<TAB>` - which entries exist.
pub fn completeInteractions(
    gpa: std.mem.Allocator,
    io: Io,
    root: store.Dir,
    body: []const u8,
    out: *Io.Writer,
) !void {
    var prefix = body;
    var qualifier: []const u8 = "";
    var journal_owned: ?[]u8 = null;
    defer if (journal_owned) |name| gpa.free(name);

    const journal: []const u8 = if (std.mem.lastIndexOfScalar(u8, body, '.')) |dot| blk: {
        qualifier = body[0 .. dot + 1];
        prefix = body[dot + 1 ..];
        journal_owned = store.findUniqueJournal(gpa, io, root, body[0..dot]) catch return;
        break :blk journal_owned.?;
    } else sys.env("TJ_JOURNAL") orelse return;

    const numbers = store.listNumbers(gpa, io, root, journal) catch return;
    defer gpa.free(numbers);

    for (numbers) |number| {
        var buf: [16]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d}", .{number}) catch continue;
        if (!std.mem.startsWith(u8, text, prefix)) continue;
        try out.print("@{s}{s}\n", .{ qualifier, text });
    }

    var metadata = annotations.openRead(gpa, io, root, journal) catch return;
    defer metadata.deinit(gpa);
    var names = metadata.names() catch return;
    defer names.deinit();
    while (names.next() catch return) |entry| {
        if (!store.interactionExists(io, root, journal, entry.number)) continue;
        if (!std.mem.startsWith(u8, entry.name, prefix)) continue;
        try out.print("@{s}{s}\n", .{ qualifier, entry.name });
    }
}

/// `@42/<TAB>` and `@42/files/<TAB>` - what the interaction holds.
pub fn completeResources(
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
    const ref_text = std.fmt.allocPrint(gpa, "@{s}", .{body[0..cut]}) catch return;
    defer gpa.free(ref_text);
    const ref = reference.parse(ref_text) catch return;
    const directory = if (cut < body.len) body[cut + 1 ..] else "";

    const found = store.locate(gpa, io, root, sys.env("TJ_JOURNAL"), ref) catch return;
    defer found.deinit(gpa);
    if (!found.exists) return;

    const names = if (directory.len == 0)
        store.listResources(gpa, io, root, found.journal, found.number) catch return
    else
        listWithin(gpa, io, root, found.journal, found.number, directory) catch return;
    defer {
        for (names) |name| gpa.free(name);
        gpa.free(names);
    }

    for (names) |name| {
        if (!std.mem.startsWith(u8, name, prefix)) continue;
        try out.print("@{s}/{s}\n", .{ body, name });
    }
}

pub fn listWithin(
    gpa: std.mem.Allocator,
    io: Io,
    root: store.Dir,
    journal: []const u8,
    number: u32,
    directory: []const u8,
) ![][]u8 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const sub = try std.fmt.bufPrint(&path_buf, "{s}/{d}/{s}", .{ journal, number, directory });

    var dir = try root.openDir(io, sub, .{ .iterate = true });
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
