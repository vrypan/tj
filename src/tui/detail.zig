//! Loading and ownership of the entry-detail document shown by the TUI.

const std = @import("std");
const Io = std.Io;

const pins = @import("../journal/pins.zig");
const plain = @import("../presentation/plain.zig");
const report = @import("../presentation/report.zig");
const store = @import("../journal/store.zig");

const output_limit = 2 * 1024 * 1024;

pub const Item = struct {
    section_start: usize,
    section_end: usize,
    payload_start: usize,
    payload_end: usize,
    export_start: usize = 0,
    export_end: usize = 0,
};

pub const Detail = struct {
    number: u32,
    document: []u8,
    exports: []u8,
    items: []Item,

    pub fn deinit(self: *Detail, gpa: std.mem.Allocator) void {
        gpa.free(self.document);
        gpa.free(self.exports);
        gpa.free(self.items);
        self.* = undefined;
    }

    pub fn itemValue(self: *const Detail, item: Item) []const u8 {
        return self.exports[item.export_start..item.export_end];
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

    const pinned = try pins.isPinned(io, root, journal, number);

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
    defer output.deinit(gpa);

    const command = try report.sanitizeDisplayText(gpa, info.command);
    defer gpa.free(command);
    const cwd_value = if (cwd) |value|
        try report.sanitizeDisplayText(gpa, value)
    else
        try gpa.dupe(u8, "");
    defer gpa.free(cwd_value);

    var document: std.ArrayList(u8) = .empty;
    errdefer document.deinit(gpa);
    var exports: std.ArrayList(u8) = .empty;
    errdefer exports.deinit(gpa);
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
    const cwd_export = try appendExport(gpa, &exports, if (cwd) |value| value else "");
    try special_items.append(gpa, .{
        .section_start = item_start,
        .section_end = document.items.len,
        .payload_start = cwd_payload_start,
        .payload_end = cwd_payload_start + cwd_value.len,
        .export_start = cwd_export.start,
        .export_end = cwd_export.end,
    });
    try document.append(gpa, '\n');

    item_start = document.items.len;
    try document.appendSlice(gpa, "cmd       ");
    const command_payload_start = document.items.len;
    if (command.len == 0) try document.appendSlice(gpa, "(empty)") else try document.appendSlice(gpa, command);
    const command_export = try appendExport(gpa, &exports, info.command);
    try special_items.append(gpa, .{
        .section_start = item_start,
        .section_end = document.items.len,
        .payload_start = command_payload_start,
        .payload_end = command_payload_start + command.len,
        .export_start = command_export.start,
        .export_end = command_export.end,
    });
    try document.append(gpa, '\n');

    if (info.exit_code) |code| {
        try document.print(gpa, "rc        {d}\n", .{code});
    } else {
        try document.appendSlice(gpa, "rc        unfinished\n");
    }
    try document.append(gpa, '\n');

    try document.print(gpa, "pinned    {s}\n", .{if (pinned) "yes" else "no"});
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
        .export_start = exports.items.len,
        .export_end = exports.items.len,
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
            .export_start = exports.items.len,
            .export_end = exports.items.len,
        });
    } else {
        var line_start: usize = 0;
        var output_line_index: usize = 0;
        while (line_start < output.text.len) {
            const relative_end = std.mem.indexOfScalar(u8, output.text[line_start..], '\n');
            const line_end = if (relative_end) |offset| line_start + offset else output.text.len;
            const source = output.raw_lines[output_line_index];
            item_start = document.items.len;
            try document.appendSlice(gpa, output.text[line_start..line_end]);
            const payload_end = document.items.len;
            if (line_end == line_start) try document.appendSlice(gpa, " ");
            const raw_export = try appendExport(gpa, &exports, output.raw[source.start..source.end]);
            try special_items.append(gpa, .{
                .section_start = item_start,
                .section_end = document.items.len,
                .payload_start = item_start,
                .payload_end = payload_end,
                .export_start = raw_export.start,
                .export_end = raw_export.end,
            });
            output_line_index += 1;
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
            const export_range = try appendExport(gpa, &exports, text[(label_len orelse 0)..]);
            try items.append(gpa, .{
                .section_start = line_start,
                .section_end = line_end,
                .payload_start = line_start + (label_len orelse 0),
                .payload_end = line_end,
                .export_start = export_range.start,
                .export_end = export_range.end,
            });
        }
        if (relative_end == null) break;
        line_start = line_end + 1;
        if (line_start == document.items.len) break;
    }
    const owned_document = try document.toOwnedSlice(gpa);
    errdefer gpa.free(owned_document);
    const owned_exports = try exports.toOwnedSlice(gpa);
    errdefer gpa.free(owned_exports);
    const owned_items = try items.toOwnedSlice(gpa);
    return .{
        .number = number,
        .document = owned_document,
        .exports = owned_exports,
        .items = owned_items,
    };
}

const ExportRange = struct { start: usize, end: usize };

fn appendExport(gpa: std.mem.Allocator, exports: *std.ArrayList(u8), value: []const u8) !ExportRange {
    const start = exports.items.len;
    try exports.appendSlice(gpa, value);
    return .{ .start = start, .end = exports.items.len };
}

