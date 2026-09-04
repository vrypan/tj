//! Browser state, navigation, selection, and key handling.

const std = @import("std");
const Io = std.Io;
const zooi = @import("zooi");

const context = @import("../commands/context.zig");
const store = @import("../journal/store.zig");
const tui_detail = @import("detail.zig");

const max_input = 63;

fn orderU32(wanted: u32, item: u32) std.math.Order {
    return std.math.order(wanted, item);
}

pub const Mode = enum { normal, add_tag, remove_tag, name, delete_confirm, detail };

pub const Effect = enum {
    none,
    quit,
    refresh,
    toggle_pin,
    begin_name,
    add_tag,
    remove_tag,
    set_name,
    begin_delete,
    delete,
    delete_unpinned,
    export_selection,
    open_detail,
    close_detail,
    choose_detail,
};

const Detail = tui_detail.Detail;
const DetailItem = tui_detail.Item;

pub const Model = struct {
    /// The allocation may be longer than count when the running browser
    /// command or entries outside a supplied filter were removed in place.
    numbers: []u32 = &.{},
    allowed_numbers: ?[]u32 = null,
    count: usize = 0,
    selected: std.DynamicBitSetUnmanaged = .{},
    range_base: std.DynamicBitSetUnmanaged = .{},
    range_anchor: ?usize = null,
    viewport: zooi.Viewport = .{},
    size: zooi.Size = .{ .rows = 24, .cols = 80 },
    mode: Mode = .normal,
    input: [max_input]u8 = undefined,
    input_len: usize = 0,
    status_buf: [256]u8 = undefined,
    status_len: usize = 0,
    delete_pinned_count: usize = 0,
    detail: ?Detail = null,
    detail_viewport: zooi.Viewport = .{},
    detail_selected: std.DynamicBitSetUnmanaged = .{},
    detail_range_base: std.DynamicBitSetUnmanaged = .{},
    detail_range_anchor: ?usize = null,
    detail_chosen: bool = false,
    selection_exported: bool = false,
    quit: bool = false,

    pub fn deinit(self: *Model, gpa: std.mem.Allocator) void {
        if (self.detail) |*detail| detail.deinit(gpa);
        self.detail_selected.deinit(gpa);
        self.detail_range_base.deinit(gpa);
        self.selected.deinit(gpa);
        self.range_base.deinit(gpa);
        gpa.free(self.numbers);
        if (self.allowed_numbers) |numbers| gpa.free(numbers);
        self.* = undefined;
    }

    pub fn visibleNumbers(self: *const Model) []const u32 {
        return self.numbers[0..self.count];
    }

    pub fn currentNumber(self: *const Model) ?u32 {
        if (self.count == 0) return null;
        return self.numbers[self.viewport.cursor];
    }

    pub fn selectedCount(self: *const Model) usize {
        return self.selected.count();
    }

    pub fn isSelected(self: *const Model, index: usize) bool {
        return index < self.selected.capacity() and self.selected.isSet(index);
    }

    pub fn toggleCurrentSelection(self: *Model) void {
        if (self.count == 0) return;
        self.selected.toggle(self.viewport.cursor);
        self.setStatus("{d} selected", .{self.selectedCount()});
    }

    pub fn extendSelection(self: *Model, delta: isize) void {
        if (self.count == 0) return;
        if (self.range_anchor == null) {
            self.range_anchor = self.viewport.cursor;
            self.range_base.unsetAll();
            self.range_base.setUnion(self.selected);
        }
        self.selected.unsetAll();
        self.selected.setUnion(self.range_base);
        self.moveCursor(delta);
        const anchor = self.range_anchor.?;
        const first = @min(anchor, self.viewport.cursor);
        const last = @max(anchor, self.viewport.cursor);
        self.selected.setRangeValue(.{ .start = first, .end = last + 1 }, true);
        self.setStatus("{d} selected", .{self.selectedCount()});
    }

    pub fn clearSelection(self: *Model) void {
        self.selected.unsetAll();
        self.range_anchor = null;
        self.setStatus("selection cleared", .{});
    }

    pub fn actionNumbers(self: *const Model, gpa: std.mem.Allocator) ![]u32 {
        const selected_count = self.selectedCount();
        const current = if (selected_count == 0) self.currentNumber() orelse return error.NoSuchInteraction else null;
        const result = try gpa.alloc(u32, if (selected_count == 0) 1 else selected_count);
        if (selected_count == 0) {
            result[0] = current.?;
            return result;
        }
        var out: usize = 0;
        for (self.visibleNumbers(), 0..) |number, index| {
            if (!self.selected.isSet(index)) continue;
            result[out] = number;
            out += 1;
        }
        return result;
    }

    pub fn listRows(self: *const Model) usize {
        if (self.size.rows < 4) return 0;
        return self.size.rows - 3;
    }

    pub fn setStatus(self: *Model, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.bufPrint(&self.status_buf, fmt, args) catch {
            self.status_len = 0;
            return;
        };
        self.status_len = text.len;
    }

    pub fn status(self: *const Model) []const u8 {
        return self.status_buf[0..self.status_len];
    }

    pub fn clearStatus(self: *Model) void {
        self.status_len = 0;
    }

    pub fn inputText(self: *const Model) []const u8 {
        return self.input[0..self.input_len];
    }

    pub fn setInput(self: *Model, text: []const u8) void {
        const len = @min(text.len, self.input.len);
        @memcpy(self.input[0..len], text[0..len]);
        self.input_len = len;
    }

    pub fn clearInput(self: *Model) void {
        self.input_len = 0;
    }

    pub fn detailSelectedCount(self: *const Model) usize {
        return self.detail_selected.count();
    }

    pub fn detailMove(self: *Model, delta: isize) void {
        const detail = self.detail orelse return;
        self.detail_viewport.move(delta, detail.items.len, self.listRows());
    }

    pub fn detailToggle(self: *Model) void {
        const detail = self.detail orelse return;
        if (detail.items.len == 0) return;
        self.detail_selected.toggle(self.detail_viewport.cursor);
    }

    pub fn detailExtend(self: *Model, delta: isize) void {
        const detail = self.detail orelse return;
        if (detail.items.len == 0) return;
        if (self.detail_range_anchor == null) {
            self.detail_range_anchor = self.detail_viewport.cursor;
            self.detail_range_base.unsetAll();
            self.detail_range_base.setUnion(self.detail_selected);
        }
        self.detail_selected.unsetAll();
        self.detail_selected.setUnion(self.detail_range_base);
        self.detailMove(delta);
        const anchor = self.detail_range_anchor.?;
        const first = @min(anchor, self.detail_viewport.cursor);
        const last = @max(anchor, self.detail_viewport.cursor);
        self.detail_selected.setRangeValue(.{ .start = first, .end = last + 1 }, true);
    }

    pub fn detailClearSelection(self: *Model) void {
        self.detail_selected.unsetAll();
        self.detail_range_anchor = null;
    }

    pub fn pushInput(self: *Model, codepoint: u21) void {
        // Journal names and tags intentionally have conservative ASCII
        // grammars. Rejecting other input here makes the prompt match them.
        if (codepoint < 0x20 or codepoint > 0x7e or self.input_len == self.input.len) return;
        self.input[self.input_len] = @intCast(codepoint);
        self.input_len += 1;
    }

    pub fn popInput(self: *Model) void {
        if (self.input_len != 0) self.input_len -= 1;
    }

    pub fn reload(
        self: *Model,
        gpa: std.mem.Allocator,
        io: Io,
        home: ?[]const u8,
        journal: []const u8,
    ) !void {
        const previous = self.currentNumber();
        const old_numbers = self.visibleNumbers();
        var root = try store.openRoot(io, home);
        defer root.close(io);
        const numbers = try store.listNumbers(gpa, io, root, journal);
        errdefer gpa.free(numbers);

        var new_count: usize = 0;
        const active = context.activeInteraction();
        for (numbers) |number| {
            if (active) |entry| {
                if (std.mem.eql(u8, entry.journal, journal) and entry.number == number) continue;
            }
            if (self.allowed_numbers) |allowed| {
                if (std.sort.binarySearch(u32, allowed, number, orderU32) == null) continue;
            }
            numbers[new_count] = number;
            new_count += 1;
        }
        var new_selected = try std.DynamicBitSetUnmanaged.initEmpty(gpa, new_count);
        errdefer new_selected.deinit(gpa);
        var new_range_base = try std.DynamicBitSetUnmanaged.initEmpty(gpa, new_count);
        errdefer new_range_base.deinit(gpa);
        var old_index: usize = 0;
        for (numbers[0..new_count], 0..) |number, new_index| {
            while (old_index < old_numbers.len and old_numbers[old_index] < number) old_index += 1;
            if (old_index < old_numbers.len and old_numbers[old_index] == number and self.isSelected(old_index)) {
                new_selected.set(new_index);
            }
        }

        gpa.free(self.numbers);
        self.selected.deinit(gpa);
        self.range_base.deinit(gpa);
        self.numbers = numbers;
        self.count = new_count;
        self.selected = new_selected;
        self.range_base = new_range_base;
        self.range_anchor = null;

        if (self.count == 0) {
            self.viewport.normalize(0, self.listRows());
            return;
        }
        var next_cursor = self.count - 1;
        if (previous) |wanted| {
            for (self.visibleNumbers(), 0..) |number, index| {
                if (number == wanted) {
                    next_cursor = index;
                    break;
                }
            }
        }
        self.viewport.setCursor(next_cursor, self.count, self.listRows());
    }

    pub fn setCursor(self: *Model, index: usize) void {
        self.viewport.setCursor(index, self.count, self.listRows());
    }

    pub fn moveCursor(self: *Model, delta: isize) void {
        self.viewport.move(delta, self.count, self.listRows());
    }
};

