//! The on-disk journal.
//!
//!     $TJ_HOME/                 default ~/.tj
//!     └── <journal-name>/
//!         ├── log               warnings from this journal, if any
//!         └── 1/
//!             ├── cmd           the command line as entered
//!             ├── cwd           absolute logical working directory
//!             ├── out           what the terminal saw
//!             ├── prompt        prompt drawn before the command
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
const journal_name = @import("journal_name.zig");
const altscreen = @import("altscreen.zig");
const annotations = @import("annotations.zig");
const mutation_lock = @import("mutation_lock.zig");

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

/// Diagnostics must not become a second unbounded recording stream. Keep a
/// small journal-wide byte ceiling and stop after a bounded number of warning
/// writes in any one writer run.
const max_log_bytes: u64 = 64 * 1024;
const max_log_warnings: usize = 64;
const log_suppression_notice = "further journal warnings suppressed\n";
const max_prompt_bytes = 64 * 1024;
const prompt_end_st = "\x1b]133;B\x1b\\";
const prompt_end_bel = "\x1b]133;B\x07";

/// Recorded once for a visible region deliberately omitted from `out`.
pub const noout_placeholder = "<tj:noout>";

/// tj's own bookkeeping, which a program may not overwrite by publishing a
/// resource with the same name.
const reserved_names = [_][]const u8{ "cmd", "cwd", "out", "prompt", "rc", "meta.json", "out.removed", ".meta.tmp", "log" };

const PromptState = enum { idle, capturing, ready };

