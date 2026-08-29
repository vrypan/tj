//! Narrow ownership-safe wrapper around TJ's embedded SQLite amalgamation.

const std = @import("std");

pub const c = @cImport({
    @cInclude("sqlite3.h");
    @cInclude("sqlite_shim.h");
});

pub const Error = error{
    Busy,
    Constraint,
    InvalidDatabase,
    DatabaseFailure,
};

pub const Step = enum { row, done };

pub const Database = struct {
    handle: *c.sqlite3,

    pub fn open(path: [*:0]const u8, flags: c_int) Error!Database {
        var handle: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open_v2(path, &handle, flags, null);
        if (rc != c.SQLITE_OK) {
            if (handle) |opened| _ = c.sqlite3_close_v2(opened);
            return mapResult(rc);
        }
        const db = Database{ .handle = handle.? };
        _ = c.sqlite3_extended_result_codes(db.handle, 1);
        return db;
    }

    pub fn close(self: *Database) void {
        _ = c.sqlite3_close_v2(self.handle);
        self.* = undefined;
    }

    pub fn exec(self: *Database, sql: [*:0]const u8) Error!void {
        const rc = c.sqlite3_exec(self.handle, sql, null, null, null);
        if (rc != c.SQLITE_OK) return mapResult(rc);
    }

    pub fn prepare(self: *Database, sql: [*:0]const u8) Error!Statement {
        var handle: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v3(
            self.handle,
            sql,
            -1,
            c.SQLITE_PREPARE_PERSISTENT,
            &handle,
            null,
        );
        if (rc != c.SQLITE_OK) return mapResult(rc);
        return .{ .handle = handle.? };
    }

    pub fn busyTimeout(self: *Database, milliseconds: c_int) Error!void {
        const rc = c.sqlite3_busy_timeout(self.handle, milliseconds);
        if (rc != c.SQLITE_OK) return mapResult(rc);
    }

    pub fn extendedCode(self: *Database) c_int {
        return c.sqlite3_extended_errcode(self.handle);
    }
};

pub const Statement = struct {
    handle: *c.sqlite3_stmt,

    pub fn finalize(self: *Statement) void {
        _ = c.sqlite3_finalize(self.handle);
        self.* = undefined;
    }

    pub fn reset(self: *Statement) Error!void {
        const rc = c.sqlite3_reset(self.handle);
        if (rc != c.SQLITE_OK) return mapResult(rc);
        _ = c.sqlite3_clear_bindings(self.handle);
    }

    pub fn bindInt(self: *Statement, index: c_int, value: i64) Error!void {
        const rc = c.sqlite3_bind_int64(self.handle, index, value);
        if (rc != c.SQLITE_OK) return mapResult(rc);
    }

    pub fn bindText(self: *Statement, index: c_int, value: []const u8) Error!void {
        const length = std.math.cast(c_int, value.len) orelse return error.DatabaseFailure;
        const rc = c.tj_sqlite_bind_text(
            self.handle,
            index,
            value.ptr,
            length,
        );
        if (rc != c.SQLITE_OK) return mapResult(rc);
    }

    pub fn step(self: *Statement) Error!Step {
        return switch (c.sqlite3_step(self.handle)) {
            c.SQLITE_ROW => .row,
            c.SQLITE_DONE => .done,
            else => |rc| mapResult(rc),
        };
    }

    pub fn columnInt(self: *const Statement, column: c_int) i64 {
        return c.sqlite3_column_int64(self.handle, column);
    }

    pub fn columnText(self: *const Statement, column: c_int) Error![]const u8 {
        if (c.sqlite3_column_type(self.handle, column) != c.SQLITE_TEXT) return error.InvalidDatabase;
        const ptr = c.sqlite3_column_text(self.handle, column) orelse return error.InvalidDatabase;
        const length = c.sqlite3_column_bytes(self.handle, column);
        if (length < 0) return error.InvalidDatabase;
        return ptr[0..@intCast(length)];
    }
};

pub const Transaction = struct {
    db: *Database,
    active: bool = true,

    pub fn beginImmediate(db: *Database) Error!Transaction {
        try db.exec("BEGIN IMMEDIATE");
        return .{ .db = db };
    }

    pub fn commit(self: *Transaction) Error!void {
        try self.db.exec("COMMIT");
        self.active = false;
    }

    pub fn deinit(self: *Transaction) void {
        if (self.active) self.db.exec("ROLLBACK") catch {};
        self.active = false;
    }
};

fn mapResult(rc: c_int) Error {
    return switch (rc & 0xff) {
        c.SQLITE_BUSY, c.SQLITE_LOCKED => error.Busy,
        c.SQLITE_CONSTRAINT => error.Constraint,
        c.SQLITE_CORRUPT, c.SQLITE_NOTADB, c.SQLITE_SCHEMA => error.InvalidDatabase,
        else => error.DatabaseFailure,
    };
}

test "embedded sqlite version is pinned" {
    try std.testing.expectEqual(@as(c_int, 3_053_004), c.sqlite3_libversion_number());
}

test "sqlite wrapper binds text and rolls transactions back" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "test.sqlite3", .{ .permissions = @enumFromInt(0o600) });
    file.close(io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &path_buf);
    const suffix = "/test.sqlite3";
    @memcpy(path_buf[root_len..][0..suffix.len], suffix);
    path_buf[root_len + suffix.len] = 0;

    var db = try Database.open(
        @ptrCast(path_buf[0 .. root_len + suffix.len :0].ptr),
        c.SQLITE_OPEN_READWRITE,
    );
    defer db.close();
    try db.exec("CREATE TABLE values_table(value TEXT NOT NULL)");

    {
        var transaction = try Transaction.beginImmediate(&db);
        defer transaction.deinit();
        var insert = try db.prepare("INSERT INTO values_table(value) VALUES (?)");
        defer insert.finalize();
        try insert.bindText(1, "quotes ' and $shell; text");
        try std.testing.expectEqual(Step.done, try insert.step());
    }

    var count = try db.prepare("SELECT count(*) FROM values_table");
    defer count.finalize();
    try std.testing.expectEqual(Step.row, try count.step());
    try std.testing.expectEqual(@as(i64, 0), count.columnInt(0));
}
