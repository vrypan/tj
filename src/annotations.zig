//! Journal-local mutable metadata backed by the embedded SQLite database.
//!
//! Entry recording metadata remains in `meta.json`. Schema version 1 of
//! `journal.sqlite3` stores only user-owned names, tags, and pins.

const std = @import("std");
const sqlite = @import("sqlite.zig");
const mutation_lock = @import("mutation_lock.zig");
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;

const file_permissions: File.Permissions = @enumFromInt(0o600);
const dir_permissions: File.Permissions = @enumFromInt(0o700);
const database_name = "journal.sqlite3";
const legacy_name = "annotations.json";
const application_id: i64 = 0x544A4442;
const schema_version: i64 = 1;
const names_schema = "CREATE TABLE names(" ++
    "entry INTEGER PRIMARY KEY CHECK(entry BETWEEN 1 AND 4294967295)," ++
    "name TEXT NOT NULL UNIQUE CHECK(length(name) BETWEEN 1 AND 63)) STRICT";
const pins_schema = "CREATE TABLE pins(" ++
    "entry INTEGER PRIMARY KEY CHECK(entry BETWEEN 1 AND 4294967295)) STRICT";
const tags_schema = "CREATE TABLE tags(" ++
    "entry INTEGER NOT NULL CHECK(entry BETWEEN 1 AND 4294967295)," ++
    "tag TEXT NOT NULL CHECK(length(tag) BETWEEN 1 AND 63)," ++
    "PRIMARY KEY(entry,tag)) STRICT, WITHOUT ROWID";
const tags_index_schema = "CREATE INDEX tags_by_tag ON tags(tag,entry)";

pub const Error = error{
    AnnotationBusy,
    AnnotationConstraint,
    InvalidAnnotationDatabase,
    LegacyAnnotationsUnsupported,
    AnnotationDatabaseFailure,
};

pub const Entry = struct {
    number: u32,
    name: ?[]u8 = null,
    tags: std.ArrayList([]u8) = .empty,
    pinned: bool = false,

    pub fn deinit(self: *Entry, gpa: std.mem.Allocator) void {
        if (self.name) |name| gpa.free(name);
        for (self.tags.items) |tag| gpa.free(tag);
        self.tags.deinit(gpa);
    }
};

/// Every annotation in one journal, read with three table scans instead of
/// three indexed lookups per entry.
///
/// This is the one place TJ holds journal-wide annotation state. It is a
/// deliberate trade against `Connection.get`, which costs three prepared
/// statements per entry and made listing a large journal dominated by SQL
/// parsing. The tables are sparse - they hold rows only for entries somebody
/// actually named, tagged, or pinned - so the resident size tracks the number
/// of annotations, not the number of entries. A journal of 200000 entries with
/// 50 named ones holds 50 rows.
///
/// Use this for listings, which touch every entry. Single-entry commands
/// should still use `Connection.get`.
pub const Set = struct {
    entries: std.AutoHashMapUnmanaged(u32, Entry) = .empty,

    pub fn deinit(self: *Set, gpa: std.mem.Allocator) void {
        var it = self.entries.valueIterator();
        while (it.next()) |entry| entry.deinit(gpa);
        self.entries.deinit(gpa);
        self.* = undefined;
    }

    pub fn get(self: *const Set, number: u32) ?*const Entry {
        return self.entries.getPtr(number);
    }

    fn slot(self: *Set, gpa: std.mem.Allocator, number: u32) !*Entry {
        const found = try self.entries.getOrPut(gpa, number);
        if (!found.found_existing) found.value_ptr.* = .{ .number = number };
        return found.value_ptr;
    }
};

