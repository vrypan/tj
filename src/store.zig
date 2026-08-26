//! The on-disk journal.
//!
//!     $TJ_HOME/                 default ~/.tj
//!     └── <session-ulid>/
//!         ├── log               warnings from this session, if any
//!         └── 1/
//!             ├── cmd           the command line as entered
//!             ├── out           what the terminal saw
//!             ├── rc            exit status, absent while incomplete
//!             └── meta.json
//!
//! Plain files, so `cat`, `diff`, shell completion and agents all work with no
//! knowledge of tj.
//!
//! Recording must never get in the way of the terminal. Every entry point here
//! swallows its errors: the first failure disables recording for the rest of
//! the session and is noted in the session log, and the proxy keeps forwarding
//! bytes as if nothing happened.

const std = @import("std");
const Io = std.Io;
pub const Dir = std.Io.Dir;
const File = std.Io.File;

const sys = @import("sys.zig");
const ulid = @import("ulid.zig");

/// The journal holds whatever appears on the terminal, which includes secrets.
/// It gets the same treatment as shell history.
const dir_permissions: File.Permissions = @enumFromInt(0o700);
const file_permissions: File.Permissions = @enumFromInt(0o600);

const out_buffer_size = 64 * 1024;

pub const Store = struct {
    io: Io,
    gpa: std.mem.Allocator,
    root: Dir,
    session_dir: Dir,
    session: ulid.Ulid,
    next_number: u32 = 1,
    current: ?Interaction = null,
    out_buffer: []u8,
    /// Set after the first write failure; recording stops, forwarding does not.
    disabled: bool = false,

    const Interaction = struct {
        number: u32,
        dir: Dir,
        file: File,
        writer: File.Writer,
        started_ms: i64,
        exit_code: ?u8 = null,
        /// Present only when the shell integration rewrote the line.
        expanded: ?[]u8 = null,
    };

    /// Creates a new session. `home_override` wins over `$TJ_HOME`, which wins
    /// over `~/.tj`.
    pub fn create(gpa: std.mem.Allocator, io: Io, home_override: ?[]const u8) !Store {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const root_path = try resolveRoot(home_override, &path_buf);

        const root = try openOrCreateRoot(io, root_path);
        errdefer root.close(io);

        const out_buffer = try gpa.alloc(u8, out_buffer_size);
        errdefer gpa.free(out_buffer);

        // ULIDs carry 80 random bits, so a clash means something is badly
        // wrong with the entropy source; retrying is still the cheap fix.
        var attempts: usize = 0;
        while (attempts < 8) : (attempts += 1) {
            const id = ulid.generate(io);
            root.createDir(io, &id, dir_permissions) catch |err| switch (err) {
                error.PathAlreadyExists => continue,
                else => return err,
            };
            const session_dir = try root.openDir(io, &id, .{});
            return .{
                .io = io,
                .gpa = gpa,
                .root = root,
                .session_dir = session_dir,
                .session = id,
                .out_buffer = out_buffer,
            };
        }
        return error.NoUniqueSession;
    }

    pub fn close(self: *Store) void {
        self.finish(null);
        self.session_dir.close(self.io);
        self.root.close(self.io);
        self.gpa.free(self.out_buffer);
    }

    pub fn isRecording(self: *const Store) bool {
        return self.current != null;
    }

    /// Opens interaction N and writes `cmd` immediately, so a session that
    /// dies mid-command still shows what was running.
    pub fn begin(self: *Store, cmd: []const u8, expanded: ?[]const u8) void {
        if (self.disabled) return;
        if (self.current != null) self.finish(null);

        var name_buf: [16]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "{d}", .{self.next_number}) catch return;

        self.beginFallible(name, cmd, expanded) catch |err| {
            self.warn("cannot start interaction {s}: {t}", .{ name, err });
            self.disable();
        };
    }

    fn beginFallible(self: *Store, name: []const u8, cmd: []const u8, expanded: ?[]const u8) !void {
        try self.session_dir.createDir(self.io, name, dir_permissions);
        var dir = try self.session_dir.openDir(self.io, name, .{});
        errdefer dir.close(self.io);

        try dir.writeFile(self.io, .{
            .sub_path = "cmd",
            .data = cmd,
            .flags = .{ .permissions = file_permissions },
        });

        const file = try dir.createFile(self.io, "out", .{ .permissions = file_permissions });
        self.current = .{
            .number = self.next_number,
            .dir = dir,
            .file = file,
            .writer = file.writerStreaming(self.io, self.out_buffer),
            .started_ms = nowMillis(self.io),
            .expanded = if (expanded) |text| try self.gpa.dupe(u8, text) else null,
        };
        self.next_number += 1;
    }

    /// Buffered: the poll loop must not wait on the disk to forward a byte.
    pub fn append(self: *Store, bytes: []const u8) void {
        const current = &(self.current orelse return);
        current.writer.interface.writeAll(bytes) catch |err| {
            self.warn("cannot write output: {t}", .{err});
            self.disable();
        };
    }

    /// Called on the periodic tick so `tail -f` on a running command's `out`
    /// shows something.
    pub fn tick(self: *Store) void {
        const current = &(self.current orelse return);
        current.writer.interface.flush() catch |err| {
            self.warn("cannot flush output: {t}", .{err});
            self.disable();
        };
    }

    /// Closes the interaction. Without an exit code the interaction stays
    /// incomplete on disk - readers must treat a missing `rc` as "aborted",
    /// never as success.
    pub fn finish(self: *Store, code: ?u8) void {
        var current = self.current orelse return;
        self.current = null;
        if (code) |value| current.exit_code = value;

        current.writer.interface.flush() catch {};
        current.file.close(self.io);

        if (current.exit_code) |value| {
            var buf: [8]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "{d}\n", .{value}) catch "";
            current.dir.writeFile(self.io, .{
                .sub_path = "rc",
                .data = text,
                .flags = .{ .permissions = file_permissions },
            }) catch |err| self.warn("cannot write rc: {t}", .{err});
        }

        self.writeMeta(&current) catch |err| self.warn("cannot write meta.json: {t}", .{err});
        if (current.expanded) |text| self.gpa.free(text);
        current.dir.close(self.io);
    }

    fn writeMeta(self: *Store, current: *const Interaction) !void {
        var buf: [8 * 1024]u8 = undefined;
        var writer = Io.Writer.fixed(&buf);
        var started: [32]u8 = undefined;
        var ended: [32]u8 = undefined;

        try writer.print("{{\"v\":1,\"started\":\"{s}\",\"ended\":\"{s}\"", .{
            formatTimestamp(current.started_ms, &started),
            formatTimestamp(nowMillis(self.io), &ended),
        });
        if (current.expanded) |text| {
            try writer.writeAll(",\"expanded_cmd\":");
            // Command lines are arbitrary bytes; they have to be escaped or the
            // file stops being JSON.
            try std.json.Stringify.encodeJsonString(text, .{}, &writer);
        }
        try writer.writeAll("}\n");

        try current.dir.writeFile(self.io, .{
            .sub_path = "meta.json",
            .data = writer.buffered(),
            .flags = .{ .permissions = file_permissions },
        });
    }

    fn disable(self: *Store) void {
        self.disabled = true;
        if (self.current) |*current| {
            current.file.close(self.io);
            current.dir.close(self.io);
            self.current = null;
        }
    }

    /// Appends to `$TJ_HOME/<session>/log`. Best effort: if even this fails
    /// there is nothing useful left to do about it.
    pub fn warn(self: *Store, comptime fmt: []const u8, args: anytype) void {
        var buf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
        const file = self.session_dir.createFile(self.io, "log", .{
            .truncate = false,
            .permissions = file_permissions,
        }) catch return;
        defer file.close(self.io);
        _ = file.length(self.io) catch {};
        file.writeStreamingAll(self.io, line) catch {};
    }
};

