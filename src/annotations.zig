//! Journal-local user annotations.
//!
//! Recording metadata belongs to each interaction's `meta.json`. Names, tags,
//! and pins are user-owned and live together in `annotations.json` so they
//! travel with the journal without changing the recording format.

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;

const file_permissions: File.Permissions = @enumFromInt(0o600);
const dir_permissions: File.Permissions = @enumFromInt(0o700);
const max_manifest_bytes = 4 * 1024 * 1024;

pub const Entry = struct {
    number: u32,
    name: ?[]u8 = null,
    tags: std.ArrayList([]u8) = .empty,
    pinned: bool = false,

    fn deinit(self: *Entry, gpa: std.mem.Allocator) void {
        if (self.name) |name| gpa.free(name);
        for (self.tags.items) |tag| gpa.free(tag);
        self.tags.deinit(gpa);
    }
};

pub const Manifest = struct {
    entries: std.ArrayList(Entry) = .empty,

    pub fn deinit(self: *Manifest, gpa: std.mem.Allocator) void {
        for (self.entries.items) |*entry| entry.deinit(gpa);
        self.entries.deinit(gpa);
    }

    pub fn find(self: *Manifest, number: u32) ?*Entry {
        for (self.entries.items) |*entry| if (entry.number == number) return entry;
        return null;
    }

    pub fn findConst(self: *const Manifest, number: u32) ?*const Entry {
        for (self.entries.items) |*entry| if (entry.number == number) return entry;
        return null;
    }

    pub fn numberForName(self: *const Manifest, name: []const u8) ?u32 {
        for (self.entries.items) |entry| {
            if (entry.name) |candidate| {
                if (std.mem.eql(u8, candidate, name)) return entry.number;
            }
        }
        return null;
    }

    fn ensure(self: *Manifest, gpa: std.mem.Allocator, number: u32) !*Entry {
        if (self.find(number)) |entry| return entry;
        try self.entries.append(gpa, .{ .number = number });
        return &self.entries.items[self.entries.items.len - 1];
    }

    pub fn setName(self: *Manifest, gpa: std.mem.Allocator, number: u32, name: []const u8) !void {
        if (!validName(name)) return error.InvalidName;
        if (self.numberForName(name)) |owner| {
            if (owner != number) return error.NameTaken;
        }
        const entry = try self.ensure(gpa, number);
        const owned = try gpa.dupe(u8, name);
        if (entry.name) |old| gpa.free(old);
        entry.name = owned;
    }

    pub fn removeName(self: *Manifest, gpa: std.mem.Allocator, name: []const u8) !void {
        if (!validName(name)) return error.InvalidName;
        for (self.entries.items, 0..) |*entry, i| {
            const old = entry.name orelse continue;
            if (!std.mem.eql(u8, old, name)) continue;
            gpa.free(old);
            entry.name = null;
            self.removeEmpty(gpa, i);
            return;
        }
    }

    pub fn addTag(self: *Manifest, gpa: std.mem.Allocator, number: u32, text: []const u8) !void {
        const tag = try normalizeTag(gpa, text);
        errdefer gpa.free(tag);
        const entry = try self.ensure(gpa, number);
        for (entry.tags.items) |old| {
            if (std.mem.eql(u8, old, tag)) {
                gpa.free(tag);
                return;
            }
        }
        try entry.tags.append(gpa, tag);
        std.mem.sort([]u8, entry.tags.items, {}, lessString);
    }

    pub fn removeTag(self: *Manifest, gpa: std.mem.Allocator, number: u32, text: []const u8) !void {
        const tag = try normalizeTag(gpa, text);
        defer gpa.free(tag);
        for (self.entries.items, 0..) |*entry, entry_i| {
            if (entry.number != number) continue;
            for (entry.tags.items, 0..) |old, tag_i| {
                if (!std.mem.eql(u8, old, tag)) continue;
                gpa.free(old);
                _ = entry.tags.orderedRemove(tag_i);
                self.removeEmpty(gpa, entry_i);
                return;
            }
            return;
        }
    }

    pub fn setPinned(self: *Manifest, gpa: std.mem.Allocator, number: u32, pinned: bool) !void {
        if (pinned) {
            const entry = try self.ensure(gpa, number);
            entry.pinned = true;
            return;
        }
        for (self.entries.items, 0..) |*entry, i| {
            if (entry.number != number) continue;
            entry.pinned = false;
            self.removeEmpty(gpa, i);
            return;
        }
    }

    pub fn removeInteraction(self: *Manifest, gpa: std.mem.Allocator, number: u32) void {
        for (self.entries.items, 0..) |*entry, i| {
            if (entry.number != number) continue;
            entry.deinit(gpa);
            _ = self.entries.orderedRemove(i);
            return;
        }
    }

    pub fn hasAllTags(self: *const Manifest, number: u32, wanted: []const []const u8) bool {
        if (wanted.len == 0) return true;
        const entry = self.findConst(number) orelse return false;
        for (wanted) |tag| {
            var found = false;
            for (entry.tags.items) |actual| {
                if (std.mem.eql(u8, actual, tag)) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }
        return true;
    }

    fn removeEmpty(self: *Manifest, gpa: std.mem.Allocator, index: usize) void {
        const entry = &self.entries.items[index];
        if (entry.name != null or entry.tags.items.len != 0 or entry.pinned) return;
        entry.deinit(gpa);
        _ = self.entries.orderedRemove(index);
    }
};

fn lessString(_: void, a: []u8, b: []u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn lessEntry(_: void, a: Entry, b: Entry) bool {
    return a.number < b.number;
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
    if (!std.ascii.isAlphanumeric(tag[0]) or !std.ascii.isAlphanumeric(tag[tag.len - 1])) return error.InvalidTag;
    for (tag) |char| {
        if (!(std.ascii.isAlphanumeric(char) or char == '.' or char == '_' or char == '-')) return error.InvalidTag;
    }
    return tag;
}

pub fn acquireMutationLock(io: Io, root: Dir, journal: []const u8) !File {
    _ = root.createDir(io, ".locks", dir_permissions) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    var locks = try root.openDir(io, ".locks", .{});
    defer locks.close(io);
    var name_buf: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "{s}.mutation", .{journal});
    return locks.createFile(io, name, .{
        .read = true,
        .truncate = false,
        .lock = .exclusive,
        .permissions = file_permissions,
    });
}

pub fn removeMutationLockFile(io: Io, root: Dir, journal: []const u8) void {
    var path_buf: [80]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, ".locks/{s}.mutation", .{journal}) catch return;
    root.deleteFile(io, path) catch {};
}

