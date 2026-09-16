//! What every subcommand has to agree on: which journal is current, what a
//! reference resolves to, which entries a range selects, and how a mutation
//! holds the journal while it writes.

const std = @import("std");
const Io = std.Io;
const zecli = @import("zecli");

const cli = @import("../cli/tj.zig");
const cli_spec = @import("../cli/tj_spec.zig");
const store = @import("../journal/store.zig");
const sys = @import("../sys.zig");
const reference = @import("../journal/reference.zig");
const mutation_lock = @import("../journal/mutation_lock.zig");

pub const Error = error{
    NotInJournal,
    NoSuchJournal,
    NothingRecorded,
    MissingArgument,
    BadReference,
    NoSuchInteraction,
    NoSuchResource,
    BadCount,
    BadReplayOption,
    InsideJournal,
    CrossJournalMutation,
    UnsupportedRemoval,
    InvalidRange,
    CurrentInteraction,
    ActiveJournal,
    AmbiguousJournal,
    ConfirmationRequired,
    Cancelled,
    BadArguments,
    InvalidMetadata,
    InsideJournalRemoval,
    InvalidStdinSelection,
    StdinSelectionTooLarge,
};

/// A batch entry-number selection read from redirected standard input, used
/// where a command accepts explicit target operands or, in their absence,
/// a piped list of current-journal entry numbers (`tj grep ... --ids | tj
/// pin`). Mirrors the TUI's own filter-input parser: ASCII whitespace
/// separators, no zero or malformed tokens, sorted and deduplicated, capped
/// so a runaway pipe cannot exhaust memory.
pub const max_stdin_selection_bytes = 4 * 1024 * 1024;

pub fn readNumberSelection(gpa: std.mem.Allocator, io: Io) ![]u32 {
    var reader_buffer: [4096]u8 = undefined;
    var reader = Io.File.stdin().readerStreaming(io, &reader_buffer);
    const input = reader.interface.allocRemaining(gpa, .limited(max_stdin_selection_bytes)) catch |err| switch (err) {
        error.StreamTooLong => return error.StdinSelectionTooLarge,
        else => return err,
    };
    defer gpa.free(input);
    return parseNumberSelection(gpa, input);
}

pub const stdin_operand = "-";

pub fn isStdinOperand(text: []const u8) bool {
    return std.mem.eql(u8, text, stdin_operand);
}

/// Reads the entry-number selection a `-` operand names, or returns null when
/// no operand is `-`. Standard input can be consumed only once.
pub fn readStdinOperand(gpa: std.mem.Allocator, io: Io, operands: []const []const u8) !?[]u32 {
    var count: usize = 0;
    for (operands) |operand| {
        if (isStdinOperand(operand)) count += 1;
    }
    if (count == 0) return null;
    if (count > 1) return error.BadArguments;
    return try readNumberSelection(gpa, io);
}

pub fn parseNumberSelection(gpa: std.mem.Allocator, input: []const u8) ![]u32 {
    var numbers: std.ArrayList(u32) = .empty;
    defer numbers.deinit(gpa);

    var tokens = std.mem.tokenizeAny(u8, input, " \t\r\n\x0b\x0c");
    while (tokens.next()) |token| {
        const number = std.fmt.parseInt(u32, token, 10) catch return error.InvalidStdinSelection;
        if (number == 0) return error.InvalidStdinSelection;
        try numbers.append(gpa, number);
    }

    std.mem.sort(u32, numbers.items, {}, std.sort.asc(u32));
    var unique: usize = 0;
    for (numbers.items) |number| {
        if (unique != 0 and numbers.items[unique - 1] == number) continue;
        numbers.items[unique] = number;
        unique += 1;
    }
    numbers.items.len = unique;
    return numbers.toOwnedSlice(gpa);
}