pub const Store = struct {
    io: Io,
    gpa: std.mem.Allocator,
    root: Dir,
    journal_dir: Dir,
    journal: []u8,
    lock_file: File,
    origin: Origin,
    next_number: ?u32 = 1,
    current: ?Interaction = null,
    out_buffer: []u8,
    /// Opened lazily on the first warning and reused so malformed protocol on
    /// the PTY hot path does not open and stat the log for every marker.
    log_file: ?File = null,
    log_bytes: u64 = 0,
    warning_count: usize = 0,
    warnings_suppressed: bool = false,
    pending_prompt: std.ArrayList(u8) = .empty,
    prompt_state: PromptState = .idle,
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

        /// OSC SLOT permits one non-nesting resource or noout region.
        open_region: ?OpenRegion = null,
        published: [max_resources]Published = undefined,
        published_count: usize = 0,
    };

    const OpenRegion = union(enum) {
        resource: OpenResource,
        noout,
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
        return createNamedJournal(gpa, io, home_override, null);
    }

    pub fn createNamedJournal(gpa: std.mem.Allocator, io: Io, home_override: ?[]const u8, requested_name: ?[]const u8) !Store {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const root_path = try resolveRoot(home_override, &path_buf);

        const root = try openOrCreateRoot(io, root_path);
        errdefer root.close(io);
        const namespace = try mutation_lock.acquireNamespace(io, root);
        defer namespace.close(io);

        if (requested_name) |name| if (!journal_name.isValid(name)) return error.InvalidJournalName;
        var attempts: usize = 0;
        candidate: while (attempts < 8) : (attempts += 1) {
            const generated = journal_name.generate(io);
            const id = requested_name orelse &generated;
            if (root.statFile(io, id, .{ .follow_symlinks = false })) |_| {
                if (requested_name == null) continue;
                return error.JournalExists;
            } else |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            }

            // Own the lifetime name before making the directory visible.
            // The namespace guard keeps another create/use/mv/rm from
            // observing the candidate between these two operations.
            const lock_file = acquireJournalLock(io, root, id) catch |err| {
                if (requested_name == null and err == error.JournalLocked) continue;
                return err;
            };

            root.createDir(io, id, dir_permissions) catch |err| {
                lock_file.close(io);
                removeLockFile(io, root, id);
                switch (err) {
                    error.PathAlreadyExists => if (requested_name == null) continue :candidate else return error.JournalExists,
                    else => return err,
                }
            };
            errdefer lock_file.close(io);
            errdefer removeLockFile(io, root, id);
            errdefer root.deleteDir(io, id) catch {};

            const journal_dir = try root.openDir(io, id, .{ .iterate = true });
            errdefer journal_dir.close(io);

            const out_buffer = try gpa.alloc(u8, out_buffer_size);
            errdefer gpa.free(out_buffer);
            const owned_id = try gpa.dupe(u8, id);
            return .{
                .io = io,
                .gpa = gpa,
                .root = root,
                .journal_dir = journal_dir,
                .journal = owned_id,
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
        const namespace = try mutation_lock.acquireNamespace(io, root);
        defer namespace.close(io);

        const selected = try findUniqueJournal(gpa, io, root, selector);
        defer gpa.free(selected);
        const id = try gpa.dupe(u8, selected);
        errdefer gpa.free(id);

        const lock_file = try acquireJournalLock(io, root, id);
        errdefer lock_file.close(io);

        // Re-open only after the lock is held. Future pruning uses the same
        // lock, so the selected directory cannot disappear between these two
        // operations.
        const journal_dir = root.openDir(io, id, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return error.NoSuchJournal,
            else => return err,
        };
        errdefer journal_dir.close(io);

        const next_number = try nextInteractionNumber(gpa, io, root, id);
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
        if (self.log_file) |file| file.close(self.io);
        self.log_file = null;
        self.journal_dir.close(self.io);

        // Only the invocation that created a journal may remove it as empty
        // noise. A continued journal is persistent even when it stays empty.
        const removed = self.origin == .created and blk: {
            self.root.deleteDir(self.io, self.journal) catch break :blk false;
            break :blk true;
        };

        self.lock_file.close(self.io);
        if (removed) removeLockFile(self.io, self.root, self.journal);

        self.root.close(self.io);
        self.gpa.free(self.out_buffer);
        self.gpa.free(self.journal);
        self.pending_prompt.deinit(self.gpa);
    }

    pub fn isRecording(self: *const Store) bool {
        return self.current != null;
    }

    /// Whether this journal had an entry when the writer attached or opened
    /// one during this run. `next_number` advances only after the entry's core
    /// files have been created successfully.
    pub fn hasRecordedEntry(self: *const Store) bool {
        return self.current != null or self.next_number == null or self.next_number.? != 1;
    }

    /// The exact journal selected and locked by this writer.
    pub fn journalId(self: *const Store) []const u8 {
        return self.journal;
    }

    /// Opens interaction N and writes `cmd` immediately, so a journal that
    /// dies mid-command still shows what was running.
    pub fn begin(self: *Store, cmd: []const u8, expanded: ?[]const u8, cwd: ?[]const u8) void {
        defer self.discardPrompt();
        if (self.disabled) return;
        if (self.current != null) self.finish(null);

        const number = self.next_number orelse {
            self.warn("journal has no entry numbers left", .{});
            self.disabled = true;
            return;
        };

        var name_buf: [16]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "{d}", .{number}) catch return;

        const prompt = if (self.prompt_state == .ready) self.pending_prompt.items else null;
        self.beginFallible(number, name, cmd, expanded, cwd, prompt) catch |err| {
            self.warn("cannot start entry {s}: {t}", .{ name, err });
            self.disable();
        };
    }

    fn beginFallible(
        self: *Store,
        number: u32,
        name: []const u8,
        cmd: []const u8,
        expanded: ?[]const u8,
        cwd: ?[]const u8,
        prompt: ?[]const u8,
    ) !void {
        try self.journal_dir.createDir(self.io, name, dir_permissions);
        var dir = try self.journal_dir.openDir(self.io, name, .{});
        errdefer dir.close(self.io);

        try dir.writeFile(self.io, .{
            .sub_path = "cmd",
            .data = cmd,
            .flags = .{ .permissions = file_permissions },
        });
        if (cwd) |path| try dir.writeFile(self.io, .{
            .sub_path = "cwd",
            .data = path,
            .flags = .{ .permissions = file_permissions },
        });
        if (prompt) |bytes| try dir.writeFile(self.io, .{
            .sub_path = "prompt",
            .data = bytes,
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
        if (self.prompt_state == .capturing) {
            if (bytes.len > max_prompt_bytes - self.pending_prompt.items.len) {
                self.discardPrompt();
                self.warn("prompt exceeded the {d}-byte limit", .{max_prompt_bytes});
                return;
            }
            self.pending_prompt.appendSlice(self.gpa, bytes) catch {
                self.discardPrompt();
                self.warn("cannot buffer prompt", .{});
            };
            return;
        }

        const current = &(self.current orelse return);

        if (current.open_region) |*region| switch (region.*) {
            // The proxy has already forwarded these bytes to the terminal.
            // They bypass both resource capture and the alternate-screen
            // filter, and deliberately leave no metadata counters behind.
            .noout => return,
            // Before the full-screen filter, not after: publishing a resource
            // is deliberate, so it is kept whatever the screen was doing.
            .resource => |*open| self.appendResource(current, open, bytes),
        };

        var sink: OutputSink = .{ .store = self, .interaction = current };
        current.fullscreen.feed(bytes, &sink);
    }

    /// Starts retaining the exact terminal bytes zsh renders as its next
    /// prompt. A prompt is pending until a later command receives its number.
    pub fn promptStart(self: *Store) void {
        self.finish(null);
        if (self.disabled) {
            self.discardPrompt();
            return;
        }
        self.pending_prompt.clearRetainingCapacity();
        self.prompt_state = .capturing;
    }

    /// Completes a pending prompt. OSC 133 is forwarded before its event is
    /// reported, so remove the trailing B marker from the captured bytes.
    pub fn promptEnd(self: *Store) void {
        if (self.prompt_state != .capturing) return;
        if (std.mem.endsWith(u8, self.pending_prompt.items, prompt_end_st)) {
            self.pending_prompt.shrinkRetainingCapacity(self.pending_prompt.items.len - prompt_end_st.len);
        } else if (std.mem.endsWith(u8, self.pending_prompt.items, prompt_end_bel)) {
            self.pending_prompt.shrinkRetainingCapacity(self.pending_prompt.items.len - prompt_end_bel.len);
        } else {
            self.discardPrompt();
            self.warn("prompt end marker was not captured", .{});
            return;
        }
        self.prompt_state = .ready;
    }

    fn discardPrompt(self: *Store) void {
        self.pending_prompt.clearRetainingCapacity();
        self.prompt_state = .idle;
    }

    /// Starts capturing output as a named resource of this interaction. The
    /// bytes stay in `out` as well; the resource is a span of it.
    pub fn beginResource(self: *Store, path: []const u8, mime: []const u8) void {
        if (self.disabled) return;
        const current = &(self.current orelse {
            // Printed by precmd, or by something outside any command.
            self.warn("resource {s} published with no entry open", .{path});
            return;
        });

        if (current.open_region != null) {
            // No nesting in v1. The open one keeps going.
            self.warn("resource {s} published while another region is open", .{path});
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

        current.open_region = .{ .resource = .{
            .file = file,
            .entry = try self.recordPublished(current, path, mime),
        } };
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

    fn appendResource(self: *Store, current: *Interaction, open: *OpenResource, bytes: []const u8) void {
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
            current.open_region = null;
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

    /// Starts a visible region that is represented in `out` only by the fixed
    /// placeholder. State is opened only after that placeholder is durable in
    /// the interaction's buffered stream.
    pub fn beginNoout(self: *Store) void {
        if (self.disabled) return;
        const current = &(self.current orelse {
            self.warn("noout region opened with no entry open", .{});
            return;
        });
        if (current.open_region != null) {
            self.warn("noout region opened while another region is open", .{});
            return;
        }
        current.writer.interface.writeAll(noout_placeholder) catch |err| {
            self.warn("cannot write noout placeholder: {t}", .{err});
            self.disable();
            return;
        };
        current.open_region = .noout;
    }

    /// The OSC end marker is generic: it closes either kind of open region.
    pub fn endRegion(self: *Store) void {
        const current = &(self.current orelse return);
        if (current.open_region == null) {
            self.warn("region end with none open", .{});
            return;
        }
        switch (current.open_region.?) {
            .resource => |*open| {
                self.flushResourceTail(open);
                open.file.close(self.io);
            },
            .noout => {},
        }
        current.open_region = null;
    }

    /// Clears an unfinished region at the interaction boundary. Resources are
    /// marked truncated; noout needs no metadata and is simply forgotten.
    fn closeOpenRegion(self: *Store, current: *Interaction) void {
        if (current.open_region == null) return;
        switch (current.open_region.?) {
            .resource => |*open| {
                self.flushResourceTail(open);
                current.published[open.entry].truncated = true;
                open.file.close(self.io);
            },
            .noout => {},
        }
        current.open_region = null;
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

        self.closeOpenRegion(&current);
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
            self.closeOpenRegion(current);
            current.file.close(self.io);
            current.dir.close(self.io);
            self.current = null;
        }
    }

    /// Appends to `$TJ_HOME/<journal>/log`. Best effort: if even this fails
    /// there is nothing useful left to do about it. The handle and current
    /// length are cached after the first warning, and both a per-run warning
    /// count and a journal-wide byte ceiling keep hostile protocol output from
    /// turning this diagnostic path into an unbounded recording stream.
    pub fn warn(self: *Store, comptime fmt: []const u8, args: anytype) void {
        if (self.warnings_suppressed) return;
        if (self.warning_count >= max_log_warnings) {
            _ = self.appendLog(log_suppression_notice);
            self.stopLogging();
            return;
        }

        var buf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
        self.warning_count += 1;
        if (!self.appendLog(line)) self.stopLogging();
    }

    fn appendLog(self: *Store, line: []const u8) bool {
        if (self.log_file == null) {
            const file = self.journal_dir.createFile(self.io, "log", .{
                .truncate = false,
                .permissions = file_permissions,
            }) catch return false;
            const end = file.length(self.io) catch {
                file.close(self.io);
                return false;
            };
            if (end >= max_log_bytes) {
                file.close(self.io);
                return false;
            }
            self.log_file = file;
            self.log_bytes = end;
        }

        const remaining = max_log_bytes - self.log_bytes;
        const line_len: u64 = @intCast(line.len);
        if (line_len > remaining) return false;
        const file = self.log_file orelse return false;
        file.writePositionalAll(self.io, line, self.log_bytes) catch return false;
        self.log_bytes += line_len;
        return true;
    }

    fn stopLogging(self: *Store) void {
        self.warnings_suppressed = true;
        if (self.log_file) |file| file.close(self.io);
        self.log_file = null;
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
    var path_buf: [journal_name.max_len + 16]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, ".locks/{s}", .{journal}) catch return;
    root.deleteFile(io, path) catch {};
}

pub fn openRoot(io: Io, home_override: ?[]const u8) !Dir {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try resolveRoot(home_override, &buf);
    return Dir.cwd().openDir(io, path, .{ .iterate = true });
}

/// Canonical journal names, in lexical order. Names carry no ordering
/// semantics.
pub fn listJournals(gpa: std.mem.Allocator, io: Io, root: Dir) ![][]const u8 {
    var found: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (found.items) |name| gpa.free(name);
        found.deinit(gpa);
    }

    var it = root.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (!journal_name.isValid(entry.name)) continue;
        try found.append(gpa, try gpa.dupe(u8, entry.name));
    }

    std.mem.sort([]const u8, found.items, {}, struct {
        fn lexical(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lexical);

    return found.toOwnedSlice(gpa);
}

pub const InteractionInfo = struct {
    number: u32,
    /// Absent means the interaction never completed.
    exit_code: ?u8,
    command: []const u8,
    /// So a reader can tell what fetching `out` would cost before doing it.
    out_bytes: u64,
    /// Distinguishes an empty output from one explicitly removed.
    out_present: bool,

    pub fn deinit(self: InteractionInfo, gpa: std.mem.Allocator) void {
        gpa.free(self.command);
    }
};

pub const EntryUsage = struct {
    number: u32,
    bytes: u64,
};

pub const JournalUsage = struct {
    total_bytes: u64,
    entries: []EntryUsage,

    pub fn deinit(self: JournalUsage, gpa: std.mem.Allocator) void {
        gpa.free(self.entries);
    }
};

/// Sums logical file lengths, not allocated filesystem blocks. Directories
/// contribute no bytes of their own; symlinks contribute the length of the
/// link itself and are never followed.
pub fn measureJournalUsage(
    gpa: std.mem.Allocator,
    io: Io,
    root: Dir,
    journal: []const u8,
) !JournalUsage {
    var dir = try root.openDir(io, journal, .{ .iterate = true });
    defer dir.close(io);

    var entries: std.ArrayList(EntryUsage) = .empty;
    errdefer entries.deinit(gpa);
    var total: u64 = 0;

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        var kind = entry.kind;
        var file_size: ?u64 = null;
        if (kind == .unknown) {
            const stat = try dir.statFile(io, entry.name, .{ .follow_symlinks = false });
            kind = stat.kind;
            file_size = stat.size;
        }

        if (kind == .directory) {
            var child = try dir.openDir(io, entry.name, .{ .iterate = true });
            defer child.close(io);
            const bytes = try directoryLogicalBytes(gpa, io, child);
            total +|= bytes;
            if (parseInteractionDirName(entry.name)) |number| {
                try entries.append(gpa, .{ .number = number, .bytes = bytes });
            }
            continue;
        }

        const bytes = file_size orelse blk: {
            const stat = try dir.statFile(io, entry.name, .{ .follow_symlinks = false });
            break :blk stat.size;
        };
        total +|= bytes;
    }

    std.mem.sort(EntryUsage, entries.items, {}, struct {
        fn byNumber(_: void, a: EntryUsage, b: EntryUsage) bool {
            return a.number < b.number;
        }
    }.byNumber);

    return .{ .total_bytes = total, .entries = try entries.toOwnedSlice(gpa) };
}

fn directoryLogicalBytes(gpa: std.mem.Allocator, io: Io, dir: Dir) !u64 {
    var walker = try dir.walkSelectively(gpa);
    defer walker.deinit();

    var total: u64 = 0;
    while (try walker.next(io)) |entry| {
        var resolved = entry;
        var file_size: ?u64 = null;
        if (resolved.kind == .unknown) {
            const stat = try resolved.dir.statFile(io, resolved.basename, .{ .follow_symlinks = false });
            resolved.kind = stat.kind;
            file_size = stat.size;
        }
        if (resolved.kind == .directory) {
            try walker.enter(io, resolved);
            continue;
        }
        const bytes = file_size orelse blk: {
            const stat = try resolved.dir.statFile(io, resolved.basename, .{ .follow_symlinks = false });
            break :blk stat.size;
        };
        total +|= bytes;
    }
    return total;
}

/// Reads one entry's listing facts. Returns null when the directory is gone,
/// which a concurrent removal can produce between listing numbers and reading
/// one of them.
///
/// Listings render only `firstLine` of a command, truncated to a terminal
/// width, so reading a whole heredoc to print eighty columns of it is waste.
/// `command_limit` lets a listing ask for a bounded prefix while `tj cat` and
/// anything else needing the real command reads it in full elsewhere.
pub fn readInteraction(
    gpa: std.mem.Allocator,
    io: Io,
    root: Dir,
    journal: []const u8,
    number: u32,
    command_limit: usize,
) !?InteractionInfo {
    var path_buf: [journal_name.max_len + 32]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{d}", .{ journal, number }) catch return null;
    var interaction = root.openDir(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        else => |other| return other,
    };
    defer interaction.close(io);

    const command = if (command_limit == 0)
        try gpa.dupe(u8, "")
    else
        interaction.readFileAlloc(io, "cmd", gpa, .limited(command_limit)) catch
            try gpa.dupe(u8, "");
    errdefer gpa.free(command);

    var out_bytes: u64 = 0;
    var out_present = false;
    if (interaction.openFile(io, "out", .{})) |file| {
        defer file.close(io);
        out_present = true;
        out_bytes = file.length(io) catch 0;
    } else |_| {}

    return .{
        .number = number,
        .exit_code = readExitCode(io, interaction),
        .command = command,
        .out_bytes = out_bytes,
        .out_present = out_present,
    };
}

/// The whole command, for callers that render more than a listing line.
pub const full_command_limit = 64 * 1024;

/// Enough to hold the first line of a command at any realistic terminal width.
/// A longer first line is truncated in listings only.
pub const listing_command_limit = 4 * 1024;

/// For callers that need an entry's numbers and status but never its command.
pub const no_command = 0;

/// Yields one interaction at a time in numeric order. Only the entry numbers
/// stay resident, so peak memory does not grow with a journal's recorded
/// command sizes. The caller owns each yielded value.
pub const InteractionIterator = struct {
    gpa: std.mem.Allocator,
    io: Io,
    root: Dir,
    journal: []const u8,
    numbers: []u32,
    index: usize = 0,
    command_limit: usize,

    pub fn deinit(self: *InteractionIterator) void {
        self.gpa.free(self.numbers);
        self.* = undefined;
    }

    pub fn count(self: *const InteractionIterator) usize {
        return self.numbers.len;
    }

    pub fn next(self: *InteractionIterator) !?InteractionInfo {
        while (self.index < self.numbers.len) {
            const number = self.numbers[self.index];
            self.index += 1;
            if (try readInteraction(
                self.gpa,
                self.io,
                self.root,
                self.journal,
                number,
                self.command_limit,
            )) |info| return info;
        }
        return null;
    }
};

pub fn iterateInteractions(
    gpa: std.mem.Allocator,
    io: Io,
    root: Dir,
    journal: []const u8,
    command_limit: usize,
) !InteractionIterator {
    return .{
        .gpa = gpa,
        .io = io,
        .root = root,
        .journal = journal,
        .numbers = try listNumbers(gpa, io, root, journal),
        .command_limit = command_limit,
    };
}

/// How many entries a journal still holds, without reading any of them.
pub fn countInteractions(gpa: std.mem.Allocator, io: Io, root: Dir, journal: []const u8) !usize {
    const numbers = try listNumbers(gpa, io, root, journal);
    defer gpa.free(numbers);
    return numbers.len;
}

/// Interactions of one journal, in numeric order. Prefer `iterateInteractions`
/// unless the whole set genuinely has to be resident at once.
pub fn listInteractions(gpa: std.mem.Allocator, io: Io, root: Dir, journal: []const u8) ![]InteractionInfo {
    var it = try iterateInteractions(gpa, io, root, journal, full_command_limit);
    defer it.deinit();

    var found: std.ArrayList(InteractionInfo) = .empty;
    errdefer {
        for (found.items) |info| info.deinit(gpa);
        found.deinit(gpa);
    }
    while (try it.next()) |info| {
        errdefer info.deinit(gpa);
        try found.append(gpa, info);
    }
    return found.toOwnedSlice(gpa);
}

/// Reads only numeric directory names, for callers that need to align entry
/// references without loading every command and output size first.
pub fn highestEntryNumber(io: Io, root: Dir, journal: []const u8) !?u32 {
    var dir = try root.openDir(io, journal, .{ .iterate = true });
    defer dir.close(io);

    var highest: ?u32 = null;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const number = parseInteractionDirName(entry.name) orelse continue;
        if (highest == null or number > highest.?) highest = number;
    }
    return highest;
}

/// The highest interaction that actually completed. `@-` resolves to this, so
/// a command reading `@-/out` never picks up the one running it.
pub fn lastCompleted(gpa: std.mem.Allocator, io: Io, root: Dir, journal: []const u8) !?u32 {
    const numbers = try listNumbers(gpa, io, root, journal);
    defer gpa.free(numbers);

    // The shell integration resolves `@-` for every command line mentioning
    // it, so walk down from the newest and stop at the first entry that has an
    // exit code rather than reading the whole journal to sort it.
    var index = numbers.len;
    while (index > 0) {
        index -= 1;
        const number = numbers[index];
        var path_buf: [journal_name.max_len + 32]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{d}", .{ journal, number }) catch continue;
        var interaction = root.openDir(io, path, .{}) catch continue;
        defer interaction.close(io);
        if (readExitCode(io, interaction) != null) return number;
    }
    return null;
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
pub fn formatTimestamp(millis: i64, buf: []u8) []const u8 {
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
        .qualified => |q| try findUniqueJournal(gpa, io, root, q.suffix),
    };
    errdefer gpa.free(journal);

    const target: reference.Target = switch (ref.body) {
        .current => |value| value,
        .qualified => |q| q.target,
        .previous => .{ .number = try lastCompleted(gpa, io, root, journal) orelse return error.NothingCompleted },
    };
    const number: u32 = switch (target) {
        .number => |value| value,
        .name => |name| blk: {
            var metadata = try annotations.openRead(gpa, io, root, journal);
            defer metadata.deinit(gpa);
            break :blk try metadata.numberForName(name) orelse return error.NoSuchInteraction;
        },
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

/// Resolves every journal selector exact-first, then by unique suffix.
pub fn findUniqueJournal(gpa: std.mem.Allocator, io: Io, root: Dir, suffix: []const u8) ![]u8 {
    if (!journal_name.isValid(suffix)) return error.NoSuchJournal;

    const journals = try listJournals(gpa, io, root);
    defer {
        for (journals) |name| gpa.free(name);
        gpa.free(journals);
    }

    var match: ?[]const u8 = null;
    for (journals) |name| {
        if (std.mem.eql(u8, name, suffix)) return gpa.dupe(u8, name);
    }
    for (journals) |name| {
        if (!std.mem.endsWith(u8, name, suffix)) continue;
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

pub fn interactionExists(io: Io, root: Dir, journal: []const u8, number: u32) bool {
    var path_buf: [journal_name.max_len + 32]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{d}", .{ journal, number }) catch return false;
    var dir = root.openDir(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

pub fn highestNumber(gpa: std.mem.Allocator, io: Io, root: Dir, journal: []const u8) !?u32 {
    const numbers = try listNumbers(gpa, io, root, journal);
    defer gpa.free(numbers);
    return if (numbers.len == 0) null else numbers[numbers.len - 1];
}

/// Makes an interaction disappear atomically from the journal namespace.
/// Annotation cleanup happens after this rename; stale annotations are hidden
/// by readers and pruned by the next mutation if that later write fails.
pub fn stageInteractionRemoval(
    gpa: std.mem.Allocator,
    io: Io,
    root: Dir,
    journal: []const u8,
    number: u32,
) ![]u8 {
    var journal_dir = try root.openDir(io, journal, .{ .follow_symlinks = false });
    defer journal_dir.close(io);
    _ = journal_dir.createDir(io, ".trash", dir_permissions) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    var trash = try journal_dir.openDir(io, ".trash", .{ .follow_symlinks = false });
    defer trash.close(io);

    const staged = try std.fmt.allocPrint(gpa, "{s}/.trash/{d}.interaction", .{ journal, number });
    errdefer gpa.free(staged);
    var trash_name_buf: [32]u8 = undefined;
    const trash_name = try std.fmt.bufPrint(&trash_name_buf, "{d}.interaction", .{number});
    try deleteOptionalEntry(io, trash, trash_name);
    var number_buf: [16]u8 = undefined;
    const source = try std.fmt.bufPrint(&number_buf, "{d}", .{number});
    var source_dir = try journal_dir.openDir(io, source, .{ .follow_symlinks = false });
    source_dir.close(io);
    try journal_dir.rename(source, trash, trash_name, io);
    return staged;
}

pub fn finishStagedRemoval(io: Io, root: Dir, staged: []const u8) !void {
    try root.deleteTree(io, staged);
}

pub fn cleanupJournalTrash(io: Io, root: Dir, journal: []const u8) void {
    var path_buf: [journal_name.max_len + 32]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/.trash", .{journal}) catch return;
    root.deleteTree(io, path) catch {};
}

pub fn recoverPendingOutputRemovals(
    gpa: std.mem.Allocator,
    io: Io,
    root: Dir,
    journal: []const u8,
) !void {
    const numbers = try listNumbers(gpa, io, root, journal);
    defer gpa.free(numbers);
    for (numbers) |number| {
        var marker_buf: [96]u8 = undefined;
        const marker_path = try std.fmt.bufPrint(&marker_buf, "{s}/{d}/out.removed", .{ journal, number });
        const marker = root.openFile(io, marker_path, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        marker.close(io);
        if (outputRemovalComplete(gpa, io, root, journal, number)) continue;
        try removeOutput(gpa, io, root, journal, number);
    }
}

fn outputRemovalComplete(
    gpa: std.mem.Allocator,
    io: Io,
    root: Dir,
    journal: []const u8,
    number: u32,
) bool {
    var path_buf: [96]u8 = undefined;
    const out_path = std.fmt.bufPrint(&path_buf, "{s}/{d}/out", .{ journal, number }) catch return false;
    if (root.openFile(io, out_path, .{})) |file| {
        file.close(io);
        return false;
    } else |_| {}

    const meta_path = std.fmt.bufPrint(&path_buf, "{s}/{d}/meta.json", .{ journal, number }) catch return false;
    const text = root.readFileAlloc(io, meta_path, gpa, .limited(4 * 1024 * 1024)) catch return false;
    defer gpa.free(text);
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, text, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object or parsed.value.object.get("resources") != null) return false;
    const removed = parsed.value.object.get("out_removed") orelse return false;
    return removed == .bool and removed.bool;
}

/// Removes output and every resource derived from it. `out.removed` is the
/// one-way boundary: once it exists, retrying this function only completes the
/// same deletion.
pub fn removeOutput(
    gpa: std.mem.Allocator,
    io: Io,
    root: Dir,
    journal: []const u8,
    number: u32,
) !void {
    var journal_dir = try root.openDir(io, journal, .{ .follow_symlinks = false });
    defer journal_dir.close(io);
    var number_buf: [16]u8 = undefined;
    const interaction_name = try std.fmt.bufPrint(&number_buf, "{d}", .{number});
    var interaction = try journal_dir.openDir(io, interaction_name, .{ .follow_symlinks = false });
    defer interaction.close(io);

    const meta_text = interaction.readFileAlloc(io, "meta.json", gpa, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.InvalidMetadata,
        else => return err,
    };
    defer gpa.free(meta_text);
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, meta_text, .{}) catch return error.InvalidMetadata;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidMetadata;

    const resources_value = parsed.value.object.get("resources");
    if (resources_value) |resources| {
        if (resources != .object) return error.InvalidMetadata;
        var validate = resources.object.iterator();
        while (validate.next()) |item| {
            if (!validResourcePath(item.key_ptr.*)) return error.InvalidMetadata;
        }
    }

    try validateOptionalFile(io, interaction, "out");
    if (resources_value) |resources| {
        var validate = resources.object.iterator();
        while (validate.next()) |item| try validateOptionalFile(io, interaction, item.key_ptr.*);
    }

    const marker = interaction.createFile(io, "out.removed", .{
        .exclusive = true,
        .permissions = file_permissions,
    }) catch |err| switch (err) {
        error.PathAlreadyExists => blk: {
            const stat = try interaction.statFile(io, "out.removed", .{ .follow_symlinks = false });
            if (stat.kind != .file) return error.InvalidMetadata;
            break :blk null;
        },
        else => return err,
    };
    if (marker) |file| {
        try file.sync(io);
        file.close(io);
    }

    _ = journal_dir.createDir(io, ".trash", dir_permissions) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    var trash = try journal_dir.openDir(io, ".trash", .{ .iterate = true, .follow_symlinks = false });
    defer trash.close(io);

    var out_dest_buf: [32]u8 = undefined;
    const out_dest = try std.fmt.bufPrint(&out_dest_buf, "{d}.0", .{number});
    try stageOptional(io, interaction, trash, "out", out_dest);
    if (resources_value) |resources| {
        var it = resources.object.iterator();
        var index: usize = 1;
        while (it.next()) |item| : (index += 1) {
            var dest_buf: [32]u8 = undefined;
            const dest = try std.fmt.bufPrint(&dest_buf, "{d}.{d}", .{ number, index });
            try stageOptional(io, interaction, trash, item.key_ptr.*, dest);
            removeEmptyResourceParents(io, interaction, item.key_ptr.*);
        }
    }

    _ = parsed.value.object.orderedRemove("resources");
    try parsed.value.object.put(parsed.arena.allocator(), "out_removed", .{ .bool = true });
    try writeJsonAtomic(gpa, io, interaction, "meta.json", ".meta.tmp", parsed.value);

    // All staged paths have names beginning with this interaction number. The
    // mutation lock prevents another remover from sharing the staging area.
    var it = trash.iterate();
    var prefix_buf: [24]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&prefix_buf, "{d}.", .{number});
    while (try it.next(io)) |entry| {
        if (!std.mem.startsWith(u8, entry.name, prefix)) continue;
        deleteOptionalEntry(io, trash, entry.name) catch {};
    }
}

/// Moves one output-derived file using directory handles opened without
/// following symlinks. Metadata is user-visible and may have been edited, so
/// lexical path validation alone is not a sufficient deletion boundary.
fn stageOptional(io: Io, source_dir: Dir, trash: Dir, source_subpath: []const u8, index: []const u8) !void {
    if (std.mem.indexOfScalar(u8, source_subpath, '/')) |cut| {
        var child = source_dir.openDir(io, source_subpath[0..cut], .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return,
            error.NotDir, error.SymLinkLoop => return error.InvalidMetadata,
            else => return err,
        };
        defer child.close(io);
        return stageOptional(io, child, trash, source_subpath[cut + 1 ..], index);
    }

    const stat = source_dir.statFile(io, source_subpath, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    if (stat.kind != .file) return error.InvalidMetadata;

    var dest_buf: [64]u8 = undefined;
    const dest = try std.fmt.bufPrint(&dest_buf, "{s}", .{index});
    try deleteOptionalEntry(io, trash, dest);
    source_dir.rename(source_subpath, trash, dest, io) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
}

fn validateOptionalFile(io: Io, source_dir: Dir, source_subpath: []const u8) !void {
    if (std.mem.indexOfScalar(u8, source_subpath, '/')) |cut| {
        var child = source_dir.openDir(io, source_subpath[0..cut], .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return,
            error.NotDir, error.SymLinkLoop => return error.InvalidMetadata,
            else => return err,
        };
        defer child.close(io);
        return validateOptionalFile(io, child, source_subpath[cut + 1 ..]);
    }
    const stat = source_dir.statFile(io, source_subpath, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    if (stat.kind != .file) return error.InvalidMetadata;
}

fn deleteOptionalEntry(io: Io, dir: Dir, name: []const u8) !void {
    const stat = dir.statFile(io, name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    switch (stat.kind) {
        .directory => try dir.deleteTree(io, name),
        else => try dir.deleteFile(io, name),
    }
}

fn removeEmptyResourceParents(io: Io, interaction: Dir, resource: []const u8) void {
    var end = std.mem.lastIndexOfScalar(u8, resource, '/') orelse return;
    while (true) {
        interaction.deleteDir(io, resource[0..end]) catch return;
        end = std.mem.lastIndexOfScalar(u8, resource[0..end], '/') orelse return;
    }
}

fn writeJsonAtomic(
    gpa: std.mem.Allocator,
    io: Io,
    dir: Dir,
    final_name: []const u8,
    temp_name: []const u8,
    value: std.json.Value,
) !void {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    var allocating = Io.Writer.Allocating.fromArrayList(gpa, &bytes);
    defer bytes = allocating.toArrayList();
    try std.json.Stringify.value(value, .{}, &allocating.writer);
    try allocating.writer.writeAll("\n");

    dir.deleteFile(io, temp_name) catch {};
    const file = try dir.createFile(io, temp_name, .{ .permissions = file_permissions });
    var renamed = false;
    defer if (!renamed) dir.deleteFile(io, temp_name) catch {};
    errdefer file.close(io);
    try file.writePositionalAll(io, allocating.writer.buffered(), 0);
    try file.sync(io);
    file.close(io);
    try dir.rename(temp_name, dir, final_name, io);
    renamed = true;
}

pub fn removeJournal(gpa: std.mem.Allocator, io: Io, root: Dir, journal: []const u8, force: bool) !void {
    const namespace = try mutation_lock.acquireNamespace(io, root);
    defer namespace.close(io);
    const selected = try findUniqueJournal(gpa, io, root, journal);
    defer gpa.free(selected);
    const lock = acquireJournalLock(io, root, selected) catch |err| switch (err) {
        error.JournalLocked => return error.ActiveJournal,
        else => return err,
    };
    var lock_open = true;
    defer if (lock_open) lock.close(io);
    const mutation_guard = try mutation_lock.acquire(io, root, selected, .exclusive);
    var mutation_lock_open = true;
    defer if (mutation_lock_open) mutation_guard.close(io);

    if (!force) {
        var metadata = try annotations.openRead(gpa, io, root, selected);
        defer metadata.deinit(gpa);
        var pins = try metadata.pins();
        defer pins.deinit();
        while (try pins.next()) |number| {
            if (interactionExists(io, root, selected, number)) return error.PinnedInteraction;
        }
    }

    var journal_dir = try root.openDir(io, selected, .{ .follow_symlinks = false });
    journal_dir.close(io);
    _ = root.createDir(io, ".trash", dir_permissions) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    var trash = try root.openDir(io, ".trash", .{ .follow_symlinks = false });
    defer trash.close(io);
    var staged_buf: [journal_name.max_len + 16]u8 = undefined;
    const staged = try std.fmt.bufPrint(&staged_buf, "{s}.journal", .{selected});
    try deleteOptionalEntry(io, trash, staged);
    try root.rename(selected, trash, staged, io);
    try deleteOptionalEntry(io, trash, staged);
    mutation_guard.close(io);
    mutation_lock_open = false;
    lock.close(io);
    lock_open = false;
    mutation_lock.removeFile(io, root, selected);
    mutation_lock.removeMetadataFile(io, root, selected);
    removeLockFile(io, root, selected);
}

/// Atomically changes an inactive journal's canonical directory identity.
pub fn renameJournal(
    gpa: std.mem.Allocator,
    io: Io,
    root: Dir,
    selector: []const u8,
    destination: []const u8,
) !void {
    if (!journal_name.isValid(destination)) return error.InvalidJournalName;
    const namespace = try mutation_lock.acquireNamespace(io, root);
    defer namespace.close(io);

    const source = try findUniqueJournal(gpa, io, root, selector);
    defer gpa.free(source);
    if (std.mem.eql(u8, source, destination)) return;
    if (root.statFile(io, destination, .{ .follow_symlinks = false })) |_| {
        return error.JournalExists;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    const source_lifetime = acquireJournalLock(io, root, source) catch |err| switch (err) {
        error.JournalLocked => return error.ActiveJournal,
        else => return err,
    };
    defer source_lifetime.close(io);
    const mutation = try mutation_lock.acquire(io, root, source, .exclusive);
    defer mutation.close(io);
    const destination_lifetime = acquireJournalLock(io, root, destination) catch |err| switch (err) {
        error.JournalLocked => return error.JournalExists,
        else => return err,
    };
    defer destination_lifetime.close(io);

    try root.rename(source, root, destination, io);
    mutation_lock.removeFile(io, root, source);
    mutation_lock.removeMetadataFile(io, root, source);
    removeLockFile(io, root, source);
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

fn makeTestJournal(tmp: *std.testing.TmpDir, io: Io, id: journal_name.Legacy, entries: []const []const u8) !void {
    try tmp.dir.createDir(io, &id, dir_permissions);
    var journal = try tmp.dir.openDir(io, &id, .{});
    defer journal.close(io);
    for (entries) |name| try journal.createDir(io, name, dir_permissions);
}

test "journal selection is exact-first then unique suffix" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const older = journal_name.legacy(1, .{0} ** 10);
    const newer = journal_name.legacy(2, .{0} ** 10);
    try makeTestJournal(&tmp, io, older, &.{});
    try makeTestJournal(&tmp, io, newer, &.{});
    try tmp.dir.createDir(io, "work", dir_permissions);
    try tmp.dir.createDir(io, "release-work", dir_permissions);

    var root = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    defer root.close(io);

    const exact = try findUniqueJournal(gpa, io, root, &older);
    defer gpa.free(exact);
    try std.testing.expectEqualStrings(&older, exact);
    const exact_over_suffix = try findUniqueJournal(gpa, io, root, "work");
    defer gpa.free(exact_over_suffix);
    try std.testing.expectEqualStrings("work", exact_over_suffix);
    try std.testing.expectError(error.NoSuchJournal, findUniqueJournal(gpa, io, root, "nope"));
    try std.testing.expectError(error.AmbiguousJournal, findUniqueJournal(gpa, io, root, "0000"));
}

test "journal listing is lexical and accepts the full name bound" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const longest = "a" ** journal_name.max_len;
    for ([_][]const u8{ "zeta", longest, "alpha", "not.valid" }) |name| {
        try tmp.dir.createDir(io, name, dir_permissions);
    }
    var root = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    defer root.close(io);
    const journals = try listJournals(gpa, io, root);
    defer {
        for (journals) |name| gpa.free(name);
        gpa.free(journals);
    }
    try std.testing.expectEqual(@as(usize, 3), journals.len);
    try std.testing.expectEqualStrings(longest, journals[0]);
    try std.testing.expectEqualStrings("alpha", journals[1]);
    try std.testing.expectEqualStrings("zeta", journals[2]);

    const selected = try findUniqueJournal(gpa, io, root, longest);
    defer gpa.free(selected);
    try std.testing.expectEqualStrings(longest, selected);
}

test "explicit journal creation validates names and rejects collisions" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = try testHome(&tmp, io, &path_buf);

    var first = try Store.createNamedJournal(gpa, io, home, "release-build");
    defer first.close();
    try std.testing.expectEqualStrings("release-build", first.journalId());
    try std.testing.expectError(error.JournalExists, Store.createNamedJournal(gpa, io, home, "release-build"));
    try std.testing.expectError(error.InvalidJournalName, Store.createNamedJournal(gpa, io, home, "Release.Build"));
}

test "rename changes identity atomically and preserves journal bytes" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "before", dir_permissions);
    var source = try tmp.dir.openDir(io, "before", .{});
    try source.writeFile(io, .{ .sub_path = "log", .data = "preserved\n" });
    source.close(io);

    var root = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    defer root.close(io);
    try renameJournal(gpa, io, root, "before", "after-build");
    try std.testing.expectError(error.NoSuchJournal, findUniqueJournal(gpa, io, root, "before"));
    const renamed = try findUniqueJournal(gpa, io, root, "build");
    defer gpa.free(renamed);
    try std.testing.expectEqualStrings("after-build", renamed);
    const contents = try root.readFileAlloc(io, "after-build/log", gpa, .limited(64));
    defer gpa.free(contents);
    try std.testing.expectEqualStrings("preserved\n", contents);

    try tmp.dir.createDir(io, "occupied", dir_permissions);
    try std.testing.expectError(error.JournalExists, renameJournal(gpa, io, root, "after-build", "occupied"));
    try std.testing.expectError(error.InvalidJournalName, renameJournal(gpa, io, root, "after-build", "Bad.Name"));

    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = try testHome(&tmp, io, &home_buf);
    var writer = try Store.continueJournal(gpa, io, home, "after-build");
    defer writer.close();
    try std.testing.expectError(error.ActiveJournal, renameJournal(gpa, io, root, "after-build", "later-build"));
}

test "continued journals use the highest entry and are never removed as empty" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = try testHome(&tmp, io, &path_buf);

    const with_gap = journal_name.legacy(3, .{1} ** 10);
    try makeTestJournal(&tmp, io, with_gap, &.{ "1", "3", "03", "0", "not-an-entry" });
    var continued = try Store.continueJournal(gpa, io, home, &with_gap);
    try std.testing.expectEqual(@as(?u32, 4), continued.next_number);
    continued.close();

    var gap_dir = try tmp.dir.openDir(io, &with_gap, .{});
    gap_dir.close(io);

    const empty = journal_name.legacy(4, .{2} ** 10);
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

    const unfinished = journal_name.legacy(5, .{3} ** 10);
    try makeTestJournal(&tmp, io, unfinished, &.{ "1", "2" });
    var continued = try Store.continueJournal(gpa, io, home, &unfinished);
    try std.testing.expectEqual(@as(?u32, 3), continued.next_number);
    continued.close();

    const full = journal_name.legacy(6, .{4} ** 10);
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

    const id = journal_name.legacy(7, .{5} ** 10);
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
    var path_buf: [journal_name.max_len + 16]u8 = undefined;
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
    return std.mem.eql(u8, name, "meta.json") or
        std.mem.eql(u8, name, "out.removed") or
        std.mem.eql(u8, name, ".meta.tmp") or
        std.mem.eql(u8, name, "log");
}

test "tj's bookkeeping files are not part of the namespace" {
    try std.testing.expect(isPrivate("meta.json"));
    try std.testing.expect(isPrivate("out.removed"));
    try std.testing.expect(isPrivate(".meta.tmp"));
    try std.testing.expect(isPrivate("log"));
    try std.testing.expect(!isPrivate("cmd"));
    try std.testing.expect(!isPrivate("cwd"));
    try std.testing.expect(!isPrivate("out"));
    try std.testing.expect(!isPrivate("prompt"));
    try std.testing.expect(!isPrivate("rc"));
    try std.testing.expect(!isPrivate("files"));
}

test "a reported working directory is a core entry resource" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buf);

    var store = try Store.createJournal(gpa, io, root_buf[0..root_len]);
    defer store.close();
    store.begin("pwd", null, "/tmp/work dir");
    store.finish(0);

    const cwd = try store.journal_dir.readFileAlloc(io, "1/cwd", gpa, .limited(4096));
    defer gpa.free(cwd);
    try std.testing.expectEqualStrings("/tmp/work dir", cwd);
}

test "a rendered prompt belongs to the next entry" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buf);

    var store = try Store.createJournal(gpa, io, root_buf[0..root_len]);
    defer store.close();

    // A canceled line draws another prompt. Only the most recently completed
    // one can belong to the command that eventually starts.
    store.promptStart();
    store.append("old prompt");
    store.append(prompt_end_st);
    store.promptEnd();
    store.promptStart();
    const rendered = "\x1b[35mleft\x1b[0m\r\n\x1b[20CRIGHT";
    store.append(rendered);
    store.append(prompt_end_st);
    store.promptEnd();
    store.begin("echo captured", null, null);
    store.finish(0);

    const prompt = try store.journal_dir.readFileAlloc(io, "1/prompt", gpa, .limited(4096));
    defer gpa.free(prompt);
    try std.testing.expectEqualStrings(rendered, prompt);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "133;B") == null);

    // If the B boundary never arrives, the partial prompt is discarded at
    // command start rather than being attached as if it were complete.
    store.promptStart();
    store.append("unfinished prompt");
    store.begin("echo no-prompt", null, null);
    store.finish(0);
    try std.testing.expectError(error.FileNotFound, store.journal_dir.openFile(io, "2/prompt", .{}));
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

