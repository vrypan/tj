//! Journal listing and disk-usage reports used by `tjctl`.

const std = @import("std");
const Io = std.Io;
const zecli = @import("zecli");

const context = @import("context.zig");
const report = @import("report.zig");
const store = @import("store.zig");
const sys = @import("sys.zig");

pub fn listJournals(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    long: bool,
    limit_text: ?[]const u8,
    out: *Io.Writer,
) !void {
    const limit = if (limit_text) |text|
        std.fmt.parseInt(usize, text, 10) catch return error.BadListNumber
    else
        std.math.maxInt(usize);
    if (limit == 0) return;

    var root = try store.openRoot(io, home);
    defer root.close(io);

    const journals = try store.listJournals(gpa, io, root);
    defer {
        for (journals) |name| gpa.free(name);
        gpa.free(journals);
    }

    const JournalRow = struct {
        name: []const u8,
        span: store.JournalEntrySpan,
    };
    var rows: std.ArrayList(JournalRow) = .empty;
    defer rows.deinit(gpa);
    for (journals) |name| {
        const span = store.journalEntrySpan(gpa, io, root, name) catch continue;
        try rows.append(gpa, .{ .name = name, .span = span });
    }
    if (rows.items.len == 0) return;

    std.mem.sort(JournalRow, rows.items, {}, struct {
        fn newestFirst(_: void, a: JournalRow, b: JournalRow) bool {
            if (a.span.last_ended) |a_last| {
                if (b.span.last_ended) |b_last| {
                    if (a_last != b_last) return a_last > b_last;
                } else return true;
            } else if (b.span.last_ended != null) return false;
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.newestFirst);

    const shown = rows.items[0..@min(limit, rows.items.len)];
    if (!long) {
        for (shown) |row| try out.print("{s}\n", .{row.name});
        return;
    }

    var name_width: usize = "JOURNAL".len;
    for (shown) |row| name_width = @max(name_width, row.name.len);

    try out.writeAll("  JOURNAL");
    try out.splatByteAll(' ', name_width - "JOURNAL".len);
    try out.writeAll("    ENTRIES  FIRST ENTRY  LAST ENTRY\n");

    const current = sys.env("TJ_JOURNAL");
    for (shown) |row| {
        const name = row.name;
        const span = row.span;
        const marker = if (current != null and std.mem.eql(u8, current.?, name)) "*" else " ";
        var first_buf: [10]u8 = undefined;
        var last_buf: [10]u8 = undefined;
        const first = formatJournalDate(span.first_started, &first_buf);
        const last = formatJournalDate(span.last_ended, &last_buf);

        try out.print("{s} {s}", .{ marker, name });
        try out.splatByteAll(' ', name_width - name.len + 1);
        try out.splatByteAll(' ', 10 - report.decimalWidth(@intCast(span.count)));
        try out.print("{d}  {s}  {s}\n", .{ span.count, first, last });
    }
}

fn formatJournalDate(millis: ?i64, buf: *[10]u8) []const u8 {
    buf.* = "----------".*;
    const value = millis orelse return buf;
    var timestamp_buf: [32]u8 = undefined;
    const timestamp = store.formatTimestamp(value, &timestamp_buf);
    if (timestamp.len < buf.len) return buf;
    @memcpy(buf, timestamp[0..buf.len]);
    return buf;
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