pub fn handleEvent(model: *Model, event: zooi.Event) Effect {
    return switch (event) {
        .resize => |size| blk: {
            model.size = size;
            model.viewport.normalize(model.count, model.listRows());
            if (model.detail) |detail| model.detail_viewport.normalize(detail.items.len, model.listRows());
            break :blk .none;
        },
        .key => |key| switch (model.mode) {
            .normal => normalKey(model, key),
            .add_tag, .remove_tag, .name => promptKey(model, key),
            .delete_confirm => deleteConfirmKey(model, key),
            .detail => detailKey(model, key),
        },
    };
}

fn normalKey(model: *Model, key: zooi.Key) Effect {
    if (key == .ctrl_c) {
        model.quit = true;
        return .quit;
    }
    if (!isRangeExtensionKey(key)) model.range_anchor = null;
    const page = @max(model.listRows(), 1);
    switch (key) {
        .up => model.moveCursor(-1),
        .down => model.moveCursor(1),
        .shift_up => model.extendSelection(-1),
        .shift_down => model.extendSelection(1),
        .shift_page_up => model.extendSelection(-@as(isize, @intCast(page))),
        .shift_page_down => model.extendSelection(@intCast(page)),
        .page_up => model.moveCursor(-@as(isize, @intCast(page))),
        .page_down => model.moveCursor(@intCast(page)),
        .shift_home => model.extendSelection(-@as(isize, @intCast(model.viewport.cursor))),
        .shift_end => if (model.count != 0) model.extendSelection(@intCast(model.count - 1 - model.viewport.cursor)),
        .home => model.setCursor(0),
        .end => if (model.count != 0) model.setCursor(model.count - 1),
        .escape => model.clearSelection(),
        .character => |codepoint| switch (codepoint) {
            'k' => model.moveCursor(-1),
            'j' => model.moveCursor(1),
            'g' => model.setCursor(0),
            'G' => if (model.count != 0) model.setCursor(model.count - 1),
            'q' => {
                model.quit = true;
                return .quit;
            },
            'r' => return .refresh,
            'p' => if (model.count != 0) return .toggle_pin,
            ' ' => if (model.count != 0) model.toggleCurrentSelection(),
            't' => if (model.count != 0) {
                model.clearInput();
                model.clearStatus();
                model.mode = .add_tag;
            },
            'T' => if (model.count != 0) {
                model.clearInput();
                model.clearStatus();
                model.mode = .remove_tag;
            },
            'n' => if (model.count != 0) return .begin_name,
            'd' => if (model.count != 0) return .begin_delete,
            'e' => {
                if (model.selectedCount() == 0) {
                    model.setStatus("select entries first", .{});
                } else {
                    return .export_selection;
                }
            },
            else => {},
        },
        .enter => if (model.count != 0) return .open_detail,
        else => {},
    }
    return .none;
}

