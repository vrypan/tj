//! `tj rm` entry removal plus the journal-removal primitive used by `tjctl`.

const std = @import("std");
const Io = std.Io;
const zecli = @import("zecli");

const store = @import("store.zig");
const sys = @import("sys.zig");
const annotations = @import("annotations.zig");
const context = @import("context.zig");
const cmd_annotate = @import("cmd_annotate.zig");

pub const RemoveRequest = struct {
    targets: []const []const u8,
    force: bool,
};

pub fn removeRequest(parsed: *const zecli.Parsed) !RemoveRequest {
    if (parsed.positionals.items.len == 0) return error.BadArguments;
    return .{ .targets = parsed.positionals.items, .force = parsed.enabled("force") };
}

test "annotation and removal requests select one semantic mode" {
    const gpa = std.testing.allocator;

    {
        var parsed = try context.parseTestCommand(.name, &.{});
        defer parsed.deinit(gpa);
        try std.testing.expect(try cmd_annotate.nameRequest(&parsed) == .list);
    }
    {
        var parsed = try context.parseTestCommand(.name, &.{ "@2", "build-failure" });
        defer parsed.deinit(gpa);
        const request = (try cmd_annotate.nameRequest(&parsed)).set;
        try std.testing.expectEqualStrings("@2", request.ref);
        try std.testing.expectEqualStrings("build-failure", request.name);
    }
    {
        var parsed = try context.parseTestCommand(.tag, &.{ "--remove", "@2", "@4..@6", "bug", "parser" });
        defer parsed.deinit(gpa);
        const request = (try cmd_annotate.tagRequest(&parsed, 2)).remove;
        try std.testing.expectEqual(@as(usize, 2), request.targets.len);
        try std.testing.expectEqualStrings("@2", request.targets[0]);
        try std.testing.expectEqualStrings("@4..@6", request.targets[1]);
        try std.testing.expectEqual(@as(usize, 2), request.tags.len);
    }
    {
        var parsed = try context.parseTestCommand(.pin, &.{"@2"});
        defer parsed.deinit(gpa);
        try std.testing.expectEqualStrings("@2", (try cmd_annotate.pinRequest(&parsed)).set);
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
        var metadata = try annotations.openRead(gpa, io, root, journal);
        defer metadata.deinit(gpa);
        var pins = try metadata.pins();
        defer pins.deinit();
        while (try pins.next()) |number| {
            if (store.interactionExists(io, root, journal, number)) return error.PinnedInteraction;
        }
        if (!sys.isTty(0)) return error.ConfirmationRequired;
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

    var read_metadata = try annotations.openRead(gpa, io, mutation.root, mutation.journal);
    defer read_metadata.deinit(gpa);
    if (!force and try read_metadata.isPinned(target.number)) {
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
    var metadata = try annotations.openWrite(gpa, io, mutation.root, mutation.journal);
    defer metadata.deinit(gpa);
    var transaction = try metadata.begin();
    defer transaction.deinit();
    try metadata.removeEntry(target.number);
    try transaction.commit();
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

    var read_metadata = try annotations.openRead(gpa, io, mutation.root, mutation.journal);
    defer read_metadata.deinit(gpa);

    // One pass decides what is being removed, and the transaction below is
    // driven by that decision rather than recomputing it against a second
    // connection. The staged directories and the deleted annotations then
    // cannot describe different sets of entries.
    const Staged = struct { number: u32, path: []u8 };
    var staged: std.ArrayList(Staged) = .empty;
    defer {
        for (staged.items) |item| gpa.free(item.path);
        staged.deinit(gpa);
    }
    try staged.ensureTotalCapacity(gpa, numbers.len);

    var skipped_pinned: usize = 0;
    for (numbers) |number| {
        if (!force and try read_metadata.isPinned(number)) {
            skipped_pinned += 1;
            continue;
        }
        const path = try store.stageInteractionRemoval(gpa, io, mutation.root, mutation.journal, number);
        staged.appendAssumeCapacity(.{ .number = number, .path = path });
    }

    if (staged.items.len != 0) {
        var metadata = try annotations.openWrite(gpa, io, mutation.root, mutation.journal);
        defer metadata.deinit(gpa);
        var transaction = try metadata.begin();
        defer transaction.deinit();
        for (staged.items) |item| try metadata.removeEntry(item.number);
        try transaction.commit();
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