/// Reads a whole journal's annotations. An absent database yields an empty
/// set, exactly as the per-entry path yields no annotations.
pub fn loadSet(gpa: std.mem.Allocator, connection: *Connection) !Set {
    var set: Set = .{};
    errdefer set.deinit(gpa);
    if (connection.database == null) return set;

    var names_iterator = try connection.names();
    defer names_iterator.deinit();
    while (try names_iterator.next()) |row| {
        const entry = try set.slot(gpa, row.number);
        const owned = try gpa.dupe(u8, row.name);
        errdefer gpa.free(owned);
        if (entry.name) |previous| gpa.free(previous);
        entry.name = owned;
    }

    var tags_iterator = try connection.tags();
    defer tags_iterator.deinit();
    while (try tags_iterator.next()) |row| {
        const entry = try set.slot(gpa, row.number);
        const owned = try gpa.dupe(u8, row.tag);
        errdefer gpa.free(owned);
        try entry.tags.append(gpa, owned);
    }

    var pins_iterator = try connection.pins();
    defer pins_iterator.deinit();
    while (try pins_iterator.next()) |number| {
        const entry = try set.slot(gpa, number);
        entry.pinned = true;
    }

    return set;
}

pub const Connection = struct {
    database: ?sqlite.Database,
    path: [:0]u8,

    pub fn deinit(self: *Connection, gpa: std.mem.Allocator) void {
        if (self.database) |*database| database.close();
        gpa.free(self.path);
        self.* = undefined;
    }

    pub fn begin(self: *Connection) !Transaction {
        const database = if (self.database) |*database_value| database_value else return error.AnnotationDatabaseFailure;
        return .{ .inner = sqlite.Transaction.beginImmediate(database) catch |err| return mapSqlite(err) };
    }

    pub fn get(self: *Connection, gpa: std.mem.Allocator, number: u32) !?Entry {
        var result: Entry = .{ .number = number };
        errdefer result.deinit(gpa);
        const database = if (self.database) |*value| value else return null;

        var name = database.prepare("SELECT name FROM names WHERE entry=?") catch |err| return mapSqlite(err);
        defer name.finalize();
        name.bindInt(1, number) catch |err| return mapSqlite(err);
        if ((name.step() catch |err| return mapSqlite(err)) == .row) {
            const text = name.columnText(0) catch |err| return mapSqlite(err);
            if (!validName(text)) return error.InvalidAnnotationDatabase;
            result.name = try gpa.dupe(u8, text);
        }

        var pin = database.prepare("SELECT 1 FROM pins WHERE entry=?") catch |err| return mapSqlite(err);
        defer pin.finalize();
        pin.bindInt(1, number) catch |err| return mapSqlite(err);
        result.pinned = (pin.step() catch |err| return mapSqlite(err)) == .row;

        var tag_statement = database.prepare("SELECT tag FROM tags WHERE entry=? ORDER BY tag") catch |err| return mapSqlite(err);
        defer tag_statement.finalize();
        tag_statement.bindInt(1, number) catch |err| return mapSqlite(err);
        while ((tag_statement.step() catch |err| return mapSqlite(err)) == .row) {
            const text = tag_statement.columnText(0) catch |err| return mapSqlite(err);
            if (!validStoredTag(text)) return error.InvalidAnnotationDatabase;
            const owned = try gpa.dupe(u8, text);
            errdefer gpa.free(owned);
            try result.tags.append(gpa, owned);
        }

        if (result.name == null and !result.pinned and result.tags.items.len == 0) {
            result.deinit(gpa);
            return null;
        }
        return result;
    }

    pub fn numberForName(self: *Connection, name: []const u8) !?u32 {
        if (!validName(name)) return null;
        const database = if (self.database) |*value| value else return null;
        var statement = database.prepare("SELECT entry FROM names WHERE name=?") catch |err| return mapSqlite(err);
        defer statement.finalize();
        statement.bindText(1, name) catch |err| return mapSqlite(err);
        if ((statement.step() catch |err| return mapSqlite(err)) == .done) return null;
        return try checkedNumber(statement.columnInt(0));
    }

    pub fn hasAllTags(self: *Connection, number: u32, wanted: []const []const u8) !bool {
        if (wanted.len == 0) return true;
        const database = if (self.database) |*value| value else return false;
        var statement = database.prepare("SELECT 1 FROM tags WHERE entry=? AND tag=?") catch |err| return mapSqlite(err);
        defer statement.finalize();
        for (wanted) |tag| {
            statement.reset() catch |err| return mapSqlite(err);
            statement.bindInt(1, number) catch |err| return mapSqlite(err);
            statement.bindText(2, tag) catch |err| return mapSqlite(err);
            if ((statement.step() catch |err| return mapSqlite(err)) == .done) return false;
        }
        return true;
    }

    pub fn isPinned(self: *Connection, number: u32) !bool {
        const database = if (self.database) |*value| value else return false;
        var statement = database.prepare("SELECT 1 FROM pins WHERE entry=?") catch |err| return mapSqlite(err);
        defer statement.finalize();
        statement.bindInt(1, number) catch |err| return mapSqlite(err);
        return (statement.step() catch |err| return mapSqlite(err)) == .row;
    }

    pub fn setName(self: *Connection, number: u32, name: []const u8) !void {
        if (!validName(name)) return error.InvalidName;
        const database = if (self.database) |*value| value else return error.AnnotationDatabaseFailure;
        var statement = database.prepare(
            "INSERT INTO names(entry,name) VALUES(?,?) " ++
                "ON CONFLICT(entry) DO UPDATE SET name=excluded.name",
        ) catch |err| return mapSqlite(err);
        defer statement.finalize();
        statement.bindInt(1, number) catch |err| return mapSqlite(err);
        statement.bindText(2, name) catch |err| return mapSqlite(err);
        _ = statement.step() catch |err| switch (err) {
            error.Constraint => {
                if (database.extendedCode() == sqlite.c.SQLITE_CONSTRAINT_UNIQUE) return error.NameTaken;
                return error.AnnotationConstraint;
            },
            else => return mapSqlite(err),
        };
    }

    pub fn removeName(self: *Connection, name: []const u8) !void {
        if (!validName(name)) return error.InvalidName;
        try self.executeText("DELETE FROM names WHERE name=?", name);
    }

    pub fn addTag(self: *Connection, number: u32, tag: []const u8) !void {
        const database = if (self.database) |*value| value else return error.AnnotationDatabaseFailure;
        var statement = database.prepare("INSERT OR IGNORE INTO tags(entry,tag) VALUES(?,?)") catch |err| return mapSqlite(err);
        defer statement.finalize();
        statement.bindInt(1, number) catch |err| return mapSqlite(err);
        statement.bindText(2, tag) catch |err| return mapSqlite(err);
        _ = statement.step() catch |err| return mapSqlite(err);
    }

    pub fn removeTag(self: *Connection, number: u32, tag: []const u8) !void {
        const database = if (self.database) |*value| value else return error.AnnotationDatabaseFailure;
        var statement = database.prepare("DELETE FROM tags WHERE entry=? AND tag=?") catch |err| return mapSqlite(err);
        defer statement.finalize();
        statement.bindInt(1, number) catch |err| return mapSqlite(err);
        statement.bindText(2, tag) catch |err| return mapSqlite(err);
        _ = statement.step() catch |err| return mapSqlite(err);
    }

    pub fn setPinned(self: *Connection, number: u32, pinned: bool) !void {
        const database = if (self.database) |*value| value else return error.AnnotationDatabaseFailure;
        var statement = database.prepare(if (pinned)
            "INSERT OR IGNORE INTO pins(entry) VALUES(?)"
        else
            "DELETE FROM pins WHERE entry=?") catch |err| return mapSqlite(err);
        defer statement.finalize();
        statement.bindInt(1, number) catch |err| return mapSqlite(err);
        _ = statement.step() catch |err| return mapSqlite(err);
    }

    pub fn removeEntry(self: *Connection, number: u32) !void {
        const database = if (self.database) |*value| value else return;
        var statement = database.prepare(
            "DELETE FROM names WHERE entry=?;",
        ) catch |err| return mapSqlite(err);
        defer statement.finalize();
        statement.bindInt(1, number) catch |err| return mapSqlite(err);
        _ = statement.step() catch |err| return mapSqlite(err);
        try deleteNumber(database, "DELETE FROM pins WHERE entry=?", number);
        try deleteNumber(database, "DELETE FROM tags WHERE entry=?", number);
    }

    pub fn names(self: *Connection) !NameIterator {
        const database = if (self.database) |*value| value else return .{};
        return .{ .statement = database.prepare("SELECT entry,name FROM names ORDER BY entry") catch |err| return mapSqlite(err) };
    }

    pub fn tags(self: *Connection) !TagIterator {
        const database = if (self.database) |*value| value else return .{};
        return .{ .statement = database.prepare("SELECT entry,tag FROM tags ORDER BY entry,tag") catch |err| return mapSqlite(err) };
    }

    pub fn pins(self: *Connection) !PinIterator {
        const database = if (self.database) |*value| value else return .{};
        return .{ .statement = database.prepare("SELECT entry FROM pins ORDER BY entry") catch |err| return mapSqlite(err) };
    }

    fn executeText(self: *Connection, sql_text: [*:0]const u8, value: []const u8) !void {
        const database = if (self.database) |*database_value| database_value else return error.AnnotationDatabaseFailure;
        var statement = database.prepare(sql_text) catch |err| return mapSqlite(err);
        defer statement.finalize();
        statement.bindText(1, value) catch |err| return mapSqlite(err);
        _ = statement.step() catch |err| return mapSqlite(err);
    }
};

