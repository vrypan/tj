//! `tj pin` - entry-local pin management.

const std = @import("std");
const Io = std.Io;
const zecli = @import("zecli");

const store = @import("../journal/store.zig");
const pins = @import("../journal/pins.zig");
const report = @import("../presentation/report.zig");
const sys = @import("../sys.zig");
const context = @import("context.zig");

pub const Request = union(enum) {
    list: bool,
    set: []const []const u8,
    remove: []const []const u8,
};

pub fn request(parsed: *const zecli.Parsed) !Request {
    const args = parsed.positionals.items;
    if (parsed.enabled("numbers")) {
        if (args.len != 0 or parsed.enabled("remove")) return error.BadArguments;
        return .{ .list = true };
    }
    if (parsed.enabled("remove")) {
        if (args.len == 0) return error.BadArguments;
        return .{ .remove = args };
    }
    if (args.len == 0) return .{ .list = false };
    return .{ .set = args };
}

pub fn pinCommand(gpa: std.mem.Allocator, io: Io, home: ?[]const u8, parsed: *const zecli.Parsed, out: *Io.Writer) !void {
    switch (try request(parsed)) {
        .list => |numbers_only| {
            const current = try context.currentJournal();
            var root = try store.openRoot(io, home);
            defer root.close(io);
            const numbers = try store.listNumbers(gpa, io, root, current);
            defer gpa.free(numbers);
            if (!numbers_only) {
                for (numbers) |number| if (try pins.isPinned(io, root, current, number)) {
                    try out.print("@{d}\n", .{number});
                };
                return;
            }
            var selected: std.ArrayList(u32) = .empty;
            defer selected.deinit(gpa);
            for (numbers) |number| if (try pins.isPinned(io, root, current, number)) try selected.append(gpa, number);
            var noout_region: report.NooutRegion = .{ .out = out, .enabled = sys.isTty(io, 1) };
            defer noout_region.finish();
            if (selected.items.len != 0) try noout_region.begin();
            try context.writeNumbers(out, selected.items);
        },
        .set => |refs| try updatePins(gpa, io, home, refs, true),
        .remove => |refs| try updatePins(gpa, io, home, refs, false),
    }
}

pub fn updatePins(gpa: std.mem.Allocator, io: Io, home: ?[]const u8, refs: []const []const u8, pinned: bool) !void {
    var targets = try context.openMutationTargetList(gpa, io, home, refs);
    defer targets.deinit(gpa, io);
    try apply(targets.mutation.root, io, targets.mutation.journal, targets.numbers, pinned);
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
