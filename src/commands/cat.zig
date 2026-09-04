//! `tj cat` - printing what a reference or a path names.

const std = @import("std");
const Io = std.Io;
const zecli = @import("zecli");

const store = @import("../journal/store.zig");
const sys = @import("../sys.zig");
const reference = @import("../journal/reference.zig");
const plain = @import("../presentation/plain.zig");
const context = @import("context.zig");

pub const read_chunk_size = 64 * 1024;

pub const CatRequest = struct {
    as_written: bool,
    window: Window,
    refs: []const []const u8,
};

pub fn catRequest(parsed: *const zecli.Parsed, stdout_is_tty: bool) CatRequest {
    var request: CatRequest = .{
        .as_written = stdout_is_tty,
        .window = .all,
        .refs = parsed.positionals.items,
    };
    for (parsed.flags.items) |flag| {
        if (std.mem.eql(u8, flag.name, "raw")) {
            request.as_written = true;
        } else if (std.mem.eql(u8, flag.name, "plain")) {
            request.as_written = false;
        } else if (std.mem.eql(u8, flag.name, "head")) {
            request.window = .{ .head = std.fmt.parseInt(usize, flag.value.?, 10) catch unreachable };
        } else if (std.mem.eql(u8, flag.name, "tail")) {
            request.window = .{ .tail = std.fmt.parseInt(usize, flag.value.?, 10) catch unreachable };
        }
    }
    return request;
}

/// `tj cat @42` - print what an interaction recorded, without needing the
/// shell integration to expand anything. Useful from bash, from a script, or
/// from a shell that is not running under tj at all.
pub fn catResource(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    parsed: *const zecli.Parsed,
    out: *Io.Writer,
) !void {
    // Terminals can render escape sequences, pipes cannot. Follow the usual
    // convention and let either flag settle it explicitly.
    const request = catRequest(parsed, sys.isTty(io, 1));

    // `tj cat ./notes.txt` is a plain file read that happens to share a
    // command with references. Opening the journal root up front made it fail
    // with "no journal yet" on a machine that has never recorded one, so the
    // root is opened only once an argument actually needs it.
    var root: LazyRoot = .{ .io = io, .home = home };
    defer root.close();

    for (request.refs) |text| {
        const maybe_range = context.parseInteractionRange(text) catch |err| switch (err) {
            // Cat ranges are deliberately current-journal-only, but this is a
            // syntax limitation rather than an attempted cross-journal write.
            error.CrossJournalMutation => return error.InvalidRange,
            else => |other| return other,
        };
        if (maybe_range) |range| {
            try catRange(gpa, io, try root.get(), request, range, out);
        } else {
            try catOne(gpa, io, &root, request, text, out);
        }
    }
}

/// Opens the journal root on first use. A reference or a range needs it; a
/// filesystem path does not, and must not fail because no journal exists yet.
pub const LazyRoot = struct {
    io: Io,
    home: ?[]const u8,
    dir: ?store.Dir = null,

    pub fn get(self: *LazyRoot) !store.Dir {
        if (self.dir) |dir| return dir;
        const dir = try store.openRoot(self.io, self.home);
        self.dir = dir;
        return dir;
    }

    pub fn close(self: *LazyRoot) void {
        if (self.dir) |dir| dir.close(self.io);
        self.dir = null;
    }
};

pub fn catRange(
    gpa: std.mem.Allocator,
    io: Io,
    root: store.Dir,
    request: CatRequest,
    range: context.InteractionRange,
    out: *Io.Writer,
) !void {
    const current = try context.currentJournal();
    const numbers = try store.listNumbers(gpa, io, root, current);
    defer gpa.free(numbers);
    if (!context.rangeSelectsAny(numbers, range)) return error.NoSuchInteraction;

    // Reading the `out` currently being produced would feed cat's own output
    // back into the same file. Refuse the whole range before emitting a byte.
    if (context.activeInteraction()) |active| {
        if (std.mem.eql(u8, active.journal, current) and range.contains(active.number)) {
            return error.CurrentInteraction;
        }
    }

    var opened: LazyRoot = .{ .io = io, .home = null, .dir = root };
    for (numbers) |number| {
        if (!range.contains(number)) continue;
        var ref_buf: [16]u8 = undefined;
        const ref = try std.fmt.bufPrint(&ref_buf, "@{d}", .{number});
        try catOne(gpa, io, &opened, request, ref, out);
    }
}

pub fn catOne(
    gpa: std.mem.Allocator,
    io: Io,
    root: *LazyRoot,
    request: CatRequest,
    text: []const u8,
    out: *Io.Writer,
) !void {
    var file = try openTarget(gpa, io, root, text);
    defer file.close(io);

    // Rendering feeds the same window as raw bytes, so line counts always
    // describe what the caller sees rather than terminal control traffic.
    var sink = WindowSink.init(gpa, request.window, out);
    defer sink.deinit();
    if (request.as_written) {
        try copyFile(io, file, &sink);
    } else {
        try renderFile(gpa, io, file, &sink);
    }
    try sink.finish();

    // Silence about what was left out would let a reader - a person or an
    // agent - take a fragment for the whole thing. It goes to stderr so that
    // stdout stays exactly what was asked for.
    if (sink.shownLines() < sink.totalLines()) {
        context.note("tj: {s}: showing {d} of {d} lines\n", .{
            text,
            sink.shownLines(),
            sink.totalLines(),
        });
    }
}