pub const Transaction = struct {
    inner: sqlite.Transaction,

    pub fn commit(self: *Transaction) !void {
        self.inner.commit() catch |err| return mapSqlite(err);
    }

    pub fn deinit(self: *Transaction) void {
        self.inner.deinit();
    }
};

pub const NameRow = struct { number: u32, name: []const u8 };
pub const TagRow = struct { number: u32, tag: []const u8 };

pub const NameIterator = struct {
    statement: ?sqlite.Statement = null,

    pub fn deinit(self: *NameIterator) void {
        if (self.statement) |*statement| statement.finalize();
    }

    pub fn next(self: *NameIterator) !?NameRow {
        const statement = if (self.statement) |*value| value else return null;
        if ((statement.step() catch |err| return mapSqlite(err)) == .done) return null;
        const name = statement.columnText(1) catch |err| return mapSqlite(err);
        if (!validName(name)) return error.InvalidAnnotationDatabase;
        return .{ .number = try checkedNumber(statement.columnInt(0)), .name = name };
    }
};

pub const TagIterator = struct {
    statement: ?sqlite.Statement = null,

    pub fn deinit(self: *TagIterator) void {
        if (self.statement) |*statement| statement.finalize();
    }

    pub fn next(self: *TagIterator) !?TagRow {
        const statement = if (self.statement) |*value| value else return null;
        if ((statement.step() catch |err| return mapSqlite(err)) == .done) return null;
        const tag = statement.columnText(1) catch |err| return mapSqlite(err);
        if (!validStoredTag(tag)) return error.InvalidAnnotationDatabase;
        return .{ .number = try checkedNumber(statement.columnInt(0)), .tag = tag };
    }
};