test "number selection parsing is sorted, deduplicated, and rejects malformed tokens" {
    const gpa = std.testing.allocator;
    const numbers = try parseNumberSelection(gpa, "1002  100\n101\t1002\n");
    defer gpa.free(numbers);
    try std.testing.expectEqualSlices(u32, &.{ 100, 101, 1002 }, numbers);
    try std.testing.expectError(error.InvalidStdinSelection, parseNumberSelection(gpa, "1 @2"));
    try std.testing.expectError(error.InvalidStdinSelection, parseNumberSelection(gpa, "0"));
    const empty = try parseNumberSelection(gpa, "   \n\t  ");
    defer gpa.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

pub fn parseTestCommand(which: cli.CommandName, args: []const [:0]const u8) !zecli.Parsed {
    var discard_buf: [1024]u8 = undefined;
    var discarding = Io.Writer.Discarding.init(&discard_buf);
    const spec = cli_spec.findCommand(@tagName(which)) orelse unreachable;
    return zecli.parseCommand(std.testing.allocator, &discarding.writer, args, spec);
}

pub fn currentJournal() Error![]const u8 {
    return sys.env("TJ_JOURNAL") orelse error.NotInJournal;
}

pub const ActiveInteraction = struct {
    journal: []const u8,
    number: u32,
};

pub fn activeInteraction() ?ActiveInteraction {
    const journal = sys.env("TJ_JOURNAL") orelse return null;
    if (journal.len == 0) return null;
    const next_text = sys.env("TJ_NEXT") orelse return null;
    const next = std.fmt.parseInt(u32, next_text, 10) catch return null;
    if (next <= 1) return null;
    return .{ .journal = journal, .number = next - 1 };
}

/// Multi-line commands are real; a listing shows only the first line of one.
pub fn firstLine(text: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, text, '\n') orelse return text;
    return text[0..end];
}

test "firstLine stops at the first newline" {
    try std.testing.expectEqualStrings("git status", firstLine("git status"));
    try std.testing.expectEqualStrings("for f in *; do", firstLine("for f in *; do\n  echo $f\ndone"));
    try std.testing.expectEqualStrings("", firstLine(""));
}

pub const CommandTarget = struct {
    journal: []u8,
    number: u32,
    subpath: []const u8,
    syntactically_qualified: bool = false,

    pub fn deinit(self: CommandTarget, gpa: std.mem.Allocator) void {
        gpa.free(self.journal);
    }
};

pub fn locateCommandTarget(
    gpa: std.mem.Allocator,
    io: Io,
    root: store.Dir,
    text: []const u8,
) !CommandTarget {
    if (reference.parse(text)) |parsed| {
        const qualified = parsed.body == .qualified;
        const found = try store.locate(gpa, io, root, sys.env("TJ_JOURNAL"), parsed);
        defer found.deinit(gpa);
        if (!found.exists) return error.NoSuchInteraction;
        return .{
            .journal = try gpa.dupe(u8, found.journal),
            .number = found.number,
            .subpath = parsed.subpath,
            .syntactically_qualified = qualified,
        };
    } else |err| switch (err) {
        error.Malformed => return error.BadReference,
        error.NotAReference => {},
    }

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try root.realPath(io, &root_buf);
    const root_path = root_buf[0..root_len];
    if (!std.mem.startsWith(u8, text, root_path) or text.len <= root_path.len or text[root_path.len] != '/') {
        return error.BadReference;
    }
    const relative = text[root_path.len + 1 ..];
    const journal_end = std.mem.indexOfScalar(u8, relative, '/') orelse return error.BadReference;
    const journal = relative[0..journal_end];
    const after_journal = relative[journal_end + 1 ..];
    const number_end = std.mem.indexOfScalar(u8, after_journal, '/') orelse after_journal.len;
    const number = std.fmt.parseInt(u32, after_journal[0..number_end], 10) catch return error.BadReference;
    if (number == 0 or !store.interactionExists(io, root, journal, number)) return error.NoSuchInteraction;
    const subpath = if (number_end < after_journal.len) after_journal[number_end + 1 ..] else "";
    if (subpath.len != 0) {
        const check = try std.fmt.allocPrint(gpa, "@1/{s}", .{subpath});
        defer gpa.free(check);
        _ = reference.parse(check) catch return error.BadReference;
    }
    return .{
        .journal = try gpa.dupe(u8, journal),
        .number = number,
        .subpath = subpath,
    };
}

pub fn requireMutationTarget(
    gpa: std.mem.Allocator,
    io: Io,
    root: store.Dir,
    text: []const u8,
) !CommandTarget {
    const current = try currentJournal();
    const target = try locateCommandTarget(gpa, io, root, text);
    errdefer target.deinit(gpa);
    if (target.syntactically_qualified or !std.mem.eql(u8, target.journal, current)) {
        return error.CrossJournalMutation;
    }
    return target;
}

pub fn requireInteraction(target: CommandTarget) !void {
    if (target.subpath.len != 0) return error.BadReference;
}

