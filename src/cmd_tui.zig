//! Full-screen, current-journal entry browser.
//!
//! Zooi owns terminal mechanics. TJ owns the model and every mutation, using
//! the same command-layer annotation operations as `tj name`, `tj tag`, and
//! `tj pin`.

const std = @import("std");
const Io = std.Io;
const posix = std.posix;
const c = std.c;
const zooi = @import("zooi");

const annotations = @import("annotations.zig");
const cmd_annotate = @import("cmd_annotate.zig");
const cmd_remove = @import("cmd_remove.zig");
const context = @import("context.zig");
const noout = @import("noout.zig");
const plain = @import("plain.zig");
const report = @import("report.zig");
const store = @import("store.zig");
const sys = @import("sys.zig");
const presentation = @import("entry_presentation.zig");

const max_input = 63;
const max_events_per_frame = 64;
const detail_output_limit = 2 * 1024 * 1024;

var region_active: std.atomic.Value(bool) = .init(false);

fn orderU32(wanted: u32, item: u32) std.math.Order {
    return std.math.order(wanted, item);
}

const Mode = enum { normal, add_tag, remove_tag, name, delete_confirm, detail };

const Effect = enum {
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
    open_detail,
    close_detail,
    choose_detail,
};

const DetailItem = struct {
    section_start: usize,
    section_end: usize,
    payload_start: usize,
    payload_end: usize,
};

const Detail = struct {
    number: u32,
    document: []u8,
    items: []DetailItem,

    fn deinit(self: *Detail, gpa: std.mem.Allocator) void {
        gpa.free(self.document);
        gpa.free(self.items);
        self.* = undefined;
    }

    fn itemValue(self: *const Detail, item: DetailItem) []const u8 {
        return self.document[item.payload_start..item.payload_end];
    }
};