test "noout records one placeholder while keeping region bytes out of metadata" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buf);

    var store = try Store.createJournal(gpa, io, root_buf[0..root_len]);
    store.begin("demo", null, null);
    store.append("before");
    store.beginNoout();
    store.append("secret bytes");
    store.endRegion();
    store.append("after");
    store.finish(0);

    const out = try store.journal_dir.readFileAlloc(io, "1/out", gpa, .limited(4096));
    defer gpa.free(out);
    try std.testing.expectEqualStrings("before" ++ noout_placeholder ++ "after", out);

    const meta = try store.journal_dir.readFileAlloc(io, "1/meta.json", gpa, .limited(4096));
    defer gpa.free(meta);
    try std.testing.expect(std.mem.indexOf(u8, meta, "\"started\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, meta, "\"ended\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, meta, "noout") == null);
    try std.testing.expect(std.mem.indexOf(u8, meta, "secret bytes") == null);
    store.close();
}

test "an empty noout region still records its placeholder once" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buf);

    var store = try Store.createJournal(gpa, io, root_buf[0..root_len]);
    store.begin("demo", null, null);
    store.beginNoout();
    store.endRegion();
    store.finish(0);
    const out = try store.journal_dir.readFileAlloc(io, "1/out", gpa, .limited(4096));
    defer gpa.free(out);
    try std.testing.expectEqualStrings(noout_placeholder, out);
    store.close();
}

