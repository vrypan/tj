//! Loading and ownership of the entry-detail document shown by the TUI.

const std = @import("std");
const Io = std.Io;

const annotations = @import("../journal/annotations.zig");
const plain = @import("../presentation/plain.zig");
const report = @import("../presentation/report.zig");
const store = @import("../journal/store.zig");

const output_limit = 2 * 1024 * 1024;

pub const Item = struct {
    section_start: usize,
    section_end: usize,
    payload_start: usize,
    payload_end: usize,
};

pub const Detail = struct {
    number: u32,
    document: []u8,
    items: []Item,

    pub fn deinit(self: *Detail, gpa: std.mem.Allocator) void {
        gpa.free(self.document);
        gpa.free(self.items);
        self.* = undefined;
    }

    pub fn itemValue(self: *const Detail, item: Item) []const u8 {
        return self.document[item.payload_start..item.payload_end];
    }
};

pub fn load(
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
    var special_items: std.ArrayList(Item) = .empty;
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

    try document.appendSlice(gpa, "\n\n");
    const output_separator_start = document.items.len;
    // The renderer expands this logical marker to a terminal-width separator.
    // Keeping a short document value means detail selection remains stable
    // across terminal resizes.
    try document.appendSlice(gpa, "=== out ===");
    try special_items.append(gpa, .{
        .section_start = output_separator_start,
        .section_end = document.items.len,
        .payload_start = document.items.len,
        .payload_end = document.items.len,
    });
    try document.append(gpa, '\n');
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
        try document.print(gpa, "\n[preview limited to {d} recorded bytes; use tj cat @{d}]", .{ output_limit, number });
    }

    var items: std.ArrayList(Item) = .empty;
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
            const text = document.items[line_start..line_end];
            const label_len = if (line_start < output_separator_start) fieldLabelLength(text) else null;
            try items.append(gpa, .{
                .section_start = line_start,
                .section_end = line_end,
                .payload_start = line_start + (label_len orelse 0),
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

/// Field labels are structural: they explain a value but are not included when
/// a user selects a detail row for insertion into the shell.
fn fieldLabelLength(line: []const u8) ?usize {
    const labels = [_][]const u8{
        "entry     ",
        "rc        ",
        "pinned    ",
        "name      ",
        "tags      ",
        "started   ",
        "ended     ",
        "duration  ",
        "out size  ",
        "resources ",
    };
    inline for (labels) |label| {
        if (std.mem.startsWith(u8, line, label)) return label.len;
    }
    return null;
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
    var remaining: usize = @intCast(@min(length, output_limit));
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
        .truncated = length > output_limit,
    };
}
