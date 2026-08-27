//! The subcommands that read the journal.

const std = @import("std");
const Io = std.Io;

const cli = @import("cli.zig");
const store = @import("store.zig");
const sys = @import("sys.zig");
const reference = @import("reference.zig");
const plain = @import("plain.zig");

/// The parsed subcommand, exactly as `cli` produced it.
const Subcommand = @FieldType(cli.Command, "subcommand");

pub const Error = error{
    NotInSession,
    NoSuchSession,
    NothingRecorded,
    MissingArgument,
    BadReference,
    NoSuchInteraction,
    NoSuchResource,
    BadCount,
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
        .hist => try listInteractions(gpa, io, sub.home, sub.args, out),
        // Handled as the proxy, never as a journal query.
        .run => unreachable,
        .last => try printLast(gpa, io, sub.home, out),
        .resolve => try resolveReference(gpa, io, sub.home, sub.args, out),
        .complete => try completeReference(gpa, io, sub.home, sub.args, out),
        .cat => try catResource(gpa, io, sub.home, sub.args, out),
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
        var size_buf: [8]u8 = undefined;
        try out.print("{d: >5}  {s: <3}  {s: >5}  {s}\n", .{
            info.number,
            status,
            humanSize(info.out_bytes, &size_buf),
            firstLine(info.command),
        });
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

// --- reading resources ------------------------------------------------------

/// `out` files can be large; this is the point at which tj gives up rather
/// than trying to hold one in memory.
const max_resource = 64 * 1024 * 1024;

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
        const bytes = try readTarget(gpa, io, root, text);
        defer gpa.free(bytes);

        // Rendering first means a line count is a count of lines the caller
        // will actually see, not of lines in the recording.
        var rendered: std.ArrayList(u8) = .empty;
        defer rendered.deinit(gpa);
        if (as_written) {
            try rendered.appendSlice(gpa, bytes);
        } else {
            var writer = Io.Writer.Allocating.fromArrayList(gpa, &rendered);
            defer rendered = writer.toArrayList();
            try plain.render(gpa, bytes, &writer.writer);
        }

        const shown = window.apply(rendered.items);
        try out.writeAll(shown);

        // Silence about what was left out would let a reader - a person or an
        // agent - take a fragment for the whole thing. It goes to stderr so
        // that stdout stays exactly what was asked for.
        if (shown.len < rendered.items.len) {
            note("tj: {s}: showing {d} of {d} lines\n", .{
                text,
                countLines(shown),
                countLines(rendered.items),
            });
        }
    }
}

/// How much of a resource to print.
const Window = union(enum) {
    all,
    head: usize,
    tail: usize,

    fn apply(self: Window, text: []const u8) []const u8 {
        return switch (self) {
            .all => text,
            .head => |n| text[0..lineBoundary(text, n, .from_start)],
            .tail => |n| text[lineBoundary(text, n, .from_end)..],
        };
    }
};

const Direction = enum { from_start, from_end };

/// The offset that keeps `n` lines from one end of `text`.
fn lineBoundary(text: []const u8, n: usize, direction: Direction) usize {
    if (n == 0) return switch (direction) {
        .from_start => 0,
        .from_end => text.len,
    };

    var seen: usize = 0;
    switch (direction) {
        .from_start => {
            var i: usize = 0;
            while (i < text.len) : (i += 1) {
                if (text[i] != '\n') continue;
                seen += 1;
                if (seen == n) return i + 1;
            }
            return text.len;
        },
        .from_end => {
            // A trailing newline ends the last line rather than starting one.
            var i: usize = text.len;
            if (i > 0 and text[i - 1] == '\n') i -= 1;
            while (i > 0) : (i -= 1) {
                if (text[i - 1] != '\n') continue;
                seen += 1;
                if (seen == n) return i;
            }
            return 0;
        },
    }
}

fn countLines(text: []const u8) usize {
    if (text.len == 0) return 0;
    var count = std.mem.count(u8, text, "\n");
    if (text[text.len - 1] != '\n') count += 1;
    return count;
}

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

test "a head window keeps whole lines from the front" {
    const text = "one\ntwo\nthree\n";
    try std.testing.expectEqualStrings("one\ntwo\n", (Window{ .head = 2 }).apply(text));
    try std.testing.expectEqualStrings("one\n", (Window{ .head = 1 }).apply(text));
    try std.testing.expectEqualStrings(text, (Window{ .head = 9 }).apply(text));
    try std.testing.expectEqualStrings("", (Window{ .head = 0 }).apply(text));
}

test "a tail window keeps whole lines from the end" {
    const text = "one\ntwo\nthree\n";
    try std.testing.expectEqualStrings("three\n", (Window{ .tail = 1 }).apply(text));
    try std.testing.expectEqualStrings("two\nthree\n", (Window{ .tail = 2 }).apply(text));
    try std.testing.expectEqualStrings(text, (Window{ .tail = 9 }).apply(text));
}

test "windows cope with no trailing newline" {
    const text = "one\ntwo";
    try std.testing.expectEqualStrings("one\n", (Window{ .head = 1 }).apply(text));
    try std.testing.expectEqualStrings("two", (Window{ .tail = 1 }).apply(text));
    try std.testing.expectEqualStrings(text, (Window{ .tail = 2 }).apply(text));
}

test "counting lines matches what a window kept" {
    try std.testing.expectEqual(@as(usize, 0), countLines(""));
    try std.testing.expectEqual(@as(usize, 1), countLines("one"));
    try std.testing.expectEqual(@as(usize, 1), countLines("one\n"));
    try std.testing.expectEqual(@as(usize, 2), countLines("one\ntwo"));
    try std.testing.expectEqual(@as(usize, 3), countLines("one\ntwo\nthree\n"));
}

/// Accepts a reference or a path to the same thing.
///
/// Inside a session the shell integration has already rewritten `@42/out`
/// into a path by the time tj is executed, so insisting on a reference would
/// make `tj cat @42` work everywhere except the place it is most likely to be
/// typed. Outside a session there is nothing to rewrite and the reference is
/// resolved here instead. Either way it ends at the same file.
fn readTarget(gpa: std.mem.Allocator, io: Io, root: store.Dir, text: []const u8) ![]u8 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var path: []const u8 = text;
    var owned: ?[]const u8 = null;
    defer if (owned) |value| gpa.free(value);

    if (reference.parse(text)) |parsed| {
        const found = try store.locate(gpa, io, root, sys.env("TJ_SESSION"), parsed);
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
    // that came from `@42` or from the path `@42` expanded to.
    if (isDirectory(io, path)) {
        path = std.fmt.bufPrint(&path_buf, "{s}/out", .{path}) catch return error.BadReference;
    }

    return store.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_resource)) catch
        error.NoSuchResource;
}

fn isDirectory(io: Io, path: []const u8) bool {
    var dir = store.Dir.cwd().openDir(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}