const Model = struct {
    /// The allocation may be longer than count when the running browser
    /// command or entries outside a supplied filter were removed in place.
    numbers: []u32 = &.{},
    allowed_numbers: ?[]u32 = null,
    count: usize = 0,
    selected: std.DynamicBitSetUnmanaged = .{},
    range_base: std.DynamicBitSetUnmanaged = .{},
    range_anchor: ?usize = null,
    cursor: usize = 0,
    scroll: usize = 0,
    size: zooi.Size = .{ .rows = 24, .cols = 80 },
    mode: Mode = .normal,
    input: [max_input]u8 = undefined,
    input_len: usize = 0,
    status_buf: [256]u8 = undefined,
    status_len: usize = 0,
    delete_pinned_count: usize = 0,
    detail: ?Detail = null,
    detail_scroll: usize = 0,
    detail_line_count: usize = 0,
    detail_cursor: usize = 0,
    detail_selected: std.DynamicBitSetUnmanaged = .{},
    detail_range_base: std.DynamicBitSetUnmanaged = .{},
    detail_range_anchor: ?usize = null,
    detail_follow_selection: bool = false,
    detail_chosen: bool = false,
    quit: bool = false,

    fn deinit(self: *Model, gpa: std.mem.Allocator) void {
        if (self.detail) |*detail| detail.deinit(gpa);
        self.detail_selected.deinit(gpa);
        self.detail_range_base.deinit(gpa);
        self.selected.deinit(gpa);
        self.range_base.deinit(gpa);
        gpa.free(self.numbers);
        if (self.allowed_numbers) |numbers| gpa.free(numbers);
        self.* = undefined;
    }

    fn visibleNumbers(self: *const Model) []const u32 {
        return self.numbers[0..self.count];
    }

    fn currentNumber(self: *const Model) ?u32 {
        if (self.count == 0) return null;
        return self.numbers[self.cursor];
    }

    fn selectedCount(self: *const Model) usize {
        return self.selected.count();
    }

    fn isSelected(self: *const Model, index: usize) bool {
        return index < self.selected.capacity() and self.selected.isSet(index);
    }

    fn toggleCurrentSelection(self: *Model) void {
        if (self.count == 0) return;
        self.selected.toggle(self.cursor);
        self.setStatus("{d} selected", .{self.selectedCount()});
    }

    fn extendSelection(self: *Model, delta: isize) void {
        if (self.count == 0) return;
        if (self.range_anchor == null) {
            self.range_anchor = self.cursor;
            self.range_base.unsetAll();
            self.range_base.setUnion(self.selected);
        }
        self.selected.unsetAll();
        self.selected.setUnion(self.range_base);
        self.moveCursor(delta);
        const anchor = self.range_anchor.?;
        const first = @min(anchor, self.cursor);
        const last = @max(anchor, self.cursor);
        self.selected.setRangeValue(.{ .start = first, .end = last + 1 }, true);
        self.setStatus("{d} selected", .{self.selectedCount()});
    }

    fn clearSelection(self: *Model) void {
        self.selected.unsetAll();
        self.range_anchor = null;
        self.setStatus("selection cleared", .{});
    }

    fn actionNumbers(self: *const Model, gpa: std.mem.Allocator) ![]u32 {
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

    fn listRows(self: *const Model) usize {
        if (self.size.rows < 3) return 0;
        return self.size.rows - 2;
    }

    fn setStatus(self: *Model, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.bufPrint(&self.status_buf, fmt, args) catch {
            self.status_len = 0;
            return;
        };
        self.status_len = text.len;
    }

    fn status(self: *const Model) []const u8 {
        return self.status_buf[0..self.status_len];
    }

    fn clearStatus(self: *Model) void {
        self.status_len = 0;
    }

    fn inputText(self: *const Model) []const u8 {
        return self.input[0..self.input_len];
    }

    fn setInput(self: *Model, text: []const u8) void {
        const len = @min(text.len, self.input.len);
        @memcpy(self.input[0..len], text[0..len]);
        self.input_len = len;
    }

    fn clearInput(self: *Model) void {
        self.input_len = 0;
    }

    fn detailSelectedCount(self: *const Model) usize {
        return self.detail_selected.count();
    }

    fn detailMove(self: *Model, delta: isize) void {
        const detail = self.detail orelse return;
        if (detail.items.len == 0) return;
        const current: isize = @intCast(self.detail_cursor);
        const last: isize = @intCast(detail.items.len - 1);
        self.detail_cursor = @intCast(@max(@as(isize, 0), @min(last, current + delta)));
        self.detail_follow_selection = true;
    }

    fn detailScrollToCursor(self: *Model) void {
        const detail = self.detail orelse return;
        const rows = self.listRows();
        if (rows == 0 or detail.items.len <= rows) {
            self.detail_scroll = 0;
            return;
        }
        self.detail_scroll = @min(self.detail_scroll, detail.items.len - rows);
        if (self.detail_cursor < self.detail_scroll) self.detail_scroll = self.detail_cursor;
        if (self.detail_cursor >= self.detail_scroll + rows) {
            self.detail_scroll = self.detail_cursor - rows + 1;
        }
    }

    fn detailToggle(self: *Model) void {
        const detail = self.detail orelse return;
        if (detail.items.len == 0) return;
        self.detail_selected.toggle(self.detail_cursor);
    }

    fn detailExtend(self: *Model, delta: isize) void {
        const detail = self.detail orelse return;
        if (detail.items.len == 0) return;
        if (self.detail_range_anchor == null) {
            self.detail_range_anchor = self.detail_cursor;
            self.detail_range_base.unsetAll();
            self.detail_range_base.setUnion(self.detail_selected);
        }
        self.detail_selected.unsetAll();
        self.detail_selected.setUnion(self.detail_range_base);
        self.detailMove(delta);
        const anchor = self.detail_range_anchor.?;
        const first = @min(anchor, self.detail_cursor);
        const last = @max(anchor, self.detail_cursor);
        self.detail_selected.setRangeValue(.{ .start = first, .end = last + 1 }, true);
    }

    fn detailClearSelection(self: *Model) void {
        self.detail_selected.unsetAll();
        self.detail_range_anchor = null;
    }

    fn pushInput(self: *Model, codepoint: u21) void {
        // Journal names and tags intentionally have conservative ASCII
        // grammars. Rejecting other input here makes the prompt match them.
        if (codepoint < 0x20 or codepoint > 0x7e or self.input_len == self.input.len) return;
        self.input[self.input_len] = @intCast(codepoint);
        self.input_len += 1;
    }

    fn popInput(self: *Model) void {
        if (self.input_len != 0) self.input_len -= 1;
    }

    fn reload(
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
            self.cursor = 0;
            self.scroll = 0;
            return;
        }
        self.cursor = self.count - 1;
        if (previous) |wanted| {
            for (self.visibleNumbers(), 0..) |number, index| {
                if (number == wanted) {
                    self.cursor = index;
                    break;
                }
            }
        }
        self.scrollToCursor();
    }

    fn setCursor(self: *Model, index: usize) void {
        if (self.count == 0) return;
        self.cursor = @min(index, self.count - 1);
        self.scrollToCursor();
    }

    fn moveCursor(self: *Model, delta: isize) void {
        if (self.count == 0) return;
        const current: isize = @intCast(self.cursor);
        const last: isize = @intCast(self.count - 1);
        self.setCursor(@intCast(@max(@as(isize, 0), @min(last, current + delta))));
    }

    fn scrollToCursor(self: *Model) void {
        const rows = self.listRows();
        if (rows == 0 or self.count <= rows) {
            self.scroll = 0;
            return;
        }
        self.scroll = @min(self.scroll, self.count - rows);
        if (self.cursor < self.scroll) self.scroll = self.cursor;
        if (self.cursor >= self.scroll + rows) self.scroll = self.cursor - rows + 1;
    }
};

pub fn run(gpa: std.mem.Allocator, io: Io, home: ?[]const u8) !void {
    return runWithFilter(gpa, io, home, null);
}

pub fn runFiltered(gpa: std.mem.Allocator, io: Io, home: ?[]const u8, numbers: []const u32) !void {
    return runWithFilter(gpa, io, home, numbers);
}

