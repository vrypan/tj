//! The subcommands that read the journal.

const std = @import("std");
const Io = std.Io;

const cli = @import("cli.zig");
const store = @import("store.zig");
const sys = @import("sys.zig");
const reference = @import("reference.zig");
const plain = @import("plain.zig");
const annotations = @import("annotations.zig");

/// The parsed subcommand, exactly as `cli` produced it.
const Subcommand = @FieldType(cli.Command, "subcommand");

pub const Error = error{
    NotInJournal,
    NoSuchJournal,
    NothingRecorded,
    MissingArgument,
    BadReference,
    NoSuchInteraction,
    NoSuchResource,
    BadCount,
    BadReplayOption,
    InsideJournal,
    CrossJournalMutation,
    InvalidName,
    InvalidTag,
    NameTaken,
    InvalidAnnotations,
    UnsupportedRemoval,
    InvalidRange,
    CurrentInteraction,
    ActiveJournal,
    AmbiguousJournal,
    ConfirmationRequired,
    Cancelled,
    BadArguments,
    InvalidMetadata,
    InsideJournalRemoval,
};

pub fn run(
    gpa: std.mem.Allocator,
    io: Io,
    sub: Subcommand,
    out: *Io.Writer,
) !void {
    switch (sub.which) {
        .current => try out.print("{s}\n", .{try currentJournal()}),
        .journals => try listJournals(gpa, io, sub.home, out),
        .hist => try listInteractions(gpa, io, sub.home, sub.args, out),
        .last => try printLast(gpa, io, sub.home, out),
        .resolve => try resolveReference(gpa, io, sub.home, sub.args, out),
        .complete => try completeReference(gpa, io, sub.home, sub.args, out),
        .cat => try catResource(gpa, io, sub.home, sub.args, out),
        .replay => try replayJournal(gpa, io, sub.home, sub.args, out),
        .name => try nameCommand(gpa, io, sub.home, sub.args, out),
        .tag => try tagCommand(gpa, io, sub.home, sub.args, out),
        .pin => try pinCommand(gpa, io, sub.home, sub.args, out),
        .rm => try removeCommand(gpa, io, sub.home, sub.args, out),
    }
}

fn currentJournal() Error![]const u8 {
    return sys.env("TJ_JOURNAL") orelse error.NotInJournal;
}

fn listJournals(gpa: std.mem.Allocator, io: Io, home: ?[]const u8, out: *Io.Writer) !void {
    var root = try store.openRoot(io, home);
    defer root.close(io);

    const journals = try store.listJournals(gpa, io, root);
    defer {
        for (journals) |name| gpa.free(name);
        gpa.free(journals);
    }

    const current = sys.env("TJ_JOURNAL");
    for (journals) |name| {
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
    var root = try store.openRoot(io, home);
    defer root.close(io);

    var filters: std.ArrayList([]u8) = .empty;
    defer {
        for (filters.items) |tag| gpa.free(tag);
        filters.deinit(gpa);
    }
    var wanted: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        var tag_text: ?[]const u8 = null;
        if (std.mem.eql(u8, arg, "--tag")) {
            if (i + 1 >= args.len) return error.MissingArgument;
            i += 1;
            tag_text = args[i];
        } else if (std.mem.startsWith(u8, arg, "--tag=")) {
            tag_text = arg["--tag=".len..];
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.BadArguments;
        } else {
            if (wanted != null) return error.BadArguments;
            wanted = arg;
        }
        if (tag_text) |text| try filters.append(gpa, annotations.normalizeTag(gpa, text) catch return error.InvalidTag);
    }

    var journal_owned: ?[]u8 = null;
    defer if (journal_owned) |name| gpa.free(name);
    const journal: []const u8 = if (wanted) |selector| blk: {
        journal_owned = try store.findNewestJournal(gpa, io, root, selector) orelse return error.NoSuchJournal;
        break :blk journal_owned.?;
    } else try currentJournal();

    var manifest = annotations.load(gpa, io, root, journal) catch |err| switch (err) {
        error.InvalidAnnotations => return error.InvalidAnnotations,
        else => return err,
    };
    defer manifest.deinit(gpa);

    const interactions = store.listInteractions(gpa, io, root, journal) catch |err| switch (err) {
        error.FileNotFound => return error.NoSuchJournal,
        else => return err,
    };
    defer {
        for (interactions) |info| info.deinit(gpa);
        gpa.free(interactions);
    }

    for (interactions) |info| {
        if (!manifest.hasAllTags(info.number, filters.items)) continue;
        const annotation = manifest.findConst(info.number);
        // A missing status means the interaction never finished; it must not
        // be shown as if it succeeded.
        var status_buf: [8]u8 = undefined;
        const status = if (info.exit_code) |code|
            std.fmt.bufPrint(&status_buf, "{d}", .{code}) catch "?"
        else
            "-";
        var size_buf: [8]u8 = undefined;
        var name_buf: [80]u8 = undefined;
        const name = if (annotation) |entry|
            if (entry.name) |value| std.fmt.bufPrint(&name_buf, "@{s}", .{value}) catch "-" else "-"
        else
            "-";
        var tags_text: std.ArrayList(u8) = .empty;
        defer tags_text.deinit(gpa);
        if (annotation) |entry| {
            for (entry.tags.items, 0..) |tag, tag_i| {
                if (tag_i != 0) try tags_text.append(gpa, ',');
                try tags_text.appendSlice(gpa, tag);
            }
        }
        const tags = if (tags_text.items.len == 0) "-" else tags_text.items;
        try out.print("{d: >5}{s}  {s: <3}  {s: >5}  {s: <20}  {s: <20}  {s}\n", .{
            info.number,
            if (annotation != null and annotation.?.pinned) "*" else " ",
            status,
            humanSize(info.out_bytes, &size_buf),
            name,
            tags,
            firstLine(info.command),
        });
    }
}

fn printLast(gpa: std.mem.Allocator, io: Io, home: ?[]const u8, out: *Io.Writer) !void {
    const journal = try currentJournal();

    var root = try store.openRoot(io, home);
    defer root.close(io);

    const number = try store.lastCompleted(gpa, io, root, journal) orelse
        return error.NothingRecorded;
    try out.print("{d}\n", .{number});
}