fn promptKey(model: *Model, key: zooi.Key) Effect {
    if (key == .ctrl_c or key == .escape) {
        model.mode = .normal;
        model.clearInput();
        model.setStatus("cancelled", .{});
        return .none;
    }
    switch (key) {
        .backspace => model.popInput(),
        .character => |codepoint| model.pushInput(codepoint),
        .enter => {
            const effect: Effect = switch (model.mode) {
                .add_tag => .add_tag,
                .remove_tag => .remove_tag,
                .name => .set_name,
                .normal, .delete_confirm, .detail => .none,
            };
            if (model.input_len == 0 and model.mode != .name) {
                model.mode = .normal;
                model.setStatus("cancelled: empty tag", .{});
                return .none;
            }
            model.mode = .normal;
            return effect;
        },
        else => {},
    }
    return .none;
}

fn deleteConfirmKey(model: *Model, key: zooi.Key) Effect {
    if (key == .ctrl_c) {
        model.quit = true;
        return .quit;
    }
    switch (key) {
        .character => |codepoint| switch (codepoint) {
            'y', 'Y' => {
                model.mode = .normal;
                return .delete;
            },
            'n', 'N' => {
                model.mode = .normal;
                return .delete_unpinned;
            },
            else => {},
        },
        .enter => {
            model.mode = .normal;
            return .delete_unpinned;
        },
        .escape => {
            model.mode = .normal;
            model.setStatus("delete cancelled", .{});
        },
        else => {},
    }
    return .none;
}