pub const PinIterator = struct {
    statement: ?sqlite.Statement = null,

    pub fn deinit(self: *PinIterator) void {
        if (self.statement) |*statement| statement.finalize();
    }

    pub fn next(self: *PinIterator) !?u32 {
        const statement = if (self.statement) |*value| value else return null;
        if ((statement.step() catch |err| return mapSqlite(err)) == .done) return null;
        return try checkedNumber(statement.columnInt(0));
    }
};

pub fn openRead(gpa: std.mem.Allocator, io: Io, root: Dir, journal: []const u8) !Connection {
    try rejectLegacy(io, root, journal);
    const path = try databasePath(gpa, io, root, journal);
    errdefer gpa.free(path);
    var sub_buf: [96]u8 = undefined;
    const sub = try std.fmt.bufPrint(&sub_buf, "{s}/{s}", .{ journal, database_name });
    const stat = root.statFile(io, sub, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return .{ .database = null, .path = path },
        else => return err,
    };
    if (stat.kind != .file) return error.InvalidAnnotationDatabase;
    var database = sqlite.Database.open(path.ptr, sqlite.c.SQLITE_OPEN_READONLY) catch |err| return mapSqlite(err);
    errdefer database.close();
    try configure(&database, false);
    if (try isUninitialized(&database)) {
        database.close();
        return .{ .database = null, .path = path };
    }
    try verifySchema(&database);
    return .{ .database = database, .path = path };
}