/// Sizes are for judging at a glance whether an output is worth fetching, so
/// three significant characters is plenty.
fn humanSize(bytes: u64, buf: []u8) []const u8 {
    if (bytes < 1024) return std.fmt.bufPrint(buf, "{d}", .{bytes}) catch "?";
    if (bytes < 1024 * 1024) return std.fmt.bufPrint(buf, "{d}K", .{bytes / 1024}) catch "?";
    return std.fmt.bufPrint(buf, "{d}M", .{bytes / (1024 * 1024)}) catch "?";
}

test "sizes read at a glance" {
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("0", humanSize(0, &buf));
    try std.testing.expectEqualStrings("185", humanSize(185, &buf));
    try std.testing.expectEqualStrings("1K", humanSize(1024, &buf));
    try std.testing.expectEqualStrings("53K", humanSize(54418, &buf));
    try std.testing.expectEqualStrings("2M", humanSize(2 * 1024 * 1024, &buf));
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

    const found = try store.locate(gpa, io, root, sys.env("TJ_JOURNAL"), ref);
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
    var journal_owned: ?[]u8 = null;
    defer if (journal_owned) |name| gpa.free(name);

    const journal: []const u8 = if (std.mem.lastIndexOfScalar(u8, body, '.')) |dot| blk: {
        qualifier = body[0 .. dot + 1];
        prefix = body[dot + 1 ..];
        journal_owned = try store.findNewestJournal(gpa, io, root, body[0..dot]) orelse return;
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

    var manifest = annotations.load(gpa, io, root, journal) catch return;
    defer manifest.deinit(gpa);
    for (manifest.entries.items) |entry| {
        const name = entry.name orelse continue;
        if (!store.interactionExists(io, root, journal, entry.number)) continue;
        if (!std.mem.startsWith(u8, name, prefix)) continue;
        try out.print("@{s}{s}\n", .{ qualifier, name });
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

fn listWithin(
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

// --- interaction annotations ----------------------------------------------

const CommandTarget = struct {
    journal: []u8,
    number: u32,
    subpath: []const u8,
    syntactically_qualified: bool = false,

    fn deinit(self: CommandTarget, gpa: std.mem.Allocator) void {
        gpa.free(self.journal);
    }
};

fn locateCommandTarget(
    gpa: std.mem.Allocator,
    io: Io,
    root: store.Dir,
    text: []const u8,
) !CommandTarget {
    if (reference.parse(text)) |parsed| {
        const qualified = parsed.body == .qualified;
        const found = try store.locate(gpa, io, root, sys.env("TJ_JOURNAL"), parsed);
        defer found.deinit(gpa);
        if (!found.exists) return error.NoSuchInteraction;
        return .{
            .journal = try gpa.dupe(u8, found.journal),
            .number = found.number,
            .subpath = parsed.subpath,
            .syntactically_qualified = qualified,
        };
    } else |err| switch (err) {
        error.Malformed => return error.BadReference,
        error.NotAReference => {},
    }

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try root.realPath(io, &root_buf);
    const root_path = root_buf[0..root_len];
    if (!std.mem.startsWith(u8, text, root_path) or text.len <= root_path.len or text[root_path.len] != '/') {
        return error.BadReference;
    }
    const relative = text[root_path.len + 1 ..];
    const journal_end = std.mem.indexOfScalar(u8, relative, '/') orelse return error.BadReference;
    const journal = relative[0..journal_end];
    const after_journal = relative[journal_end + 1 ..];
    const number_end = std.mem.indexOfScalar(u8, after_journal, '/') orelse after_journal.len;
    const number = std.fmt.parseInt(u32, after_journal[0..number_end], 10) catch return error.BadReference;
    if (number == 0 or !store.interactionExists(io, root, journal, number)) return error.NoSuchInteraction;
    const subpath = if (number_end < after_journal.len) after_journal[number_end + 1 ..] else "";
    if (subpath.len != 0) {
        const check = try std.fmt.allocPrint(gpa, "@1/{s}", .{subpath});
        defer gpa.free(check);
        _ = reference.parse(check) catch return error.BadReference;
    }
    return .{
        .journal = try gpa.dupe(u8, journal),
        .number = number,
        .subpath = subpath,
    };
}

fn requireMutationTarget(
    gpa: std.mem.Allocator,
    io: Io,
    root: store.Dir,
    text: []const u8,
) !CommandTarget {
    const current = try currentJournal();
    const target = try locateCommandTarget(gpa, io, root, text);
    errdefer target.deinit(gpa);
    if (target.syntactically_qualified or !std.mem.eql(u8, target.journal, current)) {
        return error.CrossJournalMutation;
    }
    return target;
}

fn requireInteraction(target: CommandTarget) !void {
    if (target.subpath.len != 0) return error.BadReference;
}

fn printCanonical(out: *Io.Writer, current: ?[]const u8, journal: []const u8, number: u32) !void {
    if (current) |id| {
        if (std.mem.eql(u8, id, journal)) return out.print("@{d}", .{number});
    }
    try out.print("@{s}.{d}", .{ journal, number });
}

fn openCurrentMutation(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
) !struct { root: store.Dir, journal: []const u8, lock: Io.File } {
    const journal = try currentJournal();
    var root = try store.openRoot(io, home);
    errdefer root.close(io);
    const lock = try annotations.acquireMutationLock(io, root, journal);
    errdefer lock.close(io);
    try store.recoverPendingOutputRemovals(gpa, io, root, journal);
    store.cleanupJournalTrash(io, root, journal);
    return .{ .root = root, .journal = journal, .lock = lock };
}

fn pruneMissingAnnotations(
    gpa: std.mem.Allocator,
    io: Io,
    root: store.Dir,
    journal: []const u8,
    manifest: *annotations.Manifest,
) void {
    var i: usize = 0;
    while (i < manifest.entries.items.len) {
        const number = manifest.entries.items[i].number;
        if (store.interactionExists(io, root, journal, number)) {
            i += 1;
        } else {
            manifest.removeInteraction(gpa, number);
        }
    }
}

fn nameCommand(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    args: []const []const u8,
    out: *Io.Writer,
) !void {
    if (args.len == 0) {
        const current = try currentJournal();
        var root = try store.openRoot(io, home);
        defer root.close(io);
        var manifest = try annotations.load(gpa, io, root, current);
        defer manifest.deinit(gpa);
        for (manifest.entries.items) |entry| {
            const name = entry.name orelse continue;
            if (!store.interactionExists(io, root, current, entry.number)) continue;
            try out.print("{s}  @{d}\n", .{ name, entry.number });
        }
        return;
    }

    if (std.mem.eql(u8, args[0], "--remove")) {
        if (args.len != 2) return error.BadArguments;
        var mutation = try openCurrentMutation(gpa, io, home);
        defer mutation.lock.close(io);
        defer mutation.root.close(io);
        var manifest = try annotations.load(gpa, io, mutation.root, mutation.journal);
        defer manifest.deinit(gpa);
        pruneMissingAnnotations(gpa, io, mutation.root, mutation.journal, &manifest);
        try manifest.removeName(gpa, args[1]);
        return annotations.save(gpa, io, mutation.root, mutation.journal, &manifest);
    }
    if (args.len > 2) return error.BadArguments;

    var root = try store.openRoot(io, home);
    defer root.close(io);
    if (args.len == 1) {
        const target = try locateCommandTarget(gpa, io, root, args[0]);
        defer target.deinit(gpa);
        try requireInteraction(target);
        var manifest = try annotations.load(gpa, io, root, target.journal);
        defer manifest.deinit(gpa);
        const entry = manifest.findConst(target.number) orelse return;
        const name = entry.name orelse return;
        try out.print("{s}  ", .{name});
        try printCanonical(out, sys.env("TJ_JOURNAL"), target.journal, target.number);
        return out.writeAll("\n");
    }

    const target = try requireMutationTarget(gpa, io, root, args[0]);
    defer target.deinit(gpa);
    try requireInteraction(target);
    var mutation = try openCurrentMutation(gpa, io, home);
    defer mutation.lock.close(io);
    defer mutation.root.close(io);
    if (!store.interactionExists(io, mutation.root, mutation.journal, target.number)) return error.NoSuchInteraction;
    var manifest = try annotations.load(gpa, io, mutation.root, mutation.journal);
    defer manifest.deinit(gpa);
    pruneMissingAnnotations(gpa, io, mutation.root, mutation.journal, &manifest);
    try manifest.setName(gpa, target.number, args[1]);
    try annotations.save(gpa, io, mutation.root, mutation.journal, &manifest);
}

fn tagCommand(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    args: []const []const u8,
    out: *Io.Writer,
) !void {
    if (args.len == 0) {
        const current = try currentJournal();
        var root = try store.openRoot(io, home);
        defer root.close(io);
        var manifest = try annotations.load(gpa, io, root, current);
        defer manifest.deinit(gpa);
        for (manifest.entries.items) |entry| {
            if (entry.tags.items.len == 0 or !store.interactionExists(io, root, current, entry.number)) continue;
            try out.print("@{d}", .{entry.number});
            for (entry.tags.items) |tag| try out.print("  {s}", .{tag});
            try out.writeAll("\n");
        }
        return;
    }

    const removing = std.mem.eql(u8, args[0], "--remove");
    const target_i: usize = if (removing) 1 else 0;
    if (args.len <= target_i) return error.MissingArgument;

    if (!removing and args.len == 1) {
        var root = try store.openRoot(io, home);
        defer root.close(io);
        const target = try locateCommandTarget(gpa, io, root, args[0]);
        defer target.deinit(gpa);
        try requireInteraction(target);
        var manifest = try annotations.load(gpa, io, root, target.journal);
        defer manifest.deinit(gpa);
        const entry = manifest.findConst(target.number) orelse return;
        if (entry.tags.items.len == 0) return;
        try printCanonical(out, sys.env("TJ_JOURNAL"), target.journal, target.number);
        for (entry.tags.items) |tag| try out.print("  {s}", .{tag});
        return out.writeAll("\n");
    }

    if (args.len <= target_i + 1) return error.MissingArgument;
    const target = blk: {
        var root = try store.openRoot(io, home);
        defer root.close(io);
        break :blk try requireMutationTarget(gpa, io, root, args[target_i]);
    };
    defer target.deinit(gpa);
    try requireInteraction(target);

    var mutation = try openCurrentMutation(gpa, io, home);
    defer mutation.lock.close(io);
    defer mutation.root.close(io);
    if (!store.interactionExists(io, mutation.root, mutation.journal, target.number)) return error.NoSuchInteraction;
    var manifest = try annotations.load(gpa, io, mutation.root, mutation.journal);
    defer manifest.deinit(gpa);
    pruneMissingAnnotations(gpa, io, mutation.root, mutation.journal, &manifest);
    for (args[target_i + 1 ..]) |tag| {
        if (removing) {
            try manifest.removeTag(gpa, target.number, tag);
        } else {
            try manifest.addTag(gpa, target.number, tag);
        }
    }
    try annotations.save(gpa, io, mutation.root, mutation.journal, &manifest);
}

fn pinCommand(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    args: []const []const u8,
    out: *Io.Writer,
) !void {
    if (args.len == 0) {
        const current = try currentJournal();
        var root = try store.openRoot(io, home);
        defer root.close(io);
        var manifest = try annotations.load(gpa, io, root, current);
        defer manifest.deinit(gpa);
        for (manifest.entries.items) |entry| {
            if (entry.pinned and store.interactionExists(io, root, current, entry.number)) {
                try out.print("@{d}\n", .{entry.number});
            }
        }
        return;
    }

    const removing = std.mem.eql(u8, args[0], "--remove");
    const target_i: usize = if (removing) 1 else 0;
    if (args.len != target_i + 1) return error.BadArguments;
    const target = blk: {
        var root = try store.openRoot(io, home);
        defer root.close(io);
        break :blk try requireMutationTarget(gpa, io, root, args[target_i]);
    };
    defer target.deinit(gpa);
    try requireInteraction(target);

    var mutation = try openCurrentMutation(gpa, io, home);
    defer mutation.lock.close(io);
    defer mutation.root.close(io);
    if (!store.interactionExists(io, mutation.root, mutation.journal, target.number)) return error.NoSuchInteraction;
    var manifest = try annotations.load(gpa, io, mutation.root, mutation.journal);
    defer manifest.deinit(gpa);
    pruneMissingAnnotations(gpa, io, mutation.root, mutation.journal, &manifest);
    try manifest.setPinned(gpa, target.number, !removing);
    try annotations.save(gpa, io, mutation.root, mutation.journal, &manifest);
}

fn removeCommand(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    args: []const []const u8,
    out: *Io.Writer,
) !void {
    if (args.len == 0) return error.MissingArgument;

    var journal_selector: ?[]const u8 = null;
    var force = false;
    var interaction_arg: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--journal")) {
            if (i + 1 >= args.len or journal_selector != null) return error.BadArguments;
            i += 1;
            journal_selector = args[i];
        } else if (std.mem.eql(u8, args[i], "--force")) {
            if (force) return error.BadArguments;
            force = true;
        } else {
            if (interaction_arg != null) return error.BadArguments;
            interaction_arg = args[i];
        }
    }

    if (journal_selector) |selector| {
        if (interaction_arg != null) return error.BadArguments;
        if (sys.env("TJ_JOURNAL") != null) return error.InsideJournalRemoval;
        var root = try store.openRoot(io, home);
        defer root.close(io);
        const journal = try store.findUniqueJournal(gpa, io, root, selector);
        defer gpa.free(journal);

        const interactions = try store.listInteractions(gpa, io, root, journal);
        defer {
            for (interactions) |info| info.deinit(gpa);
            gpa.free(interactions);
        }
        if (!force) {
            if (!sys.isTty(0)) return error.ConfirmationRequired;
            try out.print("Remove journal {s} with {d} interaction{s}? [y/N] ", .{
                journal,
                interactions.len,
                if (interactions.len == 1) "" else "s",
            });
            try out.flush();
            var answer_buf: [32]u8 = undefined;
            const read = try sys.read(0, &answer_buf);
            const answer = std.mem.trim(u8, answer_buf[0..read], " \t\r\n");
            if (!(std.ascii.eqlIgnoreCase(answer, "y") or std.ascii.eqlIgnoreCase(answer, "yes"))) {
                return error.Cancelled;
            }
        }
        return store.removeJournal(io, root, journal) catch |err| switch (err) {
            error.ActiveJournal => error.ActiveJournal,
            else => return err,
        };
    }

    if (force or interaction_arg == null) return error.BadArguments;
    if (try parseRemovalRange(interaction_arg.?)) |range| {
        return removeInteractionRange(gpa, io, home, range);
    }
    const target = blk: {
        var root = try store.openRoot(io, home);
        defer root.close(io);
        break :blk try requireMutationTarget(gpa, io, root, interaction_arg.?);
    };
    defer target.deinit(gpa);
    const output_only = std.mem.eql(u8, target.subpath, "out");
    if (target.subpath.len != 0 and !output_only) return error.UnsupportedRemoval;

    var mutation = try openCurrentMutation(gpa, io, home);
    defer mutation.lock.close(io);
    defer mutation.root.close(io);
    if (!std.mem.eql(u8, target.journal, mutation.journal)) return error.CrossJournalMutation;
    if (!store.interactionExists(io, mutation.root, mutation.journal, target.number)) return error.NoSuchInteraction;
    const highest = try store.highestNumber(gpa, io, mutation.root, mutation.journal) orelse
        return error.NoSuchInteraction;
    if (target.number >= highest) return error.CurrentInteraction;

    var manifest = try annotations.load(gpa, io, mutation.root, mutation.journal);
    defer manifest.deinit(gpa);
    pruneMissingAnnotations(gpa, io, mutation.root, mutation.journal, &manifest);

    if (output_only) {
        return store.removeOutput(gpa, io, mutation.root, mutation.journal, target.number) catch |err| switch (err) {
            error.InvalidMetadata => error.InvalidMetadata,
            else => return err,
        };
    }

    const staged = try store.stageInteractionRemoval(gpa, io, mutation.root, mutation.journal, target.number);
    defer gpa.free(staged);
    manifest.removeInteraction(gpa, target.number);
    try annotations.save(gpa, io, mutation.root, mutation.journal, &manifest);
    try store.finishStagedRemoval(io, mutation.root, staged);
}

const RemovalRange = struct {
    first: u32,
    last: u32,
};

/// `rm` owns this small grammar extension; ranges are not references accepted
/// by readers, zsh expansion, or other mutation commands.
fn parseRemovalRange(text: []const u8) !?RemovalRange {
    const cut = std.mem.indexOf(u8, text, "..") orelse return null;
    if (std.mem.indexOf(u8, text[cut + 2 ..], "..") != null) return error.InvalidRange;

    const first = try parseRemovalRangeEndpoint(text[0..cut]);
    const last = try parseRemovalRangeEndpoint(text[cut + 2 ..]);
    if (first > last) return error.InvalidRange;
    return .{ .first = first, .last = last };
}

fn parseRemovalRangeEndpoint(text: []const u8) !u32 {
    const parsed = reference.parse(text) catch return error.InvalidRange;
    if (parsed.subpath.len != 0 or parsed.trailing_slash) return error.InvalidRange;
    return switch (parsed.body) {
        .current => |target| switch (target) {
            .number => |number| number,
            .name => error.InvalidRange,
        },
        .qualified => error.CrossJournalMutation,
        .previous => error.InvalidRange,
    };
}

fn removeInteractionRange(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    range: RemovalRange,
) !void {
    var mutation = try openCurrentMutation(gpa, io, home);
    defer mutation.lock.close(io);
    defer mutation.root.close(io);

    const numbers = try store.listNumbers(gpa, io, mutation.root, mutation.journal);
    defer gpa.free(numbers);
    if (numbers.len == 0) return error.NoSuchInteraction;

    // The highest directory is the running removal command in normal use, or
    // an unfinished boundary left by the last writer. Validate this before
    // staging any directory so a protected range cannot partially apply.
    const highest = numbers[numbers.len - 1];
    if (range.first <= highest and highest <= range.last) return error.CurrentInteraction;

    var selected: usize = 0;
    for (numbers) |number| {
        if (range.first <= number and number <= range.last) selected += 1;
    }
    if (selected == 0) return error.NoSuchInteraction;

    var manifest = try annotations.load(gpa, io, mutation.root, mutation.journal);
    defer manifest.deinit(gpa);
    pruneMissingAnnotations(gpa, io, mutation.root, mutation.journal, &manifest);

    var staged_paths: std.ArrayList([]u8) = .empty;
    defer {
        for (staged_paths.items) |path| gpa.free(path);
        staged_paths.deinit(gpa);
    }
    try staged_paths.ensureTotalCapacity(gpa, selected);

    for (numbers) |number| {
        if (number < range.first or number > range.last) continue;
        const staged = try store.stageInteractionRemoval(gpa, io, mutation.root, mutation.journal, number);
        staged_paths.appendAssumeCapacity(staged);
        manifest.removeInteraction(gpa, number);
    }

    try annotations.save(gpa, io, mutation.root, mutation.journal, &manifest);
    for (staged_paths.items) |path| try store.finishStagedRemoval(io, mutation.root, path);
}

test "interaction removal ranges are inclusive numeric current-journal references" {
    const range = (try parseRemovalRange("@2..@10")).?;
    try std.testing.expectEqual(@as(u32, 2), range.first);
    try std.testing.expectEqual(@as(u32, 10), range.last);
    try std.testing.expect((try parseRemovalRange("@2")) == null);
    try std.testing.expectError(error.InvalidRange, parseRemovalRange("@10..@2"));
    try std.testing.expectError(error.InvalidRange, parseRemovalRange("@two..@ten"));
    try std.testing.expectError(error.InvalidRange, parseRemovalRange("@2/out..@10/out"));
    try std.testing.expectError(error.CrossJournalMutation, parseRemovalRange("@abcd.2..@abcd.10"));
}

// --- reading resources ------------------------------------------------------

const read_chunk_size = 64 * 1024;

/// `tj cat @42` - print what an interaction recorded, without needing the
/// shell integration to expand anything. Useful from bash, from a script, or
/// from a shell that is not running under tj at all.
fn catResource(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    args: []const []const u8,
    out: *Io.Writer,
) !void {
    // Terminals can render escape sequences, pipes cannot. Follow the usual
    // convention and let either flag settle it explicitly.
    var as_written = sys.isTty(1);
    var window: Window = .all;
    var refs: std.ArrayList([]const u8) = .empty;
    defer refs.deinit(gpa);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--raw") or std.mem.eql(u8, arg, "-r")) {
            as_written = true;
        } else if (std.mem.eql(u8, arg, "--plain") or std.mem.eql(u8, arg, "-p")) {
            as_written = false;
        } else if (try takeCount(args, &i, "--head")) |n| {
            window = .{ .head = n };
        } else if (try takeCount(args, &i, "--tail")) |n| {
            window = .{ .tail = n };
        } else {
            try refs.append(gpa, arg);
        }
    }
    if (refs.items.len == 0) return error.MissingArgument;

    var root = try store.openRoot(io, home);
    defer root.close(io);

    for (refs.items) |text| {
        var file = try openTarget(gpa, io, root, text);
        defer file.close(io);

        // Rendering feeds the same window as raw bytes, so line counts always
        // describe what the caller sees rather than terminal control traffic.
        var sink = WindowSink.init(gpa, window, out);
        defer sink.deinit();
        if (as_written) {
            try copyFile(io, file, &sink);
        } else {
            try renderFile(gpa, io, file, &sink);
        }
        try sink.finish();

        // Silence about what was left out would let a reader - a person or an
        // agent - take a fragment for the whole thing. It goes to stderr so
        // that stdout stays exactly what was asked for.
        if (sink.shownLines() < sink.totalLines()) {
            note("tj: {s}: showing {d} of {d} lines\n", .{
                text,
                sink.shownLines(),
                sink.totalLines(),
            });
        }
    }
}