/// The current journal held open for mutation: its root, its name, and the
/// lock that serializes writers against it.
pub const Mutation = struct {
    root: store.Dir,
    journal: []const u8,
    lock: Io.File,

    pub fn deinit(self: *Mutation, io: Io) void {
        self.lock.close(io);
        self.root.close(io);
        self.* = undefined;
    }
};

pub fn openCurrentMutation(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    mode: mutation_lock.Mode,
) !Mutation {
    const journal = try currentJournal();
    var root = try store.openRoot(io, home);
    errdefer root.close(io);
    const lock = try mutation_lock.acquire(io, root, journal, mode);
    errdefer lock.close(io);
    if (mode == .exclusive) {
        try store.recoverPendingOutputRemovals(gpa, io, root, journal);
        store.cleanupJournalTrash(io, root, journal);
    }
    return .{ .root = root, .journal = journal, .lock = lock };
}

/// The entries one command names, whether that was a single reference or a
/// range. Both forms then apply the same action to the same list, so only the
/// resolution differs and only it lives here.
///
/// A single reference must name an existing entry of the current journal; a
/// range must select at least one. Those checks are the real difference
/// between the two forms, not the transaction that follows.
pub const MutationTargets = struct {
    mutation: Mutation,
    numbers: []u32,

    pub fn deinit(self: *MutationTargets, gpa: std.mem.Allocator, io: Io) void {
        gpa.free(self.numbers);
        self.mutation.deinit(io);
        self.* = undefined;
    }
};

pub fn openMutationTargets(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    ref: []const u8,
) !MutationTargets {
    if (try parseInteractionRange(ref)) |range| {
        var mutation = try openCurrentMutation(gpa, io, home, .exclusive);
        errdefer mutation.deinit(io);
        const numbers = try selectedNumbers(gpa, io, mutation.root, mutation.journal, range);
        return .{ .mutation = mutation, .numbers = numbers };
    }

    const target = blk: {
        var root = try store.openRoot(io, home);
        defer root.close(io);
        break :blk try requireMutationTarget(gpa, io, root, ref);
    };
    defer target.deinit(gpa);
    try requireInteraction(target);

    var mutation = try openCurrentMutation(gpa, io, home, .exclusive);
    errdefer mutation.deinit(io);
    if (!store.interactionExists(io, mutation.root, mutation.journal, target.number)) {
        return error.NoSuchInteraction;
    }
    const numbers = try gpa.alloc(u32, 1);
    numbers[0] = target.number;
    return .{ .mutation = mutation, .numbers = numbers };
}

/// Resolve a batch of current-journal entry selectors under one mutation
/// guard. The returned numbers are sorted and deduplicated, and no marker is
/// changed until every operand has been validated.
pub fn openMutationTargetList(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    refs: []const []const u8,
    stdin_numbers: ?[]const u32,
) !MutationTargets {
    var mutation = try openCurrentMutation(gpa, io, home, .exclusive);
    errdefer mutation.deinit(io);
    const numbers = try selectCurrentNumbers(gpa, io, mutation.root, mutation.journal, refs, stdin_numbers);
    return .{ .mutation = mutation, .numbers = numbers };
}

/// Resolve only unqualified current-journal entry references and ranges.
/// Paths, resources, qualified references, and empty ranges are rejected.
/// A `-` operand contributes `stdin_numbers`, which must all exist.
pub fn selectCurrentNumbers(
    gpa: std.mem.Allocator,
    io: Io,
    root: store.Dir,
    journal: []const u8,
    refs: []const []const u8,
    stdin_numbers: ?[]const u32,
) ![]u32 {
    const existing = try store.listNumbers(gpa, io, root, journal);
    defer gpa.free(existing);

    var selected: std.ArrayList(u32) = .empty;
    defer selected.deinit(gpa);
    for (refs) |text| {
        if (isStdinOperand(text)) {
            const numbers = stdin_numbers orelse return error.BadReference;
            for (numbers) |number| {
                if (std.mem.indexOfScalar(u32, existing, number) == null) return error.NoSuchInteraction;
                try selected.append(gpa, number);
            }
            continue;
        }
        if (try parseInteractionRange(text)) |range| {
            if (!rangeSelectsAny(existing, range)) return error.NoSuchInteraction;
            for (existing) |number| if (range.contains(number)) try selected.append(gpa, number);
            continue;
        }

        const parsed_ref = reference.parse(text) catch |err| switch (err) {
            error.Malformed, error.NotAReference => return error.BadReference,
        };
        switch (parsed_ref.body) {
            .qualified => return error.CrossJournalMutation,
            else => {},
        }
        if (parsed_ref.subpath.len != 0 or parsed_ref.trailing_slash) return error.BadReference;

        const target = try locateCommandTarget(gpa, io, root, text);
        defer target.deinit(gpa);
        if (target.syntactically_qualified or !std.mem.eql(u8, target.journal, journal)) {
            return error.CrossJournalMutation;
        }
        try requireInteraction(target);
        if (std.mem.indexOfScalar(u32, existing, target.number) == null) return error.NoSuchInteraction;
        try selected.append(gpa, target.number);
    }

    std.mem.sort(u32, selected.items, {}, std.sort.asc(u32));
    var unique: usize = 0;
    for (selected.items) |number| {
        if (unique != 0 and selected.items[unique - 1] == number) continue;
        selected.items[unique] = number;
        unique += 1;
    }
    selected.items.len = unique;
    return selected.toOwnedSlice(gpa);
}