test "region nesting is refused and the first open region wins" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buf);

    var store = try Store.createJournal(gpa, io, root_buf[0..root_len]);
    store.begin("resource-first", null, null);
    store.beginResource("kept", "text/plain");
    store.beginNoout();
    store.append("resource body");
    store.endRegion();
    store.finish(0);

    const resource = try store.journal_dir.readFileAlloc(io, "1/kept", gpa, .limited(4096));
    defer gpa.free(resource);
    try std.testing.expectEqualStrings("resource body", resource);
    const first_out = try store.journal_dir.readFileAlloc(io, "1/out", gpa, .limited(4096));
    defer gpa.free(first_out);
    try std.testing.expectEqualStrings("resource body", first_out);

    store.begin("noout-first", null, null);
    store.beginNoout();
    store.beginResource("refused", "text/plain");
    store.append("omitted");
    store.endRegion();
    store.append("visible");
    store.finish(0);

    const second_out = try store.journal_dir.readFileAlloc(io, "2/out", gpa, .limited(4096));
    defer gpa.free(second_out);
    try std.testing.expectEqualStrings(noout_placeholder ++ "visible", second_out);
    var second = try store.journal_dir.openDir(io, "2", .{});
    defer second.close(io);
    try std.testing.expectError(error.FileNotFound, second.openFile(io, "refused", .{}));
    store.close();
}

