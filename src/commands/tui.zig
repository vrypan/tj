//! Full-screen, current-journal entry browser.
//!
//! Zooi owns terminal mechanics. TJ owns the model and every mutation, using
//! the same command-layer pin operations as `tj pin`.

const std = @import("std");
const Io = std.Io;
const posix = std.posix;
const c = std.c;
const zooi = @import("zooi");

const pins = @import("../journal/pins.zig");
const cmd_pin = @import("pin.zig");
const cmd_remove = @import("remove.zig");
const context = @import("context.zig");
const noout = @import("../protocol/noout.zig");
const store = @import("../journal/store.zig");
const sys = @import("../sys.zig");
const tui_detail = @import("../tui/detail.zig");
const tui_model = @import("../tui/model.zig");
const tui_page = @import("../tui/page.zig");
const tui_render = @import("../tui/render.zig");

const max_events_per_frame = 64;

const Effect = tui_model.Effect;
const Model = tui_model.Model;

var region_active: std.atomic.Value(bool) = .init(false);

pub fn run(gpa: std.mem.Allocator, io: Io, home: ?[]const u8) !void {
    return runWithFilter(gpa, io, home, null);
}

pub fn runFiltered(gpa: std.mem.Allocator, io: Io, home: ?[]const u8, numbers: []const u32) !void {
    return runWithFilter(gpa, io, home, numbers);
}

fn runWithFilter(gpa: std.mem.Allocator, io: Io, home: ?[]const u8, allowed_numbers: ?[]const u32) !void {
    const journal = try context.currentJournal();
    if (journal.len == 0) return error.NotInJournal;
    if (!sys.isTty(0)) return error.NoControllingTerminal;
    const terminal_output: sys.Fd = if (sys.isTty(1)) 1 else if (sys.isTty(2)) 2 else return error.NoControllingTerminal;

    var model: Model = .{};
    defer model.deinit(gpa);
    if (allowed_numbers) |numbers| model.allowed_numbers = try gpa.dupe(u32, numbers);
    try model.reload(gpa, io, home, journal);

    var page: tui_page.Page = .{};
    defer page.deinit(gpa);

    try sys.writeAll(terminal_output, noout.begin_marker);
    region_active.store(true, .release);
    defer {
        sys.writeAll(terminal_output, noout.end_marker) catch {};
        region_active.store(false, .release);
    }

    installSignalHandlers();

    var ui = try zooi.Ui.init(gpa, .{});
    var ui_active = true;
    defer if (ui_active) ui.deinit();
    model.size = ui.size();
    model.viewport.normalize(model.count, model.listRows());
    try ensurePage(gpa, io, home, journal, &model, &page);
    try tui_render.draw(journal, &model, &page, ui.screen());

    while (try ui.nextEvent()) |first| {
        var pending: ?zooi.Event = first;
        var handled: usize = 0;
        while (pending) |event| {
            const effect = tui_model.handleEvent(&model, event);
            executeEffect(gpa, io, home, journal, &model, effect) catch |err| {
                model.setStatus("{s}", .{friendlyError(err)});
            };
            if (effectMutatesPage(effect)) page.invalidate();
            handled += 1;
            if (model.quit or handled == max_events_per_frame) break;
            pending = try ui.pollEvent();
        }
        if (model.quit) break;
        try ensurePage(gpa, io, home, journal, &model, &page);
        try tui_render.draw(journal, &model, &page, ui.screen());
    }

    ui.deinit();
    ui_active = false;
    if (model.detail_chosen) {
        const detail = if (model.detail) |*value| value else return;
        const selected_count = model.detailSelectedCount();
        for (detail.items, 0..) |item, index| {
            if (selected_count == 0) {
                if (index != model.detail_viewport.cursor) continue;
            } else if (!model.detail_selected.isSet(index)) continue;
            const section = detail.document[item.section_start..item.section_end];
            if (std.mem.eql(u8, section, "=== out ===")) continue;
            try sys.writeAll(1, detail.itemValue(item));
        }
    }
    if (model.selection_exported) try writeSelectedNumbers(&model);
}

fn writeSelectedNumbers(model: *const Model) !void {
    var wrote = false;
    for (model.visibleNumbers(), 0..) |number, index| {
        if (!model.isSelected(index)) continue;
        if (wrote) try sys.writeAll(1, " ");
        var buffer: [24]u8 = undefined;
        try sys.writeAll(1, try std.fmt.bufPrint(&buffer, "{d}", .{number}));
        wrote = true;
    }
    if (wrote) try sys.writeAll(1, "\n");
}

fn ensurePage(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    journal: []const u8,
    model: *const Model,
    page: *tui_page.Page,
) !void {
    if (model.mode == .detail) return;
    const wanted = model.viewport.visibleRange(model.count, model.listRows());
    try page.ensure(gpa, io, home, journal, model.visibleNumbers(), wanted);
}

fn effectMutatesPage(effect: Effect) bool {
    return switch (effect) {
        .refresh, .toggle_pin, .begin_delete, .delete, .delete_unpinned => true,
        else => false,
    };
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
        .toggle_pin => {
            const numbers = try model.actionNumbers(gpa);
            defer gpa.free(numbers);
            var root = try store.openRoot(io, home);
            defer root.close(io);
            var all_pinned = true;
            for (numbers) |number| all_pinned = all_pinned and try pins.isPinned(io, root, journal, number);
            try cmd_pin.updatePinNumbers(gpa, io, home, numbers, !all_pinned);
            model.setStatus("{d} {s} {s}", .{
                numbers.len,
                if (numbers.len == 1) "entry" else "entries",
                if (all_pinned) "unpinned" else "pinned",
            });
        },
        .begin_delete => {
            const numbers = try model.actionNumbers(gpa);
            defer gpa.free(numbers);
            var root = try store.openRoot(io, home);
            defer root.close(io);
            var pinned: usize = 0;
            for (numbers) |number| pinned += @intFromBool(try pins.isPinned(io, root, journal, number));
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
        .export_selection => {
            model.selection_exported = true;
            model.quit = true;
        },
        .open_detail => {
            const number = model.currentNumber() orelse return;
            if (model.detail) |*detail| detail.deinit(gpa);
            model.detail = try tui_detail.load(gpa, io, home, journal, number);
            model.detail_selected.deinit(gpa);
            model.detail_selected = try std.DynamicBitSetUnmanaged.initEmpty(gpa, model.detail.?.items.len);
            model.detail_range_base.deinit(gpa);
            model.detail_range_base = try std.DynamicBitSetUnmanaged.initEmpty(gpa, model.detail.?.items.len);
            model.detail_viewport = .{};
            model.detail_range_anchor = null;
            model.mode = .detail;
        },
        .close_detail => {
            if (model.detail) |*detail| detail.deinit(gpa);
            model.detail = null;
            model.detail_selected.deinit(gpa);
            model.detail_selected = .{};
            model.detail_range_base.deinit(gpa);
            model.detail_range_base = .{};
            model.detail_viewport = .{};
            model.detail_range_anchor = null;
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
    const old_cursor = model.viewport.cursor;
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

fn friendlyError(err: anyerror) []const u8 {
    return switch (err) {
        error.NoSuchInteraction => "entry disappeared; press r to refresh",
        else => @errorName(err),
    };
}