fn copyFile(io: Io, file: Io.File, out: anytype) !void {
    var reader_buffer: [read_chunk_size]u8 = undefined;
    var bytes: [read_chunk_size]u8 = undefined;
    var reader = file.readerStreaming(io, &reader_buffer);
    while (true) {
        const n = try reader.interface.readSliceShort(&bytes);
        if (n == 0) break;
        try out.writeAll(bytes[0..n]);
    }
}

fn renderFile(gpa: std.mem.Allocator, io: Io, file: Io.File, out: anytype) !void {
    var renderer = plain.Renderer.init(gpa);
    defer renderer.deinit();
    var reader_buffer: [read_chunk_size]u8 = undefined;
    var bytes: [read_chunk_size]u8 = undefined;
    var reader = file.readerStreaming(io, &reader_buffer);
    while (true) {
        const n = try reader.interface.readSliceShort(&bytes);
        if (n == 0) break;
        try renderer.feed(bytes[0..n], out);
    }
    try renderer.finish(out);
}

/// How much of a resource to print.
const Window = union(enum) {
    all,
    head: usize,
    tail: usize,
};

/// Applies a line window without retaining bytes that cannot be returned.
/// Tail storage is proportional to the requested final lines, not the file.
const WindowSink = struct {
    gpa: std.mem.Allocator,
    window: Window,
    out: *Io.Writer,
    tail: std.ArrayList(u8) = .empty,
    tail_lines: usize = 0,
    head_newlines: usize = 0,
    total_newlines: u64 = 0,
    total_any: bool = false,
    total_ends_newline: bool = false,

    fn init(gpa: std.mem.Allocator, window: Window, out: *Io.Writer) WindowSink {
        return .{ .gpa = gpa, .window = window, .out = out };
    }

    fn deinit(self: *WindowSink) void {
        self.tail.deinit(self.gpa);
    }

    pub fn writeAll(self: *WindowSink, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        self.total_any = true;
        self.total_ends_newline = bytes[bytes.len - 1] == '\n';
        self.total_newlines = std.math.add(
            u64,
            self.total_newlines,
            @as(u64, @intCast(std.mem.count(u8, bytes, "\n"))),
        ) catch return error.ResourceTooLarge;

        switch (self.window) {
            .all => try self.out.writeAll(bytes),
            .head => |n| try self.writeHead(n, bytes),
            .tail => |n| try self.writeTail(n, bytes),
        }
    }

    fn writeHead(self: *WindowSink, n: usize, bytes: []const u8) !void {
        if (n == 0 or self.head_newlines >= n) return;

        var end = bytes.len;
        var offset: usize = 0;
        while (std.mem.indexOfScalar(u8, bytes[offset..], '\n')) |relative| {
            const newline = offset + relative;
            self.head_newlines += 1;
            if (self.head_newlines == n) {
                end = newline + 1;
                break;
            }
            offset = newline + 1;
        }
        try self.out.writeAll(bytes[0..end]);
    }

    fn writeTail(self: *WindowSink, n: usize, bytes: []const u8) !void {
        if (n == 0) return;
        for (bytes) |byte| {
            if (self.tail.items.len == 0) {
                self.tail_lines = 1;
            } else if (self.tail.items[self.tail.items.len - 1] == '\n') {
                if (self.tail_lines == n) self.dropFirstTailLine();
                self.tail_lines += 1;
            }
            try self.tail.append(self.gpa, byte);
        }
    }

    fn dropFirstTailLine(self: *WindowSink) void {
        const cut = (std.mem.indexOfScalar(u8, self.tail.items, '\n') orelse unreachable) + 1;
        const remaining = self.tail.items.len - cut;
        std.mem.copyForwards(u8, self.tail.items[0..remaining], self.tail.items[cut..]);
        self.tail.items.len = remaining;
        self.tail_lines -= 1;
    }

    fn finish(self: *WindowSink) !void {
        if (self.window == .tail) try self.out.writeAll(self.tail.items);
    }

    fn totalLines(self: *const WindowSink) u64 {
        return self.total_newlines + @intFromBool(self.total_any and !self.total_ends_newline);
    }

    fn shownLines(self: *const WindowSink) u64 {
        return switch (self.window) {
            .all => self.totalLines(),
            .head => |n| @min(self.totalLines(), @as(u64, @intCast(n))),
            .tail => |n| @min(self.totalLines(), @as(u64, @intCast(n))),
        };
    }
};

