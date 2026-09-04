//! Semantic entry presentation shared by history, grep, and the TUI.
//!
//! This module derives what an entry means on a row. Output backends still
//! decide how ANSI bytes or Zooi cells represent those roles.

const std = @import("std");

const context = @import("../commands/context.zig");
const report = @import("report.zig");

pub const MetadataPart = union(enum) {
    failure: u8,
};

pub const EntryPresentation = struct {
    journal: []const u8,
    number: u32,
    qualified: bool,
    pinned: bool,
    exit_code: ?u8,

    pub fn init(
        journal: []const u8,
        number: u32,
        qualified: bool,
        pinned: bool,
        exit_code: ?u8,
    ) EntryPresentation {
        return .{
            .journal = journal,
            .number = number,
            .qualified = qualified,
            .pinned = pinned,
            .exit_code = exit_code,
        };
    }

    pub fn failed(self: EntryPresentation) bool {
        return self.exit_code != null and self.exit_code.? != 0;
    }

    pub fn flags(self: EntryPresentation) [2]u8 {
        return .{
            if (self.pinned) '*' else ' ',
            if (self.failed()) '!' else ' ',
        };
    }

    pub fn referenceWidth(self: EntryPresentation) usize {
        const number_width = report.decimalWidth(self.number);
        if (!self.qualified) return number_width;
        return 1 + self.journal.len + 1 + number_width;
    }

    pub fn formatReference(self: EntryPresentation, buf: []u8) ![]const u8 {
        if (self.qualified) {
            return std.fmt.bufPrint(buf, "@{s}.{d}", .{ self.journal, self.number });
        }
        return std.fmt.bufPrint(buf, "{d}", .{self.number});
    }

    pub fn metadata(self: *const EntryPresentation) MetadataIterator {
        return .{ .entry = self };
    }

    /// Width of the metadata suffix including its leading separator.
    pub fn metadataSuffixWidth(self: *const EntryPresentation) usize {
        var iterator = self.metadata();
        var width: usize = 0;
        while (iterator.next()) |part| {
            width += 1;
            width += switch (part) {
                .failure => |code| 1 + report.decimalWidth(code),
            };
        }
        return width;
    }

    /// Appends the canonical `!rc` suffix to a command payload.
    /// Returned offsets let a byte renderer color metadata and failures
    /// without learning how the suffix is assembled.
    pub fn appendMetadata(
        self: *const EntryPresentation,
        gpa: std.mem.Allocator,
        payload: *std.ArrayList(u8),
    ) !MetadataOffsets {
        var result: MetadataOffsets = .{};
        var iterator = self.metadata();
        while (iterator.next()) |part| {
            if (payload.items.len != 0) try payload.append(gpa, ' ');
            switch (part) {
                .failure => |code| {
                    result.failure_start = payload.items.len;
                    try payload.print(gpa, "!{d}", .{code});
                },
            }
        }
        return result;
    }
};

pub const MetadataOffsets = struct {
    failure_start: ?usize = null,
};

pub const MetadataIterator = struct {
    entry: *const EntryPresentation,
    done: bool = false,

    pub fn next(self: *MetadataIterator) ?MetadataPart {
        if (self.done) return null;
        self.done = true;
        if (self.entry.failed()) return .{ .failure = self.entry.exit_code.? };
        return null;
    }
};

pub fn displayCommand(gpa: std.mem.Allocator, command: []const u8) ![]u8 {
    return report.sanitizeDisplayText(gpa, context.firstLine(command));
}

test "entry presentation derives flags reference and metadata once" {
    const gpa = std.testing.allocator;
    const entry = EntryPresentation.init("work", 42, true, true, 7);
    try std.testing.expectEqualStrings("*!", &entry.flags());
    var reference_buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("@work.42", try entry.formatReference(&reference_buf));
    try std.testing.expectEqual(@as(usize, 3), entry.metadataSuffixWidth());

    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(gpa);
    try payload.appendSlice(gpa, "make check");
    const offsets = try entry.appendMetadata(gpa, &payload);
    try std.testing.expectEqualStrings("make check !7", payload.items);
    try std.testing.expectEqual(@as(?usize, 11), offsets.failure_start);
}

test "entry presentation keeps unfinished and successful entries distinct" {
    const unfinished = EntryPresentation.init("work", 1, false, false, null);
    const successful = EntryPresentation.init("work", 2, false, false, 0);
    try std.testing.expect(!unfinished.failed());
    try std.testing.expect(!successful.failed());
    try std.testing.expectEqualStrings("  ", &unfinished.flags());
    try std.testing.expectEqual(@as(usize, 0), unfinished.metadataSuffixWidth());
}

test "display command uses the first safe line" {
    const gpa = std.testing.allocator;
    const text = try displayCommand(gpa, "echo before\x1b[2Jafter\necho ignored");
    defer gpa.free(text);
    try std.testing.expectEqualStrings("echo beforeafter", text);
}
