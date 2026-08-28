//! The on-disk journal.
//!
//!     $TJ_HOME/                 default ~/.tj
//!     └── <journal-ulid>/
//!         ├── log               warnings from this journal, if any
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
//! the journal and is noted in the journal log, and the proxy keeps forwarding
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
    journal_dir: Dir,
    journal: ulid.Ulid,
    lock_file: File,
    origin: Origin,
    next_number: ?u32 = 1,
    current: ?Interaction = null,
    out_buffer: []u8,
    /// Set after the first write failure; recording stops, forwarding does not.
    disabled: bool = false,

    const Origin = enum { created, existing };

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

    /// Creates a new journal. `home_override` wins over `$TJ_HOME`, which wins
    /// over `~/.tj`.
    pub fn createJournal(gpa: std.mem.Allocator, io: Io, home_override: ?[]const u8) !Store {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const root_path = try resolveRoot(home_override, &path_buf);

        const root = try openOrCreateRoot(io, root_path);
        errdefer root.close(io);

        // ULIDs carry 80 random bits, so a clash means something is badly
        // wrong with the entropy source; retrying is still the cheap fix.
        var attempts: usize = 0;
        while (attempts < 8) : (attempts += 1) {
            const id = ulid.generate(io);
            root.createDir(io, &id, dir_permissions) catch |err| switch (err) {
                error.PathAlreadyExists => continue,
                else => return err,
            };
            errdefer root.deleteDir(io, &id) catch {};

            const lock_file = acquireJournalLock(io, root, &id) catch |err| {
                removeLockFile(io, root, &id);
                return err;
            };
            errdefer lock_file.close(io);
            errdefer removeLockFile(io, root, &id);

            const journal_dir = try root.openDir(io, &id, .{ .iterate = true });
            errdefer journal_dir.close(io);

            const out_buffer = try gpa.alloc(u8, out_buffer_size);
            return .{
                .io = io,
                .gpa = gpa,
                .root = root,
                .journal_dir = journal_dir,
                .journal = id,
                .lock_file = lock_file,
                .origin = .created,
                .out_buffer = out_buffer,
            };
        }
        return error.NoUniqueJournal;
    }

    /// Attaches a writer to exactly one existing journal. Selection,
    /// locking, and numbering all finish before the caller starts a child.
    pub fn continueJournal(
        gpa: std.mem.Allocator,
        io: Io,
        home_override: ?[]const u8,
        selector: []const u8,
    ) !Store {
        const root = openRoot(io, home_override) catch |err| switch (err) {
            error.FileNotFound => return error.NoSuchJournal,
            else => return err,
        };
        errdefer root.close(io);

        const selected = try findUniqueJournal(gpa, io, root, selector);
        defer gpa.free(selected);
        var id: ulid.Ulid = undefined;
        @memcpy(&id, selected);

        const lock_file = try acquireJournalLock(io, root, &id);
        errdefer lock_file.close(io);

        // Re-open only after the lock is held. Future pruning uses the same
        // lock, so the selected directory cannot disappear between these two
        // operations.
        const journal_dir = root.openDir(io, &id, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return error.NoSuchJournal,
            else => return err,
        };
        errdefer journal_dir.close(io);

        const next_number = try nextInteractionNumber(gpa, io, root, &id);
        const out_buffer = try gpa.alloc(u8, out_buffer_size);

        return .{
            .io = io,
            .gpa = gpa,
            .root = root,
            .journal_dir = journal_dir,
            .journal = id,
            .lock_file = lock_file,
            .origin = .existing,
            .next_number = next_number,
            .out_buffer = out_buffer,
        };
    }

    pub fn close(self: *Store) void {
        self.finish(null);
        self.journal_dir.close(self.io);

        // Only the invocation that created a journal may remove it as empty
        // noise. A continued journal is persistent even when it stays empty.
        const removed = self.origin == .created and blk: {
            self.root.deleteDir(self.io, &self.journal) catch break :blk false;
            break :blk true;
        };

        self.lock_file.close(self.io);
        if (removed) removeLockFile(self.io, self.root, &self.journal);

        self.root.close(self.io);
        self.gpa.free(self.out_buffer);
    }

    pub fn isRecording(self: *const Store) bool {
        return self.current != null;
    }

    /// Opens interaction N and writes `cmd` immediately, so a journal that
    /// dies mid-command still shows what was running.
    pub fn begin(self: *Store, cmd: []const u8, expanded: ?[]const u8) void {
        if (self.disabled) return;
        if (self.current != null) self.finish(null);

        const number = self.next_number orelse {
            self.warn("journal has no interaction numbers left", .{});
            self.disabled = true;
            return;
        };

        var name_buf: [16]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "{d}", .{number}) catch return;

        self.beginFallible(number, name, cmd, expanded) catch |err| {
            self.warn("cannot start interaction {s}: {t}", .{ name, err });
            self.disable();
        };
    }

    fn beginFallible(self: *Store, number: u32, name: []const u8, cmd: []const u8, expanded: ?[]const u8) !void {
        try self.journal_dir.createDir(self.io, name, dir_permissions);
        var dir = try self.journal_dir.openDir(self.io, name, .{});
        errdefer dir.close(self.io);

        try dir.writeFile(self.io, .{
            .sub_path = "cmd",
            .data = cmd,
            .flags = .{ .permissions = file_permissions },
        });

        const file = try dir.createFile(self.io, "out", .{ .permissions = file_permissions });
        self.current = .{
            .number = number,
            .dir = dir,
            .file = file,
            .writer = file.writerStreaming(self.io, self.out_buffer),
            .started_ms = nowMillis(self.io),
            .expanded = if (expanded) |text| try self.gpa.dupe(u8, text) else null,
        };
        self.next_number = std.math.add(u32, number, 1) catch null;
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
        var json: std.ArrayList(u8) = .empty;
        defer json.deinit(self.gpa);
        var writer = Io.Writer.Allocating.fromArrayList(self.gpa, &json);
        defer json = writer.toArrayList();
        var started: [32]u8 = undefined;
        var ended: [32]u8 = undefined;

        try writer.writer.print("{{\"v\":1,\"started\":\"{s}\",\"ended\":\"{s}\"", .{
            formatTimestamp(current.started_ms, &started),
            formatTimestamp(nowMillis(self.io), &ended),
        });
        if (current.expanded) |text| {
            try writer.writer.writeAll(",\"expanded_cmd\":");
            // Command lines are arbitrary bytes; they have to be escaped or the
            // file stops being JSON.
            try std.json.Stringify.encodeJsonString(text, .{}, &writer.writer);
        }

        // A near-empty `out` for `vi` is correct but surprising, so the
        // reason is recorded next to it.
        if (current.fullscreen.regions > 0) {
            try writer.writer.print(",\"fullscreen\":{{\"regions\":{d},\"suppressed_bytes\":{d}}}", .{
                current.fullscreen.regions,
                current.fullscreen.suppressed,
            });
        }
        if (current.published_count > 0) {
            try writer.writer.writeAll(",\"resources\":{");
            for (current.published[0..current.published_count], 0..) |entry, i| {
                if (i > 0) try writer.writer.writeAll(",");
                // Paths and mime types come from the program, so both are
                // escaped rather than trusted to be plain.
                try std.json.Stringify.encodeJsonString(entry.path, .{}, &writer.writer);
                try writer.writer.writeAll(":{\"mime\":");
                try std.json.Stringify.encodeJsonString(entry.mime, .{}, &writer.writer);
                try writer.writer.print(",\"truncated\":{}}}", .{entry.truncated});
            }
            try writer.writer.writeAll("}");
        }
        try writer.writer.writeAll("}\n");

        try current.dir.writeFile(self.io, .{
            .sub_path = "meta.json",
            .data = writer.writer.buffered(),
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

    /// Appends to `$TJ_HOME/<journal>/log`. Best effort: if even this fails
    /// there is nothing useful left to do about it.
    pub fn warn(self: *Store, comptime fmt: []const u8, args: anytype) void {
        var buf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
        const file = self.journal_dir.createFile(self.io, "log", .{
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
    return Dir.cwd().openDir(io, path, .{ .iterate = true });
}

fn acquireJournalLock(io: Io, root: Dir, journal: []const u8) !File {
    _ = root.createDir(io, ".locks", dir_permissions) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    var locks = try root.openDir(io, ".locks", .{});
    defer locks.close(io);

    return locks.createFile(io, journal, .{
        .read = true,
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
        .permissions = file_permissions,
    }) catch |err| switch (err) {
        error.WouldBlock => error.JournalLocked,
        else => return err,
    };
}

fn removeLockFile(io: Io, root: Dir, journal: []const u8) void {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, ".locks/{s}", .{journal}) catch return;
    root.deleteFile(io, path) catch {};
}

pub fn openRoot(io: Io, home_override: ?[]const u8) !Dir {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try resolveRoot(home_override, &buf);
    return Dir.cwd().openDir(io, path, .{ .iterate = true });
}

/// Journal ids, newest first. ULIDs sort chronologically, so this is just a
/// reverse sort of the directory names.
pub fn listJournals(gpa: std.mem.Allocator, io: Io, root: Dir) ![][]const u8 {
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

/// Interactions of one journal, in numeric order.
pub fn listInteractions(gpa: std.mem.Allocator, io: Io, root: Dir, journal: []const u8) ![]InteractionInfo {
    var dir = try root.openDir(io, journal, .{ .iterate = true });
    defer dir.close(io);

    var found: std.ArrayList(InteractionInfo) = .empty;
    errdefer {
        for (found.items) |info| info.deinit(gpa);
        found.deinit(gpa);
    }

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const number = parseInteractionDirName(entry.name) orelse continue;

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
pub fn lastCompleted(gpa: std.mem.Allocator, io: Io, root: Dir, journal: []const u8) !?u32 {
    const interactions = try listInteractions(gpa, io, root, journal);
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
    /// `@42` and `@-` are relative to the journal you are in.
    NotInJournal,
    /// No journal directory ends with the given suffix.
    NoSuchJournal,
    /// `@-` used before anything has completed.
    NothingCompleted,
};

pub const Resolved = struct {
    /// Always absolute, so the path keeps working wherever it is pasted.
    path: []u8,
    journal: []u8,
    number: u32,
    /// Whether the interaction directory is actually there. The resource
    /// inside it may still be missing.
    exists: bool,

    pub fn deinit(self: Resolved, gpa: std.mem.Allocator) void {
        gpa.free(self.path);
        gpa.free(self.journal);
    }
};

/// Turns a parsed reference into a filesystem path. `current` is the journal
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
    const journal: []u8 = switch (ref.body) {
        .previous, .current => try gpa.dupe(u8, current orelse return error.NotInJournal),
        .qualified => |q| try findNewestJournal(gpa, io, root, q.suffix) orelse return error.NoSuchJournal,
    };
    errdefer gpa.free(journal);

    const number: u32 = switch (ref.body) {
        .current => |n| n,
        .qualified => |q| q.number,
        .previous => try lastCompleted(gpa, io, root, journal) orelse return error.NothingCompleted,
    };

    var base: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = try root.realPath(io, &base);

    var path: std.ArrayList(u8) = .empty;
    errdefer path.deinit(gpa);
    try path.appendSlice(gpa, base[0..base_len]);
    try path.append(gpa, '/');
    try path.appendSlice(gpa, journal);
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
        .journal = journal,
        .number = number,
        .exists = exists,
    };
}

/// The most recent journal whose id ends with `suffix`. Short suffixes are for
/// interactive use and deliberately trade certainty for convenience; anything
/// that needs to stay valid should use the full id.
pub fn findNewestJournal(gpa: std.mem.Allocator, io: Io, root: Dir, suffix: []const u8) !?[]u8 {
    var lowered: [reference.max_suffix]u8 = undefined;
    if (suffix.len > lowered.len) return null;
    const wanted = std.ascii.lowerString(lowered[0..suffix.len], suffix);

    const journals = try listJournals(gpa, io, root);
    defer {
        for (journals) |name| gpa.free(name);
        gpa.free(journals);
    }

    // listJournals is newest first, so the first match wins.
    for (journals) |name| {
        if (std.mem.endsWith(u8, name, wanted)) return try gpa.dupe(u8, name);
    }
    return null;
}

/// Resolves a journal selector for mutation. Unlike references, ambiguity is
/// an error because selecting the wrong result would append to the wrong
/// durable object.
pub fn findUniqueJournal(gpa: std.mem.Allocator, io: Io, root: Dir, suffix: []const u8) ![]u8 {
    var lowered: [reference.max_suffix]u8 = undefined;
    if (suffix.len == 0 or suffix.len > lowered.len) return error.NoSuchJournal;
    const wanted = std.ascii.lowerString(lowered[0..suffix.len], suffix);

    const journals = try listJournals(gpa, io, root);
    defer {
        for (journals) |name| gpa.free(name);
        gpa.free(journals);
    }

    var match: ?[]const u8 = null;
    for (journals) |name| {
        if (!std.mem.endsWith(u8, name, wanted)) continue;
        if (match != null) return error.AmbiguousJournal;
        match = name;
    }
    return gpa.dupe(u8, match orelse return error.NoSuchJournal);
}

/// Interaction numbers present in a journal, in numeric order.
pub fn listNumbers(gpa: std.mem.Allocator, io: Io, root: Dir, journal: []const u8) ![]u32 {
    var dir = try root.openDir(io, journal, .{ .iterate = true });
    defer dir.close(io);

    var found: std.ArrayList(u32) = .empty;
    errdefer found.deinit(gpa);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const number = parseInteractionDirName(entry.name) orelse continue;
        try found.append(gpa, number);
    }

    std.mem.sort(u32, found.items, {}, std.sort.asc(u32));
    return found.toOwnedSlice(gpa);
}

fn parseInteractionDirName(name: []const u8) ?u32 {
    if (name.len == 0 or name[0] == '0') return null;
    for (name) |char| if (!std.ascii.isDigit(char)) return null;
    return std.fmt.parseInt(u32, name, 10) catch null;
}

fn nextInteractionNumber(gpa: std.mem.Allocator, io: Io, root: Dir, journal: []const u8) !u32 {
    const numbers = try listNumbers(gpa, io, root, journal);
    defer gpa.free(numbers);
    if (numbers.len == 0) return 1;
    return std.math.add(u32, numbers[numbers.len - 1], 1) catch error.JournalFull;
}

fn testHome(tmp: *std.testing.TmpDir, io: Io, buf: []u8) ![]const u8 {
    const len = try tmp.dir.realPath(io, buf);
    return buf[0..len];
}

fn makeTestJournal(tmp: *std.testing.TmpDir, io: Io, id: ulid.Ulid, entries: []const []const u8) !void {
    try tmp.dir.createDir(io, &id, dir_permissions);
    var journal = try tmp.dir.openDir(io, &id, .{});
    defer journal.close(io);
    for (entries) |name| try journal.createDir(io, name, dir_permissions);
}

test "continuation resolves one journal and keeps newest reference lookup" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const older = ulid.encode(1, .{0} ** 10);
    const newer = ulid.encode(2, .{0} ** 10);
    try makeTestJournal(&tmp, io, older, &.{});
    try makeTestJournal(&tmp, io, newer, &.{});

    var root = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    defer root.close(io);

    const exact = try findUniqueJournal(gpa, io, root, &older);
    defer gpa.free(exact);
    try std.testing.expectEqualStrings(&older, exact);
    try std.testing.expectError(error.NoSuchJournal, findUniqueJournal(gpa, io, root, "nope"));
    try std.testing.expectError(error.AmbiguousJournal, findUniqueJournal(gpa, io, root, "0000"));

    const newest = (try findNewestJournal(gpa, io, root, "0000")).?;
    defer gpa.free(newest);
    try std.testing.expectEqualStrings(&newer, newest);
}

test "continued journals use the highest entry and are never removed as empty" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = try testHome(&tmp, io, &path_buf);

    const with_gap = ulid.encode(3, .{1} ** 10);
    try makeTestJournal(&tmp, io, with_gap, &.{ "1", "3", "03", "0", "not-an-entry" });
    var continued = try Store.continueJournal(gpa, io, home, &with_gap);
    try std.testing.expectEqual(@as(?u32, 4), continued.next_number);
    continued.close();

    var gap_dir = try tmp.dir.openDir(io, &with_gap, .{});
    gap_dir.close(io);

    const empty = ulid.encode(4, .{2} ** 10);
    try makeTestJournal(&tmp, io, empty, &.{});
    var empty_continue = try Store.continueJournal(gpa, io, home, &empty);
    try std.testing.expectEqual(@as(?u32, 1), empty_continue.next_number);
    empty_continue.close();
    var empty_dir = try tmp.dir.openDir(io, &empty, .{});
    empty_dir.close(io);
}

test "unfinished entries consume their numbers and full journals fail" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = try testHome(&tmp, io, &path_buf);

    const unfinished = ulid.encode(5, .{3} ** 10);
    try makeTestJournal(&tmp, io, unfinished, &.{ "1", "2" });
    var continued = try Store.continueJournal(gpa, io, home, &unfinished);
    try std.testing.expectEqual(@as(?u32, 3), continued.next_number);
    continued.close();

    const full = ulid.encode(6, .{4} ** 10);
    try makeTestJournal(&tmp, io, full, &.{"4294967295"});
    try std.testing.expectError(error.JournalFull, Store.continueJournal(gpa, io, home, &full));
}

