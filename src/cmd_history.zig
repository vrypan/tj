//! Entry history plus the journal listings and usage report used by `tjctl`.

const std = @import("std");
const Io = std.Io;
const zecli = @import("zecli");

const cli = @import("cli.zig");
const store = @import("store.zig");
const sys = @import("sys.zig");
const reference = @import("reference.zig");
const journal_name = @import("journal_name.zig");
const plain = @import("plain.zig");
const annotations = @import("annotations.zig");
const mutation_lock = @import("mutation_lock.zig");
const search = @import("search.zig");
const noout = @import("noout.zig");
const report = @import("report.zig");
const replay_engine = @import("replay.zig");
const context = @import("context.zig");

pub fn listJournals(gpa: std.mem.Allocator, io: Io, home: ?[]const u8, out: *Io.Writer) !void {
    var root = try store.openRoot(io, home);
    defer root.close(io);

    const journals = try store.listJournals(gpa, io, root);
    defer {
        for (journals) |name| gpa.free(name);
        gpa.free(journals);
    }

    const current = sys.env("TJ_JOURNAL");
    for (journals) |name| {
        const entries = store.countInteractions(gpa, io, root, name) catch continue;
        const marker = if (current != null and std.mem.eql(u8, current.?, name)) "*" else " ";
        try out.print("{s} {s}  {d} {s}\n", .{
            marker,
            name,
            entries,
            if (entries == 1) "entry" else "entries",
        });
    }
}

pub const HistoryJournal = struct {
    name: []u8,
    /// Entry numbers only. A listing reads one entry at a time, so a journal's
    /// recorded commands never all sit in memory at once.
    numbers: []u32,

    pub fn deinit(self: *HistoryJournal, gpa: std.mem.Allocator) void {
        gpa.free(self.numbers);
        gpa.free(self.name);
    }

    pub fn has(self: *const HistoryJournal, number: u32) bool {
        for (self.numbers) |candidate| {
            if (candidate == number) return true;
        }
        return false;
    }
};

/// What a command-line argument selected, kept as a rule rather than as an
/// expanded list of entries. The number of rules is bounded by argv; expanding
/// them into entries is done twice, lazily, by `HistoryCursor`.
pub const HistorySelection = struct {
    journal_index: usize,
    qualified: bool,
    what: union(enum) {
        whole,
        range: context.InteractionRange,
        single: u32,
    },
};

/// Walks every entry the selections name, in the order they were given.
pub const HistoryCursor = struct {
    journals: []const HistoryJournal,
    selections: []const HistorySelection,
    selection: usize = 0,
    index: usize = 0,

    const Item = struct {
        journal_index: usize,
        number: u32,
        qualified: bool,
    };

    pub fn next(self: *HistoryCursor) ?Item {
        while (self.selection < self.selections.len) {
            const selection = self.selections[self.selection];
            const journal = &self.journals[selection.journal_index];
            switch (selection.what) {
                .single => |number| {
                    self.selection += 1;
                    self.index = 0;
                    return .{
                        .journal_index = selection.journal_index,
                        .number = number,
                        .qualified = selection.qualified,
                    };
                },
                .whole, .range => {
                    while (self.index < journal.numbers.len) {
                        const number = journal.numbers[self.index];
                        self.index += 1;
                        if (selection.what == .range and !selection.what.range.contains(number)) continue;
                        return .{
                            .journal_index = selection.journal_index,
                            .number = number,
                            .qualified = selection.qualified,
                        };
                    }
                    self.selection += 1;
                    self.index = 0;
                },
            }
        }
        return null;
    }
};

pub fn loadHistoryJournal(
    gpa: std.mem.Allocator,
    io: Io,
    root: store.Dir,
    journals: *std.ArrayList(HistoryJournal),
    name: []const u8,
) !usize {
    for (journals.items, 0..) |journal, index| {
        if (std.mem.eql(u8, journal.name, name)) return index;
    }

    const owned_name = try gpa.dupe(u8, name);
    errdefer gpa.free(owned_name);
    const numbers = store.listNumbers(gpa, io, root, name) catch |err| switch (err) {
        error.FileNotFound => return error.NoSuchJournal,
        else => return err,
    };
    errdefer gpa.free(numbers);
    try journals.append(gpa, .{
        .name = owned_name,
        .numbers = numbers,
    });
    return journals.items.len - 1;
}

