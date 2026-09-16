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
    include_pinned: bool,
    ignore_missing: bool,
};

pub fn removeRequest(parsed: *const zecli.Parsed) !RemoveRequest {
    const targets = parsed.positionals.items;
    if (targets.len == 0) return error.BadArguments;
    return .{
        .targets = targets,
        .include_pinned = parsed.enabled("include-pinned"),
        .ignore_missing = parsed.enabled("ignore-missing"),
    };
}

test "pin and removal requests select one semantic mode" {
    const gpa = std.testing.allocator;

    {
        var parsed = try context.parseTestCommand(.pin, &.{"@2"});
        defer parsed.deinit(gpa);
        try std.testing.expectEqualStrings("@2", (try cmd_pin.request(&parsed)).set[0]);
    }
    {
        var parsed = try context.parseTestCommand(.rm, &.{ "--include-pinned", "@2", "@4/out", "-", "@6..@8" });
        defer parsed.deinit(gpa);
        const request = try removeRequest(&parsed);
        try std.testing.expectEqual(@as(usize, 4), request.targets.len);
        try std.testing.expectEqualStrings("@2", request.targets[0]);
        try std.testing.expectEqualStrings("@4/out", request.targets[1]);
        try std.testing.expectEqualStrings("-", request.targets[2]);
        try std.testing.expectEqualStrings("@6..@8", request.targets[3]);
        try std.testing.expect(request.include_pinned);
        try std.testing.expect(!request.ignore_missing);
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
    // Read stdin before locking so a slow producer cannot stall other writers.
    const stdin_numbers = try context.readStdinOperand(gpa, io, request.targets);
    defer if (stdin_numbers) |numbers| gpa.free(numbers);
    if (request.targets.len == 1 and stdin_numbers != null and stdin_numbers.?.len == 0) return;

    var mutation = try context.openCurrentMutation(gpa, io, home, .exclusive);
    defer mutation.deinit(io);

    for (request.targets) |target| {
        if (context.isStdinOperand(target)) {
            try removeStdinNumbers(gpa, io, &mutation, stdin_numbers.?, request);
            continue;
        }
        removeTarget(gpa, io, &mutation, target, request.include_pinned) catch |err| switch (err) {
            error.NoSuchInteraction => if (request.ignore_missing) continue else return err,
            else => return err,
        };
    }
}

/// Removes a `-` selection as one batch: every number is validated before any
/// entry is removed, unless --ignore-missing drops the stale ones first.
fn removeStdinNumbers(
    gpa: std.mem.Allocator,
    io: Io,
    mutation: *context.Mutation,
    numbers: []const u32,
    request: RemoveRequest,
) !void {
    const selected = if (request.ignore_missing)
        try filterExisting(gpa, io, mutation, numbers)
    else
        numbers;
    defer if (request.ignore_missing) gpa.free(selected);
    if (selected.len == 0) return;
    const result = try removeNumbers(gpa, io, mutation, selected, request.include_pinned);
    noteSkippedPins(io, result.skipped_pinned);
}

fn filterExisting(
    gpa: std.mem.Allocator,
    io: Io,
    mutation: *context.Mutation,
    numbers: []const u32,
) ![]u32 {
    var kept: std.ArrayList(u32) = .empty;
    errdefer kept.deinit(gpa);
    for (numbers) |number| {
        if (store.interactionExists(io, mutation.root, mutation.journal, number)) try kept.append(gpa, number);
    }
    return kept.toOwnedSlice(gpa);
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

fn removeTarget(
    gpa: std.mem.Allocator,
    io: Io,
    mutation: *context.Mutation,
    interaction: []const u8,
    include_pinned: bool,
) !void {
    if (try context.parseInteractionRange(interaction)) |range| {
        const selected = try context.selectedNumbers(gpa, io, mutation.root, mutation.journal, range);
        defer gpa.free(selected);
        const result = try removeNumbers(gpa, io, mutation, selected, include_pinned);
        noteSkippedPins(io, result.skipped_pinned);
        return;
    }
    const target = try context.requireMutationTarget(gpa, io, mutation.root, interaction);
    defer target.deinit(gpa);
    const output_only = std.mem.eql(u8, target.subpath, "out");
    if (target.subpath.len != 0 and !output_only) return error.UnsupportedRemoval;

    if (!std.mem.eql(u8, target.journal, mutation.journal)) return error.CrossJournalMutation;
    if (!store.interactionExists(io, mutation.root, mutation.journal, target.number)) return error.NoSuchInteraction;
    const highest = try store.highestNumber(gpa, io, mutation.root, mutation.journal) orelse
        return error.NoSuchInteraction;
    if (target.number >= highest) return error.CurrentInteraction;

    if (!include_pinned and try pins.isPinned(io, mutation.root, mutation.journal, target.number)) {
        context.note(io, "tj: skipped pinned entry @{d}; use --include-pinned to remove it\n", .{target.number});
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
    include_pinned: bool,
) !RemovalResult {
    var mutation = try context.openCurrentMutation(gpa, io, home, .exclusive);
    defer mutation.deinit(io);
    return removeNumbers(gpa, io, &mutation, numbers, include_pinned);
}

fn removeNumbers(
    gpa: std.mem.Allocator,
    io: Io,
    mutation: *context.Mutation,
    numbers: []const u32,
    include_pinned: bool,
) !RemovalResult {
    if (numbers.len == 0) return error.NoSuchInteraction;
    const highest = try store.highestNumber(gpa, io, mutation.root, mutation.journal) orelse
        return error.NoSuchInteraction;
    for (numbers, 0..) |number, index| {
        if (!store.interactionExists(io, mutation.root, mutation.journal, number)) return error.NoSuchInteraction;
        if (number >= highest) return error.CurrentInteraction;
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
        if (!include_pinned and try pins.isPinned(io, mutation.root, mutation.journal, number)) {
            skipped_pinned += 1;
            continue;
        }
        const path = try store.stageInteractionRemoval(gpa, io, mutation.root, mutation.journal, number);
        staged.appendAssumeCapacity(.{ .number = number, .path = path });
    }

    for (staged.items) |item| try store.finishStagedRemoval(io, mutation.root, item.path);
    return .{ .removed = staged.items.len, .skipped_pinned = skipped_pinned };
}

fn noteSkippedPins(io: Io, skipped_pinned: usize) void {
    if (skipped_pinned == 0) return;
    context.note(io, "tj: skipped {d} pinned {s}; use --include-pinned to remove {s}\n", .{
        skipped_pinned,
        if (skipped_pinned == 1) "entry" else "entries",
        if (skipped_pinned == 1) "it" else "them",
    });
}