test "journal writer locks are exclusive and released on close" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = try testHome(&tmp, io, &path_buf);

    const id = ulid.encode(7, .{5} ** 10);
    try makeTestJournal(&tmp, io, id, &.{"1"});
    var first = try Store.continueJournal(gpa, io, home, &id);
    try std.testing.expectError(error.JournalLocked, Store.continueJournal(gpa, io, home, &id));

    var root = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    const journals = try listJournals(gpa, io, root);
    defer {
        for (journals) |name| gpa.free(name);
        gpa.free(journals);
    }
    root.close(io);
    try std.testing.expectEqual(@as(usize, 1), journals.len);

    first.close();
    var second = try Store.continueJournal(gpa, io, home, &id);
    second.close();
}

/// Resource names inside one interaction. `meta.json` and the journal log are
/// tj's own bookkeeping and are never offered.
pub fn listResources(gpa: std.mem.Allocator, io: Io, root: Dir, journal: []const u8, number: u32) ![][]u8 {
    var path_buf: [64]u8 = undefined;
    const sub = try std.fmt.bufPrint(&path_buf, "{s}/{d}", .{ journal, number });

    var dir = try root.openDir(io, sub, .{ .iterate = true });
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
/// disk. A write failure stops recording for the journal; it never stops the
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
    for ([_][]const u8{
        "err",
        "files/data.csv",
        "a/b/c.txt",
        "files/.hidden",
        "files/name with spaces.txt",
        "files/glob*$?.txt",
        "files/quote's.txt",
    }) |path| {
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

    var store = try Store.createJournal(std.testing.allocator, io, path_buf[0..len]);
    store.warn("first warning, which is a long one", .{});
    store.warn("second", .{});
    store.warn("third", .{});

    const text = try store.journal_dir.readFileAlloc(io, "log", std.testing.allocator, .limited(4096));
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
        var store = try Store.createJournal(std.testing.allocator, io, path_buf[0..len]);
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

    var store = try Store.createJournal(std.testing.allocator, io, path_buf[0..len]);
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

test "metadata preserves every accepted resource beyond eight kibibytes" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buf);

    const long_mime =
        "application/x-test; title=\"quoted\\\\value\"; padding=" ++
        "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ++
        "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ++
        "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ++
        "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ++
        "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ++
        "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx";

    var store = try Store.createJournal(gpa, io, root_buf[0..root_len]);
    store.begin("demo", "expanded \"command\" with \\ and a newline\n");

    for (0..max_resources) |i| {
        var path_buf: [96]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "files/item-\"quoted\"-\\\\-{d}.dat", .{i});
        store.beginResource(path, long_mime);
        store.endResource();
        store.current.?.published[i].truncated = i % 3 == 0;
    }
    store.finish(0);

    const meta = try store.journal_dir.readFileAlloc(io, "1/meta.json", gpa, .limited(64 * 1024));
    defer gpa.free(meta);
    store.close();

    try std.testing.expect(meta.len > 8 * 1024);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, meta, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expect(root.get("started").?.string.len > 0);
    try std.testing.expect(root.get("ended").?.string.len > 0);
    try std.testing.expectEqualStrings("expanded \"command\" with \\ and a newline\n", root.get("expanded_cmd").?.string);

    const resources = root.get("resources").?.object;
    try std.testing.expectEqual(max_resources, resources.count());
    for (0..max_resources) |i| {
        var path_buf: [96]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "files/item-\"quoted\"-\\\\-{d}.dat", .{i});
        const entry = resources.get(path).?.object;
        try std.testing.expectEqualStrings(long_mime, entry.get("mime").?.string);
        try std.testing.expectEqual(i % 3 == 0, entry.get("truncated").?.bool);
    }
}