pub fn openWrite(gpa: std.mem.Allocator, io: Io, root: Dir, journal: []const u8) !Connection {
    try rejectLegacy(io, root, journal);
    const initialization_guard = try mutation_lock.acquireMetadataInit(io, root, journal);
    defer initialization_guard.close(io);
    var journal_dir = try root.openDir(io, journal, .{ .follow_symlinks = false });
    defer journal_dir.close(io);
    var new_file = false;
    const stat = journal_dir.statFile(io, database_name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => blk: {
            const file = journal_dir.createFile(io, database_name, .{
                .exclusive = true,
                .permissions = file_permissions,
            }) catch |create_err| switch (create_err) {
                error.PathAlreadyExists => null,
                else => return create_err,
            };
            if (file) |created| {
                created.close(io);
                new_file = true;
            }
            break :blk try journal_dir.statFile(io, database_name, .{ .follow_symlinks = false });
        },
        else => return err,
    };
    if (stat.kind != .file) return error.InvalidAnnotationDatabase;
    if (stat.size == 0) new_file = true;

    const path = try databasePath(gpa, io, root, journal);
    errdefer gpa.free(path);
    var database = sqlite.Database.open(
        path.ptr,
        sqlite.c.SQLITE_OPEN_READWRITE,
    ) catch |err| return mapSqlite(err);
    errdefer database.close();
    try configure(&database, true);
    if (new_file or try isUninitialized(&database)) try initializeSchema(&database) else try verifySchema(&database);
    return .{ .database = database, .path = path };
}

fn configure(database: *sqlite.Database, writable: bool) !void {
    database.busyTimeout(5000) catch |err| return mapSqlite(err);
    database.exec("PRAGMA cache_size=-512") catch |err| return mapSqlite(err);
    database.exec("PRAGMA mmap_size=0") catch |err| return mapSqlite(err);
    database.exec("PRAGMA trusted_schema=OFF") catch |err| return mapSqlite(err);
    if (!writable) return;
    var journal_mode = database.prepare("PRAGMA journal_mode=WAL") catch |err| return mapSqlite(err);
    defer journal_mode.finalize();
    if ((journal_mode.step() catch |err| return mapSqlite(err)) != .row) return error.InvalidAnnotationDatabase;
    const mode = journal_mode.columnText(0) catch |err| return mapSqlite(err);
    if (!std.mem.eql(u8, mode, "wal")) return error.InvalidAnnotationDatabase;
    database.exec("PRAGMA synchronous=FULL") catch |err| return mapSqlite(err);
}

fn initializeSchema(database: *sqlite.Database) !void {
    var transaction = sqlite.Transaction.beginImmediate(database) catch |err| return mapSqlite(err);
    defer transaction.deinit();
    database.exec(
        names_schema ++ ";" ++ pins_schema ++ ";" ++ tags_schema ++ ";" ++ tags_index_schema ++ ";" ++
            "PRAGMA application_id=0x544A4442;" ++
            "PRAGMA user_version=1;",
    ) catch |err| return mapSqlite(err);
    transaction.commit() catch |err| return mapSqlite(err);
    try verifySchema(database);
}

