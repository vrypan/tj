//! Journal-local coordination between annotation writes and destructive work.

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;

const file_permissions: File.Permissions = @enumFromInt(0o600);
const dir_permissions: File.Permissions = @enumFromInt(0o700);

pub const Mode = enum { shared, exclusive };

/// Serializes short operations that change the root journal namespace.
pub fn acquireNamespace(io: Io, root: Dir) !File {
    return acquireNamed(io, root, ".namespace", "", .exclusive);
}

pub fn acquire(io: Io, root: Dir, journal: []const u8, mode: Mode) !File {
    return acquireNamed(io, root, journal, ".mutation", mode);
}

/// Serializes connection setup and first-time WAL/schema initialization. The
/// handle is released before the caller begins its annotation transaction.
pub fn acquireMetadataInit(io: Io, root: Dir, journal: []const u8) !File {
    return acquireNamed(io, root, journal, ".metadata", .exclusive);
}

fn acquireNamed(io: Io, root: Dir, journal: []const u8, suffix: []const u8, mode: Mode) !File {
    _ = root.createDir(io, ".locks", dir_permissions) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    var locks = try root.openDir(io, ".locks", .{});
    defer locks.close(io);
    var name_buf: [@import("name.zig").max_len + 16]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "{s}{s}", .{ journal, suffix });
    return locks.createFile(io, name, .{
        .read = true,
        .truncate = false,
        .lock = switch (mode) {
            .shared => .shared,
            .exclusive => .exclusive,
        },
        .permissions = file_permissions,
    });
}

pub fn removeFile(io: Io, root: Dir, journal: []const u8) void {
    var path_buf: [80]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, ".locks/{s}.mutation", .{journal}) catch return;
    root.deleteFile(io, path) catch {};
}

pub fn removeMetadataFile(io: Io, root: Dir, journal: []const u8) void {
    var path_buf: [80]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, ".locks/{s}.metadata", .{journal}) catch return;
    root.deleteFile(io, path) catch {};
}

test "shared guards compose while exclusive guards serialize" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "journal", dir_permissions);
    var root = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    defer root.close(io);

    const first = try acquire(io, root, "journal", .shared);
    defer first.close(io);
    const second = try acquire(io, root, "journal", .shared);
    defer second.close(io);

    var lock_file = try root.openFile(io, ".locks/journal.mutation", .{});
    defer lock_file.close(io);
    try std.testing.expect(!(try lock_file.tryLock(io, .exclusive)));
}