fn detailKey(model: *Model, key: zooi.Key) Effect {
    if (key == .ctrl_c) {
        model.quit = true;
        return .quit;
    }
    if (!isRangeExtensionKey(key)) model.detail_range_anchor = null;
    const page = @max(model.listRows(), 1);
    switch (key) {
        .up => model.detailMove(-1),
        .down => model.detailMove(1),
        .shift_up => model.detailExtend(-1),
        .shift_down => model.detailExtend(1),
        .shift_page_up => model.detailExtend(-@as(isize, @intCast(page))),
        .shift_page_down => model.detailExtend(@intCast(page)),
        .page_up => model.detailMove(-@as(isize, @intCast(page))),
        .page_down => model.detailMove(@intCast(page)),
        .shift_home => model.detailExtend(-@as(isize, @intCast(model.detail_viewport.cursor))),
        .shift_end => if (model.detail) |detail| {
            if (detail.items.len != 0) model.detailExtend(@intCast(detail.items.len - 1 - model.detail_viewport.cursor));
        },
        .home => {
            const count = if (model.detail) |detail| detail.items.len else 0;
            model.detail_viewport.setCursor(0, count, model.listRows());
        },
        .end => {
            if (model.detail) |detail| {
                if (detail.items.len != 0) model.detail_viewport.setCursor(detail.items.len - 1, detail.items.len, model.listRows());
            }
        },
        .escape => {
            if (model.detailSelectedCount() != 0) {
                model.detailClearSelection();
                return .none;
            }
            return .close_detail;
        },
        .enter => return .choose_detail,
        .character => |codepoint| switch (codepoint) {
            'k' => model.detailMove(-1),
            'j' => model.detailMove(1),
            'g' => {
                const count = if (model.detail) |detail| detail.items.len else 0;
                model.detail_viewport.setCursor(0, count, model.listRows());
            },
            'G' => {
                if (model.detail) |detail| {
                    if (detail.items.len != 0) model.detail_viewport.setCursor(detail.items.len - 1, detail.items.len, model.listRows());
                }
            },
            ' ' => model.detailToggle(),
            'q' => return .close_detail,
            else => {},
        },
        else => {},
    }
    return .none;
}