// --- reading the journal ---------------------------------------------------

pub fn resolveRoot(home_override: ?[]const u8, buf: []u8) ![]const u8 {
    if (home_override) |path| return path;
    if (sys.env("TJ_HOME")) |path| return path;
    const home = sys.env("HOME") orelse return error.NoHomeDirectory;
    return std.fmt.bufPrint(buf, "{s}/.tj", .{home});
}

fn openOrCreateRoot(io: Io, path: []const u8) !Dir {
    _ = Dir.cwd().createDirPathStatus(io, path, dir_permissions) catch |err| switch (err) {
        error.PathAlreadyExists => .existed,
        else => return err,
    };
    return Dir.cwd().openDir(io, path, .{});
}

pub fn openRoot(io: Io, home_override: ?[]const u8) !Dir {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try resolveRoot(home_override, &buf);
    return Dir.cwd().openDir(io, path, .{});
}

/// Session ids, newest first. ULIDs sort chronologically, so this is just a
/// reverse sort of the directory names.
pub fn listSessions(gpa: std.mem.Allocator, io: Io, root: Dir) ![][]const u8 {
    var found: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (found.items) |name| gpa.free(name);
        found.deinit(gpa);
    }

    var it = root.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (!ulid.isValid(entry.name)) continue;
        try found.append(gpa, try gpa.dupe(u8, entry.name));
    }

    std.mem.sort([]const u8, found.items, {}, struct {
        fn newestFirst(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .gt;
        }
    }.newestFirst);

    return found.toOwnedSlice(gpa);
}

