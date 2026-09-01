//! `tj name`, `tj tag`, and `tj pin` - user-owned entry metadata.

const std = @import("std");
const Io = std.Io;
const zecli = @import("zecli");

const store = @import("store.zig");
const sys = @import("sys.zig");
const annotations = @import("annotations.zig");
const context = @import("context.zig");

pub const NameRequest = union(enum) {
    list,
    query: []const u8,
    set: struct { ref: []const u8, name: []const u8 },
    remove: []const u8,
};

pub fn nameRequest(parsed: *const zecli.Parsed) !NameRequest {
    const args = parsed.positionals.items;
    if (parsed.enabled("remove")) {
        if (args.len != 1) return error.BadArguments;
        return .{ .remove = args[0] };
    }
    return switch (args.len) {
        0 => .list,
        1 => .{ .query = args[0] },
        2 => .{ .set = .{ .ref = args[0], .name = args[1] } },
        else => error.BadArguments,
    };
}

pub fn nameCommand(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    parsed: *const zecli.Parsed,
    out: *Io.Writer,
) !void {
    switch (try nameRequest(parsed)) {
        .list => {
            const current = try context.currentJournal();
            var root = try store.openRoot(io, home);
            defer root.close(io);
            var metadata = try annotations.openRead(gpa, io, root, current);
            defer metadata.deinit(gpa);
            var names = try metadata.names();
            defer names.deinit();
            while (try names.next()) |entry| {
                if (!store.interactionExists(io, root, current, entry.number)) continue;
                try out.print("{s}  @{d}\n", .{ entry.name, entry.number });
            }
            return;
        },
        .query => |ref| {
            var root = try store.openRoot(io, home);
            defer root.close(io);
            const target = try context.locateCommandTarget(gpa, io, root, ref);
            defer target.deinit(gpa);
            try context.requireInteraction(target);
            var metadata = try annotations.openRead(gpa, io, root, target.journal);
            defer metadata.deinit(gpa);
            var entry = try metadata.get(gpa, target.number) orelse return;
            defer entry.deinit(gpa);
            const name = entry.name orelse return;
            try out.print("{s}  ", .{name});
            try context.printCanonical(out, sys.env("TJ_JOURNAL"), target.journal, target.number);
            return out.writeAll("\n");
        },
        .remove => |name| {
            var mutation = try context.openCurrentMutation(gpa, io, home, .shared);
            defer mutation.deinit(io);
            var metadata = try annotations.openWrite(gpa, io, mutation.root, mutation.journal);
            defer metadata.deinit(gpa);
            var transaction = try metadata.begin();
            defer transaction.deinit();
            try metadata.removeName(name);
            return transaction.commit();
        },
        .set => |request| try updateName(gpa, io, home, request.ref, request.name),
    }
}

/// Changes the name of one current-journal entry. The CLI and interactive
/// browser share this path so uniqueness, stale-row cleanup, and locking do
/// not acquire subtly different semantics. A null name removes the entry's
/// current name, if any.
pub fn updateName(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    ref: []const u8,
    new_name: ?[]const u8,
) !void {
    var root = try store.openRoot(io, home);
    defer root.close(io);
    const target = try context.requireMutationTarget(gpa, io, root, ref);
    defer target.deinit(gpa);
    try context.requireInteraction(target);

    var mutation = try context.openCurrentMutation(gpa, io, home, .shared);
    defer mutation.deinit(io);
    if (!store.interactionExists(io, mutation.root, mutation.journal, target.number)) return error.NoSuchInteraction;
    var metadata = try annotations.openWrite(gpa, io, mutation.root, mutation.journal);
    defer metadata.deinit(gpa);
    var transaction = try metadata.begin();
    defer transaction.deinit();

    if (new_name) |name| {
        if (try metadata.numberForName(name)) |owner| {
            if (!store.interactionExists(io, mutation.root, mutation.journal, owner)) {
                try metadata.removeName(name);
            }
        }
        try metadata.setName(target.number, name);
    } else if (try metadata.get(gpa, target.number)) |owned_entry| {
        var entry = owned_entry;
        defer entry.deinit(gpa);
        if (entry.name) |name| try metadata.removeName(name);
    }
    try transaction.commit();
}

pub const TagRequest = union(enum) {
    list,
    query: []const []const u8,
    add: struct { targets: []const []const u8, tags: []const []const u8 },
    remove: struct { targets: []const []const u8, tags: []const []const u8 },
};