fn verifySchema(database: *sqlite.Database) !void {
    if (try pragmaInt(database, "PRAGMA application_id") != application_id or
        try pragmaInt(database, "PRAGMA user_version") != schema_version) return error.InvalidAnnotationDatabase;
    if (try schemaObjectCount(database) != 4) return error.InvalidAnnotationDatabase;
    var statement = database.prepare(
        "SELECT count(*) FROM sqlite_schema WHERE " ++
            "(type='table' AND name='names' AND sql='" ++ names_schema ++ "') OR " ++
            "(type='table' AND name='pins' AND sql='" ++ pins_schema ++ "') OR " ++
            "(type='table' AND name='tags' AND sql='" ++ tags_schema ++ "') OR " ++
            "(type='index' AND name='tags_by_tag' AND sql='" ++ tags_index_schema ++ "')",
    ) catch |err| return mapSqlite(err);
    defer statement.finalize();
    if ((statement.step() catch |err| return mapSqlite(err)) != .row or statement.columnInt(0) != 4) {
        return error.InvalidAnnotationDatabase;
    }
}

fn isUninitialized(database: *sqlite.Database) !bool {
    return try pragmaInt(database, "PRAGMA application_id") == 0 and
        try pragmaInt(database, "PRAGMA user_version") == 0 and
        try schemaObjectCount(database) == 0;
}

fn schemaObjectCount(database: *sqlite.Database) !i64 {
    var statement = database.prepare(
        "SELECT count(*) FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%'",
    ) catch |err| return mapSqlite(err);
    defer statement.finalize();
    if ((statement.step() catch |err| return mapSqlite(err)) != .row) return error.InvalidAnnotationDatabase;
    return statement.columnInt(0);
}

fn pragmaInt(database: *sqlite.Database, sql_text: [*:0]const u8) !i64 {
    var statement = database.prepare(sql_text) catch |err| return mapSqlite(err);
    defer statement.finalize();
    if ((statement.step() catch |err| return mapSqlite(err)) != .row) return error.InvalidAnnotationDatabase;
    return statement.columnInt(0);
}

fn databasePath(gpa: std.mem.Allocator, io: Io, root: Dir, journal: []const u8) ![:0]u8 {
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try root.realPath(io, &root_buf);
    return std.fmt.allocPrintSentinel(gpa, "{s}/{s}/{s}", .{ root_buf[0..root_len], journal, database_name }, 0);
}

fn rejectLegacy(io: Io, root: Dir, journal: []const u8) !void {
    var path_buf: [96]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ journal, legacy_name });
    _ = root.statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    return error.LegacyAnnotationsUnsupported;
}

/// Completes the database half of entry removals whose directory rename was
/// durable but whose annotation transaction may not have committed.
pub fn recoverStagedRemovals(
    gpa: std.mem.Allocator,
    io: Io,
    root: Dir,
    journal: []const u8,
) !void {
    var path_buf: [96]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/.trash", .{journal});
    var trash = root.openDir(io, path, .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer trash.close(io);

    var numbers: std.ArrayList(u32) = .empty;
    defer numbers.deinit(gpa);
    var iterator = trash.iterate();
    while (try iterator.next(io)) |entry| {
        const suffix = ".interaction";
        if (!std.mem.endsWith(u8, entry.name, suffix)) continue;
        const number_text = entry.name[0 .. entry.name.len - suffix.len];
        const number = std.fmt.parseInt(u32, number_text, 10) catch continue;
        if (number == 0) continue;
        try numbers.append(gpa, number);
    }
    if (numbers.items.len == 0) return;

    var metadata = try openWrite(gpa, io, root, journal);
    defer metadata.deinit(gpa);
    var transaction = try metadata.begin();
    defer transaction.deinit();
    for (numbers.items) |number| try metadata.removeEntry(number);
    try transaction.commit();
}

fn deleteNumber(database: *sqlite.Database, sql_text: [*:0]const u8, number: u32) !void {
    var statement = database.prepare(sql_text) catch |err| return mapSqlite(err);
    defer statement.finalize();
    statement.bindInt(1, number) catch |err| return mapSqlite(err);
    _ = statement.step() catch |err| return mapSqlite(err);
}

fn checkedNumber(value: i64) !u32 {
    if (value <= 0 or value > std.math.maxInt(u32)) return error.InvalidAnnotationDatabase;
    return @intCast(value);
}

fn mapSqlite(err: sqlite.Error) Error {
    return switch (err) {
        error.Busy => error.AnnotationBusy,
        error.Constraint => error.AnnotationConstraint,
        error.InvalidDatabase => error.InvalidAnnotationDatabase,
        error.DatabaseFailure => error.AnnotationDatabaseFailure,
    };
}

pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 63) return false;
    if (name[0] < 'a' or name[0] > 'z') return false;
    if (!std.ascii.isAlphanumeric(name[name.len - 1])) return false;
    var all_digits = true;
    for (name) |char| {
        if (!std.ascii.isDigit(char)) all_digits = false;
        if (!((char >= 'a' and char <= 'z') or std.ascii.isDigit(char) or char == '-')) return false;
    }
    return !all_digits;
}