test "an unfinished noout region is reset at the entry boundary" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buf);

    var store = try Store.createJournal(gpa, io, root_buf[0..root_len]);
    store.begin("unfinished", null, null);
    store.beginNoout();
    store.append("omitted");
    store.finish(0);
    store.begin("next", null, null);
    store.append("recorded normally");
    store.finish(0);

    const first = try store.journal_dir.readFileAlloc(io, "1/out", gpa, .limited(4096));
    defer gpa.free(first);
    try std.testing.expectEqualStrings(noout_placeholder, first);
    const second = try store.journal_dir.readFileAlloc(io, "2/out", gpa, .limited(4096));
    defer gpa.free(second);
    try std.testing.expectEqualStrings("recorded normally", second);
    store.close();
}

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
        "../out",      "files/../../etc/passwd", "/etc/passwd", "a//b",
        "./x",         "..",
        // Overwriting tj's own bookkeeping.
                            "cmd",         "cwd",
        "out",         "prompt",                 "rc",          "meta.json",
        "out.removed", ".meta.tmp",              "log",
        // Nothing, or control characters.
                "",
        "a\x00b",      "a\nb",
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

test "warning logging stops after a bounded number per writer run" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);

    var store = try Store.createJournal(std.testing.allocator, io, path_buf[0..len]);
    defer store.close();
    for (0..max_log_warnings + 100) |number| store.warn("warning {d}", .{number});

    const text = try store.journal_dir.readFileAlloc(io, "log", std.testing.allocator, .limited(max_log_bytes + 1));
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "warning 63\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "warning 64\n") == null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, log_suppression_notice));
    try std.testing.expect(text.len <= max_log_bytes);

    const length_after_suppression = text.len;
    for (0..100) |_| store.warn("never written", .{});
    const unchanged = try store.journal_dir.readFileAlloc(io, "log", std.testing.allocator, .limited(max_log_bytes + 1));
    defer std.testing.allocator.free(unchanged);
    try std.testing.expectEqual(length_after_suppression, unchanged.len);
}

