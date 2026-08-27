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
    BadReplayOption,
    InsideSession,
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
        .replay => try replaySession(gpa, io, sub.home, sub.args, out),
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
        if (as_written and window == .all) {
            var file = try openTarget(gpa, io, root, text);
            defer file.close(io);
            try copyFile(io, file, out);
            continue;
        }
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

fn copyFile(io: Io, file: Io.File, out: *Io.Writer) !void {
    var buffer: [64 * 1024]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    while (true) {
        const n = try reader.interface.readSliceShort(&buffer);
        if (n == 0) break;
        try out.writeAll(buffer[0..n]);
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
    var file = try openTarget(gpa, io, root, text);
    defer file.close(io);
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(gpa);
    var writer = Io.Writer.Allocating.fromArrayList(gpa, &bytes);
    defer bytes = writer.toArrayList();
    try copyFile(io, file, &writer.writer);
    return writer.toOwnedSlice();
}

fn openTarget(gpa: std.mem.Allocator, io: Io, root: store.Dir, text: []const u8) !Io.File {
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

    return store.Dir.cwd().openFile(io, path, .{}) catch error.NoSuchResource;
}

fn isDirectory(io: Io, path: []const u8) bool {
    var dir = store.Dir.cwd().openDir(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

// --- replaying a session -----------------------------------------------------

/// How a recording is played back. The recorded timings give the rhythm; the
/// defaults keep it watchable, since a real session has gaps where somebody
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
    const scaled = @as(f64, @floatFromInt(value)) / speed;
    if (!std.math.isFinite(scaled) or scaled < 0 or scaled > @as(f64, @floatFromInt(std.math.maxInt(u64)))) {
        return error.BadReplayOption;
    }
    return @intFromFloat(scaled);
}

fn addDuration(total: *u64, value: u64) !void {
    total.* = std.math.add(u64, total.*, value) catch return error.BadReplayOption;
}

/// `tj replay <session>` - play a recording back into the terminal.
///
/// Nothing is re-executed: this is the output that was captured, escape
/// sequences and all, so it looks the way it looked. What cannot be
/// reconstructed is when each byte arrived, since only the start and end of
/// each interaction were recorded - so output appears at once, and the pacing
/// comes from the real durations and the real gaps between commands.
fn replaySession(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    args: []const []const u8,
    out: *Io.Writer,
) !void {
    var replay: Replay = .{};
    var wanted: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (try takeCount(args, &i, "--typing")) |n| {
            replay.typing_ms = n;
        } else if (try takeCount(args, &i, "--max-pause")) |n| {
            replay.max_pause_ms = n;
        } else if (try takeReplayNumber(args, &i, "--from")) |n| {
            replay.from = n;
        } else if (try takeReplayNumber(args, &i, "--to")) |n| {
            replay.to = n;
        } else if (try takeText(args, &i, "--prompt")) |text| {
            replay.prompt = text;
        } else if (try takeText(args, &i, "--speed")) |text| {
            replay.speed = std.fmt.parseFloat(f64, text) catch return error.BadReplayOption;
            if (!std.math.isFinite(replay.speed) or replay.speed <= 0) return error.BadReplayOption;
        } else if (std.mem.eql(u8, arg, "--duration")) {
            replay.duration_only = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownFlag;
        } else {
            if (wanted != null) return error.BadReplayOption;
            wanted = arg;
        }
    }

    // Replaying into a live session would feed the recording back into the
    // journal: the replayed shell-integration markers read as real command
    // boundaries, which truncates the recording of the replay itself and
    // pins the replayed exit status onto it. Asking for the duration prints
    // no recording, so it stays allowed - `tj-tape` needs it.
    if (!replay.duration_only and sys.env("TJ_SESSION") != null) return error.InsideSession;

    var root = try store.openRoot(io, home);
    defer root.close(io);

    // A suffix works here as it does anywhere else a session is named. With
    // no session named, the most recent one: there is no current session to
    // fall back on, since replay only runs outside one.
    var owned: ?[]u8 = null;
    defer if (owned) |name| gpa.free(name);

    const session: []const u8 = if (wanted) |name| blk: {
        owned = try store.findSession(gpa, io, root, name) orelse return error.NoSuchSession;
        break :blk owned.?;
    } else blk: {
        const sessions = try store.listSessions(gpa, io, root);
        defer {
            for (sessions) |name| gpa.free(name);
            gpa.free(sessions);
        }
        if (sessions.len == 0) return error.NothingRecorded;
        owned = try gpa.dupe(u8, sessions[0]);
        break :blk owned.?;
    };

    const numbers = store.listNumbers(gpa, io, root, session) catch return error.NoSuchSession;
    defer gpa.free(numbers);

    var previous_end: ?i64 = null;
    var total_ms: u64 = 0;

    for (numbers) |number| {
        if (number < replay.from or number > replay.to) continue;

        const timing = store.readTiming(gpa, io, root, session, number);

        // The gap since the last command finished is the time somebody spent
        // reading it and typing the next one.
        if (previous_end) |ended| {
            if (timing) |t| try addDuration(&total_ms, try replay.wait(t.started - ended));
        }

        if (!replay.duration_only) try out.writeAll(replay.prompt);
        try addDuration(&total_ms, try typeOut(gpa, io, root, session, number, replay, out));

        // Then the command runs, which took as long as it took.
        if (timing) |t| try addDuration(&total_ms, try replay.wait(t.duration()));

        if (!replay.duration_only) {
            try writeResource(io, root, session, number, "out", out);
            try out.flush();
        }

        previous_end = if (timing) |t| t.ended else null;
    }

    // Rounded up, so a tape that waits this long never cuts the end off.
    if (replay.duration_only) try out.print("{d}\n", .{(try std.math.add(u64, total_ms, 999)) / 1000});
}

/// Types the command line out a character at a time, the way it was typed.
fn typeOut(
    gpa: std.mem.Allocator,
    io: Io,
    root: store.Dir,
    session: []const u8,
    number: u32,
    replay: Replay,
    out: *Io.Writer,
) !u64 {
    var path_buf: [64]u8 = undefined;
    const sub = try std.fmt.bufPrint(&path_buf, "{s}/{d}/cmd", .{ session, number });
    const cmd = root.readFileAlloc(io, sub, gpa, .limited(max_resource)) catch "";
    defer if (cmd.len > 0) gpa.free(cmd);

    const per_char: u64 = if (replay.typing_ms == 0) 0 else try scaleMillis(replay.typing_ms, replay.speed);

    const total = std.math.mul(u64, per_char, @as(u64, @intCast(cmd.len))) catch return error.BadReplayOption;
    if (replay.duration_only) return total;

    if (per_char == 0) {
        try out.writeAll(cmd);
    } else {
        for (cmd) |char| {
            try out.writeAll(&[_]u8{char});
            try out.flush();
            sys.sleepMs(per_char);
        }
    }
    try out.writeAll("\r\n");
    try out.flush();
    return total;
}

fn takeReplayNumber(args: []const []const u8, i: *usize, comptime name: []const u8) !?u32 {
    const text = try takeText(args, i, name) orelse return null;
    const number = std.fmt.parseInt(u32, text, 10) catch return error.BadReplayOption;
    if (number == 0) return error.BadReplayOption;
    return number;
}

/// Writes a recorded resource through verbatim. `out` is what the terminal
/// saw, so replaying it raw is what makes the colours come back.
fn writeResource(
    io: Io,
    root: store.Dir,
    session: []const u8,
    number: u32,
    name: []const u8,
    out: *Io.Writer,
) !void {
    var path_buf: [64]u8 = undefined;
    const sub = try std.fmt.bufPrint(&path_buf, "{s}/{d}/{s}", .{ session, number, name });
    var file = root.openFile(io, sub, .{}) catch return;
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