fn takeCount(args: []const []const u8, i: *usize, comptime name: []const u8) !?usize {
    const arg = args[i.*];
    var text: []const u8 = undefined;

    if (std.mem.eql(u8, arg, name)) {
        if (i.* + 1 >= args.len) return error.MissingFlagValue;
        i.* += 1;
        text = args[i.*];
    } else if (std.mem.startsWith(u8, arg, name ++ "=")) {
        text = arg[name.len + 1 ..];
    } else return null;

    return std.fmt.parseInt(usize, text, 10) catch error.BadCount;
}

fn note(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
    sys.writeAll(2, text) catch {};
}

fn applyWindow(gpa: std.mem.Allocator, window: Window, text: []const u8, chunk_size: usize) !struct {
    bytes: []u8,
    shown_lines: u64,
    total_lines: u64,
} {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(gpa);
    var writer = Io.Writer.Allocating.fromArrayList(gpa, &result);
    defer result = writer.toArrayList();
    var sink = WindowSink.init(gpa, window, &writer.writer);
    defer sink.deinit();

    var offset: usize = 0;
    while (offset < text.len) {
        const end = @min(offset + chunk_size, text.len);
        try sink.writeAll(text[offset..end]);
        offset = end;
    }
    try sink.finish();
    return .{
        .bytes = try writer.toOwnedSlice(),
        .shown_lines = sink.shownLines(),
        .total_lines = sink.totalLines(),
    };
}