test "the journal warning log has an absolute byte ceiling" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);

    var store = try Store.createJournal(std.testing.allocator, io, path_buf[0..len]);
    defer store.close();
    while (store.appendLog("X" ** 512)) {}
    store.stopLogging();

    const text = try store.journal_dir.readFileAlloc(io, "log", std.testing.allocator, .limited(max_log_bytes + 1));
    defer std.testing.allocator.free(text);
    try std.testing.expectEqual(@as(usize, max_log_bytes), text.len);
    try std.testing.expect(store.warnings_suppressed);
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
        store.begin("demo", null, null);
        store.beginResource("script.sh", "text/x-shellscript");

        const written = "#!/bin/sh\r\necho hi\r\n\rlone cr\r\n";
        var i: usize = 0;
        while (i < written.len) {
            const end = @min(i + chunk, written.len);
            store.append(written[i..end]);
            i = end;
        }
        store.endRegion();

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
    store.begin("demo", null, null);
    store.beginResource("trailing", "text/plain");
    store.append("ends with cr\r");
    store.endRegion();

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
    store.begin("demo", "expanded \"command\" with \\ and a newline\n", null);

    for (0..max_resources) |i| {
        var path_buf: [96]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "files/item-\"quoted\"-\\\\-{d}.dat", .{i});
        store.beginResource(path, long_mime);
        store.endRegion();
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