pub fn normalizeTag(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    if (text.len == 0 or text.len > 63) return error.InvalidTag;
    const tag = try gpa.alloc(u8, text.len);
    errdefer gpa.free(tag);
    for (text, 0..) |char, i| {
        if (!std.ascii.isAscii(char)) return error.InvalidTag;
        tag[i] = std.ascii.toLower(char);
    }
    if (!validStoredTag(tag)) return error.InvalidTag;
    return tag;
}

fn validStoredTag(tag: []const u8) bool {
    if (tag.len == 0 or tag.len > 63) return false;
    if (!std.ascii.isAlphanumeric(tag[0]) or !std.ascii.isAlphanumeric(tag[tag.len - 1])) return false;
    for (tag) |char| {
        if (!std.ascii.isAscii(char) or std.ascii.toLower(char) != char) return false;
        if (!(std.ascii.isAlphanumeric(char) or char == '.' or char == '_' or char == '-')) return false;
    }
    return true;
}

test "annotation grammar is conservative and tags normalize" {
    try std.testing.expect(validName("build-failure"));
    try std.testing.expect(validName("x"));
    for ([_][]const u8{ "42", "Build", "bad_name", "bad.name", "-bad", "bad-", "" }) |name| {
        try std.testing.expect(!validName(name));
    }
    const tag = try normalizeTag(std.testing.allocator, "Bug.Parser_2");
    defer std.testing.allocator.free(tag);
    try std.testing.expectEqualStrings("bug.parser_2", tag);
    try std.testing.expectError(error.InvalidTag, normalizeTag(std.testing.allocator, "bad tag"));
}

test "sqlite annotations are sparse unique and idempotent" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "journal", dir_permissions);
    var root = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    defer root.close(io);

    var connection = try openWrite(gpa, io, root, "journal");
    defer connection.deinit(gpa);
    var transaction = try connection.begin();
    defer transaction.deinit();
    try connection.setName(1, "build-failure");
    try std.testing.expectError(error.NameTaken, connection.setName(2, "build-failure"));
    try connection.setName(1, "renamed-entry");
    try connection.addTag(1, "parser");
    try connection.addTag(1, "parser");
    try connection.addTag(1, "bug");
    try connection.removeTag(1, "missing");
    try connection.setPinned(1, true);
    try connection.setPinned(1, true);
    try transaction.commit();

    const entry = (try connection.get(gpa, 1)).?;
    var owned = entry;
    defer owned.deinit(gpa);
    try std.testing.expectEqualStrings("renamed-entry", owned.name.?);
    try std.testing.expectEqual(@as(usize, 2), owned.tags.items.len);
    try std.testing.expectEqualStrings("bug", owned.tags.items[0]);
    try std.testing.expect(try connection.hasAllTags(1, &.{ "bug", "parser" }));
    try std.testing.expect(owned.pinned);

    {
        var rollback = try connection.begin();
        defer rollback.deinit();
        try connection.setName(2, "rolled-back");
        try connection.setPinned(2, true);
    }
    try std.testing.expect((try connection.get(gpa, 2)) == null);

    var cleanup = try connection.begin();
    defer cleanup.deinit();
    try connection.removeName("renamed-entry");
    try connection.removeTag(1, "bug");
    try connection.setPinned(1, false);
    try cleanup.commit();
    try std.testing.expect((try connection.numberForName("renamed-entry")) == null);
}