pub const InteractionInfo = struct {
    number: u32,
    /// Absent means the interaction never completed.
    exit_code: ?u8,
    command: []const u8,

    pub fn deinit(self: InteractionInfo, gpa: std.mem.Allocator) void {
        gpa.free(self.command);
    }
};

/// Interactions of one session, in numeric order.
pub fn listInteractions(gpa: std.mem.Allocator, io: Io, root: Dir, session: []const u8) ![]InteractionInfo {
    var dir = try root.openDir(io, session, .{});
    defer dir.close(io);

    var found: std.ArrayList(InteractionInfo) = .empty;
    errdefer {
        for (found.items) |info| info.deinit(gpa);
        found.deinit(gpa);
    }

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const number = std.fmt.parseInt(u32, entry.name, 10) catch continue;

        var interaction = try dir.openDir(io, entry.name, .{});
        defer interaction.close(io);

        const command = interaction.readFileAlloc(io, "cmd", gpa, .limited(64 * 1024)) catch
            try gpa.dupe(u8, "");
        errdefer gpa.free(command);

        try found.append(gpa, .{
            .number = number,
            .exit_code = readExitCode(io, interaction),
            .command = command,
        });
    }

    std.mem.sort(InteractionInfo, found.items, {}, struct {
        fn byNumber(_: void, a: InteractionInfo, b: InteractionInfo) bool {
            return a.number < b.number;
        }
    }.byNumber);

    return found.toOwnedSlice(gpa);
}

/// The highest interaction that actually completed. `@-` resolves to this, so
/// a command reading `@-/out` never picks up the one running it.
pub fn lastCompleted(gpa: std.mem.Allocator, io: Io, root: Dir, session: []const u8) !?u32 {
    const interactions = try listInteractions(gpa, io, root, session);
    defer {
        for (interactions) |info| info.deinit(gpa);
        gpa.free(interactions);
    }

    var highest: ?u32 = null;
    for (interactions) |info| {
        if (info.exit_code == null) continue;
        if (highest == null or info.number > highest.?) highest = info.number;
    }
    return highest;
}

fn readExitCode(io: Io, dir: Dir) ?u8 {
    var buf: [16]u8 = undefined;
    const file = dir.openFile(io, "rc", .{}) catch return null;
    defer file.close(io);
    const n = file.readStreaming(io, &.{buf[0..]}) catch return null;
    const text = std.mem.trim(u8, buf[0..n], " \r\n\t");
    return std.fmt.parseInt(u8, text, 10) catch null;
}

// --- time ------------------------------------------------------------------

fn nowMillis(io: Io) i64 {
    return Io.Clock.now(.real, io).toMilliseconds();
}

/// ISO 8601 with milliseconds, always UTC.
fn formatTimestamp(millis: i64, buf: []u8) []const u8 {
    const seconds = @divFloor(millis, 1000);
    const remainder: u16 = @intCast(@mod(millis, 1000));
    if (seconds < 0) return "";

    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(seconds) };
    const day = epoch.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const time = epoch.getDaySeconds();

    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        time.getHoursIntoDay(),
        time.getMinutesIntoHour(),
        time.getSecondsIntoMinute(),
        remainder,
    }) catch "";
}

test "timestamps format as UTC ISO 8601" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("1970-01-01T00:00:00.000Z", formatTimestamp(0, &buf));
    try std.testing.expectEqualStrings("2026-08-26T14:03:22.117Z", formatTimestamp(1787753002117, &buf));
    // A leap day, and the last millisecond of a year.
    try std.testing.expectEqualStrings("2024-02-29T12:00:00.500Z", formatTimestamp(1709208000500, &buf));
    try std.testing.expectEqualStrings("2025-12-31T23:59:59.999Z", formatTimestamp(1767225599999, &buf));
}

// --- resolving references --------------------------------------------------

const reference = @import("reference.zig");

pub const ResolveError = error{
    /// `@42` and `@-` are relative to the session you are in.
    NotInSession,
    /// No session directory ends with the given suffix.
    NoSuchSession,
    /// `@-` used before anything has completed.
    NothingCompleted,
};

pub const Resolved = struct {
    /// Always absolute, so the path keeps working wherever it is pasted.
    path: []u8,
    session: []u8,
    number: u32,
    /// Whether the interaction directory is actually there. The resource
    /// inside it may still be missing.
    exists: bool,

    pub fn deinit(self: Resolved, gpa: std.mem.Allocator) void {
        gpa.free(self.path);
        gpa.free(self.session);
    }
};