/// The existing entries a range covers, refusing a range that selects none.
pub fn selectedNumbers(
    gpa: std.mem.Allocator,
    io: Io,
    root: store.Dir,
    journal: []const u8,
    range: InteractionRange,
) ![]u32 {
    const all = try store.listNumbers(gpa, io, root, journal);
    defer gpa.free(all);
    if (!rangeSelectsAny(all, range)) return error.NoSuchInteraction;

    var selected: std.ArrayList(u32) = .empty;
    errdefer selected.deinit(gpa);
    for (all) |number| {
        if (range.contains(number)) try selected.append(gpa, number);
    }
    return selected.toOwnedSlice(gpa);
}

pub const InteractionRange = struct {
    first: u32,
    last: u32,

    pub fn contains(self: InteractionRange, number: u32) bool {
        return self.first <= number and number <= self.last;
    }
};

/// Ranges are a small command-level grammar extension, not references resolved
/// by zsh. They deliberately select numeric interactions in the current
/// journal; names, resources, `@-`, and qualified journals are not ranges.
pub fn parseInteractionRange(text: []const u8) !?InteractionRange {
    if (text.len == 0 or text[0] != '@') return null;
    const cut = std.mem.indexOf(u8, text, "..") orelse return null;
    if (std.mem.indexOf(u8, text[cut + 2 ..], "..") != null) return error.InvalidRange;

    const first = try parseInteractionRangeEndpoint(text[0..cut]);
    const last = try parseInteractionRangeEndpoint(text[cut + 2 ..]);
    if (first > last) return error.InvalidRange;
    return .{ .first = first, .last = last };
}

pub fn parseInteractionRangeEndpoint(text: []const u8) !u32 {
    const parsed = reference.parse(text) catch return error.InvalidRange;
    if (parsed.subpath.len != 0 or parsed.trailing_slash) return error.InvalidRange;
    return switch (parsed.body) {
        .current => |target| target,
        .qualified => error.CrossJournalMutation,
        .previous => error.InvalidRange,
    };
}

pub fn rangeSelectsAny(numbers: []const u32, range: InteractionRange) bool {
    for (numbers) |number| if (range.contains(number)) return true;
    return false;
}

pub fn writeNumbers(out: *Io.Writer, numbers: []const u32) !void {
    for (numbers, 0..) |number, index| {
        if (index != 0) try out.writeByte(' ');
        try out.print("{d}", .{number});
    }
    if (numbers.len != 0) try out.writeByte('\n');
}

test "entry ranges are inclusive numeric current-journal references" {
    const range = (try parseInteractionRange("@2..@10")).?;
    try std.testing.expectEqual(@as(u32, 2), range.first);
    try std.testing.expectEqual(@as(u32, 10), range.last);
    try std.testing.expect((try parseInteractionRange("@2")) == null);
    try std.testing.expect((try parseInteractionRange("/tmp/a..b")) == null);
    try std.testing.expectError(error.InvalidRange, parseInteractionRange("@10..@2"));
    try std.testing.expectError(error.InvalidRange, parseInteractionRange("@two..@ten"));
    try std.testing.expectError(error.InvalidRange, parseInteractionRange("@2/out..@10/out"));
    try std.testing.expectError(error.CrossJournalMutation, parseInteractionRange("@abcd.2..@abcd.10"));
}

pub fn note(io: Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
    sys.writeAll(io, 2, text) catch {};
}
