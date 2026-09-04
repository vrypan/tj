//! `tj rm` entry removal plus the journal-removal primitive used by `tjctl`.

const std = @import("std");
const Io = std.Io;
const zecli = @import("zecli");

const store = @import("../journal/store.zig");
const sys = @import("../sys.zig");
const pins = @import("../journal/pins.zig");
const context = @import("context.zig");
const cmd_pin = @import("pin.zig");

pub const RemoveRequest = struct {
    targets: []const []const u8,
    force: bool,
};

pub fn removeRequest(parsed: *const zecli.Parsed) !RemoveRequest {
    if (parsed.positionals.items.len == 0) return error.BadArguments;
    return .{ .targets = parsed.positionals.items, .force = parsed.enabled("force") };
}

test "pin and removal requests select one semantic mode" {
    const gpa = std.testing.allocator;

    {
        var parsed = try context.parseTestCommand(.pin, &.{"@2"});
        defer parsed.deinit(gpa);
        try std.testing.expectEqualStrings("@2", (try cmd_pin.request(&parsed)).set);
    }
    {
        var parsed = try context.parseTestCommand(.rm, &.{ "--force", "@2", "@4/out", "@6..@8" });
        defer parsed.deinit(gpa);
        const request = try removeRequest(&parsed);
        try std.testing.expectEqual(@as(usize, 3), request.targets.len);
        try std.testing.expectEqualStrings("@2", request.targets[0]);
        try std.testing.expectEqualStrings("@4/out", request.targets[1]);
        try std.testing.expectEqualStrings("@6..@8", request.targets[2]);
        try std.testing.expect(request.force);
    }
}

pub fn removeCommand(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    parsed: *const zecli.Parsed,
    out: *Io.Writer,
) !void {
    _ = out;
    const request = try removeRequest(parsed);
    for (request.targets) |target| {
        try removeInteraction(gpa, io, home, target, request.force);
    }
}

pub fn removeJournal(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    selector: []const u8,
    force: bool,
    out: *Io.Writer,
) !void {
    if (sys.env("TJ_JOURNAL") != null) return error.InsideJournalRemoval;
    var root = try store.openRoot(io, home);
    defer root.close(io);
    const journal = try store.findUniqueJournal(gpa, io, root, selector);
    defer gpa.free(journal);

    const entries = try store.countInteractions(gpa, io, root, journal);
    if (!force) {
        const numbers = try store.listNumbers(gpa, io, root, journal);
        defer gpa.free(numbers);
        for (numbers) |number| if (try pins.isPinned(io, root, journal, number)) return error.PinnedInteraction;
        if (!sys.isTty(io, 0)) return error.ConfirmationRequired;
        try out.print("Remove journal {s} with {d} {s}? [y/N] ", .{
            journal,
            entries,
            if (entries == 1) "entry" else "entries",
        });
        try out.flush();
        var answer_buf: [32]u8 = undefined;
        const read = try sys.read(0, &answer_buf);
        const answer = std.mem.trim(u8, answer_buf[0..read], " \t\r\n");
        if (!(std.ascii.eqlIgnoreCase(answer, "y") or std.ascii.eqlIgnoreCase(answer, "yes"))) {
            return error.Cancelled;
        }
    }
    return store.removeJournal(gpa, io, root, journal, force) catch |err| switch (err) {
        error.ActiveJournal => error.ActiveJournal,
        else => return err,
    };
}