// --- reading back what a journal recorded ------------------------------------

/// When an interaction ran, as milliseconds since the epoch.
pub const Timing = struct {
    started: i64,
    ended: i64,

    /// How long the command itself took.
    pub fn duration(self: Timing) i64 {
        return @max(0, self.ended - self.started);
    }
};

/// Reads the timings an interaction recorded. Absent or unparseable metadata
/// is not an error: replaying without pacing is better than not replaying.
pub fn readTiming(gpa: std.mem.Allocator, io: Io, root: Dir, journal: []const u8, number: u32) ?Timing {
    var path_buf: [64]u8 = undefined;
    const sub = std.fmt.bufPrint(&path_buf, "{s}/{d}/meta.json", .{ journal, number }) catch return null;

    const text = root.readFileAlloc(io, sub, gpa, .limited(64 * 1024)) catch return null;
    defer gpa.free(text);

    const Meta = struct { started: []const u8 = "", ended: []const u8 = "" };
    const parsed = std.json.parseFromSlice(Meta, gpa, text, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();

    return .{
        .started = parseTimestamp(parsed.value.started) orelse return null,
        .ended = parseTimestamp(parsed.value.ended) orelse return null,
    };
}

/// The inverse of `formatTimestamp`. Only the exact shape tj writes is
/// accepted: `2026-08-27T16:15:10.502Z`.
pub fn parseTimestamp(text: []const u8) ?i64 {
    if (text.len != 24 or text[4] != '-' or text[7] != '-' or text[10] != 'T') return null;
    if (text[13] != ':' or text[16] != ':' or text[19] != '.' or text[23] != 'Z') return null;

    const year = parseDigits(text[0..4]) orelse return null;
    const month = parseDigits(text[5..7]) orelse return null;
    const day = parseDigits(text[8..10]) orelse return null;
    const hour = parseDigits(text[11..13]) orelse return null;
    const minute = parseDigits(text[14..16]) orelse return null;
    const second = parseDigits(text[17..19]) orelse return null;
    const millis = parseDigits(text[20..23]) orelse return null;

    if (month < 1 or month > 12 or day < 1 or day > 31) return null;
    if (hour > 23 or minute > 59 or second > 60) return null;

    const days = daysFromCivil(year, @intCast(month), @intCast(day));
    return ((days * 24 + hour) * 60 + minute) * 60 * 1000 + second * 1000 + millis;
}

fn parseDigits(text: []const u8) ?i64 {
    var value: i64 = 0;
    for (text) |char| {
        if (!std.ascii.isDigit(char)) return null;
        value = value * 10 + (char - '0');
    }
    return value;
}

/// Days since 1970-01-01, by Howard Hinnant's civil-date algorithm: it shifts
/// the year to start in March so the leap day falls at the end, which removes
/// every special case.
fn daysFromCivil(year: i64, month: u32, day: u32) i64 {
    const shifted = year - @as(i64, if (month <= 2) 1 else 0);
    const era = @divFloor(if (shifted >= 0) shifted else shifted - 399, 400);
    const year_of_era = shifted - era * 400;
    const month_shift: i64 = if (month > 2) -3 else 9;
    const day_of_year = @divFloor(153 * (@as(i64, month) + month_shift) + 2, 5) + @as(i64, day) - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100) + day_of_year;
    return era * 146097 + day_of_era - 719468;
}

test "a timestamp survives the round trip the journal puts it through" {
    var buf: [32]u8 = undefined;
    for ([_]i64{ 0, 1000, 1787753002117, 1709208000500, 1767225599999 }) |millis| {
        try std.testing.expectEqual(millis, parseTimestamp(formatTimestamp(millis, &buf)).?);
    }
}

test "malformed timestamps are refused rather than guessed at" {
    for ([_][]const u8{
        "",
        "2026-08-27",
        "2026-08-27T16:15:10Z",
        "2026-08-27 16:15:10.502Z",
        "20x6-08-27T16:15:10.502Z",
        "2026-13-27T16:15:10.502Z",
        "2026-08-00T16:15:10.502Z",
        "2026-08-27T25:15:10.502Z",
    }) |text| {
        try std.testing.expect(parseTimestamp(text) == null);
    }
}