test "streaming windows keep whole lines across chunk boundaries" {
    const gpa = std.testing.allocator;
    const cases = [_]struct {
        window: Window,
        input: []const u8,
        expected: []const u8,
        shown: u64,
        total: u64,
    }{
        .{ .window = .all, .input = "one\ntwo\nthree\n", .expected = "one\ntwo\nthree\n", .shown = 3, .total = 3 },
        .{ .window = .{ .head = 2 }, .input = "one\ntwo\nthree\n", .expected = "one\ntwo\n", .shown = 2, .total = 3 },
        .{ .window = .{ .tail = 2 }, .input = "one\ntwo\nthree\n", .expected = "two\nthree\n", .shown = 2, .total = 3 },
        .{ .window = .{ .head = 0 }, .input = "one\ntwo", .expected = "", .shown = 0, .total = 2 },
        .{ .window = .{ .tail = 0 }, .input = "one\ntwo", .expected = "", .shown = 0, .total = 2 },
        .{ .window = .{ .head = 1 }, .input = "one\ntwo", .expected = "one\n", .shown = 1, .total = 2 },
        .{ .window = .{ .tail = 1 }, .input = "one\ntwo", .expected = "two", .shown = 1, .total = 2 },
        .{ .window = .{ .tail = 2 }, .input = "one\ntwo", .expected = "one\ntwo", .shown = 2, .total = 2 },
        .{ .window = .{ .tail = 2 }, .input = "", .expected = "", .shown = 0, .total = 0 },
    };

    for (cases) |case| {
        for ([_]usize{ 1, 2, 3, 64 }) |chunk_size| {
            const result = try applyWindow(gpa, case.window, case.input, chunk_size);
            defer gpa.free(result.bytes);
            try std.testing.expectEqualStrings(case.expected, result.bytes);
            try std.testing.expectEqual(case.shown, result.shown_lines);
            try std.testing.expectEqual(case.total, result.total_lines);
        }
    }
}

