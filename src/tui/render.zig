//! Pure TUI rendering from already-loaded model and page state.

const std = @import("std");
const zooi = @import("zooi");

const presentation = @import("../presentation/entry.zig");
const report = @import("../presentation/report.zig");
const detail_layout = @import("detail_layout.zig");
const page_module = @import("page.zig");

const header_style: zooi.Style = .{ .bold = true };
const cursor_style: zooi.Style = .{ .reverse = true };
const selected_style: zooi.Style = .{ .fg = .{ .ansi = 6 } };
const focused_selected_style: zooi.Style = .{ .reverse = true, .fg = .{ .ansi = 6 } };
const number_style: zooi.Style = .{ .fg = .{ .ansi = 3 } };
const metadata_style: zooi.Style = .{ .fg = .{ .ansi = 2 } };
const failure_style: zooi.Style = .{ .fg = .{ .ansi = 1 } };
const footer_style: zooi.Style = .{ .dim = true };

pub fn draw(journal: []const u8, model: anytype, page: *const page_module.Page, screen: *zooi.Screen) !void {
    screen.begin();
    if (model.size.rows < 4 or model.size.cols < 24) {
        screen.move(0, 0);
        screen.write("terminal too small");
        return screen.present();
    }

    if (model.mode == .detail) {
        try drawDetail(model, screen);
        return;
    }

    drawHeader(journal, model, screen);
    const number_width = if (model.count == 0)
        1
    else
        report.decimalWidth(model.numbers[model.count - 1]);

    for (page.rows) |*row| {
        if (row.index < page.range.start or row.index >= page.range.end) continue;
        const content_row = row.index - page.range.start;
        if (content_row >= model.listRows()) continue;
        const screen_row = content_row + 2;
        const focused = row.index == model.viewport.cursor;
        const picked = model.isSelected(row.index);
        const base_style: zooi.Style = if (focused and picked)
            focused_selected_style
        else if (focused)
            cursor_style
        else if (picked)
            selected_style
        else
            .{};

        screen.move(@intCast(screen_row), 0);
        if (focused) screen.fillToEndOfLine(base_style);
        screen.move(@intCast(screen_row), 0);

        const row_view = presentation.EntryPresentation.init(
            journal,
            row.info.number,
            false,
            row.pinned,
            row.info.exit_code,
        );
        const flags = row_view.flags();
        screen.writeStyled(flags[0..1], base_style);
        screen.writeStyled(flags[1..2], if (focused) base_style else if (row_view.failed()) failure_style else base_style);
        screen.writeStyled(" ", base_style);

        var number_buf: [24]u8 = undefined;
        const number_text = try std.fmt.bufPrint(&number_buf, "{d}", .{row.info.number});
        var padding: [24]u8 = @splat(' ');
        screen.writeStyled(padding[0 .. number_width - number_text.len], base_style);
        screen.writeStyled(number_text, if (focused or picked) base_style else number_style);
        screen.writeStyled(" ", base_style);

        var size_buf: [24]u8 = undefined;
        const size_text = report.formatEntrySize(row.info, &size_buf);
        screen.writeStyled(size_text, if (focused) base_style else metadata_style);
        screen.writeStyled(" ", base_style);
        screen.writeStyled(row.command, base_style);

        var metadata_parts = row_view.metadata();
        while (metadata_parts.next()) |part| {
            screen.writeStyled(" ", base_style);
            const role_style = if (focused) base_style else failure_style;
            switch (part) {
                .failure => |code| {
                    var rc_buf: [8]u8 = undefined;
                    const rc = try std.fmt.bufPrint(&rc_buf, "!{d}", .{code});
                    screen.writeStyled(rc, role_style);
                },
            }
        }
    }

    drawFooter(model, screen);
    try screen.present();
}