/// Field labels are structural: they explain a value but are not included when
/// a user selects a detail row for insertion into the shell.
fn fieldLabelLength(line: []const u8) ?usize {
    const labels = [_][]const u8{
        "entry     ",
        "rc        ",
        "pinned    ",
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
    raw: []u8,
    raw_lines: []ExportRange,
    present: bool,
    truncated: bool,

    fn deinit(self: PlainOutput, gpa: std.mem.Allocator) void {
        gpa.free(self.text);
        gpa.free(self.raw);
        gpa.free(self.raw_lines);
    }
};

const OutputMapper = struct {
    gpa: std.mem.Allocator,
    text: std.ArrayList(u8) = .empty,
    raw_lines: std.ArrayList(ExportRange) = .empty,
    raw_start: usize = 0,
    raw_end: usize = 0,

    fn deinit(self: *OutputMapper) void {
        self.text.deinit(self.gpa);
        self.raw_lines.deinit(self.gpa);
    }

    pub fn writeAll(self: *OutputMapper, bytes: []const u8) !void {
        try self.text.appendSlice(self.gpa, bytes);
        if (std.mem.eql(u8, bytes, "\n")) {
            try self.raw_lines.append(self.gpa, .{ .start = self.raw_start, .end = self.raw_end });
            self.raw_start = self.raw_end;
        }
    }

    fn finishLine(self: *OutputMapper) !void {
        if (self.text.items.len == 0 or self.text.items[self.text.items.len - 1] == '\n') return;
        try self.raw_lines.append(self.gpa, .{ .start = self.raw_start, .end = self.raw_end });
    }
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
        error.FileNotFound => {
            const text = try gpa.dupe(u8, "");
            errdefer gpa.free(text);
            const raw = try gpa.dupe(u8, "");
            errdefer gpa.free(raw);
            return .{
                .text = text,
                .raw = raw,
                .raw_lines = try gpa.alloc(ExportRange, 0),
                .present = false,
                .truncated = false,
            };
        },
        else => return err,
    };
    defer file.close(io);
    const length = try file.length(io);

    var raw: std.ArrayList(u8) = .empty;
    errdefer raw.deinit(gpa);
    var mapper: OutputMapper = .{ .gpa = gpa };
    errdefer mapper.deinit();
    var renderer = plain.Renderer.init(gpa);
    defer renderer.deinit();
    var reader_buf: [64 * 1024]u8 = undefined;
    var bytes: [64 * 1024]u8 = undefined;
    var reader = file.readerStreaming(io, &reader_buf);
    var remaining: usize = @intCast(@min(length, output_limit));
    while (remaining != 0) {
        const count = try reader.interface.readSliceShort(bytes[0..@min(bytes.len, remaining)]);
        if (count == 0) break;
        for (bytes[0..count]) |byte| {
            try raw.append(gpa, byte);
            mapper.raw_end = raw.items.len;
            try renderer.feed(&.{byte}, &mapper);
        }
        remaining -= count;
    }
    try renderer.finish(&mapper);
    try mapper.finishLine();
    const text = try mapper.text.toOwnedSlice(gpa);
    errdefer gpa.free(text);
    const raw_lines = try mapper.raw_lines.toOwnedSlice(gpa);
    errdefer gpa.free(raw_lines);
    return .{
        .text = text,
        .raw = try raw.toOwnedSlice(gpa),
        .raw_lines = raw_lines,
        .present = true,
        .truncated = length > output_limit,
    };
}

test "detail exports original command cwd and output bytes" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buf);
    const home = root_buf[0..root_len];

    var journal = try store.Store.createJournal(gpa, io, home);
    defer journal.close();
    journal.begin("echo first\necho second", null, "/tmp/two  spaces");
    journal.append("  indented\t\x1b[31mred\x1b[0m\n\x1b]0;hidden\nstill hidden\x07last line");
    journal.finish(0);

    var detail = try load(gpa, io, home, journal.journalId(), 1);
    defer detail.deinit(gpa);
    var command_found = false;
    var cwd_found = false;
    var first_output_found = false;
    var last_output_found = false;
    for (detail.items) |item| {
        const shown = detail.document[item.section_start..item.section_end];
        const value = detail.itemValue(item);
        if (std.mem.startsWith(u8, shown, "cmd       ")) {
            try std.testing.expectEqualStrings("echo first\necho second", value);
            command_found = true;
        } else if (std.mem.startsWith(u8, shown, "cwd       ")) {
            try std.testing.expectEqualStrings("/tmp/two  spaces", value);
            cwd_found = true;
        } else if (std.mem.indexOf(u8, shown, "indented") != null) {
            try std.testing.expectEqualStrings("  indented\t\x1b[31mred\x1b[0m\n", value);
            first_output_found = true;
        } else if (std.mem.indexOf(u8, shown, "last line") != null) {
            try std.testing.expectEqualStrings("\x1b]0;hidden\nstill hidden\x07last line", value);
            last_output_found = true;
        }
    }
    try std.testing.expect(command_found and cwd_found and first_output_found and last_output_found);
}