/// Accepts a reference or a path to the same thing.
///
/// Inside a journal writer, shorthand `@42/out` becomes canonical
/// `~[@42]/out`, which zsh expands to a path before tj executes. Insisting on a
/// reference would therefore make `tj cat @42` work everywhere except the
/// place it is most likely to be typed. Outside a writer there is no named
/// directory expansion and the reference is resolved here instead. Either way
/// it ends at the same open file.
fn openTarget(gpa: std.mem.Allocator, io: Io, root: store.Dir, text: []const u8) !Io.File {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var path: []const u8 = text;
    var owned: ?[]const u8 = null;
    defer if (owned) |value| gpa.free(value);

    if (reference.parse(text)) |parsed| {
        const found = try store.locate(gpa, io, root, sys.env("TJ_JOURNAL"), parsed);
        defer found.deinit(gpa);
        if (!found.exists) return error.NoSuchInteraction;
        owned = try gpa.dupe(u8, found.path);
        path = owned.?;
    } else |err| switch (err) {
        // Shaped like a reference but wrong: worth saying so rather than
        // trying it as a filename.
        error.Malformed => return error.BadReference,
        error.NotAReference => {},
    }

    // Naming the interaction rather than a resource means its output, whether
    // that came from `@42` or from the path `~[@42]` expanded to.
    if (isDirectory(io, path)) {
        path = std.fmt.bufPrint(&path_buf, "{s}/out", .{path}) catch return error.BadReference;
    }

    return store.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => error.NoSuchResource,
        else => |other| other,
    };
}