pub fn copyFile(io: Io, file: Io.File, out: anytype) !void {
    var reader_buffer: [read_chunk_size]u8 = undefined;
    var bytes: [read_chunk_size]u8 = undefined;
    var reader = file.readerStreaming(io, &reader_buffer);
    while (true) {
        const n = try reader.interface.readSliceShort(&bytes);
        if (n == 0) break;
        try out.writeAll(bytes[0..n]);
    }
}

pub fn renderFile(gpa: std.mem.Allocator, io: Io, file: Io.File, out: anytype) !void {
    var renderer = plain.Renderer.init(gpa);
    defer renderer.deinit();
    var reader_buffer: [read_chunk_size]u8 = undefined;
    var bytes: [read_chunk_size]u8 = undefined;
    var reader = file.readerStreaming(io, &reader_buffer);
    while (true) {
        const n = try reader.interface.readSliceShort(&bytes);
        if (n == 0) break;
        try renderer.feed(bytes[0..n], out);
    }
    try renderer.finish(out);
}

/// How much of a resource to print.
pub const Window = union(enum) {
    all,
    head: usize,
    tail: usize,
};

test "cat request preserves option occurrence order" {
    const gpa = std.testing.allocator;
    var parsed = try context.parseTestCommand(.cat, &.{
        "--raw", "--plain", "--head", "10", "--tail=3", "--head=1", "recording",
    });
    defer parsed.deinit(gpa);
    const request = catRequest(&parsed, true);
    try std.testing.expect(!request.as_written);
    try std.testing.expectEqual(@as(usize, 1), request.window.head);
    try std.testing.expectEqualStrings("recording", request.refs[0]);

    try std.testing.expectError(error.ReportedCliError, context.parseTestCommand(.cat, &.{ "--head", "bad", "@1" }));
}

/// Applies a line window without retaining bytes that cannot be returned.
/// Tail storage is proportional to the requested final lines, not the file.
pub const WindowSink = struct {
    gpa: std.mem.Allocator,
    window: Window,
    out: *Io.Writer,
    tail: std.ArrayList(u8) = .empty,
    tail_lines: usize = 0,
    head_newlines: usize = 0,
    total_newlines: u64 = 0,
    total_any: bool = false,
    total_ends_newline: bool = false,

    pub fn init(gpa: std.mem.Allocator, window: Window, out: *Io.Writer) WindowSink {
        return .{ .gpa = gpa, .window = window, .out = out };
    }

    pub fn deinit(self: *WindowSink) void {
        self.tail.deinit(self.gpa);
    }

    pub fn writeAll(self: *WindowSink, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        self.total_any = true;
        self.total_ends_newline = bytes[bytes.len - 1] == '\n';
        self.total_newlines = std.math.add(
            u64,
            self.total_newlines,
            @as(u64, @intCast(std.mem.count(u8, bytes, "\n"))),
        ) catch return error.ResourceTooLarge;

        switch (self.window) {
            .all => try self.out.writeAll(bytes),
            .head => |n| try self.writeHead(n, bytes),
            .tail => |n| try self.writeTail(n, bytes),
        }
    }

    pub fn writeHead(self: *WindowSink, n: usize, bytes: []const u8) !void {
        if (n == 0 or self.head_newlines >= n) return;

        var end = bytes.len;
        var offset: usize = 0;
        while (std.mem.indexOfScalar(u8, bytes[offset..], '\n')) |relative| {
            const newline = offset + relative;
            self.head_newlines += 1;
            if (self.head_newlines == n) {
                end = newline + 1;
                break;
            }
            offset = newline + 1;
        }
        try self.out.writeAll(bytes[0..end]);
    }

    pub fn writeTail(self: *WindowSink, n: usize, bytes: []const u8) !void {
        if (n == 0) return;
        for (bytes) |byte| {
            if (self.tail.items.len == 0) {
                self.tail_lines = 1;
            } else if (self.tail.items[self.tail.items.len - 1] == '\n') {
                if (self.tail_lines == n) self.dropFirstTailLine();
                self.tail_lines += 1;
            }
            try self.tail.append(self.gpa, byte);
        }
    }

    pub fn dropFirstTailLine(self: *WindowSink) void {
        const cut = (std.mem.indexOfScalar(u8, self.tail.items, '\n') orelse unreachable) + 1;
        const remaining = self.tail.items.len - cut;
        std.mem.copyForwards(u8, self.tail.items[0..remaining], self.tail.items[cut..]);
        self.tail.items.len = remaining;
        self.tail_lines -= 1;
    }

    pub fn finish(self: *WindowSink) !void {
        if (self.window == .tail) try self.out.writeAll(self.tail.items);
    }

    pub fn totalLines(self: *const WindowSink) u64 {
        return self.total_newlines + @intFromBool(self.total_any and !self.total_ends_newline);
    }

    pub fn shownLines(self: *const WindowSink) u64 {
        return switch (self.window) {
            .all => self.totalLines(),
            .head => |n| @min(self.totalLines(), @as(u64, @intCast(n))),
            .tail => |n| @min(self.totalLines(), @as(u64, @intCast(n))),
        };
    }
};

