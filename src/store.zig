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
const altscreen = @import("altscreen.zig");

/// The journal holds whatever appears on the terminal, which includes secrets.
/// It gets the same treatment as shell history.
const dir_permissions: File.Permissions = @enumFromInt(0o700);
const file_permissions: File.Permissions = @enumFromInt(0o600);

const out_buffer_size = 64 * 1024;

/// Past this a resource stops growing and is flagged truncated. `out` itself
/// is uncapped: a program can only publish what it also printed.
const max_resource_bytes = 64 * 1024 * 1024;

/// Per interaction. A program publishing more than this is misbehaving.
const max_resources = 32;

/// tj's own bookkeeping, which a program may not overwrite by publishing a
/// resource with the same name.
const reserved_names = [_][]const u8{ "cmd", "out", "rc", "meta.json", "log" };

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
        /// Keeps full-screen programs out of `out`, the way the alternate
        /// screen keeps them out of the terminal's scrollback.
        fullscreen: altscreen.Filter = .{},

        /// The resource currently being published, if any.
        open_resource: ?OpenResource = null,
        published: [max_resources]Published = undefined,
        published_count: usize = 0,
    };

    const OpenResource = struct {
        file: File,
        written: u64 = 0,
        /// Index into `published`, whose entry this is filling in.
        entry: usize,
        /// A carriage return held back because the next byte decides whether
        /// it was a line ending. See `writeResource`.
        pending_cr: bool = false,
    };

    const Published = struct {
        path: []u8,
        mime: []u8,
        /// The program never closed it, or it hit the size cap.
        truncated: bool = false,
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

        // A session that recorded nothing is noise: nothing to reference,
        // nothing to read, and one more name for a short suffix to collide
        // with. Removing a directory refuses to remove one with anything in
        // it, so this cannot take a session that has content - including one
        // that only managed to write a log saying why it recorded nothing.
        self.root.deleteDir(self.io, &self.session) catch {};

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

        // Before the full-screen filter, not after: publishing a resource is a
        // deliberate act by the program, so it is kept whatever the screen was
        // doing at the time.
        self.appendResource(current, bytes);

        var sink: OutputSink = .{ .store = self, .interaction = current };
        current.fullscreen.feed(bytes, &sink);
    }

    /// Starts capturing output as a named resource of this interaction. The
    /// bytes stay in `out` as well; the resource is a span of it.
    pub fn beginResource(self: *Store, path: []const u8, mime: []const u8) void {
        if (self.disabled) return;
        const current = &(self.current orelse {
            // Printed by precmd, or by something outside any command.
            self.warn("resource {s} published with no interaction open", .{path});
            return;
        });

        if (current.open_resource != null) {
            // No nesting in v1. The open one keeps going.
            self.warn("resource {s} published while another is open", .{path});
            return;
        }
        if (!validResourcePath(path)) {
            self.warn("refused resource name {s}", .{path});
            return;
        }

        self.openResource(current, path, mime) catch |err| {
            self.warn("cannot publish resource {s}: {t}", .{ path, err });
        };
    }

    fn openResource(self: *Store, current: *Interaction, path: []const u8, mime: []const u8) !void {
        if (std.mem.lastIndexOfScalar(u8, path, '/')) |cut| {
            try current.dir.createDirPath(self.io, path[0..cut]);
        }
        const file = try current.dir.createFile(self.io, path, .{ .permissions = file_permissions });
        errdefer file.close(self.io);

        current.open_resource = .{
            .file = file,
            .entry = try self.recordPublished(current, path, mime),
        };
    }

    /// Finds or makes the `meta.json` entry for this path. Publishing the same
    /// name twice within one interaction means the last one wins.
    fn recordPublished(self: *Store, current: *Interaction, path: []const u8, mime: []const u8) !usize {
        for (current.published[0..current.published_count], 0..) |*entry, i| {
            if (!std.mem.eql(u8, entry.path, path)) continue;
            self.warn("resource {s} published twice; keeping the last", .{path});
            self.gpa.free(entry.mime);
            entry.mime = try self.gpa.dupe(u8, mime);
            entry.truncated = false;
            return i;
        }

        if (current.published_count == current.published.len) return error.TooManyResources;
        current.published[current.published_count] = .{
            .path = try self.gpa.dupe(u8, path),
            .mime = try self.gpa.dupe(u8, mime),
        };
        current.published_count += 1;
        return current.published_count - 1;
    }

    fn appendResource(self: *Store, current: *Interaction, bytes: []const u8) void {
        const open = &(current.open_resource orelse return);
        const entry = &current.published[open.entry];

        const room = max_resource_bytes - @min(open.written, max_resource_bytes);
        const take = @min(bytes.len, room);
        if (take < bytes.len and !entry.truncated) {
            entry.truncated = true;
            self.warn("resource {s} hit the size cap", .{entry.path});
        }
        if (take == 0) return;

        self.writeResource(current, open, bytes[0..take]) catch |err| {
            self.warn("cannot write resource {s}: {t}", .{ entry.path, err });
            entry.truncated = true;
            open.file.close(self.io);
            current.open_resource = null;
        };
    }

    /// Writes resource bytes, undoing the terminal's newline translation.
    ///
    /// A program writes "\n" and the pty turns it into "\r\n" on the way out,
    /// so that is what tj sees. `out` keeps it, because that is what the
    /// terminal saw. A resource is different: it is published to be used as a
    /// file, and the design's own example is a shell script, which will not
    /// run with a carriage return on its shebang line. The "\r" is an artifact
    /// of the transport, not something the program wrote.
    ///
    /// A lone "\r" is kept: only the pair is translation.
    fn writeResource(self: *Store, current: *Interaction, open: *OpenResource, bytes: []const u8) !void {
        var i: usize = 0;
        while (i < bytes.len) {
            if (open.pending_cr) {
                open.pending_cr = false;
                // Not a line ending after all, so the carriage return was real.
                if (bytes[i] != '\n') try self.emitResource(open, "\r");
            }

            const start = i;
            while (i < bytes.len and bytes[i] != '\r') i += 1;
            if (i > start) try self.emitResource(open, bytes[start..i]);

            if (i < bytes.len) {
                // Hold it: the byte that decides may be in the next read.
                open.pending_cr = true;
                i += 1;
            }
        }
        _ = current;
    }

    fn emitResource(self: *Store, open: *OpenResource, bytes: []const u8) !void {
        try open.file.writePositionalAll(self.io, bytes, open.written);
        open.written += bytes.len;
    }

    /// A carriage return held to the very end was never part of a line ending.
    fn flushResourceTail(self: *Store, open: *OpenResource) void {
        if (!open.pending_cr) return;
        open.pending_cr = false;
        self.emitResource(open, "\r") catch {};
    }

    pub fn endResource(self: *Store) void {
        const current = &(self.current orelse return);
        if (current.open_resource == null) {
            self.warn("resource end with none open", .{});
            return;
        }
        const open = &current.open_resource.?;
        self.flushResourceTail(open);
        open.file.close(self.io);
        current.open_resource = null;
    }

    /// A resource the program never closed. The interaction is ending, so what
    /// was captured is all there will be.
    fn closeOpenResource(self: *Store, current: *Interaction) void {
        if (current.open_resource == null) return;
        const open = &current.open_resource.?;
        self.flushResourceTail(open);
        current.published[open.entry].truncated = true;
        open.file.close(self.io);
        current.open_resource = null;
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

        self.closeOpenResource(&current);
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
        for (current.published[0..current.published_count]) |entry| {
            self.gpa.free(entry.path);
            self.gpa.free(entry.mime);
        }
        current.dir.close(self.io);
    }

    fn writeMeta(self: *Store, current: *Interaction) !void {
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

        // A near-empty `out` for `vi` is correct but surprising, so the
        // reason is recorded next to it.
        if (current.fullscreen.regions > 0) {
            try writer.print(",\"fullscreen\":{{\"regions\":{d},\"suppressed_bytes\":{d}}}", .{
                current.fullscreen.regions,
                current.fullscreen.suppressed,
            });
        }
        if (current.published_count > 0) {
            try writer.writeAll(",\"resources\":{");
            for (current.published[0..current.published_count], 0..) |entry, i| {
                if (i > 0) try writer.writeAll(",");
                // Paths and mime types come from the program, so both are
                // escaped rather than trusted to be plain.
                try std.json.Stringify.encodeJsonString(entry.path, .{}, &writer);
                try writer.writeAll(":{\"mime\":");
                try std.json.Stringify.encodeJsonString(entry.mime, .{}, &writer);
                try writer.print(",\"truncated\":{}}}", .{entry.truncated});
            }
            try writer.writeAll("}");
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
            self.closeOpenResource(current);
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
        // Opening without truncating still starts writing at zero, so each
        // warning has to be placed after the last one deliberately.
        const end = file.length(self.io) catch return;
        file.writePositionalAll(self.io, line, end) catch {};
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
    /// So a reader can tell what fetching `out` would cost before doing it.
    out_bytes: u64,

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
            .out_bytes = blk: {
                const file = interaction.openFile(io, "out", .{}) catch break :blk 0;
                defer file.close(io);
                break :blk file.length(io) catch 0;
            },
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

/// Receives the bytes that survive the full-screen filter and puts them on
/// disk. A write failure stops recording for the session; it never stops the
/// terminal.
const OutputSink = struct {
    store: *Store,
    interaction: *Store.Interaction,

    pub fn keep(self: *OutputSink, bytes: []const u8) void {
        self.interaction.writer.interface.writeAll(bytes) catch |err| {
            self.store.warn("cannot write output: {t}", .{err});
            self.store.disable();
        };
    }
};

// --- resources published by programs ----------------------------------------

/// A resource name comes from the program, so this is a boundary rather than
/// a nicety: it decides what a program can write inside the journal.
pub fn validResourcePath(path: []const u8) bool {
    if (path.len == 0 or path.len > 256) return false;
    if (path[0] == '/') return false;

    for (reserved_names) |name| {
        if (std.mem.eql(u8, path, name)) return false;
    }

    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0) return false;
        if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
        for (segment) |char| if (char < 0x20) return false;
    }
    return true;
}

