//! Cached visual-row layout for selectable entry-detail items.

const std = @import("std");
const zooi = @import("zooi");

pub const ItemKind = enum { field, output, separator };

pub const Fragment = struct {
    start: usize = 0,
    end: usize = 0,
    indent: usize = 0,
    show_prefix: bool = false,
    replacement: bool = false,
    separator: bool = false,
};

pub const Layout = struct {
    columns: usize = 0,
    fragments: std.ArrayList(Fragment) = .empty,
    starts: std.ArrayList(usize) = .empty,
    heights: std.ArrayList(usize) = .empty,
    offsets: std.ArrayList(usize) = .empty,
    row_index: ?zooi.RowIndex = null,

    pub fn deinit(self: *Layout, gpa: std.mem.Allocator) void {
        self.fragments.deinit(gpa);
        self.starts.deinit(gpa);
        self.heights.deinit(gpa);
        self.offsets.deinit(gpa);
        self.* = .{};
    }

    pub fn reflow(self: *Layout, gpa: std.mem.Allocator, document: []const u8, items: anytype, columns: usize) !void {
        if (columns == 0) return error.ZeroColumns;
        if (self.row_index != null and self.columns == columns and self.heights.items.len == items.len) return;

        self.row_index = null;
        self.fragments.clearRetainingCapacity();
        self.starts.clearRetainingCapacity();
        self.heights.clearRetainingCapacity();
        self.offsets.clearRetainingCapacity();

        try self.starts.ensureTotalCapacity(gpa, items.len);
        try self.heights.ensureTotalCapacity(gpa, items.len);
        try self.offsets.ensureTotalCapacity(gpa, items.len + 1);

        for (items) |item| {
            try self.starts.append(gpa, self.fragments.items.len);
            if (item.kind == .separator) {
                try self.fragments.append(gpa, .{ .separator = true });
                try self.heights.append(gpa, 1);
                continue;
            }

            const prefix_start = item.section_start;
            const prefix_end = if (item.kind == .field) item.payload_start else item.section_start;
            const prefix_columns = @min(zooi.displayWidth(document[prefix_start..prefix_end]), columns -| 1);
            const content_start = prefix_end;
            const available = @max(columns -| prefix_columns, 1);
            const mode: zooi.wrap.Mode = if (item.kind == .output) .cell else .word;
            var wrapped = try zooi.wrap.iterator(document[content_start..item.section_end], available, mode);
            var first = true;
            while (wrapped.next()) |fragment| {
                try self.fragments.append(gpa, .{
                    .start = content_start + fragment.start,
                    .end = content_start + fragment.end,
                    .indent = if (first) 0 else prefix_columns,
                    .show_prefix = first and prefix_end > prefix_start,
                    .replacement = fragment.kind == .replacement,
                });
                first = false;
            }
            const start = self.starts.items[self.starts.items.len - 1];
            try self.heights.append(gpa, @max(self.fragments.items.len - start, 1));
        }

        self.offsets.appendAssumeCapacity(0);
        var total: usize = 0;
        for (self.heights.items) |height| {
            total = try std.math.add(usize, total, height);
            self.offsets.appendAssumeCapacity(total);
        }
        self.row_index = try zooi.RowIndex.build(self.heights.items, self.offsets.items);
        self.columns = columns;
    }

    pub fn index(self: *const Layout) zooi.RowIndex {
        return self.row_index.?;
    }

    pub fn itemFragments(self: *const Layout, item: usize) []const Fragment {
        const start = self.starts.items[item];
        return self.fragments.items[start .. start + self.heights.items[item]];
    }
};

test "detail layout wraps fields and output into indexed visual rows" {
    const gpa = std.testing.allocator;
    const document = "cmd       alpha beta gamma\nabcdefghijklmnop\n=== out ===";
    const Item = struct {
        section_start: usize,
        section_end: usize,
        payload_start: usize,
        kind: ItemKind,
    };
    const items = [_]Item{
        .{ .section_start = 0, .section_end = 26, .payload_start = 10, .kind = .field },
        .{ .section_start = 27, .section_end = 43, .payload_start = 27, .kind = .output },
        .{ .section_start = 44, .section_end = document.len, .payload_start = document.len, .kind = .separator },
    };

    var layout: Layout = .{};
    defer layout.deinit(gpa);
    try layout.reflow(gpa, document, &items, 14);
    try std.testing.expect(layout.heights.items[0] > 1);
    try std.testing.expect(layout.heights.items[1] > 1);
    try std.testing.expectEqual(@as(usize, 1), layout.heights.items[2]);
    try std.testing.expect(layout.itemFragments(0)[0].show_prefix);
    try std.testing.expectEqual(@as(usize, 10), layout.itemFragments(0)[1].indent);
    try std.testing.expect(layout.itemFragments(2)[0].separator);
    const narrow_rows = layout.index().totalRows();

    try layout.reflow(gpa, document, &items, 28);
    try std.testing.expect(layout.index().totalRows() < narrow_rows);
    try std.testing.expectEqual(items.len, layout.index().itemCount());
}