pub fn parseHistoryJournalSelector(text: []const u8) ?[]const u8 {
    if (text.len < 3 or text[0] != '@' or text[text.len - 1] != '.') return null;
    const suffix = text[1 .. text.len - 1];
    if (!journal_name.isValid(suffix)) return null;
    return suffix;
}

test "history journal selectors use a trailing dot" {
    try std.testing.expectEqualStrings("build", parseHistoryJournalSelector("@build.").?);
    try std.testing.expectEqualStrings("01m12awjf7hd5pdfvnkzmw8wpc", parseHistoryJournalSelector("@01m12awjf7hd5pdfvnkzmw8wpc.").?);
    try std.testing.expectEqualStrings("release-build", parseHistoryJournalSelector("@release-build.").?);
    try std.testing.expect(parseHistoryJournalSelector("8wpc") == null);
    try std.testing.expect(parseHistoryJournalSelector("@build") == null);
    try std.testing.expect(parseHistoryJournalSelector("@.") == null);
    try std.testing.expect(parseHistoryJournalSelector("@bad_suffix.") == null);
}

pub fn appendWholeHistoryJournal(
    gpa: std.mem.Allocator,
    io: Io,
    root: store.Dir,
    journals: *std.ArrayList(HistoryJournal),
    selected: *std.ArrayList(HistorySelection),
    name: []const u8,
    qualified: bool,
) !void {
    const journal_index = try loadHistoryJournal(gpa, io, root, journals, name);
    try selected.append(gpa, .{
        .journal_index = journal_index,
        .qualified = qualified,
        .what = .whole,
    });
}

pub fn historyReferenceWidth(journal: *const HistoryJournal, item: HistoryCursor.Item) usize {
    const number_width = report.decimalWidth(item.number);
    if (!item.qualified) return number_width;
    return 1 + journal.name.len + 1 + number_width;
}

pub fn writeHistoryReference(
    out: *Io.Writer,
    journal: *const HistoryJournal,
    item: HistoryCursor.Item,
    width: usize,
    color_enabled: bool,
) !void {
    const actual_width = historyReferenceWidth(journal, item);
    try out.splatByteAll(' ', width - actual_width);
    if (color_enabled) try out.writeAll("\x1b[33m");
    if (item.qualified) {
        try out.print("@{s}.{d}", .{ journal.name, item.number });
    } else {
        try out.print("{d}", .{item.number});
    }
    if (color_enabled) try out.writeAll("\x1b[0m");
}