pub fn tagRequest(parsed: *const zecli.Parsed, target_count: usize) !TagRequest {
    const args = parsed.positionals.items;
    if (args.len == 0) {
        if (parsed.enabled("remove")) return error.MissingArgument;
        return .list;
    }
    if (target_count == 0 or target_count > args.len) return error.BadArguments;
    const targets = args[0..target_count];
    const tags = args[target_count..];
    if (parsed.enabled("remove")) {
        if (tags.len == 0) return error.MissingArgument;
        return .{ .remove = .{ .targets = targets, .tags = tags } };
    }
    if (tags.len == 0) return .{ .query = targets };
    return .{ .add = .{ .targets = targets, .tags = tags } };
}

pub fn tagTargetCount(io: Io, root: store.Dir, args: []const []const u8) !usize {
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try root.realPath(io, &root_buf);
    const root_path = root_buf[0..root_len];

    var count: usize = 0;
    for (args) |arg| {
        const shorthand = arg.len != 0 and arg[0] == '@';
        const expanded = std.mem.startsWith(u8, arg, root_path) and
            arg.len > root_path.len and arg[root_path.len] == '/';
        if (!shorthand and !expanded) break;
        count += 1;
    }
    return count;
}

pub fn tagCommand(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    parsed: *const zecli.Parsed,
    out: *Io.Writer,
) !void {
    const target_count = if (parsed.positionals.items.len == 0) 0 else blk: {
        var root = try store.openRoot(io, home);
        defer root.close(io);
        break :blk try tagTargetCount(io, root, parsed.positionals.items);
    };
    switch (try tagRequest(parsed, target_count)) {
        .list => {
            const current = try context.currentJournal();
            var root = try store.openRoot(io, home);
            defer root.close(io);
            var metadata = try annotations.openRead(gpa, io, root, current);
            defer metadata.deinit(gpa);
            var rows = try metadata.tags();
            defer rows.deinit();
            var printed: ?u32 = null;
            while (try rows.next()) |row| {
                if (!store.interactionExists(io, root, current, row.number)) continue;
                if (printed != row.number) {
                    if (printed != null) try out.writeAll("\n");
                    try out.print("@{d}", .{row.number});
                    printed = row.number;
                }
                try out.print("  {s}", .{row.tag});
            }
            if (printed != null) try out.writeAll("\n");
        },
        .query => |targets| {
            for (targets) |target| try queryTags(gpa, io, home, target, out);
        },
        .add => |request| {
            for (request.targets) |target| try updateTags(gpa, io, home, target, request.tags, false);
        },
        .remove => |request| {
            for (request.targets) |target| try updateTags(gpa, io, home, target, request.tags, true);
        },
    }
}

pub fn queryTags(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    ref: []const u8,
    out: *Io.Writer,
) !void {
    var targets = try context.openQueryTargets(gpa, io, home, ref);
    defer targets.deinit(gpa, io);

    var metadata = try annotations.openRead(gpa, io, targets.root, targets.journal);
    defer metadata.deinit(gpa);
    const current = sys.env("TJ_JOURNAL");
    for (targets.numbers) |number| {
        var entry = (try metadata.get(gpa, number)) orelse continue;
        defer entry.deinit(gpa);
        if (entry.tags.items.len == 0) continue;
        try context.printCanonical(out, current, targets.journal, number);
        for (entry.tags.items) |tag| try out.print("  {s}", .{tag});
        try out.writeAll("\n");
    }
}

pub fn updateTags(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    ref: []const u8,
    tags: []const []const u8,
    removing: bool,
) !void {
    var targets = try context.openMutationTargets(gpa, io, home, ref);
    defer targets.deinit(gpa, io);

    const normalized = try normalizeTags(gpa, tags);
    defer freeTags(gpa, normalized);
    var metadata = try annotations.openWrite(gpa, io, targets.mutation.root, targets.mutation.journal);
    defer metadata.deinit(gpa);
    var transaction = try metadata.begin();
    defer transaction.deinit();
    try applyTags(&metadata, targets.numbers, normalized, removing);
    try transaction.commit();
}