pub fn applyWindow(gpa: std.mem.Allocator, window: Window, text: []const u8, chunk_size: usize) !struct {
    bytes: []u8,
    shown_lines: u64,
    total_lines: u64,
} {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(gpa);
    var writer = Io.Writer.Allocating.fromArrayList(gpa, &result);
    defer result = writer.toArrayList();
    var sink = WindowSink.init(gpa, window, &writer.writer);
    defer sink.deinit();

    var offset: usize = 0;
    while (offset < text.len) {
        const end = @min(offset + chunk_size, text.len);
        try sink.writeAll(text[offset..end]);
        offset = end;
    }
    try sink.finish();
    return .{
        .bytes = try writer.toOwnedSlice(),
        .shown_lines = sink.shownLines(),
        .total_lines = sink.totalLines(),
    };
}

test "streaming windows keep whole lines across chunk boundaries" {
    const gpa = std.testing.allocator;
    const cases = [_]struct {
        window: Window,
        input: []const u8,
        expected: []const u8,
        shown: u64,
        total: u64,
    }{
        .{ .window = .all, .input = "one\ntwo\nthree\n", .expected = "one\ntwo\nthree\n", .shown = 3, .total = 3 },
        .{ .window = .{ .head = 2 }, .input = "one\ntwo\nthree\n", .expected = "one\ntwo\n", .shown = 2, .total = 3 },
        .{ .window = .{ .tail = 2 }, .input = "one\ntwo\nthree\n", .expected = "two\nthree\n", .shown = 2, .total = 3 },
        .{ .window = .{ .head = 0 }, .input = "one\ntwo", .expected = "", .shown = 0, .total = 2 },
        .{ .window = .{ .tail = 0 }, .input = "one\ntwo", .expected = "", .shown = 0, .total = 2 },
        .{ .window = .{ .head = 1 }, .input = "one\ntwo", .expected = "one\n", .shown = 1, .total = 2 },
        .{ .window = .{ .tail = 1 }, .input = "one\ntwo", .expected = "two", .shown = 1, .total = 2 },
        .{ .window = .{ .tail = 2 }, .input = "one\ntwo", .expected = "one\ntwo", .shown = 2, .total = 2 },
        .{ .window = .{ .tail = 2 }, .input = "", .expected = "", .shown = 0, .total = 0 },
    };

    for (cases) |case| {
        for ([_]usize{ 1, 2, 3, 64 }) |chunk_size| {
            const result = try applyWindow(gpa, case.window, case.input, chunk_size);
            defer gpa.free(result.bytes);
            try std.testing.expectEqualStrings(case.expected, result.bytes);
            try std.testing.expectEqual(case.shown, result.shown_lines);
            try std.testing.expectEqual(case.total, result.total_lines);
        }
    }
}

/// Accepts a reference or a path to the same thing.
///
/// Inside a journal writer, shorthand `@42/out` becomes canonical
/// `$(tj @42/out)`, which zsh expands to a path before tj executes. Insisting on a
/// reference would therefore make `tj cat @42` work everywhere except the
/// place it is most likely to be typed. Outside a writer there is no named
/// directory expansion and the reference is resolved here instead. Either way
/// it ends at the same open file.
pub fn openTarget(gpa: std.mem.Allocator, io: Io, root: *LazyRoot, text: []const u8) !Io.File {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var path: []const u8 = text;
    var owned: ?[]const u8 = null;
    defer if (owned) |value| gpa.free(value);

    if (reference.parse(text)) |parsed| {
        const found = try store.locate(gpa, io, try root.get(), sys.env("TJ_JOURNAL"), parsed);
        defer found.deinit(gpa);
        if (!found.exists) return error.NoSuchInteraction;
        owned = try gpa.dupe(u8, found.path);
        path = owned.?;
    } else |err| switch (err) {
        // Shaped like a reference but wrong: worth saying so rather than
        // trying it as a filename.
        error.Malformed => return error.BadReference,
        error.NotAReference => {},
    }

    // Naming the interaction rather than a resource means its output, whether
    // that came from `@42` or from the path `tj @42` expanded to.
    if (isDirectory(io, path)) {
        path = std.fmt.bufPrint(&path_buf, "{s}/out", .{path}) catch return error.BadReference;
    }

    return store.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => error.NoSuchResource,
        else => |other| other,
    };
}

pub fn isDirectory(io: Io, path: []const u8) bool {
    var dir = store.Dir.cwd().openDir(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}