pub fn listInteractions(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    parsed: *const zecli.Parsed,
    out: *Io.Writer,
) !void {
    var root = try store.openRoot(io, home);
    defer root.close(io);

    var filters: std.ArrayList([]u8) = .empty;
    defer {
        for (filters.items) |tag| gpa.free(tag);
        filters.deinit(gpa);
    }
    for (parsed.flags.items) |flag| {
        if (!std.mem.eql(u8, flag.name, "tag")) continue;
        try filters.append(gpa, annotations.normalizeTag(gpa, flag.value.?) catch return error.InvalidTag);
    }
    const pinned_only = parsed.enabled("pinned");

    var journals: std.ArrayList(HistoryJournal) = .empty;
    defer {
        for (journals.items) |*journal| journal.deinit(gpa);
        journals.deinit(gpa);
    }
    var selected: std.ArrayList(HistorySelection) = .empty;
    defer selected.deinit(gpa);

    if (parsed.positionals.items.len == 0) {
        try appendWholeHistoryJournal(gpa, io, root, &journals, &selected, try context.currentJournal(), false);
    } else {
        for (parsed.positionals.items) |text| {
            if (parseHistoryJournalSelector(text)) |suffix| {
                const journal = try store.findUniqueJournal(gpa, io, root, suffix);
                defer gpa.free(journal);
                try appendWholeHistoryJournal(gpa, io, root, &journals, &selected, journal, true);
                continue;
            }

            const maybe_range = context.parseInteractionRange(text) catch |err| switch (err) {
                error.CrossJournalMutation => return error.InvalidRange,
                else => |other| return other,
            };
            if (maybe_range) |range| {
                const journal_index = try loadHistoryJournal(gpa, io, root, &journals, try context.currentJournal());
                if (!context.rangeSelectsAny(journals.items[journal_index].numbers, range)) {
                    return error.NoSuchInteraction;
                }
                try selected.append(gpa, .{
                    .journal_index = journal_index,
                    .qualified = false,
                    .what = .{ .range = range },
                });
                continue;
            }

            const target = try context.locateCommandTarget(gpa, io, root, text);
            defer target.deinit(gpa);
            try context.requireInteraction(target);
            const journal_index = try loadHistoryJournal(gpa, io, root, &journals, target.journal);
            if (!journals.items[journal_index].has(target.number)) return error.NoSuchInteraction;
            const current = sys.env("TJ_JOURNAL");
            try selected.append(gpa, .{
                .journal_index = journal_index,
                .qualified = target.syntactically_qualified or current == null or
                    !std.mem.eql(u8, current.?, target.journal),
                .what = .{ .single = target.number },
            });
        }
    }

    // Column widths depend on every visible entry, so they need a pass before
    // anything is printed. It keeps nothing: each entry is read, measured, and
    // released, and the print pass reads it again. Two cheap passes cost less
    // than one resident copy of the journal.
    // Columns are fixed, so nothing has to be read before printing starts.
    // The reference column is as wide as its journal's highest entry number
    // ever needs, which the sorted number list already knows; the size column
    // is as wide as `formatHumanSize` can ever be. Both are exact rather than
    // guessed, and a listing lines up with every other listing of the same
    // journal instead of shifting with whatever the filter happened to match.
    var number_width: usize = 1;
    for (selected.items) |selection| {
        const journal = &journals.items[selection.journal_index];
        if (journal.numbers.len == 0) continue;
        var width = report.decimalWidth(journal.numbers[journal.numbers.len - 1]);
        if (selection.qualified) width += 1 + journal.name.len + 1;
        number_width = @max(number_width, width);
    }
    const size_width = report.max_entry_size_width;

    const date_width = 12;
    const prefix_width = 4 + 1 + number_width + 1 + size_width + 1 + date_width + 1;
    const columns = report.terminalColumns();
    const payload_width: ?usize = if (columns) |value|
        if (value > prefix_width) value - prefix_width else 1
    else
        null;
    const color_enabled = report.layoutColorEnabled();
    const current = sys.env("TJ_JOURNAL");
    var noout_region: report.NooutRegion = .{
        .out = out,
        .enabled = current != null and current.?.len != 0 and sys.isTty(1),
    };
    defer noout_region.finish();
    const now_ms = Io.Clock.now(.real, io).toMilliseconds();

    var render_metadata: ?annotations.Connection = null;
    defer if (render_metadata) |*metadata| metadata.deinit(gpa);
    var render_journal: ?usize = null;
    var render_annotations: annotations.Set = .{};
    defer render_annotations.deinit(gpa);
    var render_cursor: HistoryCursor = .{ .journals = journals.items, .selections = selected.items };
    while (render_cursor.next()) |item| {
        const journal = &journals.items[item.journal_index];
        if (render_journal != item.journal_index) {
            if (render_metadata) |*metadata| metadata.deinit(gpa);
            render_metadata = null;
            render_metadata = try annotations.openRead(gpa, io, root, journal.name);
            render_annotations.deinit(gpa);
            render_annotations = try annotations.loadSet(gpa, &render_metadata.?);
            render_journal = item.journal_index;
        }
        const annotation = render_annotations.get(item.number);
        if (!historyEntryVisible(annotation, filters.items, pinned_only)) continue;

        const info = try store.readInteraction(
            gpa,
            io,
            root,
            journal.name,
            item.number,
            store.listing_command_limit,
        ) orelse continue;
        defer info.deinit(gpa);

        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(gpa);
        const command = try report.sanitizeDisplayText(gpa, context.firstLine(info.command));
        defer gpa.free(command);
        try payload.appendSlice(gpa, command);

        var metadata_start: ?usize = null;
        var rc_start: ?usize = null;
        const has_name = annotation != null and annotation.?.name != null;
        const has_tags = annotation != null and annotation.?.tags.items.len != 0;
        const has_failure = info.exit_code != null and info.exit_code.? != 0;
        if (has_name or has_tags or has_failure) {
            if (payload.items.len != 0) try payload.append(gpa, ' ');
            if (has_name or has_tags) metadata_start = payload.items.len;
            if (has_name) {
                try payload.append(gpa, '@');
                try payload.appendSlice(gpa, annotation.?.name.?);
            }
            if (has_tags) {
                for (annotation.?.tags.items, 0..) |tag, tag_i| {
                    if (has_name or tag_i != 0) try payload.append(gpa, ' ');
                    try payload.append(gpa, '#');
                    try payload.appendSlice(gpa, tag);
                }
            }
            if (has_failure) {
                if (has_name or has_tags) try payload.append(gpa, ' ');
                rc_start = payload.items.len;
                try payload.print(gpa, "!{d}", .{info.exit_code.?});
            }
        }

        var lines = try wrapHistoryText(gpa, payload.items, payload_width, prefix_width);
        defer lines.deinit(gpa);
        try noout_region.begin();

        var size_buf: [24]u8 = undefined;
        const size_text = report.formatEntrySize(info, &size_buf);
        var date_buf: [date_width]u8 = undefined;
        const timing = store.readTiming(gpa, io, root, journal.name, info.number);
        const date_text = formatLsDate(if (timing) |value| value.started else null, now_ms, &date_buf);

        for (lines.items, 0..) |line, line_i| {
            if (line_i == 0) {
                try out.writeByte(if (annotation != null and annotation.?.pinned) '*' else ' ');
                try out.writeByte(if (has_name) '@' else ' ');
                try out.writeByte(if (has_tags) '#' else ' ');
                if (has_failure and color_enabled) try out.writeAll("\x1b[31m");
                try out.writeByte(if (has_failure) '!' else ' ');
                if (has_failure and color_enabled) try out.writeAll("\x1b[0m");
                try out.writeByte(' ');
                try writeHistoryReference(out, journal, item, number_width, color_enabled);
                try out.writeByte(' ');
                try out.splatByteAll(' ', size_width - size_text.len);
                if (color_enabled) try out.writeAll("\x1b[32m");
                try out.writeAll(size_text);
                if (color_enabled) try out.writeAll("\x1b[0m");
                try out.writeByte(' ');
                if (color_enabled) try out.writeAll("\x1b[34m");
                try out.writeAll(date_text);
                if (color_enabled) try out.writeAll("\x1b[0m");
                try out.writeByte(' ');
            } else {
                try out.splatByteAll(' ', prefix_width);
            }
            try writeHistoryLine(out, payload.items, line, metadata_start, rc_start, color_enabled);
            try out.writeByte('\n');
        }
    }
}