test "resource paths that programs may use" {
    for ([_][]const u8{ "err", "files/data.csv", "a/b/c.txt", "files/.hidden" }) |path| {
        try std.testing.expect(validResourcePath(path));
    }
}

test "resource paths that must be refused" {
    for ([_][]const u8{
        // Escaping the interaction directory.
        "../out", "files/../../etc/passwd", "/etc/passwd", "a//b",
        "./x",    "..",
        // Overwriting tj's own bookkeeping.
                            "cmd",         "out",
        "rc",     "meta.json",              "log",
        // Nothing, or control characters.
                "",
        "a\x00b", "a\nb",
    }) |path| {
        try std.testing.expect(!validResourcePath(path));
    }
}

test "a reserved name is only reserved whole" {
    // `cmd` is tj's; `files/cmd` and `cmd.txt` are the program's business.
    try std.testing.expect(validResourcePath("files/cmd"));
    try std.testing.expect(validResourcePath("cmd.txt"));
}

test "every warning is kept, not written over the last one" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);

    var store = try Store.create(std.testing.allocator, io, path_buf[0..len]);
    store.warn("first warning, which is a long one", .{});
    store.warn("second", .{});
    store.warn("third", .{});

    const text = try store.session_dir.readFileAlloc(io, "log", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(text);
    store.close();

    try std.testing.expectEqualStrings(
        "first warning, which is a long one\nsecond\nthird\n",
        text,
    );
}