test "output removal redacts out and published resources but keeps the entry" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buf);

    var journal = try Store.createJournal(gpa, io, root_buf[0..root_len]);
    const id = try gpa.dupe(u8, journal.journal);
    defer gpa.free(id);
    journal.begin("publish", null, null);
    journal.beginResource("files/report.txt", "text/plain");
    journal.append("published bytes\r\n");
    journal.endRegion();
    journal.finish(0);
    journal.begin("later", null, null);
    journal.finish(0);
    journal.close();

    var root = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    defer root.close(io);
    var marker_path_buf: [96]u8 = undefined;
    const marker_path = try std.fmt.bufPrint(&marker_path_buf, "{s}/1/out.removed", .{id});
    try root.writeFile(io, .{ .sub_path = marker_path, .data = "", .flags = .{ .permissions = file_permissions } });
    try recoverPendingOutputRemovals(gpa, io, root, id);

    var path_buf: [96]u8 = undefined;
    const interaction_path = try std.fmt.bufPrint(&path_buf, "{s}/1", .{id});
    var interaction = try root.openDir(io, interaction_path, .{});
    defer interaction.close(io);
    try std.testing.expectError(error.FileNotFound, interaction.openFile(io, "out", .{}));
    try std.testing.expectError(error.FileNotFound, interaction.openFile(io, "files/report.txt", .{}));
    var cmd = try interaction.openFile(io, "cmd", .{});
    cmd.close(io);
    var rc = try interaction.openFile(io, "rc", .{});
    rc.close(io);
    var marker = try interaction.openFile(io, "out.removed", .{});
    marker.close(io);

    const meta = try interaction.readFileAlloc(io, "meta.json", gpa, .limited(64 * 1024));
    defer gpa.free(meta);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, meta, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("resources") == null);
    try std.testing.expect(parsed.value.object.get("out_removed").?.bool);
}