pub fn usageJournal(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    selector: ?[]const u8,
    parsed: *const zecli.Parsed,
    out: *Io.Writer,
) !void {
    var root = try store.openRoot(io, home);
    defer root.close(io);

    var owned: ?[]u8 = null;
    defer if (owned) |name| gpa.free(name);
    const journal = if (selector) |wanted| blk: {
        owned = try store.findUniqueJournal(gpa, io, root, wanted);
        break :blk owned.?;
    } else try context.currentJournal();
    const measured = store.measureJournalUsage(gpa, io, root, journal) catch |err| switch (err) {
        error.FileNotFound => return error.NoSuchJournal,
        else => |other| return other,
    };
    defer measured.deinit(gpa);

    var noout_region: report.NooutRegion = .{
        .out = out,
        .enabled = sys.isTty(1),
    };
    defer noout_region.finish();
    try noout_region.begin();

    var total_buf: [24]u8 = undefined;
    const exact_bytes = parsed.enabled("bytes");
    const total_text = formatUsageSize(measured.total_bytes, exact_bytes, &total_buf);
    if (!parsed.enabled("chart") and !exact_bytes) {
        try out.print("{s}\n", .{total_text});
        return;
    }
    if (!parsed.enabled("chart")) {
        for (measured.entries) |entry| {
            if (sys.env("TJ_JOURNAL")) |current| {
                if (std.mem.eql(u8, current, journal)) {
                    try out.print("@{d} {d}\n", .{ entry.number, entry.bytes });
                    continue;
                }
            }
            try out.print("@{s}.{d} {d}\n", .{ journal, entry.number, entry.bytes });
        }
        return;
    }

    const color_enabled = report.layoutColorEnabled();
    const qualified = if (sys.env("TJ_JOURNAL")) |current|
        !std.mem.eql(u8, current, journal)
    else
        true;
    try out.writeAll("Total ");
    if (color_enabled) try out.writeAll("\x1b[32m");
    try out.writeAll(total_text);
    if (color_enabled) try out.writeAll("\x1b[0m");
    try out.writeAll("\n\nEntry Size Chart\n");

    var reference_width: usize = if (qualified) journal.len + 3 else 2;
    var size_width: usize = 1;
    var largest: u64 = 0;
    for (measured.entries) |entry| {
        const entry_width = 1 + report.decimalWidth(entry.number) + if (qualified) journal.len + 1 else 0;
        reference_width = @max(reference_width, entry_width);
        var size_buf: [24]u8 = undefined;
        size_width = @max(size_width, formatUsageSize(entry.bytes, exact_bytes, &size_buf).len);
        largest = @max(largest, entry.bytes);
    }
    const prefix_width = reference_width + 1 + size_width + 1;
    const columns = report.terminalColumns() orelse 80;
    const available = if (columns > prefix_width) columns - prefix_width else 1;

    for (measured.entries) |entry| {
        const actual_reference_width = 1 + report.decimalWidth(entry.number) + if (qualified) journal.len + 1 else 0;
        try out.splatByteAll(' ', reference_width - actual_reference_width);
        if (color_enabled) try out.writeAll("\x1b[33m");
        if (qualified) {
            try out.print("@{s}.{d}", .{ journal, entry.number });
        } else {
            try out.print("@{d}", .{entry.number});
        }
        if (color_enabled) try out.writeAll("\x1b[0m");
        try out.writeByte(' ');

        var size_buf: [24]u8 = undefined;
        const size_text = formatUsageSize(entry.bytes, exact_bytes, &size_buf);
        try out.splatByteAll(' ', size_width - size_text.len);
        if (color_enabled) try out.writeAll("\x1b[32m");
        try out.writeAll(size_text);
        if (color_enabled) try out.writeAll("\x1b[0m");

        const width = usageBarWidth(entry.bytes, largest, available);
        if (width != 0) {
            try out.writeByte(' ');
            try out.splatBytesAll("█", width);
        }
        try out.writeByte('\n');
    }
}