/// Turns a parsed reference into a filesystem path. `current` is the session
/// the caller is in, if any.
pub fn resolve(
    gpa: std.mem.Allocator,
    io: Io,
    root: Dir,
    current: ?[]const u8,
    ref: reference.Reference,
) ![]const u8 {
    const found = try locate(gpa, io, root, current, ref);
    defer found.deinit(gpa);
    if (!found.exists) return error.NoSuchInteraction;
    return gpa.dupe(u8, found.path);
}

pub fn locate(
    gpa: std.mem.Allocator,
    io: Io,
    root: Dir,
    current: ?[]const u8,
    ref: reference.Reference,
) !Resolved {
    const session: []u8 = switch (ref.body) {
        .previous, .current => try gpa.dupe(u8, current orelse return error.NotInSession),
        .qualified => |q| try findSession(gpa, io, root, q.suffix) orelse return error.NoSuchSession,
    };
    errdefer gpa.free(session);

    const number: u32 = switch (ref.body) {
        .current => |n| n,
        .qualified => |q| q.number,
        .previous => try lastCompleted(gpa, io, root, session) orelse return error.NothingCompleted,
    };

    var base: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = try root.realPath(io, &base);

    var path: std.ArrayList(u8) = .empty;
    errdefer path.deinit(gpa);
    try path.appendSlice(gpa, base[0..base_len]);
    try path.append(gpa, '/');
    try path.appendSlice(gpa, session);
    try path.print(gpa, "/{d}", .{number});

    const exists = blk: {
        var dir = root.openDir(io, path.items[base_len + 1 ..], .{}) catch break :blk false;
        dir.close(io);
        break :blk true;
    };

    if (ref.subpath.len > 0) {
        try path.append(gpa, '/');
        try path.appendSlice(gpa, ref.subpath);
    }

    return .{
        .path = try path.toOwnedSlice(gpa),
        .session = session,
        .number = number,
        .exists = exists,
    };
}

/// The most recent session whose id ends with `suffix`. Short suffixes are for
/// interactive use and deliberately trade certainty for convenience; anything
/// that needs to stay valid should use the full id.
pub fn findSession(gpa: std.mem.Allocator, io: Io, root: Dir, suffix: []const u8) !?[]u8 {
    var lowered: [reference.max_suffix]u8 = undefined;
    if (suffix.len > lowered.len) return null;
    const wanted = std.ascii.lowerString(lowered[0..suffix.len], suffix);

    const sessions = try listSessions(gpa, io, root);
    defer {
        for (sessions) |name| gpa.free(name);
        gpa.free(sessions);
    }

    // listSessions is newest first, so the first match wins.
    for (sessions) |name| {
        if (std.mem.endsWith(u8, name, wanted)) return try gpa.dupe(u8, name);
    }
    return null;
}

/// Interaction numbers present in a session, in numeric order.
pub fn listNumbers(gpa: std.mem.Allocator, io: Io, root: Dir, session: []const u8) ![]u32 {
    var dir = try root.openDir(io, session, .{});
    defer dir.close(io);

    var found: std.ArrayList(u32) = .empty;
    errdefer found.deinit(gpa);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const number = std.fmt.parseInt(u32, entry.name, 10) catch continue;
        try found.append(gpa, number);
    }

    std.mem.sort(u32, found.items, {}, std.sort.asc(u32));
    return found.toOwnedSlice(gpa);
}

/// Resource names inside one interaction. `meta.json` and the session log are
/// tj's own bookkeeping and are never offered.
pub fn listResources(gpa: std.mem.Allocator, io: Io, root: Dir, session: []const u8, number: u32) ![][]u8 {
    var path_buf: [64]u8 = undefined;
    const sub = try std.fmt.bufPrint(&path_buf, "{s}/{d}", .{ session, number });

    var dir = try root.openDir(io, sub, .{});
    defer dir.close(io);

    var found: std.ArrayList([]u8) = .empty;
    errdefer {
        for (found.items) |name| gpa.free(name);
        found.deinit(gpa);
    }

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (isPrivate(entry.name)) continue;
        const name = if (entry.kind == .directory)
            try std.fmt.allocPrint(gpa, "{s}/", .{entry.name})
        else
            try gpa.dupe(u8, entry.name);
        try found.append(gpa, name);
    }

    std.mem.sort([]u8, found.items, {}, struct {
        fn byName(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.byName);

    return found.toOwnedSlice(gpa);
}

fn isPrivate(name: []const u8) bool {
    return std.mem.eql(u8, name, "meta.json") or std.mem.eql(u8, name, "log");
}

test "tj's bookkeeping files are not part of the namespace" {
    try std.testing.expect(isPrivate("meta.json"));
    try std.testing.expect(isPrivate("log"));
    try std.testing.expect(!isPrivate("cmd"));
    try std.testing.expect(!isPrivate("out"));
    try std.testing.expect(!isPrivate("rc"));
    try std.testing.expect(!isPrivate("files"));
}
