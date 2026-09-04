//! Entry-local pin markers.
//!
//! A journal entry is pinned when `<journal>/<entry>/pin` exists. The marker
//! is intentionally empty: its presence is the value, and it moves or is
//! deleted with the entry directory.

const std = @import("std");
const Io = std.Io;

pub const marker_name = "pin";

pub fn isPinned(io: Io, root: Io.Dir, journal: []const u8, number: u32) !bool {
    var journal_dir = root.openDir(io, journal, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer journal_dir.close(io);
    var number_buf: [16]u8 = undefined;
    const entry_name = try std.fmt.bufPrint(&number_buf, "{d}", .{number});
    var entry_dir = journal_dir.openDir(io, entry_name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer entry_dir.close(io);
    _ = entry_dir.statFile(io, marker_name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

pub fn setPinned(io: Io, root: Io.Dir, journal: []const u8, number: u32, pinned: bool) !void {
    var journal_dir = try root.openDir(io, journal, .{ .follow_symlinks = false });
    defer journal_dir.close(io);
    var number_buf: [16]u8 = undefined;
    const entry_name = try std.fmt.bufPrint(&number_buf, "{d}", .{number});
    var entry_dir = try journal_dir.openDir(io, entry_name, .{ .follow_symlinks = false });
    defer entry_dir.close(io);
    if (pinned) {
        const file = entry_dir.createFile(io, marker_name, .{
            .exclusive = true,
            .permissions = @enumFromInt(0o600),
        }) catch |err| switch (err) {
            error.PathAlreadyExists => return,
            else => return err,
        };
        file.close(io);
    } else {
        entry_dir.deleteFile(io, marker_name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
}

test "pin markers are sparse and idempotent" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "journal/1");

    try std.testing.expect(!try isPinned(io, tmp.dir, "journal", 1));
    try setPinned(io, tmp.dir, "journal", 1, true);
    try setPinned(io, tmp.dir, "journal", 1, true);
    try std.testing.expect(try isPinned(io, tmp.dir, "journal", 1));
    try setPinned(io, tmp.dir, "journal", 1, false);
    try setPinned(io, tmp.dir, "journal", 1, false);
    try std.testing.expect(!try isPinned(io, tmp.dir, "journal", 1));
}