fn isRangeExtensionKey(key: zooi.Key) bool {
    return switch (key) {
        .shift_up, .shift_down, .shift_page_up, .shift_page_down, .shift_home, .shift_end => true,
        else => false,
    };
}

test "browser navigation clamps and scrolls" {
    const gpa = std.testing.allocator;
    var model: Model = .{
        .numbers = try gpa.dupe(u32, &.{ 2, 4, 9, 10 }),
        .count = 4,
        .size = .{ .rows = 4, .cols = 80 },
    };
    defer model.deinit(gpa);

    model.setCursor(3);
    try std.testing.expectEqual(@as(usize, 3), model.viewport.cursor);
    try std.testing.expectEqual(@as(usize, 2), model.viewport.offset);
    model.size.rows = 5;
    model.viewport.normalize(model.count, model.listRows());
    try std.testing.expectEqual(@as(usize, 1), model.viewport.offset);
    model.moveCursor(-20);
    try std.testing.expectEqual(@as(usize, 0), model.viewport.cursor);
    try std.testing.expectEqual(@as(usize, 0), model.viewport.offset);
    model.moveCursor(20);
    try std.testing.expectEqual(@as(usize, 3), model.viewport.cursor);
}

test "browser prompt maps add remove and empty-name removal" {
    var model: Model = .{ .mode = .add_tag };
    _ = promptKey(&model, .{ .character = 'B' });
    _ = promptKey(&model, .{ .character = 'u' });
    _ = promptKey(&model, .{ .character = 'g' });
    try std.testing.expectEqual(Effect.add_tag, promptKey(&model, .enter));
    try std.testing.expectEqualStrings("Bug", model.inputText());

    model.mode = .remove_tag;
    model.clearInput();
    try std.testing.expectEqual(Effect.none, promptKey(&model, .enter));
    model.mode = .name;
    try std.testing.expectEqual(Effect.set_name, promptKey(&model, .enter));
}

test "browser deletion requires explicit confirmation" {
    var model: Model = .{ .mode = .delete_confirm };
    try std.testing.expectEqual(Effect.delete_unpinned, deleteConfirmKey(&model, .{ .character = 'n' }));
    try std.testing.expectEqual(Mode.normal, model.mode);

    model.mode = .delete_confirm;
    try std.testing.expectEqual(Effect.delete, deleteConfirmKey(&model, .{ .character = 'Y' }));
    try std.testing.expectEqual(Mode.normal, model.mode);

    model.mode = .delete_confirm;
    try std.testing.expectEqual(Effect.none, deleteConfirmKey(&model, .escape));
    try std.testing.expectEqualStrings("delete cancelled", model.status());
}

test "browser selects individual entries and inclusive ranges" {
    const gpa = std.testing.allocator;
    var model: Model = .{
        .numbers = try gpa.dupe(u32, &.{ 2, 4, 9, 10 }),
        .count = 4,
        .selected = try std.DynamicBitSetUnmanaged.initEmpty(gpa, 4),
        .range_base = try std.DynamicBitSetUnmanaged.initEmpty(gpa, 4),
    };
    defer model.deinit(gpa);

    model.setCursor(1);
    model.toggleCurrentSelection();
    try std.testing.expect(model.isSelected(1));
    model.setCursor(3);
    model.toggleCurrentSelection();
    try std.testing.expectEqual(@as(usize, 2), model.selectedCount());

    model.clearSelection();
    model.setCursor(3);
    model.extendSelection(-1);
    model.extendSelection(-1);
    try std.testing.expectEqual(@as(usize, 3), model.selectedCount());
    try std.testing.expect(!model.isSelected(0));
    model.extendSelection(1);
    try std.testing.expectEqual(@as(usize, 2), model.selectedCount());
    try std.testing.expect(model.isSelected(2));
    try std.testing.expect(model.isSelected(3));

    const targets = try model.actionNumbers(gpa);
    defer gpa.free(targets);
    try std.testing.expectEqualSlices(u32, &.{ 9, 10 }, targets);

    try std.testing.expectEqual(Effect.none, normalKey(&model, .escape));
    try std.testing.expectEqual(@as(usize, 0), model.selectedCount());
    const focused = try model.actionNumbers(gpa);
    defer gpa.free(focused);
    try std.testing.expectEqualSlices(u32, &.{10}, focused);
}

