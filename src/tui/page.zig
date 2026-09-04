//! The bounded set of journal entries needed for the current TUI frame.

const std = @import("std");
const Io = std.Io;
const zooi = @import("zooi");

const pins = @import("../journal/pins.zig");
const presentation = @import("../presentation/entry.zig");
const store = @import("../journal/store.zig");

pub const Row = struct {
    index: usize,
    info: store.InteractionInfo,
    command: []u8,
    pinned: bool,

    fn deinit(self: *Row, gpa: std.mem.Allocator) void {
        self.info.deinit(gpa);
        gpa.free(self.command);
        self.* = undefined;
    }
};

pub const Page = struct {
    range: zooi.Viewport.Range = .{ .start = 0, .end = 0 },
    rows: []Row = &.{},
    valid: bool = false,

    pub fn deinit(self: *Page, gpa: std.mem.Allocator) void {
        self.clear(gpa);
        self.* = undefined;
    }

    pub fn invalidate(self: *Page) void {
        self.valid = false;
    }

    pub fn ensure(
        self: *Page,
        gpa: std.mem.Allocator,
        io: Io,
        home: ?[]const u8,
        journal: []const u8,
        numbers: []const u32,
        wanted: zooi.Viewport.Range,
    ) !void {
        if (self.valid and sameRange(self.range, wanted)) return;

        var next: std.ArrayList(Row) = .empty;
        errdefer {
            for (next.items) |*row| row.deinit(gpa);
            next.deinit(gpa);
        }

        var root = try store.openRoot(io, home);
        defer root.close(io);
        for (wanted.start..wanted.end) |index| {
            if (index >= numbers.len) break;
            var row = (try loadRow(gpa, io, root, journal, numbers[index], index)) orelse continue;
            next.append(gpa, row) catch |err| {
                row.deinit(gpa);
                return err;
            };
        }

        const owned = try next.toOwnedSlice(gpa);
        self.clear(gpa);
        self.rows = owned;
        self.range = wanted;
        self.valid = true;
    }

    fn clear(self: *Page, gpa: std.mem.Allocator) void {
        for (self.rows) |*row| row.deinit(gpa);
        gpa.free(self.rows);
        self.rows = &.{};
    }
};

fn loadRow(
    gpa: std.mem.Allocator,
    io: Io,
    root: store.Dir,
    journal: []const u8,
    number: u32,
    index: usize,
) !?Row {
    const info = (try store.readInteraction(
        gpa,
        io,
        root,
        journal,
        number,
        store.listing_command_limit,
    )) orelse return null;
    errdefer info.deinit(gpa);
    const command = try presentation.displayCommand(gpa, info.command);
    errdefer gpa.free(command);
    return .{
        .index = index,
        .info = info,
        .command = command,
        .pinned = try pins.isPinned(io, root, journal, number),
    };
}

fn sameRange(a: zooi.Viewport.Range, b: zooi.Viewport.Range) bool {
    return a.start == b.start and a.end == b.end;
}

test "page cache recognizes the exact visible range" {
    var page: Page = .{ .range = .{ .start = 4, .end = 10 }, .valid = true };
    try std.testing.expect(sameRange(page.range, .{ .start = 4, .end = 10 }));
    try std.testing.expect(!sameRange(page.range, .{ .start = 5, .end = 11 }));
    page.invalidate();
    try std.testing.expect(!page.valid);
}