pub fn load(gpa: std.mem.Allocator, io: Io, root: Dir, journal: []const u8) !Manifest {
    var path_buf: [96]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/annotations.json", .{journal});
    const text = root.readFileAlloc(io, path, gpa, .limited(max_manifest_bytes)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer gpa.free(text);

    const parsed = std.json.parseFromSlice(std.json.Value, gpa, text, .{}) catch return error.InvalidAnnotations;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidAnnotations;
    const top = parsed.value.object;
    if (top.count() != 2) return error.InvalidAnnotations;
    const version = top.get("v") orelse return error.InvalidAnnotations;
    if (version != .integer or version.integer != 1) return error.InvalidAnnotations;
    const interactions_value = top.get("interactions") orelse return error.InvalidAnnotations;
    if (interactions_value != .object) return error.InvalidAnnotations;

    var result: Manifest = .{};
    errdefer result.deinit(gpa);
    var it = interactions_value.object.iterator();
    while (it.next()) |item| {
        const number = std.fmt.parseInt(u32, item.key_ptr.*, 10) catch return error.InvalidAnnotations;
        if (number == 0 or item.value_ptr.* != .object) return error.InvalidAnnotations;
        const object = item.value_ptr.object;
        var fields = object.iterator();
        while (fields.next()) |field| {
            if (!std.mem.eql(u8, field.key_ptr.*, "name") and
                !std.mem.eql(u8, field.key_ptr.*, "tags") and
                !std.mem.eql(u8, field.key_ptr.*, "pinned")) return error.InvalidAnnotations;
        }
        var entry: Entry = .{ .number = number };
        errdefer entry.deinit(gpa);

        if (object.get("name")) |value| {
            if (value != .string or !validName(value.string)) return error.InvalidAnnotations;
            if (result.numberForName(value.string) != null) return error.InvalidAnnotations;
            entry.name = try gpa.dupe(u8, value.string);
        }
        if (object.get("tags")) |value| {
            if (value != .array) return error.InvalidAnnotations;
            for (value.array.items) |tag_value| {
                if (tag_value != .string) return error.InvalidAnnotations;
                const tag = try normalizeTag(gpa, tag_value.string);
                errdefer gpa.free(tag);
                if (!std.mem.eql(u8, tag, tag_value.string)) return error.InvalidAnnotations;
                for (entry.tags.items) |old| if (std.mem.eql(u8, old, tag)) return error.InvalidAnnotations;
                try entry.tags.append(gpa, tag);
            }
            std.mem.sort([]u8, entry.tags.items, {}, lessString);
        }
        if (object.get("pinned")) |value| {
            if (value != .bool) return error.InvalidAnnotations;
            entry.pinned = value.bool;
        }
        if (entry.name == null and entry.tags.items.len == 0 and !entry.pinned) return error.InvalidAnnotations;
        try result.entries.append(gpa, entry);
    }
    std.mem.sort(Entry, result.entries.items, {}, lessEntry);
    return result;
}

pub fn save(gpa: std.mem.Allocator, io: Io, root: Dir, journal: []const u8, manifest: *Manifest) !void {
    std.mem.sort(Entry, manifest.entries.items, {}, lessEntry);
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(gpa);
    var allocating = Io.Writer.Allocating.fromArrayList(gpa, &json);
    defer json = allocating.toArrayList();
    const out = &allocating.writer;

    try out.writeAll("{\"v\":1,\"interactions\":{");
    for (manifest.entries.items, 0..) |entry, i| {
        if (i != 0) try out.writeAll(",");
        try out.print("\"{d}\":{{", .{entry.number});
        var field = false;
        if (entry.name) |name| {
            try out.writeAll("\"name\":");
            try std.json.Stringify.encodeJsonString(name, .{}, out);
            field = true;
        }
        if (entry.tags.items.len != 0) {
            if (field) try out.writeAll(",");
            try out.writeAll("\"tags\":[");
            for (entry.tags.items, 0..) |tag, tag_i| {
                if (tag_i != 0) try out.writeAll(",");
                try std.json.Stringify.encodeJsonString(tag, .{}, out);
            }
            try out.writeAll("]");
            field = true;
        }
        if (entry.pinned) {
            if (field) try out.writeAll(",");
            try out.writeAll("\"pinned\":true");
        }
        try out.writeAll("}");
    }
    try out.writeAll("}}\n");
    if (out.buffered().len > max_manifest_bytes) return error.InvalidAnnotations;

    var journal_dir = try root.openDir(io, journal, .{});
    defer journal_dir.close(io);
    journal_dir.deleteFile(io, ".annotations.tmp") catch {};
    const temp = try journal_dir.createFile(io, ".annotations.tmp", .{
        .truncate = true,
        .permissions = file_permissions,
    });
    var renamed = false;
    defer if (!renamed) journal_dir.deleteFile(io, ".annotations.tmp") catch {};
    errdefer temp.close(io);
    try temp.writePositionalAll(io, out.buffered(), 0);
    try temp.sync(io);
    temp.close(io);
    try journal_dir.rename(".annotations.tmp", journal_dir, "annotations.json", io);
    renamed = true;
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

test "names are unique and tag and pin operations are idempotent" {
    const gpa = std.testing.allocator;
    var manifest: Manifest = .{};
    defer manifest.deinit(gpa);
    try manifest.setName(gpa, 1, "first");
    try std.testing.expectError(error.NameTaken, manifest.setName(gpa, 2, "first"));
    try manifest.setName(gpa, 1, "renamed");
    try manifest.addTag(gpa, 1, "BUG");
    try manifest.addTag(gpa, 1, "bug");
    try manifest.setPinned(gpa, 1, true);
    try manifest.setPinned(gpa, 1, true);
    try std.testing.expectEqual(@as(usize, 1), manifest.find(1).?.tags.items.len);
    try std.testing.expect(manifest.find(1).?.pinned);
}

test "annotation manifests round trip atomically" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "journal", dir_permissions);
    var root = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    defer root.close(io);

    var manifest: Manifest = .{};
    defer manifest.deinit(gpa);
    try manifest.setName(gpa, 42, "build-failure");
    try manifest.addTag(gpa, 42, "Parser");
    try manifest.setPinned(gpa, 42, true);
    try save(gpa, io, root, "journal", &manifest);

    var loaded = try load(gpa, io, root, "journal");
    defer loaded.deinit(gpa);
    const entry = loaded.findConst(42).?;
    try std.testing.expectEqualStrings("build-failure", entry.name.?);
    try std.testing.expectEqualStrings("parser", entry.tags.items[0]);
    try std.testing.expect(entry.pinned);
}

test "malformed and newer annotation manifests fail closed" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "journal", dir_permissions);
    var root = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    defer root.close(io);

    try root.writeFile(io, .{
        .sub_path = "journal/annotations.json",
        .data = "{not json}\n",
        .flags = .{ .permissions = file_permissions },
    });
    try std.testing.expectError(error.InvalidAnnotations, load(gpa, io, root, "journal"));

    try root.writeFile(io, .{
        .sub_path = "journal/annotations.json",
        .data = "{\"v\":2,\"interactions\":{}}\n",
        .flags = .{ .permissions = file_permissions },
    });
    try std.testing.expectError(error.InvalidAnnotations, load(gpa, io, root, "journal"));

    const unchanged = try root.readFileAlloc(io, "journal/annotations.json", gpa, .limited(256));
    defer gpa.free(unchanged);
    try std.testing.expectEqualStrings("{\"v\":2,\"interactions\":{}}\n", unchanged);
}