test "browser exports only an explicit selection" {
    const gpa = std.testing.allocator;
    var model: Model = .{
        .numbers = try gpa.dupe(u32, &.{ 2, 4, 9 }),
        .count = 3,
        .selected = try std.DynamicBitSetUnmanaged.initEmpty(gpa, 3),
        .range_base = try std.DynamicBitSetUnmanaged.initEmpty(gpa, 3),
    };
    defer model.deinit(gpa);

    try std.testing.expectEqual(Effect.none, normalKey(&model, .{ .character = 'e' }));
    try std.testing.expectEqualStrings("select entries first", model.status());

    model.selected.set(0);
    model.selected.set(2);
    try std.testing.expectEqual(Effect.export_selection, normalKey(&model, .{ .character = 'e' }));
}

test "browser extends selections by pages and to boundaries" {
    const gpa = std.testing.allocator;
    var model: Model = .{
        .numbers = try gpa.dupe(u32, &.{ 1, 2, 3, 4, 5, 6, 7 }),
        .count = 7,
        .size = .{ .rows = 6, .cols = 80 },
        .selected = try std.DynamicBitSetUnmanaged.initEmpty(gpa, 7),
        .range_base = try std.DynamicBitSetUnmanaged.initEmpty(gpa, 7),
    };
    defer model.deinit(gpa);

    model.setCursor(1);
    _ = normalKey(&model, .shift_page_down);
    try std.testing.expectEqual(@as(usize, 4), model.viewport.cursor);
    try std.testing.expectEqual(@as(usize, 4), model.selectedCount());

    _ = normalKey(&model, .shift_end);
    try std.testing.expectEqual(@as(usize, 6), model.viewport.cursor);
    try std.testing.expectEqual(@as(usize, 6), model.selectedCount());

    _ = normalKey(&model, .shift_home);
    try std.testing.expectEqual(@as(usize, 0), model.viewport.cursor);
    try std.testing.expectEqual(@as(usize, 2), model.selectedCount());
}

test "detail navigation selects values and inclusive ranges" {
    const gpa = std.testing.allocator;
    var items = [_]DetailItem{
        .{ .section_start = 0, .section_end = 3, .payload_start = 0, .payload_end = 3 },
        .{ .section_start = 4, .section_end = 7, .payload_start = 4, .payload_end = 7 },
        .{ .section_start = 8, .section_end = 11, .payload_start = 8, .payload_end = 11 },
        .{ .section_start = 12, .section_end = 15, .payload_start = 12, .payload_end = 15 },
    };
    var model: Model = .{
        .mode = .detail,
        .detail = .{
            .number = 1,
            .document = @constCast("cwd cmd one two"),
            .items = &items,
        },
        .detail_selected = try std.DynamicBitSetUnmanaged.initEmpty(gpa, items.len),
        .detail_range_base = try std.DynamicBitSetUnmanaged.initEmpty(gpa, items.len),
    };
    defer model.detail_selected.deinit(gpa);
    defer model.detail_range_base.deinit(gpa);

    try std.testing.expectEqual(Effect.none, detailKey(&model, .down));
    try std.testing.expectEqual(@as(usize, 1), model.detail_viewport.cursor);

    try std.testing.expectEqual(Effect.none, detailKey(&model, .{ .character = 'j' }));
    try std.testing.expectEqual(@as(usize, 2), model.detail_viewport.cursor);

    _ = detailKey(&model, .shift_down);
    try std.testing.expectEqual(@as(usize, 3), model.detail_viewport.cursor);
    try std.testing.expectEqual(@as(usize, 2), model.detailSelectedCount());
    try std.testing.expect(model.detail_selected.isSet(2));
    try std.testing.expect(model.detail_selected.isSet(3));
    try std.testing.expectEqual(Effect.none, detailKey(&model, .escape));
    try std.testing.expectEqual(@as(usize, 0), model.detailSelectedCount());
    try std.testing.expectEqual(Effect.choose_detail, detailKey(&model, .enter));
    try std.testing.expectEqual(Effect.close_detail, detailKey(&model, .escape));
}