test "a resource keeps the newlines the program wrote, not the pty's" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);

    // Fed one byte at a time, so a CRLF straddling two reads is covered too.
    for ([_]usize{ 1, 2, 3, 64 }) |chunk| {
        var store = try Store.create(std.testing.allocator, io, path_buf[0..len]);
        store.begin("demo", null);
        store.beginResource("script.sh", "text/x-shellscript");

        const written = "#!/bin/sh\r\necho hi\r\n\rlone cr\r\n";
        var i: usize = 0;
        while (i < written.len) {
            const end = @min(i + chunk, written.len);
            store.append(written[i..end]);
            i = end;
        }
        store.endResource();

        const text = try store.current.?.dir.readFileAlloc(io, "script.sh", std.testing.allocator, .limited(4096));
        defer std.testing.allocator.free(text);
        store.finish(0);
        store.close();

        // Line endings normalised; the lone carriage return survives.
        try std.testing.expectEqualStrings("#!/bin/sh\necho hi\n\rlone cr\n", text);
    }
}

test "a carriage return at the very end of a resource is kept" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);

    var store = try Store.create(std.testing.allocator, io, path_buf[0..len]);
    store.begin("demo", null);
    store.beginResource("trailing", "text/plain");
    store.append("ends with cr\r");
    store.endResource();

    const text = try store.current.?.dir.readFileAlloc(io, "trailing", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(text);
    store.finish(0);
    store.close();

    try std.testing.expectEqualStrings("ends with cr\r", text);
}