pub fn formatUsageSize(bytes: u64, exact: bool, buf: *[24]u8) []const u8 {
    if (!exact) return report.formatHumanSize(bytes, buf);
    return std.fmt.bufPrint(buf, "{d}", .{bytes}) catch "?";
}

pub fn usageBarWidth(bytes: u64, largest: u64, available: usize) usize {
    if (bytes == 0 or largest == 0 or available == 0) return 0;
    const numerator = @as(u128, bytes) * available;
    return @intCast((numerator + largest - 1) / largest);
}

test "usage chart bars preserve small entries and avoid integer overflow" {
    try std.testing.expectEqual(@as(usize, 0), usageBarWidth(0, 10, 80));
    try std.testing.expectEqual(@as(usize, 0), usageBarWidth(10, 0, 80));
    try std.testing.expectEqual(@as(usize, 5), usageBarWidth(5, 10, 10));
    try std.testing.expectEqual(@as(usize, 4), usageBarWidth(1, 3, 10));
    try std.testing.expectEqual(@as(usize, 80), usageBarWidth(std.math.maxInt(u64), std.math.maxInt(u64), 80));
}

/// `ls -l`-style UTC date: current-year entries show HH:MM, older entries the
/// year. UTC keeps output deterministic and matches the timestamps in meta.
pub fn formatLsDate(started_ms: ?i64, now_ms: i64, buf: *[12]u8) []const u8 {
    buf.* = "--- -- --:--".*;
    const millis = started_ms orelse return buf;
    if (millis < 0) return buf;

    const seconds = @divFloor(millis, 1000);
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(seconds) };
    const day = epoch.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const time = epoch.getDaySeconds();
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    const month_index: usize = @intCast(month_day.month.numeric() - 1);
    @memcpy(buf[0..3], months[month_index]);
    const month_date: u32 = month_day.day_index + 1;
    buf[4] = if (month_date >= 10) '0' + @as(u8, @intCast(month_date / 10)) else ' ';
    buf[5] = '0' + @as(u8, @intCast(month_date % 10));

    const now_year = if (now_ms >= 0) blk: {
        const now_seconds = @divFloor(now_ms, 1000);
        const now_epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(now_seconds) };
        break :blk now_epoch.getEpochDay().calculateYearDay().year;
    } else year_day.year;
    if (year_day.year == now_year) {
        const hour = time.getHoursIntoDay();
        const minute = time.getMinutesIntoHour();
        buf[7] = '0' + @as(u8, @intCast(hour / 10));
        buf[8] = '0' + @as(u8, @intCast(hour % 10));
        buf[9] = ':';
        buf[10] = '0' + @as(u8, @intCast(minute / 10));
        buf[11] = '0' + @as(u8, @intCast(minute % 10));
    } else {
        const year: u32 = @intCast(year_day.year);
        buf[7] = ' ';
        buf[8] = '0' + @as(u8, @intCast((year / 1000) % 10));
        buf[9] = '0' + @as(u8, @intCast((year / 100) % 10));
        buf[10] = '0' + @as(u8, @intCast((year / 10) % 10));
        buf[11] = '0' + @as(u8, @intCast(year % 10));
    }
    return buf;
}