fn isDirectory(io: Io, path: []const u8) bool {
    var dir = store.Dir.cwd().openDir(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

// --- replaying a journal -----------------------------------------------------

/// How a recording is played back. The recorded timings give the rhythm; the
/// defaults keep it watchable, since a real journal has gaps where somebody
/// was reading something for a minute.
const Replay = struct {
    /// Divides every delay. 2 means twice as fast.
    speed: f64 = 1.0,
    /// Per character of the command line. 0 shows it at once.
    typing_ms: u64 = 35,
    /// No single pause runs longer than this, however long the real one was.
    max_pause_ms: u64 = 2000,
    prompt: []const u8 = "$ ",
    from: u32 = 1,
    to: u32 = std.math.maxInt(u32),
    /// Report how long the replay would take instead of playing it, so a
    /// generated vhs tape can wait exactly that long and no longer.
    duration_only: bool = false,

    /// A recorded gap, capped and scaled into something watchable.
    fn delay(self: Replay, millis: i64) !u64 {
        if (millis <= 0) return 0;
        const capped = @min(@as(u64, @intCast(millis)), self.max_pause_ms);
        return scaleMillis(capped, self.speed);
    }

    /// Sleeps unless only the total was asked for. Returns what it cost
    /// either way, so the two paths cannot drift apart.
    fn wait(self: Replay, millis: i64) !u64 {
        const ms = try self.delay(millis);
        if (!self.duration_only) sys.sleepMs(ms);
        return ms;
    }
};

fn scaleMillis(value: u64, speed: f64) !u64 {
    if (!std.math.isFinite(speed) or speed <= 0) return error.BadReplayOption;
    const scaled = @as(f64, @floatFromInt(value)) / speed;
    // maxInt(u64) rounds to 2^64 as an f64, so equality is already outside
    // the integer range accepted by @intFromFloat.
    if (!std.math.isFinite(scaled) or scaled < 0 or scaled >= @as(f64, @floatFromInt(std.math.maxInt(u64)))) {
        return error.BadReplayOption;
    }
    return @intFromFloat(scaled);
}

fn addDuration(total: *u64, value: u64) !void {
    total.* = std.math.add(u64, total.*, value) catch return error.BadReplayOption;
}

fn typingDuration(per_char: u64, command_len: u64) !u64 {
    return std.math.mul(u64, per_char, command_len) catch return error.BadReplayOption;
}

const ReplayRequest = struct {
    replay: Replay,
    wanted: ?[]const u8,
};

fn parseReplayArgs(args: []const []const u8) !ReplayRequest {
    var request: ReplayRequest = .{ .replay = .{}, .wanted = null };

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (try takeReplayMillis(args, &i, "--typing")) |n| {
            request.replay.typing_ms = n;
        } else if (try takeReplayMillis(args, &i, "--max-pause")) |n| {
            request.replay.max_pause_ms = n;
        } else if (try takeReplayNumber(args, &i, "--from")) |n| {
            request.replay.from = n;
        } else if (try takeReplayNumber(args, &i, "--to")) |n| {
            request.replay.to = n;
        } else if (try takeText(args, &i, "--prompt")) |text| {
            request.replay.prompt = text;
        } else if (try takeReplaySpeed(args, &i)) |speed| {
            request.replay.speed = speed;
        } else if (std.mem.eql(u8, arg, "--duration")) {
            request.replay.duration_only = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownFlag;
        } else {
            if (request.wanted != null) return error.BadReplayOption;
            request.wanted = arg;
        }
    }

    return request;
}

/// `tj replay <journal>` - play a recording back into the terminal.
///
/// Nothing is re-executed: this is the output that was captured, escape
/// sequences and all, so it looks the way it looked. What cannot be
/// reconstructed is when each byte arrived, since only the start and end of
/// each interaction were recorded - so output appears at once, and the pacing
/// comes from the real durations and the real gaps between commands.
fn replayJournal(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    args: []const []const u8,
    out: *Io.Writer,
) !void {
    const request = try parseReplayArgs(args);
    const replay = request.replay;
    const wanted = request.wanted;

    // Replaying inside a live journal writer would feed the recording back
    // into the journal: the replayed shell-integration markers read as real command
    // boundaries, which truncates the recording of the replay itself and
    // pins the replayed exit status onto it. Asking for the duration prints
    // no recording, so it stays allowed - `tj-tape` needs it.
    if (!replay.duration_only and sys.env("TJ_JOURNAL") != null) return error.InsideJournal;

    var root = try store.openRoot(io, home);
    defer root.close(io);

    // A suffix works here as it does anywhere else a journal is named. With
    // no journal named, the most recent one: there is no current journal to
    // fall back on, since replay only runs outside one.
    var owned: ?[]u8 = null;
    defer if (owned) |name| gpa.free(name);

    const journal: []const u8 = if (wanted) |name| blk: {
        owned = try store.findNewestJournal(gpa, io, root, name) orelse return error.NoSuchJournal;
        break :blk owned.?;
    } else blk: {
        const journals = try store.listJournals(gpa, io, root);
        defer {
            for (journals) |name| gpa.free(name);
            gpa.free(journals);
        }
        if (journals.len == 0) return error.NothingRecorded;
        owned = try gpa.dupe(u8, journals[0]);
        break :blk owned.?;
    };

    const numbers = store.listNumbers(gpa, io, root, journal) catch return error.NoSuchJournal;
    defer gpa.free(numbers);

    var previous_end: ?i64 = null;
    var total_ms: u64 = 0;

    for (numbers) |number| {
        if (number < replay.from or number > replay.to) continue;

        const timing = store.readTiming(gpa, io, root, journal, number);

        // The gap since the last command finished is the time somebody spent
        // reading it and typing the next one.
        if (previous_end) |ended| {
            if (timing) |t| try addDuration(&total_ms, try replay.wait(t.started - ended));
        }

        if (!replay.duration_only) try out.writeAll(replay.prompt);
        try addDuration(&total_ms, try typeOut(io, root, journal, number, replay, out));

        // Then the command runs, which took as long as it took.
        if (timing) |t| try addDuration(&total_ms, try replay.wait(t.duration()));

        if (!replay.duration_only) {
            try writeResource(io, root, journal, number, "out", out);
            try out.flush();
        }

        previous_end = if (timing) |t| t.ended else null;
    }

    // Rounded up, so a tape that waits this long never cuts the end off.
    if (replay.duration_only) try out.print("{d}\n", .{(try std.math.add(u64, total_ms, 999)) / 1000});
}

/// Types the command line out a character at a time, the way it was typed.
fn typeOut(
    io: Io,
    root: store.Dir,
    journal: []const u8,
    number: u32,
    replay: Replay,
    out: *Io.Writer,
) !u64 {
    var path_buf: [64]u8 = undefined;
    const sub = try std.fmt.bufPrint(&path_buf, "{s}/{d}/cmd", .{ journal, number });
    const per_char: u64 = if (replay.typing_ms == 0) 0 else try scaleMillis(replay.typing_ms, replay.speed);
    var file = root.openFile(io, sub, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            if (!replay.duration_only) {
                try out.writeAll("\r\n");
                try out.flush();
            }
            return 0;
        },
        else => |other| return other,
    };
    defer file.close(io);

    const total = try typingDuration(per_char, (try file.stat(io)).size);
    if (replay.duration_only) return total;

    if (per_char == 0) {
        try copyFile(io, file, out);
    } else {
        var reader_buffer: [read_chunk_size]u8 = undefined;
        var bytes: [read_chunk_size]u8 = undefined;
        var reader = file.readerStreaming(io, &reader_buffer);
        while (true) {
            const n = try reader.interface.readSliceShort(&bytes);
            if (n == 0) break;
            for (bytes[0..n]) |char| {
                try out.writeAll(&[_]u8{char});
                try out.flush();
                sys.sleepMs(per_char);
            }
        }
    }
    try out.writeAll("\r\n");
    try out.flush();
    return total;
}