pub fn removeInteraction(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    interaction: []const u8,
    force: bool,
) !void {
    if (try context.parseInteractionRange(interaction)) |range| {
        return removeInteractionRange(gpa, io, home, range, force);
    }
    const target = blk: {
        var root = try store.openRoot(io, home);
        defer root.close(io);
        break :blk try context.requireMutationTarget(gpa, io, root, interaction);
    };
    defer target.deinit(gpa);
    const output_only = std.mem.eql(u8, target.subpath, "out");
    if (target.subpath.len != 0 and !output_only) return error.UnsupportedRemoval;

    var mutation = try context.openCurrentMutation(gpa, io, home, .exclusive);
    defer mutation.deinit(io);
    if (!std.mem.eql(u8, target.journal, mutation.journal)) return error.CrossJournalMutation;
    if (!store.interactionExists(io, mutation.root, mutation.journal, target.number)) return error.NoSuchInteraction;
    const highest = try store.highestNumber(gpa, io, mutation.root, mutation.journal) orelse
        return error.NoSuchInteraction;
    if (target.number >= highest) return error.CurrentInteraction;

    if (!force and try pins.isPinned(io, mutation.root, mutation.journal, target.number)) {
        context.note("tj: skipped pinned entry @{d}; use --force to remove it\n", .{target.number});
        return;
    }

    if (output_only) {
        return store.removeOutput(gpa, io, mutation.root, mutation.journal, target.number) catch |err| switch (err) {
            error.InvalidMetadata => error.InvalidMetadata,
            else => return err,
        };
    }

    const staged = try store.stageInteractionRemoval(gpa, io, mutation.root, mutation.journal, target.number);
    defer gpa.free(staged);
    try store.finishStagedRemoval(io, mutation.root, staged);
}

pub fn removeInteractionRange(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    range: context.InteractionRange,
    force: bool,
) !void {
    var mutation = try context.openCurrentMutation(gpa, io, home, .exclusive);
    defer mutation.deinit(io);
    const selected = try context.selectedNumbers(gpa, io, mutation.root, mutation.journal, range);
    defer gpa.free(selected);
    const result = try removeNumbers(gpa, io, &mutation, selected, force);
    noteSkippedPins(result.skipped_pinned);
}

pub const RemovalResult = struct {
    removed: usize,
    skipped_pinned: usize,
};

/// Removes an already resolved, sorted, unique set of current-journal entry
/// numbers as one operation. Interactive frontends receive the skip count
/// instead of writing diagnostics over their screen.
pub fn removeInteractionNumbers(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    numbers: []const u32,
    force: bool,
) !RemovalResult {
    var mutation = try context.openCurrentMutation(gpa, io, home, .exclusive);
    defer mutation.deinit(io);
    return removeNumbers(gpa, io, &mutation, numbers, force);
}

fn removeNumbers(
    gpa: std.mem.Allocator,
    io: Io,
    mutation: *context.Mutation,
    numbers: []const u32,
    force: bool,
) !RemovalResult {
    if (numbers.len == 0) return error.NoSuchInteraction;
    const highest = try store.highestNumber(gpa, io, mutation.root, mutation.journal) orelse
        return error.NoSuchInteraction;
    for (numbers, 0..) |number, index| {
        if (number >= highest) return error.CurrentInteraction;
        if (!store.interactionExists(io, mutation.root, mutation.journal, number)) return error.NoSuchInteraction;
        if (index != 0 and numbers[index - 1] >= number) return error.BadArguments;
    }

    // One pass decides what is being removed. Pin markers move with staged
    // entry directories, so no separate metadata cleanup is needed.
    const Staged = struct { number: u32, path: []u8 };
    var staged: std.ArrayList(Staged) = .empty;
    defer {
        for (staged.items) |item| gpa.free(item.path);
        staged.deinit(gpa);
    }
    try staged.ensureTotalCapacity(gpa, numbers.len);

    var skipped_pinned: usize = 0;
    for (numbers) |number| {
        if (!force and try pins.isPinned(io, mutation.root, mutation.journal, number)) {
            skipped_pinned += 1;
            continue;
        }
        const path = try store.stageInteractionRemoval(gpa, io, mutation.root, mutation.journal, number);
        staged.appendAssumeCapacity(.{ .number = number, .path = path });
    }

    for (staged.items) |item| try store.finishStagedRemoval(io, mutation.root, item.path);
    return .{ .removed = staged.items.len, .skipped_pinned = skipped_pinned };
}

fn noteSkippedPins(skipped_pinned: usize) void {
    if (skipped_pinned == 0) return;
    context.note("tj: skipped {d} pinned {s}; use --force to remove {s}\n", .{
        skipped_pinned,
        if (skipped_pinned == 1) "entry" else "entries",
        if (skipped_pinned == 1) "it" else "them",
    });
}
