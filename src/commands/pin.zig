//! `tj pin` - entry-local pin management.

const std = @import("std");
const Io = std.Io;
const zecli = @import("zecli");

const store = @import("../journal/store.zig");
const pins = @import("../journal/pins.zig");
const context = @import("context.zig");

pub const Request = union(enum) {
    list,
    set: []const u8,
    remove: []const u8,
};

pub fn request(parsed: *const zecli.Parsed) !Request {
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

pub fn pinCommand(gpa: std.mem.Allocator, io: Io, home: ?[]const u8, parsed: *const zecli.Parsed, out: *Io.Writer) !void {
    switch (try request(parsed)) {
        .list => {
            const current = try context.currentJournal();
            var root = try store.openRoot(io, home);
            defer root.close(io);
            const numbers = try store.listNumbers(gpa, io, root, current);
            defer gpa.free(numbers);
            for (numbers) |number| if (try pins.isPinned(io, root, current, number)) {
                try out.print("@{d}\n", .{number});
            };
        },
        .set => |ref| try updatePin(gpa, io, home, ref, true),
        .remove => |ref| try updatePin(gpa, io, home, ref, false),
    }
}

pub fn updatePin(gpa: std.mem.Allocator, io: Io, home: ?[]const u8, ref: []const u8, pinned: bool) !void {
    var targets = try context.openMutationTargets(gpa, io, home, ref);
    defer targets.deinit(gpa, io);
    try apply(targets.mutation.root, io, targets.mutation.journal, targets.numbers, pinned);
}

pub fn updatePinNumbers(gpa: std.mem.Allocator, io: Io, home: ?[]const u8, numbers: []const u32, pinned: bool) !void {
    var mutation = try context.openCurrentMutation(gpa, io, home, .exclusive);
    defer mutation.deinit(io);
    for (numbers) |number| {
        if (!store.interactionExists(io, mutation.root, mutation.journal, number)) return error.NoSuchInteraction;
    }
    try apply(mutation.root, io, mutation.journal, numbers, pinned);
}

fn apply(root: store.Dir, io: Io, journal: []const u8, numbers: []const u32, pinned: bool) !void {
    for (numbers) |number| try pins.setPinned(io, root, journal, number, pinned);
}