fn takeReplayNumber(args: []const []const u8, i: *usize, comptime name: []const u8) !?u32 {
    const text = takeText(args, i, name) catch |err| switch (err) {
        error.MissingFlagValue => return error.BadReplayOption,
    } orelse return null;
    const number = std.fmt.parseInt(u32, text, 10) catch return error.BadReplayOption;
    if (number == 0) return error.BadReplayOption;
    return number;
}

fn takeReplayMillis(args: []const []const u8, i: *usize, comptime name: []const u8) !?u64 {
    const text = takeText(args, i, name) catch |err| switch (err) {
        error.MissingFlagValue => return error.BadReplayOption,
    } orelse return null;
    return std.fmt.parseInt(u64, text, 10) catch error.BadReplayOption;
}

fn takeReplaySpeed(args: []const []const u8, i: *usize) !?f64 {
    const text = takeText(args, i, "--speed") catch |err| switch (err) {
        error.MissingFlagValue => return error.BadReplayOption,
    } orelse return null;
    const speed = std.fmt.parseFloat(f64, text) catch return error.BadReplayOption;
    if (!std.math.isFinite(speed) or speed <= 0) return error.BadReplayOption;
    return speed;
}

test "replay interaction ranges parse directly into u32" {
    const minimum = try parseReplayArgs(&.{ "--from", "1", "--to=4294967295" });
    try std.testing.expectEqual(@as(u32, 1), minimum.replay.from);
    try std.testing.expectEqual(std.math.maxInt(u32), minimum.replay.to);

    try std.testing.expectError(error.BadReplayOption, parseReplayArgs(&.{ "--from", "0" }));
    try std.testing.expectError(error.BadReplayOption, parseReplayArgs(&.{"--to=4294967296"}));
}

test "replay accepts only finite positive speeds" {
    for ([_][]const u8{ "0.5", "1", "2" }) |text| {
        const parsed = try parseReplayArgs(&.{ "--speed", text });
        try std.testing.expect(parsed.replay.speed > 0);
        try std.testing.expect(std.math.isFinite(parsed.replay.speed));
    }

    for ([_][]const u8{ "nan", "inf", "-inf", "0", "-1" }) |text| {
        try std.testing.expectError(error.BadReplayOption, parseReplayArgs(&.{ "--speed", text }));
    }
}

test "replay millisecond options use their final u64 type" {
    const parsed = try parseReplayArgs(&.{ "--typing=18446744073709551615", "--max-pause", "0" });
    try std.testing.expectEqual(std.math.maxInt(u64), parsed.replay.typing_ms);
    try std.testing.expectEqual(@as(u64, 0), parsed.replay.max_pause_ms);
    try std.testing.expectError(
        error.BadReplayOption,
        parseReplayArgs(&.{ "--typing", "18446744073709551616" }),
    );
}

test "replay rejects more than one journal name" {
    try std.testing.expectError(error.BadReplayOption, parseReplayArgs(&.{ "first", "second" }));
}

test "replay timing arithmetic rejects unrepresentable durations" {
    try std.testing.expectError(error.BadReplayOption, scaleMillis(std.math.maxInt(u64), 1));
    try std.testing.expectError(error.BadReplayOption, scaleMillis(1, 0));
    try std.testing.expectError(error.BadReplayOption, typingDuration(std.math.maxInt(u64), 2));

    var total: u64 = std.math.maxInt(u64);
    try std.testing.expectError(error.BadReplayOption, addDuration(&total, 1));
}

/// Writes a recorded resource through verbatim. `out` is what the terminal
/// saw, so replaying it raw is what makes the colours come back.
fn writeResource(
    io: Io,
    root: store.Dir,
    journal: []const u8,
    number: u32,
    name: []const u8,
    out: *Io.Writer,
) !void {
    var path_buf: [64]u8 = undefined;
    const sub = try std.fmt.bufPrint(&path_buf, "{s}/{d}/{s}", .{ journal, number, name });
    var file = root.openFile(io, sub, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => |other| return other,
    };
    defer file.close(io);
    try copyFile(io, file, out);
}

fn takeText(args: []const []const u8, i: *usize, comptime name: []const u8) !?[]const u8 {
    const arg = args[i.*];
    if (std.mem.eql(u8, arg, name)) {
        if (i.* + 1 >= args.len) return error.MissingFlagValue;
        i.* += 1;
        return args[i.*];
    }
    if (std.mem.startsWith(u8, arg, name ++ "=")) return arg[name.len + 1 ..];
    return null;
}

test "a recorded gap is capped so a demo stays watchable" {
    const replay: Replay = .{ .max_pause_ms = 2000, .speed = 1.0 };
    try std.testing.expectEqual(@as(u64, 0), try replay.delay(0));
    try std.testing.expectEqual(@as(u64, 0), try replay.delay(-5));
    try std.testing.expectEqual(@as(u64, 500), try replay.delay(500));
    // A minute of somebody reading the screen becomes two seconds.
    try std.testing.expectEqual(@as(u64, 2000), try replay.delay(60_000));
}

test "speed divides every delay" {
    const fast: Replay = .{ .max_pause_ms = 4000, .speed = 4.0 };
    try std.testing.expectEqual(@as(u64, 250), try fast.delay(1000));
    const slow: Replay = .{ .max_pause_ms = 4000, .speed = 0.5 };
    try std.testing.expectEqual(@as(u64, 2000), try slow.delay(1000));
}