test "output removal refuses resource paths that traverse symlinks" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buf);

    try tmp.dir.createDir(io, "outside", dir_permissions);
    try tmp.dir.writeFile(io, .{
        .sub_path = "outside/report.txt",
        .data = "must survive",
        .flags = .{ .permissions = file_permissions },
    });

    var journal = try Store.createJournal(gpa, io, root_buf[0..root_len]);
    const id = try gpa.dupe(u8, journal.journal);
    defer gpa.free(id);
    journal.begin("publish", null, null);
    journal.beginResource("files/report.txt", "text/plain");
    journal.append("recorded\r\n");
    journal.endRegion();
    journal.finish(0);
    journal.close();

    var root = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    defer root.close(io);
    var interaction_path_buf: [96]u8 = undefined;
    const interaction_path = try std.fmt.bufPrint(&interaction_path_buf, "{s}/1", .{id});
    var interaction = try root.openDir(io, interaction_path, .{});
    defer interaction.close(io);
    try interaction.deleteTree(io, "files");
    try interaction.symLink(io, "../../outside", "files", .{ .is_directory = true });

    try std.testing.expectError(error.InvalidMetadata, removeOutput(gpa, io, root, id, 1));
    var out = try interaction.openFile(io, "out", .{});
    out.close(io);
    try std.testing.expectError(error.FileNotFound, interaction.openFile(io, "out.removed", .{}));
    const outside = try root.readFileAlloc(io, "outside/report.txt", gpa, .limited(64));
    defer gpa.free(outside);
    try std.testing.expectEqualStrings("must survive", outside);
}

test "staged entry removal leaves a numbering hole" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const id = journal_name.legacy(30, .{9} ** 10);
    try makeTestJournal(&tmp, io, id, &.{ "1", "2", "3" });
    var root = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    defer root.close(io);

    const staged = try stageInteractionRemoval(gpa, io, root, &id, 2);
    defer gpa.free(staged);
    try std.testing.expect(!interactionExists(io, root, &id, 2));
    try std.testing.expectEqual(@as(u32, 4), try nextInteractionNumber(gpa, io, root, &id));
    try finishStagedRemoval(io, root, staged);
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
    var path_buf: [journal_name.max_len + 32]u8 = undefined;
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