test "annotation database policy and schema fail closed" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "journal", dir_permissions);
    var root = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    defer root.close(io);

    var connection = try openWrite(gpa, io, root, "journal");
    const database = if (connection.database) |*value| value else unreachable;
    try std.testing.expectEqual(@as(i64, application_id), try pragmaInt(database, "PRAGMA application_id"));
    try std.testing.expectEqual(@as(i64, schema_version), try pragmaInt(database, "PRAGMA user_version"));
    try std.testing.expectEqual(@as(i64, -512), try pragmaInt(database, "PRAGMA cache_size"));
    try std.testing.expectEqual(@as(i64, 0), try pragmaInt(database, "PRAGMA mmap_size"));
    const stat = try root.statFile(io, "journal/journal.sqlite3", .{ .follow_symlinks = false });
    if (@import("builtin").os.tag != .windows) {
        try std.testing.expectEqual(@as(u16, 0o600), @as(u16, @intCast(@intFromEnum(stat.permissions) & 0o777)));
        for ([_][]const u8{ "journal/journal.sqlite3-wal", "journal/journal.sqlite3-shm" }) |path| {
            const sidecar = try root.statFile(io, path, .{ .follow_symlinks = false });
            try std.testing.expectEqual(@as(u16, 0o600), @as(u16, @intCast(@intFromEnum(sidecar.permissions) & 0o777)));
        }
    }
    database.exec("PRAGMA user_version=2") catch |err| return mapSqlite(err);
    connection.deinit(gpa);
    try std.testing.expectError(error.InvalidAnnotationDatabase, openRead(gpa, io, root, "journal"));
}

test "corrupt annotation databases are not replaced" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "journal", dir_permissions);
    var root = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    defer root.close(io);
    const corrupt = "definitely not sqlite";
    try root.writeFile(io, .{
        .sub_path = "journal/journal.sqlite3",
        .data = corrupt,
        .flags = .{ .permissions = file_permissions },
    });
    try std.testing.expectError(error.InvalidAnnotationDatabase, openRead(gpa, io, root, "journal"));
    const after = try root.readFileAlloc(io, "journal/journal.sqlite3", gpa, .limited(128));
    defer gpa.free(after);
    try std.testing.expectEqualStrings(corrupt, after);
}

test "staged entry recovery removes its sparse rows transactionally" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "journal", dir_permissions);
    try tmp.dir.createDirPath(io, "journal/.trash/2.interaction");
    var root = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    defer root.close(io);

    {
        var metadata = try openWrite(gpa, io, root, "journal");
        defer metadata.deinit(gpa);
        var transaction = try metadata.begin();
        defer transaction.deinit();
        try metadata.setName(2, "stale-name");
        try metadata.addTag(2, "stale-tag");
        try metadata.setPinned(2, true);
        try transaction.commit();
    }
    try recoverStagedRemovals(gpa, io, root, "journal");
    var metadata = try openRead(gpa, io, root, "journal");
    defer metadata.deinit(gpa);
    try std.testing.expect((try metadata.get(gpa, 2)) == null);
    var staged = try root.openDir(io, "journal/.trash/2.interaction", .{});
    staged.close(io);
}

test "annotation reads do not create a database and legacy json fails" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "journal", dir_permissions);
    var root = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    defer root.close(io);

    var empty = try openRead(gpa, io, root, "journal");
    empty.deinit(gpa);
    try std.testing.expectError(error.FileNotFound, root.openFile(io, "journal/journal.sqlite3", .{}));
    try root.writeFile(io, .{
        .sub_path = "journal/annotations.json",
        .data = "{}\n",
        .flags = .{ .permissions = file_permissions },
    });
    try std.testing.expectError(error.LegacyAnnotationsUnsupported, openRead(gpa, io, root, "journal"));
}