fn runWithFilter(gpa: std.mem.Allocator, io: Io, home: ?[]const u8, allowed_numbers: ?[]const u32) !void {
    const journal = try context.currentJournal();
    if (journal.len == 0) return error.NotInJournal;
    if (!sys.isTty(0) or !sys.isTty(1)) return error.NoControllingTerminal;

    var model: Model = .{};
    defer model.deinit(gpa);
    if (allowed_numbers) |numbers| model.allowed_numbers = try gpa.dupe(u32, numbers);
    try model.reload(gpa, io, home, journal);

    try sys.writeAll(1, noout.begin_marker);
    region_active.store(true, .release);
    defer {
        sys.writeAll(1, noout.end_marker) catch {};
        region_active.store(false, .release);
    }

    installSignalHandlers();

    var ui = try zooi.Ui.init(gpa, .{});
    var ui_active = true;
    defer if (ui_active) ui.deinit();
    model.size = ui.size();
    model.scrollToCursor();
    try render(gpa, io, home, journal, &model, ui.screen());

    while (try ui.nextEvent()) |first| {
        var pending: ?zooi.Event = first;
        var handled: usize = 0;
        while (pending) |event| {
            const effect = update(&model, event);
            executeEffect(gpa, io, home, journal, &model, effect) catch |err| {
                model.setStatus("{s}", .{friendlyError(err)});
            };
            handled += 1;
            if (model.quit or handled == max_events_per_frame) break;
            pending = try ui.pollEvent();
        }
        if (model.quit) break;
        try render(gpa, io, home, journal, &model, ui.screen());
    }

    ui.deinit();
    ui_active = false;
    if (model.detail_chosen) {
        const detail = if (model.detail) |*value| value else return;
        const selected_count = model.detailSelectedCount();
        for (detail.items, 0..) |item, index| {
            if (selected_count == 0) {
                if (index != model.detail_cursor) continue;
            } else if (!model.detail_selected.isSet(index)) continue;
            try sys.writeAll(1, detail.itemValue(item));
            try sys.writeAll(1, "\n");
        }
    }
}