fn drawDetail(model: anytype, screen: *zooi.Screen) !void {
    const detail = if (model.detail) |*value| value else return error.NoSuchInteraction;
    const rows = model.listRows();

    var header_buf: [96]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "entry @{d}  details ", .{detail.number}) catch "entry details ";
    screen.move(0, 0);
    screen.writeStyled(header, header_style);
    screen.fillToEndOfLine(header_style);

    var visible = model.detail_viewport.visibleItems(detail.layout.index(), rows);
    while (visible.next()) |visible_item| {
        const item_index = visible_item.item;
        const item = detail.items[item_index];
        const output_separator = item.kind == .separator;
        const focused = item_index == model.detail_viewport.cursor;
        const selected = model.detail_selected.isSet(item_index);
        const style: zooi.Style = if (focused and selected)
            focused_selected_style
        else if (focused)
            cursor_style
        else if (selected)
            selected_style
        else if (output_separator)
            .{ .bold = true, .fg = .{ .ansi = 3 } }
        else
            .{};
        const structural_style: zooi.Style = if (focused or selected) style else .{ .fg = .{ .ansi = 3 } };
        const fragments = detail.layout.itemFragments(item_index);
        for (0..visible_item.row_count) |fragment_offset| {
            const row = visible_item.screen_row + fragment_offset + 2;
            const fragment = fragments[visible_item.first_row + fragment_offset];
            screen.move(@intCast(row), 0);
            if (focused) screen.fillToEndOfLine(style);
            screen.move(@intCast(row), 0);
            if (output_separator) {
                drawOutputSeparator(screen, model.size.cols, style);
                continue;
            }
            for (0..fragment.indent) |_| screen.writeStyled(" ", structural_style);
            if (fragment.show_prefix) {
                screen.writeStyled(detail.document[item.section_start..item.payload_start], structural_style);
            }
            if (fragment.replacement) {
                const replacement_style = if (fragment.start >= item.payload_start and fragment.start < item.payload_end)
                    style
                else
                    structural_style;
                screen.writeStyled("?", replacement_style);
            } else {
                writeDetailRange(screen, detail.document, item, fragment.start, fragment.end, style, structural_style);
            }
        }
    }

    screen.move(model.size.rows - 1, 0);
    if (model.detailSelectedCount() == 0) {
        screen.writeStyled("↑↓/jk move  shift+nav range  space toggle  ⏎ print  esc/q back", footer_style);
    } else {
        var footer_buf: [128]u8 = undefined;
        const footer = std.fmt.bufPrint(&footer_buf, "{d} selected  shift+nav range  space toggle  ⏎ print  esc clear", .{model.detailSelectedCount()}) catch "selected  ⏎ print  esc clear";
        screen.writeStyled(footer, footer_style);
    }
    try screen.present();
}

fn drawOutputSeparator(screen: *zooi.Screen, columns: usize, style: zooi.Style) void {
    const label = " out ";
    const padding = if (columns > label.len) columns - label.len else 0;
    const left = padding / 2;
    const right = padding - left;
    for (0..left) |_| screen.writeStyled("=", style);
    screen.writeStyled(label, style);
    for (0..right) |_| screen.writeStyled("=", style);
}

fn writeDetailRange(screen: *zooi.Screen, document: []const u8, item: anytype, start: usize, end: usize, value_style: zooi.Style, structural_style: zooi.Style) void {
    const before_end = @min(end, item.payload_start);
    if (start < before_end) screen.writeStyled(document[start..before_end], structural_style);

    const value_start = @max(start, item.payload_start);
    const value_end = @min(end, item.payload_end);
    if (value_start < value_end) screen.writeStyled(document[value_start..value_end], value_style);

    const after_start = @max(start, item.payload_end);
    if (after_start < end) screen.writeStyled(document[after_start..end], structural_style);
}

fn drawHeader(journal: []const u8, model: anytype, screen: *zooi.Screen) void {
    var buffer: [160]u8 = undefined;
    const noun = if (model.allowed_numbers != null) "matches" else "entries";
    const text = if (model.selectedCount() == 0)
        std.fmt.bufPrint(&buffer, "tj  {s}  {d} {s} ", .{ journal, model.count, noun }) catch "tj "
    else
        std.fmt.bufPrint(&buffer, "tj  {s}  {d} {s}  {d} selected ", .{ journal, model.count, noun, model.selectedCount() }) catch "tj ";
    screen.move(0, 0);
    screen.writeStyled(text, header_style);
    screen.fillToEndOfLine(header_style);
}