pub fn historyEntryVisible(
    annotation: ?*const annotations.Entry,
    tags: []const []const u8,
    pinned_only: bool,
) bool {
    if (pinned_only and (annotation == null or !annotation.?.pinned)) return false;
    if (tags.len == 0) return true;
    const entry = annotation orelse return false;
    for (tags) |wanted| {
        var found = false;
        for (entry.tags.items) |actual| {
            if (std.mem.eql(u8, wanted, actual)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

pub const HistoryLine = struct { start: usize, end: usize };

pub fn historyCell(text: []const u8, index: usize, column: usize) struct { bytes: usize, width: usize } {
    const byte = text[index];
    if (byte == '\t') return .{ .bytes = 1, .width = 8 - (column % 8) };
    if (byte < 0x20 or byte == 0x7f) return .{ .bytes = 1, .width = 0 };
    if (byte < 0x80) return .{ .bytes = 1, .width = 1 };
    const sequence_len: usize = std.unicode.utf8ByteSequenceLength(byte) catch return .{ .bytes = 1, .width = 1 };
    if (index + sequence_len > text.len) return .{ .bytes = 1, .width = 1 };
    _ = std.unicode.utf8Decode(text[index .. index + sequence_len]) catch return .{ .bytes = 1, .width = 1 };
    return .{ .bytes = sequence_len, .width = 1 };
}

pub fn wrapHistoryText(
    gpa: std.mem.Allocator,
    text: []const u8,
    width: ?usize,
    start_column: usize,
) !std.ArrayList(HistoryLine) {
    var lines: std.ArrayList(HistoryLine) = .empty;
    errdefer lines.deinit(gpa);
    if (text.len == 0 or width == null) {
        try lines.append(gpa, .{ .start = 0, .end = text.len });
        return lines;
    }

    const available = @max(width.?, 1);
    var start: usize = 0;
    while (start < text.len) {
        var index = start;
        var column = start_column;
        var last_space: ?usize = null;
        while (index < text.len) {
            const cell = historyCell(text, index, column);
            if (column + cell.width > start_column + available) {
                if (text[index] == ' ' or text[index] == '\t') last_space = index;
                break;
            }
            if (text[index] == ' ' or text[index] == '\t') last_space = index;
            index += cell.bytes;
            column += cell.width;
        }

        if (index == text.len) {
            try lines.append(gpa, .{ .start = start, .end = text.len });
            break;
        }

        var end: usize = undefined;
        var next: usize = undefined;
        if (last_space != null and last_space.? > start) {
            end = last_space.?;
            while (end > start and text[end - 1] == ' ') end -= 1;
            next = last_space.? + 1;
            while (next < text.len and (text[next] == ' ' or text[next] == '\t')) next += 1;
        } else if (index > start) {
            end = index;
            next = index;
        } else {
            const cell = historyCell(text, start, start_column);
            end = start + cell.bytes;
            next = end;
        }
        try lines.append(gpa, .{ .start = start, .end = end });
        start = next;
    }
    return lines;
}

pub fn writeHistoryLine(
    out: *Io.Writer,
    text: []const u8,
    line: HistoryLine,
    metadata_start: ?usize,
    rc_start: ?usize,
    color_enabled: bool,
) !void {
    if (!color_enabled) return out.writeAll(text[line.start..line.end]);

    var position = line.start;
    if (metadata_start) |start| {
        const styled_start = @max(line.start, start);
        const styled_end = @min(line.end, rc_start orelse line.end);
        if (position < @min(styled_start, line.end)) {
            try out.writeAll(text[position..@min(styled_start, line.end)]);
            position = @min(styled_start, line.end);
        }
        if (styled_start < styled_end) {
            try out.writeAll("\x1b[32m");
            try out.writeAll(text[styled_start..styled_end]);
            try out.writeAll("\x1b[0m");
            position = styled_end;
        }
    }
    if (rc_start) |start| {
        const styled_start = @max(line.start, start);
        if (position < @min(styled_start, line.end)) {
            try out.writeAll(text[position..@min(styled_start, line.end)]);
            position = @min(styled_start, line.end);
        }
        if (styled_start < line.end) {
            try out.writeAll("\x1b[31m");
            try out.writeAll(text[styled_start..line.end]);
            try out.writeAll("\x1b[0m");
            position = line.end;
        }
    }
    if (position < line.end) try out.writeAll(text[position..line.end]);
}

test "history wrapping prefers words and hard-wraps oversized words" {
    const gpa = std.testing.allocator;
    var words = try wrapHistoryText(gpa, "alpha beta gamma", 10, 0);
    defer words.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), words.items.len);
    try std.testing.expectEqualStrings("alpha beta", "alpha beta gamma"[words.items[0].start..words.items[0].end]);
    try std.testing.expectEqualStrings("gamma", "alpha beta gamma"[words.items[1].start..words.items[1].end]);

    var hard = try wrapHistoryText(gpa, "abcdefgh", 3, 0);
    defer hard.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 3), hard.items.len);
    try std.testing.expectEqualStrings("abc", "abcdefgh"[hard.items[0].start..hard.items[0].end]);
    try std.testing.expectEqualStrings("def", "abcdefgh"[hard.items[1].start..hard.items[1].end]);
    try std.testing.expectEqualStrings("gh", "abcdefgh"[hard.items[2].start..hard.items[2].end]);
}