fn installSignalHandlers() void {
    const action: posix.Sigaction = .{
        .handler = .{ .handler = onFatalSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(.TERM, &action, null);
    posix.sigaction(.HUP, &action, null);
}

fn onFatalSignal(signal: posix.SIG) callconv(.c) void {
    zooi.restore();
    if (region_active.load(.acquire)) {
        _ = c.write(1, noout.end_marker.ptr, noout.end_marker.len);
    }
    c._exit(@intCast(128 + @intFromEnum(signal)));
}

fn update(model: *Model, event: zooi.Event) Effect {
    return switch (event) {
        .resize => |size| blk: {
            model.size = size;
            model.scrollToCursor();
            if (model.mode == .detail) model.detail_follow_selection = true;
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
    if (key != .shift_up and key != .shift_down) model.range_anchor = null;
    const page = @max(model.listRows(), 1);
    switch (key) {
        .up => model.moveCursor(-1),
        .down => model.moveCursor(1),
        .shift_up => model.extendSelection(-1),
        .shift_down => model.extendSelection(1),
        .page_up => model.moveCursor(-@as(isize, @intCast(page))),
        .page_down => model.moveCursor(@intCast(page)),
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
    if (key != .shift_up and key != .shift_down) model.detail_range_anchor = null;
    const page = @max(model.listRows(), 1);
    switch (key) {
        .up => model.detailMove(-1),
        .down => model.detailMove(1),
        .shift_up => model.detailExtend(-1),
        .shift_down => model.detailExtend(1),
        .page_up => model.detailMove(-@as(isize, @intCast(page))),
        .page_down => model.detailMove(@intCast(page)),
        .home => {
            model.detail_cursor = 0;
            model.detail_follow_selection = true;
        },
        .end => {
            if (model.detail) |detail| {
                if (detail.items.len != 0) model.detail_cursor = detail.items.len - 1;
            }
            model.detail_follow_selection = true;
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
                model.detail_cursor = 0;
                model.detail_follow_selection = true;
            },
            'G' => {
                if (model.detail) |detail| {
                    if (detail.items.len != 0) model.detail_cursor = detail.items.len - 1;
                }
                model.detail_follow_selection = true;
            },
            ' ' => model.detailToggle(),
            'q' => return .close_detail,
            else => {},
        },
        else => {},
    }
    return .none;
}

fn executeEffect(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    journal: []const u8,
    model: *Model,
    effect: Effect,
) !void {
    switch (effect) {
        .none, .quit => {},
        .refresh => {
            try model.reload(gpa, io, home, journal);
            model.setStatus("refreshed", .{});
        },
        .begin_name => {
            const number = model.currentNumber() orelse return;
            var root = try store.openRoot(io, home);
            defer root.close(io);
            var metadata = try annotations.openRead(gpa, io, root, journal);
            defer metadata.deinit(gpa);
            var entry = try metadata.get(gpa, number);
            defer if (entry) |*value| value.deinit(gpa);
            model.setInput(if (entry) |value| value.name orelse "" else "");
            model.clearStatus();
            model.mode = .name;
        },
        .toggle_pin => {
            const numbers = try model.actionNumbers(gpa);
            defer gpa.free(numbers);
            var root = try store.openRoot(io, home);
            defer root.close(io);
            var metadata = try annotations.openRead(gpa, io, root, journal);
            defer metadata.deinit(gpa);
            var all_pinned = true;
            for (numbers) |number| all_pinned = all_pinned and try metadata.isPinned(number);
            try cmd_annotate.updatePinNumbers(gpa, io, home, numbers, !all_pinned);
            model.setStatus("{d} {s} {s}", .{
                numbers.len,
                if (numbers.len == 1) "entry" else "entries",
                if (all_pinned) "unpinned" else "pinned",
            });
        },
        .add_tag, .remove_tag => {
            const numbers = try model.actionNumbers(gpa);
            defer gpa.free(numbers);
            const tag = model.inputText();
            try cmd_annotate.updateTagNumbers(gpa, io, home, numbers, &.{tag}, effect == .remove_tag);
            model.setStatus("{d} {s} {s} #{s}", .{
                numbers.len,
                if (numbers.len == 1) "entry" else "entries",
                if (effect == .remove_tag) "removed" else "tagged",
                tag,
            });
        },
        .set_name => {
            const number = model.currentNumber() orelse return;
            const name = model.inputText();
            var ref_buf: [24]u8 = undefined;
            const ref = try std.fmt.bufPrint(&ref_buf, "@{d}", .{number});
            try cmd_annotate.updateName(gpa, io, home, ref, if (name.len == 0) null else name);
            if (name.len == 0) {
                model.setStatus("removed entry {d} name", .{number});
            } else {
                model.setStatus("named entry {d} @{s}", .{ number, name });
            }
        },
        .begin_delete => {
            const numbers = try model.actionNumbers(gpa);
            defer gpa.free(numbers);
            var root = try store.openRoot(io, home);
            defer root.close(io);
            var metadata = try annotations.openRead(gpa, io, root, journal);
            defer metadata.deinit(gpa);
            var pinned: usize = 0;
            for (numbers) |number| pinned += @intFromBool(try metadata.isPinned(number));
            model.delete_pinned_count = pinned;
            model.clearStatus();
            if (pinned == 0) {
                try deleteTargets(gpa, io, home, journal, model, false);
            } else {
                model.mode = .delete_confirm;
            }
        },
        .delete => try deleteTargets(gpa, io, home, journal, model, true),
        .delete_unpinned => try deleteTargets(gpa, io, home, journal, model, false),
        .open_detail => {
            const number = model.currentNumber() orelse return;
            if (model.detail) |*detail| detail.deinit(gpa);
            model.detail = try loadDetail(gpa, io, home, journal, number);
            model.detail_selected.deinit(gpa);
            model.detail_selected = try std.DynamicBitSetUnmanaged.initEmpty(gpa, model.detail.?.items.len);
            model.detail_range_base.deinit(gpa);
            model.detail_range_base = try std.DynamicBitSetUnmanaged.initEmpty(gpa, model.detail.?.items.len);
            model.detail_scroll = 0;
            model.detail_line_count = 0;
            model.detail_cursor = 0;
            model.detail_range_anchor = null;
            model.detail_follow_selection = true;
            model.mode = .detail;
        },
        .close_detail => {
            if (model.detail) |*detail| detail.deinit(gpa);
            model.detail = null;
            model.detail_selected.deinit(gpa);
            model.detail_selected = .{};
            model.detail_range_base.deinit(gpa);
            model.detail_range_base = .{};
            model.detail_scroll = 0;
            model.detail_line_count = 0;
            model.detail_cursor = 0;
            model.detail_range_anchor = null;
            model.detail_follow_selection = false;
            model.mode = .normal;
        },
        .choose_detail => {
            model.detail_chosen = true;
            model.quit = true;
        },
    }
}

fn deleteTargets(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    journal: []const u8,
    model: *Model,
    include_pinned: bool,
) !void {
    const numbers = try model.actionNumbers(gpa);
    defer gpa.free(numbers);
    const old_cursor = model.cursor;
    const result = try cmd_remove.removeInteractionNumbers(gpa, io, home, numbers, include_pinned);
    try model.reload(gpa, io, home, journal);
    if (model.count != 0) model.setCursor(@min(old_cursor, model.count - 1));
    model.delete_pinned_count = 0;
    if (result.removed != 0 and result.skipped_pinned != 0) {
        model.setStatus("deleted {d}; kept {d} pinned", .{ result.removed, result.skipped_pinned });
    } else if (result.removed != 0) {
        model.setStatus("deleted {d} {s}", .{ result.removed, if (result.removed == 1) "entry" else "entries" });
    } else {
        model.setStatus("kept {d} pinned {s}", .{
            result.skipped_pinned,
            if (result.skipped_pinned == 1) "entry" else "entries",
        });
    }
}

fn loadDetail(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    journal: []const u8,
    number: u32,
) !Detail {
    var root = try store.openRoot(io, home);
    defer root.close(io);
    const info_optional = try store.readInteraction(gpa, io, root, journal, number, store.full_command_limit);
    const info = info_optional orelse return error.NoSuchInteraction;
    defer info.deinit(gpa);

    var metadata = try annotations.openRead(gpa, io, root, journal);
    defer metadata.deinit(gpa);
    var annotation = try metadata.get(gpa, number);
    defer if (annotation) |*value| value.deinit(gpa);

    var path_buf: [128]u8 = undefined;
    const cwd_path = try std.fmt.bufPrint(&path_buf, "{s}/{d}/cwd", .{ journal, number });
    const cwd = root.readFileAlloc(io, cwd_path, gpa, .limited(16 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (cwd) |value| gpa.free(value);

    const resources = try store.listResources(gpa, io, root, journal, number);
    defer {
        for (resources) |resource| gpa.free(resource);
        gpa.free(resources);
    }
    const output = try readPlainOutput(gpa, io, root, journal, number);
    defer gpa.free(output.text);

    const command = try report.sanitizeDisplayText(gpa, info.command);
    defer gpa.free(command);
    const cwd_value = if (cwd) |value|
        try report.sanitizeDisplayText(gpa, value)
    else
        try gpa.dupe(u8, "");
    defer gpa.free(cwd_value);

    var document: std.ArrayList(u8) = .empty;
    errdefer document.deinit(gpa);
    var special_items: std.ArrayList(DetailItem) = .empty;
    defer special_items.deinit(gpa);
    try document.print(gpa, "entry     @{d}\n", .{number});

    var item_start = document.items.len;
    try document.appendSlice(gpa, "cwd       ");
    const cwd_payload_start = document.items.len;
    if (cwd == null) {
        try document.appendSlice(gpa, "(missing)");
    } else if (cwd_value.len == 0) {
        try document.appendSlice(gpa, "(empty)");
    } else {
        try document.appendSlice(gpa, cwd_value);
    }
    try special_items.append(gpa, .{
        .section_start = item_start,
        .section_end = document.items.len,
        .payload_start = cwd_payload_start,
        .payload_end = cwd_payload_start + cwd_value.len,
    });
    try document.append(gpa, '\n');

    item_start = document.items.len;
    try document.appendSlice(gpa, "cmd       ");
    const command_payload_start = document.items.len;
    if (command.len == 0) try document.appendSlice(gpa, "(empty)") else try document.appendSlice(gpa, command);
    try special_items.append(gpa, .{
        .section_start = item_start,
        .section_end = document.items.len,
        .payload_start = command_payload_start,
        .payload_end = command_payload_start + command.len,
    });
    try document.append(gpa, '\n');

    if (info.exit_code) |code| {
        try document.print(gpa, "rc        {d}\n", .{code});
    } else {
        try document.appendSlice(gpa, "rc        unfinished\n");
    }
    try document.append(gpa, '\n');

    if (annotation) |value| {
        try document.print(gpa, "pinned    {s}\n", .{if (value.pinned) "yes" else "no"});
        try document.print(gpa, "name      {s}\n", .{if (value.name) |name| name else "-"});
        try document.appendSlice(gpa, "tags     ");
        if (value.tags.items.len == 0) {
            try document.appendSlice(gpa, " -");
        } else {
            for (value.tags.items) |tag| try document.print(gpa, " #{s}", .{tag});
        }
        try document.append(gpa, '\n');
    } else {
        try document.appendSlice(gpa, "pinned    no\nname      -\ntags      -\n");
    }
    if (store.readTiming(gpa, io, root, journal, number)) |timing| {
        var started_buf: [32]u8 = undefined;
        var ended_buf: [32]u8 = undefined;
        try document.print(gpa, "started   {s}\n", .{store.formatTimestamp(timing.started, &started_buf)});
        try document.print(gpa, "ended     {s}\n", .{store.formatTimestamp(timing.ended, &ended_buf)});
        try document.print(gpa, "duration  {d} ms\n", .{timing.duration()});
    } else {
        try document.appendSlice(gpa, "started   -\nended     -\nduration  -\n");
    }
    if (info.out_present) {
        var size_buf: [24]u8 = undefined;
        try document.print(gpa, "out size  {s} ({d} bytes)\n", .{ report.formatHumanSize(info.out_bytes, &size_buf), info.out_bytes });
    } else {
        try document.appendSlice(gpa, "out size  removed\n");
    }
    try document.appendSlice(gpa, "resources");
    if (resources.len == 0) {
        try document.appendSlice(gpa, " -");
    } else {
        for (resources) |resource| try document.print(gpa, " {s}", .{resource});
    }

    try document.appendSlice(gpa, "\n\nout\n");
    if (!output.present or output.text.len == 0) {
        item_start = document.items.len;
        try document.appendSlice(gpa, if (output.present) "(empty)" else "(removed)");
        try special_items.append(gpa, .{
            .section_start = item_start,
            .section_end = document.items.len,
            .payload_start = item_start,
            .payload_end = item_start,
        });
    } else {
        var line_start: usize = 0;
        while (line_start < output.text.len) {
            const relative_end = std.mem.indexOfScalar(u8, output.text[line_start..], '\n');
            const line_end = if (relative_end) |offset| line_start + offset else output.text.len;
            item_start = document.items.len;
            try document.appendSlice(gpa, output.text[line_start..line_end]);
            const payload_end = document.items.len;
            if (line_end == line_start) try document.appendSlice(gpa, " ");
            try special_items.append(gpa, .{
                .section_start = item_start,
                .section_end = document.items.len,
                .payload_start = item_start,
                .payload_end = payload_end,
            });
            if (relative_end == null) break;
            try document.append(gpa, '\n');
            line_start = line_end + 1;
        }
    }
    if (output.truncated) {
        try document.print(gpa, "\n[preview limited to {d} recorded bytes; use tj cat @{d}]", .{ detail_output_limit, number });
    }

    var items: std.ArrayList(DetailItem) = .empty;
    errdefer items.deinit(gpa);
    var line_start: usize = 0;
    var special_index: usize = 0;
    while (true) {
        const relative_end = std.mem.indexOfScalar(u8, document.items[line_start..], '\n');
        const line_end = if (relative_end) |offset| line_start + offset else document.items.len;
        if (special_index < special_items.items.len and special_items.items[special_index].section_start == line_start) {
            try items.append(gpa, special_items.items[special_index]);
            special_index += 1;
        } else {
            try items.append(gpa, .{
                .section_start = line_start,
                .section_end = line_end,
                .payload_start = line_start,
                .payload_end = line_end,
            });
        }
        if (relative_end == null) break;
        line_start = line_end + 1;
        if (line_start == document.items.len) break;
    }
    const owned_document = try document.toOwnedSlice(gpa);
    errdefer gpa.free(owned_document);
    const owned_items = try items.toOwnedSlice(gpa);
    return .{
        .number = number,
        .document = owned_document,
        .items = owned_items,
    };
}

const PlainOutput = struct {
    text: []u8,
    present: bool,
    truncated: bool,
};

fn readPlainOutput(
    gpa: std.mem.Allocator,
    io: Io,
    root: store.Dir,
    journal: []const u8,
    number: u32,
) !PlainOutput {
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{d}/out", .{ journal, number });
    const file = root.openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .{ .text = try gpa.dupe(u8, ""), .present = false, .truncated = false },
        else => return err,
    };
    defer file.close(io);
    const length = try file.length(io);

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(gpa);
    var writer = Io.Writer.Allocating.fromArrayList(gpa, &output);
    defer output = writer.toArrayList();
    var renderer = plain.Renderer.init(gpa);
    defer renderer.deinit();
    var reader_buf: [64 * 1024]u8 = undefined;
    var bytes: [64 * 1024]u8 = undefined;
    var reader = file.readerStreaming(io, &reader_buf);
    var remaining: usize = @intCast(@min(length, detail_output_limit));
    while (remaining != 0) {
        const count = try reader.interface.readSliceShort(bytes[0..@min(bytes.len, remaining)]);
        if (count == 0) break;
        try renderer.feed(bytes[0..count], &writer.writer);
        remaining -= count;
    }
    try renderer.finish(&writer.writer);
    return .{
        .text = try writer.toOwnedSlice(),
        .present = true,
        .truncated = length > detail_output_limit,
    };
}

const header_style: zooi.Style = .{ .reverse = true, .bold = true };
const cursor_style: zooi.Style = .{ .reverse = true };
const selected_style: zooi.Style = .{ .fg = .{ .ansi = 6 } };
const focused_selected_style: zooi.Style = .{ .reverse = true, .fg = .{ .ansi = 6 } };
const number_style: zooi.Style = .{ .fg = .{ .ansi = 3 } };
const metadata_style: zooi.Style = .{ .fg = .{ .ansi = 2 } };
const failure_style: zooi.Style = .{ .fg = .{ .ansi = 1 } };
const footer_style: zooi.Style = .{ .dim = true };

fn render(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    journal: []const u8,
    model: *Model,
    screen: *zooi.Screen,
) !void {
    screen.begin();
    if (model.size.rows < 3 or model.size.cols < 24) {
        screen.move(0, 0);
        screen.write("terminal too small");
        return screen.present();
    }

    if (model.mode == .detail) {
        try renderDetail(gpa, model, screen);
        return;
    }

    renderHeader(journal, model, screen);

    var root = try store.openRoot(io, home);
    defer root.close(io);
    var metadata = try annotations.openRead(gpa, io, root, journal);
    defer metadata.deinit(gpa);

    const number_width = if (model.count == 0)
        1
    else
        report.decimalWidth(model.numbers[model.count - 1]);
    var row: usize = 0;
    while (row < model.listRows()) : (row += 1) {
        const index = model.scroll + row;
        if (index >= model.count) break;
        const number = model.numbers[index];
        const info_optional = try store.readInteraction(
            gpa,
            io,
            root,
            journal,
            number,
            store.listing_command_limit,
        );
        if (info_optional == null) continue;
        const info = info_optional.?;
        defer info.deinit(gpa);
        var annotation = try metadata.get(gpa, number);
        defer if (annotation) |*value| value.deinit(gpa);

        const line: u16 = @intCast(row + 1);
        const focused = index == model.cursor;
        const picked = model.isSelected(index);
        const base_style: zooi.Style = if (focused and picked)
            focused_selected_style
        else if (focused)
            cursor_style
        else if (picked)
            selected_style
        else
            .{};
        if (focused) fillRow(screen, line, model.size.cols, base_style);
        screen.move(line, 0);

        const row_view = presentation.EntryPresentation.init(journal, number, false, if (annotation) |*value| value else null, info.exit_code);
        const flags = row_view.flags();
        screen.writeStyled(flags[0..1], base_style);
        screen.writeStyled(flags[1..2], base_style);
        screen.writeStyled(flags[2..3], base_style);
        screen.writeStyled(flags[3..4], if (focused) base_style else if (row_view.failed()) failure_style else base_style);
        screen.writeStyled(" ", base_style);

        var number_buf: [24]u8 = undefined;
        const number_text = try std.fmt.bufPrint(&number_buf, "{d}", .{number});
        var padding: [24]u8 = @splat(' ');
        screen.writeStyled(padding[0 .. number_width - number_text.len], base_style);
        screen.writeStyled(number_text, if (focused or picked) base_style else number_style);
        screen.writeStyled(" ", base_style);

        var size_buf: [24]u8 = undefined;
        const size_text = report.formatEntrySize(info, &size_buf);
        screen.writeStyled(size_text, if (focused) base_style else metadata_style);
        screen.writeStyled(" ", base_style);

        const command = try presentation.displayCommand(gpa, info.command);
        defer gpa.free(command);
        screen.writeStyled(command, base_style);
        var metadata_parts = row_view.metadata();
        while (metadata_parts.next()) |part| {
            screen.writeStyled(" ", base_style);
            const role_style = if (focused)
                base_style
            else switch (part.role()) {
                .metadata => metadata_style,
                .failure => failure_style,
                else => unreachable,
            };
            switch (part) {
                .name => |name| {
                    screen.writeStyled("@", base_style);
                    screen.writeStyled(name, role_style);
                },
                .tag => |tag| {
                    screen.writeStyled("#", base_style);
                    screen.writeStyled(tag, role_style);
                },
                .failure => |code| {
                    var rc_buf: [8]u8 = undefined;
                    const rc = try std.fmt.bufPrint(&rc_buf, "!{d}", .{code});
                    screen.writeStyled(rc, role_style);
                },
            }
        }
    }

    renderFooter(model, screen);
    try screen.present();
}

fn renderDetail(gpa: std.mem.Allocator, model: *Model, screen: *zooi.Screen) !void {
    _ = gpa;
    const detail = if (model.detail) |*value| value else return error.NoSuchInteraction;
    model.detail_line_count = detail.items.len;
    const rows = model.listRows();
    const max_scroll = detail.items.len -| rows;
    if (model.detail_follow_selection and detail.items.len != 0) {
        model.detailScrollToCursor();
        model.detail_follow_selection = false;
    }
    model.detail_scroll = @min(model.detail_scroll, max_scroll);

    var header_buf: [96]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, " entry @{d}  details ", .{detail.number}) catch " entry details ";
    screen.move(0, 0);
    screen.writeStyled(header, header_style);
    var spaces: [256]u8 = @splat(' ');
    var remaining = @as(usize, model.size.cols) -| zooi.displayWidth(header);
    while (remaining != 0) {
        const count = @min(remaining, spaces.len);
        screen.writeStyled(spaces[0..count], header_style);
        remaining -= count;
    }

    var row: usize = 0;
    while (row < rows and model.detail_scroll + row < detail.items.len) : (row += 1) {
        const item_index = model.detail_scroll + row;
        const item = detail.items[item_index];
        const text = detail.document[item.section_start..item.section_end];
        screen.move(@intCast(row + 1), 0);
        const focused = item_index == model.detail_cursor;
        const selected = model.detail_selected.isSet(item_index);
        const style: zooi.Style = if (focused and selected)
            focused_selected_style
        else if (focused)
            cursor_style
        else if (selected)
            selected_style
        else if (std.mem.eql(u8, text, "out"))
            .{ .bold = true, .fg = .{ .ansi = 3 } }
        else
            .{};
        if (focused) fillRow(screen, @intCast(row + 1), model.size.cols, style);
        screen.move(@intCast(row + 1), 0);
        screen.writeStyled(text, style);
    }

    screen.move(model.size.rows - 1, 0);
    if (model.detailSelectedCount() == 0) {
        screen.writeStyled("↑↓/jk move  shift+↑↓ range  space toggle  ⏎ print  esc/q back", footer_style);
    } else {
        var footer_buf: [128]u8 = undefined;
        const footer = std.fmt.bufPrint(&footer_buf, "{d} selected  shift+↑↓ range  space toggle  ⏎ print  esc clear", .{model.detailSelectedCount()}) catch "selected  ⏎ print  esc clear";
        screen.writeStyled(footer, footer_style);
    }
    try screen.present();
}

fn fillRow(screen: *zooi.Screen, row: u16, columns: u16, style: zooi.Style) void {
    screen.move(row, 0);
    var spaces: [256]u8 = @splat(' ');
    var remaining: usize = columns;
    while (remaining != 0) {
        const count = @min(remaining, spaces.len);
        screen.writeStyled(spaces[0..count], style);
        remaining -= count;
    }
}

fn renderHeader(journal: []const u8, model: *const Model, screen: *zooi.Screen) void {
    var buffer: [160]u8 = undefined;
    const noun = if (model.allowed_numbers != null) "matches" else "entries";
    const text = if (model.selectedCount() == 0)
        std.fmt.bufPrint(&buffer, " tj  {s}  {d} {s} ", .{ journal, model.count, noun }) catch " tj "
    else
        std.fmt.bufPrint(&buffer, " tj  {s}  {d} {s}  {d} selected ", .{ journal, model.count, noun, model.selectedCount() }) catch " tj ";
    screen.move(0, 0);
    screen.writeStyled(text, header_style);
    var spaces: [256]u8 = @splat(' ');
    var remaining = @as(usize, model.size.cols) -| zooi.displayWidth(text);
    while (remaining != 0) {
        const count = @min(remaining, spaces.len);
        screen.writeStyled(spaces[0..count], header_style);
        remaining -= count;
    }
}

fn renderFooter(model: *const Model, screen: *zooi.Screen) void {
    const row: u16 = model.size.rows - 1;
    screen.move(row, 0);
    switch (model.mode) {
        .add_tag, .remove_tag, .name => {
            const label = switch (model.mode) {
                .add_tag => "tag: ",
                .remove_tag => "untag: ",
                .name => "name: ",
                .normal, .delete_confirm, .detail => unreachable,
            };
            screen.write(label);
            screen.write(model.inputText());
            screen.showCursor(row, @intCast(zooi.displayWidth(label) + zooi.displayWidth(model.inputText())));
        },
        .normal => {
            if (model.status_len != 0) {
                screen.writeStyled(model.status(), .{ .fg = .{ .ansi = 3 } });
            } else {
                screen.writeStyled("space toggle  shift+↑↓ range  esc clear  ⏎ details  p pin  t/T tag  n name  d delete  q quit", footer_style);
            }
        },
        .delete_confirm => {
            var buffer: [128]u8 = undefined;
            const text = if (model.delete_pinned_count == 1)
                std.fmt.bufPrint(&buffer, "Delete pinned entry too? [y/N] ", .{}) catch "Delete pinned entry too? [y/N] "
            else
                std.fmt.bufPrint(&buffer, "Delete {d} pinned entries too? [y/N] ", .{model.delete_pinned_count}) catch "Delete pinned entries too? [y/N] ";
            screen.writeStyled(text, .{ .bold = true, .fg = .{ .ansi = 1 } });
        },
        .detail => unreachable,
    }
}

fn friendlyError(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidName => "invalid name: use lowercase letters, digits, and internal hyphens",
        error.InvalidTag => "invalid tag",
        error.NameTaken => "that name is already used by another entry",
        error.NoSuchInteraction => "entry disappeared; press r to refresh",
        error.AnnotationBusy => "journal metadata is busy",
        error.AnnotationConstraint => "journal metadata violates its schema",
        error.AnnotationDatabaseFailure => "cannot update journal metadata",
        else => @errorName(err),
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
    try std.testing.expectEqual(@as(usize, 3), model.cursor);
    try std.testing.expectEqual(@as(usize, 2), model.scroll);
    model.size.rows = 5;
    model.scrollToCursor();
    try std.testing.expectEqual(@as(usize, 1), model.scroll);
    model.moveCursor(-20);
    try std.testing.expectEqual(@as(usize, 0), model.cursor);
    try std.testing.expectEqual(@as(usize, 0), model.scroll);
    model.moveCursor(20);
    try std.testing.expectEqual(@as(usize, 3), model.cursor);
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
        .detail_line_count = 20,
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
    try std.testing.expectEqual(@as(usize, 1), model.detail_cursor);
    try std.testing.expect(model.detail_follow_selection);

    model.detail_follow_selection = false;
    try std.testing.expectEqual(Effect.none, detailKey(&model, .{ .character = 'j' }));
    try std.testing.expectEqual(@as(usize, 2), model.detail_cursor);
    try std.testing.expect(model.detail_follow_selection);

    _ = detailKey(&model, .shift_down);
    try std.testing.expectEqual(@as(usize, 3), model.detail_cursor);
    try std.testing.expectEqual(@as(usize, 2), model.detailSelectedCount());
    try std.testing.expect(model.detail_selected.isSet(2));
    try std.testing.expect(model.detail_selected.isSet(3));
    try std.testing.expectEqual(Effect.none, detailKey(&model, .escape));
    try std.testing.expectEqual(@as(usize, 0), model.detailSelectedCount());
    try std.testing.expectEqual(Effect.choose_detail, detailKey(&model, .enter));
    try std.testing.expectEqual(Effect.close_detail, detailKey(&model, .escape));
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

    model.detail_cursor = 2;
    model.detailScrollToCursor();
    try std.testing.expectEqual(@as(usize, 0), model.detail_scroll);
    model.detail_cursor = 4;
    model.detailScrollToCursor();
    try std.testing.expectEqual(@as(usize, 1), model.detail_scroll);
    model.detail_cursor = 6;
    model.detailScrollToCursor();
    try std.testing.expectEqual(@as(usize, 3), model.detail_scroll);
    model.detail_cursor = 0;
    model.detailScrollToCursor();
    try std.testing.expectEqual(@as(usize, 0), model.detail_scroll);
}