fn drawFooter(model: anytype, screen: *zooi.Screen) void {
    const row: u16 = model.size.rows - 1;
    screen.move(row, 0);
    switch (model.mode) {
        .normal => {
            if (model.status_len != 0) {
                screen.writeStyled(model.status(), .{ .fg = .{ .ansi = 3 } });
            } else {
                screen.writeStyled("space toggle  shift+nav range  esc clear  ⏎ details  e export  p pin  d delete  q quit", footer_style);
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

const TestMode = enum { normal, delete_confirm, detail };
const TestDetailItem = struct {
    section_start: usize,
    section_end: usize,
    payload_start: usize,
    payload_end: usize,
    kind: detail_layout.ItemKind = .field,
};
const TestDetail = struct {
    number: u32,
    document: []const u8,
    items: []const TestDetailItem,
    layout: detail_layout.Layout,
};

const TestModel = struct {
    numbers: []const u32,
    count: usize,
    allowed_numbers: ?[]const u32 = null,
    viewport: zooi.Viewport = .{},
    size: zooi.Size,
    mode: TestMode = .normal,
    selected: std.DynamicBitSetUnmanaged = .{},
    status_buf: []const u8 = "",
    status_len: usize = 0,
    input: []const u8 = "",
    delete_pinned_count: usize = 0,
    detail: ?TestDetail = null,
    detail_viewport: zooi.VariableViewport = .{},
    detail_selected: std.DynamicBitSetUnmanaged = .{},

    pub fn listRows(self: *const TestModel) usize {
        return if (self.size.rows < 4) 0 else self.size.rows - 3;
    }

    pub fn isSelected(self: *const TestModel, index: usize) bool {
        return index < self.selected.capacity() and self.selected.isSet(index);
    }

    pub fn selectedCount(self: *const TestModel) usize {
        return self.selected.count();
    }

    pub fn status(self: *const TestModel) []const u8 {
        return self.status_buf[0..self.status_len];
    }

    pub fn detailSelectedCount(self: *const TestModel) usize {
        return self.detail_selected.count();
    }
};

fn testScreen(rows: u16, cols: u16) !struct { zooi.Screen, std.posix.fd_t } {
    const fd = try std.posix.openatZ(
        std.posix.AT.FDCWD,
        "/dev/null",
        .{ .ACCMODE = .WRONLY },
        0,
    );
    return .{ zooi.Screen.init(std.testing.allocator, fd, .{ .rows = rows, .cols = cols }), fd };
}

test "entry render leaves a blank row after the bold header" {
    const gpa = std.testing.allocator;
    var selected = try std.DynamicBitSetUnmanaged.initEmpty(gpa, 2);
    defer selected.deinit(gpa);
    var model: TestModel = .{
        .numbers = &.{ 7, 12 },
        .count = 2,
        .size = .{ .rows = 5, .cols = 40 },
        .selected = selected,
    };
    var rows = [_]page_module.Row{
        .{
            .index = 0,
            .info = .{ .number = 7, .exit_code = 0, .command = "echo ok", .out_bytes = 12, .out_present = true },
            .command = @constCast("echo ok"),
            .pinned = false,
        },
        .{
            .index = 1,
            .info = .{ .number = 12, .exit_code = 2, .command = "make", .out_bytes = 800, .out_present = true },
            .command = @constCast("make"),
            .pinned = false,
        },
    };
    const page: page_module.Page = .{ .range = .{ .start = 0, .end = 2 }, .rows = &rows, .valid = true };

    var screen_and_fd = try testScreen(5, 40);
    defer (std.Io.File{ .handle = screen_and_fd[1], .flags = .{ .nonblocking = false } }).close(std.testing.io);
    defer screen_and_fd[0].deinit();
    try draw("work", &model, &page, &screen_and_fd[0]);

    try std.testing.expectEqual(zooi.Size{ .rows = 5, .cols = 40 }, zooi.testing.presentedSize(&screen_and_fd[0]).?);
    try std.testing.expect(zooi.testing.inspectCell(&screen_and_fd[0], 0, 0).?.style.bold);
    try std.testing.expect(!zooi.testing.inspectCell(&screen_and_fd[0], 0, 39).?.style.reverse);
    try std.testing.expectEqualStrings("", zooi.testing.inspectCell(&screen_and_fd[0], 1, 0).?.text);
    try std.testing.expect(zooi.testing.inspectCell(&screen_and_fd[0], 2, 39).?.style.reverse);
    try std.testing.expectEqual(@as(?u8, 1), zooi.testing.inspectCell(&screen_and_fd[0], 3, 1).?.style.fg.?.ansi);
}

test "entry render includes the last row at minimum terminal height" {
    const gpa = std.testing.allocator;
    var selected = try std.DynamicBitSetUnmanaged.initEmpty(gpa, 1);
    defer selected.deinit(gpa);
    var model: TestModel = .{
        .numbers = &.{42},
        .count = 1,
        .size = .{ .rows = 4, .cols = 32 },
        .selected = selected,
    };
    var rows = [_]page_module.Row{.{
        .index = 0,
        .info = .{ .number = 42, .exit_code = 0, .command = "visible", .out_bytes = 0, .out_present = true },
        .command = @constCast("visible"),
        .pinned = false,
    }};
    const page: page_module.Page = .{ .range = .{ .start = 0, .end = 1 }, .rows = &rows, .valid = true };

    var screen_and_fd = try testScreen(4, 32);
    defer (std.Io.File{ .handle = screen_and_fd[1], .flags = .{ .nonblocking = false } }).close(std.testing.io);
    defer screen_and_fd[0].deinit();
    try draw("work", &model, &page, &screen_and_fd[0]);

    try std.testing.expectEqualStrings("4", zooi.testing.inspectCell(&screen_and_fd[0], 2, 3).?.text);
    try std.testing.expect(zooi.testing.inspectCell(&screen_and_fd[0], 2, 31).?.style.reverse);
}

test "detail render leaves a blank row after the bold header" {
    const gpa = std.testing.allocator;
    var selected = try std.DynamicBitSetUnmanaged.initEmpty(gpa, 2);
    defer selected.deinit(gpa);
    var detail_selected = try std.DynamicBitSetUnmanaged.initEmpty(gpa, 2);
    defer detail_selected.deinit(gpa);
    var items = [_]TestDetailItem{
        .{ .section_start = 0, .section_end = 3, .payload_start = 0, .payload_end = 3 },
        .{ .section_start = 4, .section_end = 15, .payload_start = 15, .payload_end = 15, .kind = .separator },
    };
    var layout: detail_layout.Layout = .{};
    defer layout.deinit(gpa);
    try layout.reflow(gpa, "cmd\n=== out ===", &items, 32);
    var model: TestModel = .{
        .numbers = &.{1},
        .count = 1,
        .size = .{ .rows = 5, .cols = 32 },
        .mode = .detail,
        .selected = selected,
        .detail = .{ .number = 1, .document = "cmd\n=== out ===", .items = &items, .layout = layout },
        .detail_viewport = .{ .cursor = 1 },
        .detail_selected = detail_selected,
    };
    const page: page_module.Page = .{};

    var screen_and_fd = try testScreen(5, 32);
    defer (std.Io.File{ .handle = screen_and_fd[1], .flags = .{ .nonblocking = false } }).close(std.testing.io);
    defer screen_and_fd[0].deinit();
    try draw("work", &model, &page, &screen_and_fd[0]);

    try std.testing.expect(zooi.testing.inspectCell(&screen_and_fd[0], 0, 0).?.style.bold);
    try std.testing.expect(!zooi.testing.inspectCell(&screen_and_fd[0], 0, 31).?.style.reverse);
    try std.testing.expectEqualStrings("", zooi.testing.inspectCell(&screen_and_fd[0], 1, 0).?.text);
    try std.testing.expect(zooi.testing.inspectCell(&screen_and_fd[0], 3, 31).?.style.reverse);
    try std.testing.expectEqualStrings("=", zooi.testing.inspectCell(&screen_and_fd[0], 3, 0).?.text);
    try std.testing.expectEqualStrings("o", zooi.testing.inspectCell(&screen_and_fd[0], 3, 14).?.text);
}

test "detail render draws every wrapped fragment of one logical item" {
    const gpa = std.testing.allocator;
    var selected = try std.DynamicBitSetUnmanaged.initEmpty(gpa, 1);
    defer selected.deinit(gpa);
    var detail_selected = try std.DynamicBitSetUnmanaged.initEmpty(gpa, 1);
    defer detail_selected.deinit(gpa);
    const document = "cmd       alpha beta gamma delta epsilon";
    var items = [_]TestDetailItem{.{
        .section_start = 0,
        .section_end = document.len,
        .payload_start = 10,
        .payload_end = document.len,
    }};
    var layout: detail_layout.Layout = .{};
    defer layout.deinit(gpa);
    try layout.reflow(gpa, document, &items, 24);
    try std.testing.expect(layout.heights.items[0] > 1);
    var model: TestModel = .{
        .numbers = &.{1},
        .count = 1,
        .size = .{ .rows = 7, .cols = 24 },
        .mode = .detail,
        .selected = selected,
        .detail = .{ .number = 1, .document = document, .items = &items, .layout = layout },
        .detail_selected = detail_selected,
    };
    const page: page_module.Page = .{};

    var screen_and_fd = try testScreen(7, 24);
    defer (std.Io.File{ .handle = screen_and_fd[1], .flags = .{ .nonblocking = false } }).close(std.testing.io);
    defer screen_and_fd[0].deinit();
    try draw("work", &model, &page, &screen_and_fd[0]);

    const second_fragment = layout.itemFragments(0)[1];
    try std.testing.expectEqualStrings("c", zooi.testing.inspectCell(&screen_and_fd[0], 2, 0).?.text);
    try std.testing.expectEqualStrings("a", zooi.testing.inspectCell(&screen_and_fd[0], 2, 10).?.text);
    try std.testing.expectEqualStrings(document[second_fragment.start..][0..1], zooi.testing.inspectCell(&screen_and_fd[0], 3, 10).?.text);
    try std.testing.expect(zooi.testing.inspectCell(&screen_and_fd[0], 2, 23).?.style.reverse);
    try std.testing.expect(zooi.testing.inspectCell(&screen_and_fd[0], 3, 23).?.style.reverse);
}