/// Applies tags atomically to an already resolved set of current-journal
/// entry numbers. Interactive frontends use this instead of manufacturing
/// reference strings or duplicating annotation transactions.
pub fn updateTagNumbers(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    numbers: []const u32,
    tags: []const []const u8,
    removing: bool,
) !void {
    var mutation = try context.openCurrentMutation(gpa, io, home, .shared);
    defer mutation.deinit(io);
    for (numbers) |number| {
        if (!store.interactionExists(io, mutation.root, mutation.journal, number)) return error.NoSuchInteraction;
    }
    const normalized = try normalizeTags(gpa, tags);
    defer freeTags(gpa, normalized);
    var metadata = try annotations.openWrite(gpa, io, mutation.root, mutation.journal);
    defer metadata.deinit(gpa);
    var transaction = try metadata.begin();
    defer transaction.deinit();
    try applyTags(&metadata, numbers, normalized, removing);
    try transaction.commit();
}

fn applyTags(metadata: *annotations.Connection, numbers: []const u32, tags: []const []const u8, removing: bool) !void {
    for (numbers) |number| {
        for (tags) |tag| {
            if (removing) {
                try metadata.removeTag(number, tag);
            } else {
                try metadata.addTag(number, tag);
            }
        }
    }
}

pub fn normalizeTags(gpa: std.mem.Allocator, tags: []const []const u8) ![][]u8 {
    const normalized = try gpa.alloc([]u8, tags.len);
    errdefer gpa.free(normalized);
    var completed: usize = 0;
    errdefer for (normalized[0..completed]) |tag| gpa.free(tag);
    for (tags, 0..) |tag, index| {
        normalized[index] = try annotations.normalizeTag(gpa, tag);
        completed += 1;
    }
    return normalized;
}

pub fn freeTags(gpa: std.mem.Allocator, tags: [][]u8) void {
    for (tags) |tag| gpa.free(tag);
    gpa.free(tags);
}

pub const PinRequest = union(enum) {
    list,
    set: []const u8,
    remove: []const u8,
};

pub fn pinRequest(parsed: *const zecli.Parsed) !PinRequest {
    const args = parsed.positionals.items;
    if (parsed.enabled("remove")) {
        if (args.len != 1) return error.BadArguments;
        return .{ .remove = args[0] };
    }
    return switch (args.len) {
        0 => .list,
        1 => .{ .set = args[0] },
        else => error.BadArguments,
    };
}

pub fn pinCommand(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    parsed: *const zecli.Parsed,
    out: *Io.Writer,
) !void {
    switch (try pinRequest(parsed)) {
        .list => {
            const current = try context.currentJournal();
            var root = try store.openRoot(io, home);
            defer root.close(io);
            var metadata = try annotations.openRead(gpa, io, root, current);
            defer metadata.deinit(gpa);
            var pins = try metadata.pins();
            defer pins.deinit();
            while (try pins.next()) |number| {
                if (store.interactionExists(io, root, current, number)) try out.print("@{d}\n", .{number});
            }
        },
        .set => |ref| try updatePin(gpa, io, home, ref, true),
        .remove => |ref| try updatePin(gpa, io, home, ref, false),
    }
}

pub fn updatePin(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    ref: []const u8,
    pinned: bool,
) !void {
    var targets = try context.openMutationTargets(gpa, io, home, ref);
    defer targets.deinit(gpa, io);

    var metadata = try annotations.openWrite(gpa, io, targets.mutation.root, targets.mutation.journal);
    defer metadata.deinit(gpa);
    var transaction = try metadata.begin();
    defer transaction.deinit();
    try applyPins(&metadata, targets.numbers, pinned);
    try transaction.commit();
}

/// Pins or unpins an already resolved selection in one transaction.
pub fn updatePinNumbers(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    numbers: []const u32,
    pinned: bool,
) !void {
    var mutation = try context.openCurrentMutation(gpa, io, home, .shared);
    defer mutation.deinit(io);
    for (numbers) |number| {
        if (!store.interactionExists(io, mutation.root, mutation.journal, number)) return error.NoSuchInteraction;
    }
    var metadata = try annotations.openWrite(gpa, io, mutation.root, mutation.journal);
    defer metadata.deinit(gpa);
    var transaction = try metadata.begin();
    defer transaction.deinit();
    try applyPins(&metadata, numbers, pinned);
    try transaction.commit();
}

fn applyPins(metadata: *annotations.Connection, numbers: []const u32, pinned: bool) !void {
    for (numbers) |number| try metadata.setPinned(number, pinned);
}