test "detail navigation extends selections by pages and to boundaries" {
    const gpa = std.testing.allocator;
    var items: [7]DetailItem = @splat(.{ .section_start = 0, .section_end = 0, .payload_start = 0, .payload_end = 0 });
    var model: Model = .{
        .mode = .detail,
        .size = .{ .rows = 6, .cols = 80 },
        .detail = .{ .number = 1, .document = @constCast(""), .items = &items },
        .detail_selected = try std.DynamicBitSetUnmanaged.initEmpty(gpa, items.len),
        .detail_range_base = try std.DynamicBitSetUnmanaged.initEmpty(gpa, items.len),
    };
    defer model.detail_selected.deinit(gpa);
    defer model.detail_range_base.deinit(gpa);

    model.detail_viewport.setCursor(1, items.len, model.listRows());
    _ = detailKey(&model, .shift_page_down);
    try std.testing.expectEqual(@as(usize, 4), model.detail_viewport.cursor);
    try std.testing.expectEqual(@as(usize, 4), model.detailSelectedCount());

    _ = detailKey(&model, .shift_home);
    try std.testing.expectEqual(@as(usize, 0), model.detail_viewport.cursor);
    try std.testing.expectEqual(@as(usize, 2), model.detailSelectedCount());

    _ = detailKey(&model, .shift_end);
    try std.testing.expectEqual(@as(usize, 6), model.detail_viewport.cursor);
    try std.testing.expectEqual(@as(usize, 6), model.detailSelectedCount());
}

test "detail scrolling moves only when focus crosses a viewport edge" {
    var items = [_]DetailItem{
        .{ .section_start = 0, .section_end = 0, .payload_start = 0, .payload_end = 0 },
        .{ .section_start = 0, .section_end = 0, .payload_start = 0, .payload_end = 0 },
        .{ .section_start = 0, .section_end = 0, .payload_start = 0, .payload_end = 0 },
        .{ .section_start = 0, .section_end = 0, .payload_start = 0, .payload_end = 0 },
        .{ .section_start = 0, .section_end = 0, .payload_start = 0, .payload_end = 0 },
        .{ .section_start = 0, .section_end = 0, .payload_start = 0, .payload_end = 0 },
        .{ .section_start = 0, .section_end = 0, .payload_start = 0, .payload_end = 0 },
    };
    var model: Model = .{
        .size = .{ .rows = 6, .cols = 80 },
        .detail = .{ .number = 1, .document = @constCast(""), .items = &items },
    };

    model.detail_viewport.setCursor(2, items.len, model.listRows());
    try std.testing.expectEqual(@as(usize, 0), model.detail_viewport.offset);
    model.detail_viewport.setCursor(4, items.len, model.listRows());
    try std.testing.expectEqual(@as(usize, 1), model.detail_viewport.offset);
    model.detail_viewport.setCursor(6, items.len, model.listRows());
    try std.testing.expectEqual(@as(usize, 3), model.detail_viewport.offset);
    model.detail_viewport.setCursor(0, items.len, model.listRows());
    try std.testing.expectEqual(@as(usize, 0), model.detail_viewport.offset);
}