test "history renders annotations green and failures red" {
    const gpa = std.testing.allocator;
    const text = "false @build #bug !1";
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    var writer = Io.Writer.Allocating.fromArrayList(gpa, &bytes);
    defer bytes = writer.toArrayList();

    try writeHistoryLine(&writer.writer, text, .{ .start = 0, .end = text.len }, 6, 18, true);
    try std.testing.expectEqualStrings(
        "false \x1b[32m@build #bug \x1b[0m\x1b[31m!1\x1b[0m",
        writer.writer.buffered(),
    );
}

test "long listing formats human sizes and ls-style UTC dates" {
    var size_buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("0b", report.formatHumanSize(0, &size_buf));
    try std.testing.expectEqualStrings("999b", report.formatHumanSize(999, &size_buf));
    try std.testing.expectEqualStrings("1.5k", report.formatHumanSize(1536, &size_buf));
    try std.testing.expectEqualStrings("18k", report.formatHumanSize(18 * 1024, &size_buf));
    try std.testing.expectEqualStrings("6.1M", report.formatHumanSize(6 * 1024 * 1024 + 1024 * 1024 / 10, &size_buf));

    // The history size column is a fixed width, so the formatter must never
    // exceed it. Probe every unit boundary and the extremes rather than trust
    // the reasoning in the constant's comment.
    var widest: usize = 0;
    var unit: u64 = 1;
    for (0..7) |_| {
        for ([_]u64{ 0, 1, 9, 10, 999, 1000, 1023, 1024, 1025 }) |offset| {
            const bytes = unit *| offset;
            var probe_buf: [24]u8 = undefined;
            widest = @max(widest, report.formatHumanSize(bytes, &probe_buf).len);
        }
        unit *|= 1024;
    }
    var extreme_buf: [24]u8 = undefined;
    widest = @max(widest, report.formatHumanSize(std.math.maxInt(u64), &extreme_buf).len);
    try std.testing.expectEqual(report.max_entry_size_width, widest);

    const current = store.parseTimestamp("2026-08-29T10:14:00.000Z").?;
    const now = store.parseTimestamp("2026-12-01T00:00:00.000Z").?;
    const old = store.parseTimestamp("2025-03-14T09:00:00.000Z").?;
    var date_buf: [12]u8 = undefined;
    try std.testing.expectEqualStrings("Aug 29 10:14", formatLsDate(current, now, &date_buf));
    try std.testing.expectEqualStrings("Mar 14  2025", formatLsDate(old, now, &date_buf));
    try std.testing.expectEqualStrings("--- -- --:--", formatLsDate(null, now, &date_buf));
}

pub fn printLast(gpa: std.mem.Allocator, io: Io, home: ?[]const u8, out: *Io.Writer) !void {
    const journal = try context.currentJournal();

    var root = try store.openRoot(io, home);
    defer root.close(io);

    const number = try store.lastCompleted(gpa, io, root, journal) orelse
        return error.NothingRecorded;
    try out.print("{d}\n", .{number});
}
