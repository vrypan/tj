//! Repeatable grep search microbenchmarks. Fixtures are generated before the
//! clock starts; the first pass is labelled cold-order, followed by warm-order
//! medians without claiming to flush or control the operating-system cache.

const std = @import("std");
const Io = std.Io;
const search = @import("grep_search");

const repetitions = 7;

const DiscardSink = struct {
    matches: u64 = 0,

    fn emit(context: *anyopaque, _: Io.File, _: u64, _: u64) !void {
        const self: *DiscardSink = @ptrCast(@alignCast(context));
        self.matches += 1;
    }
};

const Result = struct {
    ns: u64,
    matches: u64,
};

const ParallelState = struct {
    io: Io,
    files: []const Io.File,
    matcher: *const search.Matcher,
    next: std.atomic.Value(usize) = .init(0),
    matches: std.atomic.Value(u64) = .init(0),

    fn worker(self: *ParallelState) void {
        while (true) {
            const index = self.next.fetchAdd(1, .monotonic);
            if (index >= self.files.len) return;
            if (search.fileContains(self.io, self.files[index], self.matcher) catch unreachable) {
                _ = self.matches.fetchAdd(1, .monotonic);
            }
        }
    }
};

fn elapsedNs(io: Io, before: Io.Clock.Timestamp) u64 {
    const value = before.durationTo(.now(io, .awake)).raw.toNanoseconds();
    return @intCast(@max(value, 0));
}

fn runContains(io: Io, files: []const Io.File, matcher: *const search.Matcher, scalar: bool) !Result {
    const before = Io.Clock.Timestamp.now(io, .awake);
    var matches: u64 = 0;
    for (files) |file| if (if (scalar)
        try search.Benchmark.fileContainsScalar(io, file, matcher)
    else
        try search.fileContains(io, file, matcher))
    {
        matches += 1;
    };
    return .{ .ns = elapsedNs(io, before), .matches = matches };
}

fn runContainsParallel(io: Io, files: []const Io.File, matcher: *const search.Matcher, workers: usize) !Result {
    const before = Io.Clock.Timestamp.now(io, .awake);
    var state: ParallelState = .{ .io = io, .files = files, .matcher = matcher };
    var threads: [8]std.Thread = undefined;
    for (threads[0..workers], 0..) |*thread, i| {
        _ = i;
        thread.* = try std.Thread.spawn(.{}, ParallelState.worker, .{&state});
    }
    for (threads[0..workers]) |thread| thread.join();
    return .{ .ns = elapsedNs(io, before), .matches = state.matches.load(.monotonic) };
}

fn runFormatted(io: Io, dir: Io.Dir, path: []const u8, matcher: *const search.Matcher, scalar: bool) !Result {
    const file = try dir.openFile(io, path, .{});
    defer file.close(io);
    const before = Io.Clock.Timestamp.now(io, .awake);
    var sink: DiscardSink = .{};
    const target: search.Sink = .{ .context = &sink, .emit = DiscardSink.emit };
    _ = if (scalar)
        try search.Benchmark.scanFileScalar(io, file, matcher, target)
    else
        try search.scanFile(io, file, matcher, target);
    return .{ .ns = elapsedNs(io, before), .matches = sink.matches };
}

fn median(values: *[repetitions]u64) u64 {
    std.mem.sort(u64, values, {}, std.sort.asc(u64));
    return values[repetitions / 2];
}

fn report(
    out: *Io.Writer,
    io: Io,
    label: []const u8,
    bytes: u64,
    resources: usize,
    files: []const Io.File,
    formatted_dir: ?Io.Dir,
    formatted_path: ?[]const u8,
    matcher: *const search.Matcher,
    formatted: bool,
) !void {
    const cold = if (formatted)
        try runFormatted(io, formatted_dir.?, formatted_path.?, matcher, false)
    else
        try runContains(io, files, matcher, false);
    var baseline_samples: [repetitions]u64 = undefined;
    var optimized_samples: [repetitions]u64 = undefined;
    var matches = cold.matches;
    for (&baseline_samples, &optimized_samples) |*baseline, *optimized| {
        baseline.* = (if (formatted)
            try runFormatted(io, formatted_dir.?, formatted_path.?, matcher, true)
        else
            try runContains(io, files, matcher, true)).ns;
        const result = if (formatted)
            try runFormatted(io, formatted_dir.?, formatted_path.?, matcher, false)
        else
            try runContains(io, files, matcher, false);
        optimized.* = result.ns;
        matches = result.matches;
    }
    const baseline = median(&baseline_samples);
    const optimized = median(&optimized_samples);
    const mib_s = if (optimized == 0) 0 else (bytes * std.time.ns_per_s) / optimized / (1024 * 1024);
    const improvement: i64 = if (baseline == 0) 0 else @intCast(@divTrunc(
        (@as(i128, baseline) - @as(i128, optimized)) * 100,
        @as(i128, baseline),
    ));
    try out.print(
        "{s}: bytes={d} resources={d} matches={d} cold-order-us={d} " ++
            "baseline-median-us={d} optimized-median-us={d} " ++
            "improvement-percent={d} MiB/s={d}\n",
        .{ label, bytes, resources, matches, cold.ns / 1000, baseline / 1000, optimized / 1000, improvement, mib_s },
    );
}

fn reportParallel(
    out: *Io.Writer,
    io: Io,
    label: []const u8,
    bytes: u64,
    files: []const Io.File,
    matcher: *const search.Matcher,
    workers: usize,
) !void {
    var serial_samples: [repetitions]u64 = undefined;
    var parallel_samples: [repetitions]u64 = undefined;
    for (&serial_samples) |*sample| sample.* = (try runContains(io, files, matcher, false)).ns;
    for (&parallel_samples) |*sample| sample.* = (try runContainsParallel(io, files, matcher, workers)).ns;
    const serial = median(&serial_samples);
    const parallel = median(&parallel_samples);
    const improvement: i64 = if (serial == 0) 0 else @intCast(@divTrunc(
        (@as(i128, serial) - @as(i128, parallel)) * 100,
        @as(i128, serial),
    ));
    try out.print(
        "{s}-{d}-workers: bytes={d} resources={d} serial-median-us={d} " ++
            "parallel-median-us={d} improvement-percent={d}\n",
        .{ label, workers, bytes, files.len, serial / 1000, parallel / 1000, improvement },
    );
}

const TraversalRequest = struct {
    commands: bool,
    output: bool,
};

const TraversalStats = struct {
    lists: usize = 0,
    entries: usize = 0,
    resources: usize = 0,
    rc: usize = 0,
    pin: usize = 0,
    reads: usize = 0,
    bytes: u64 = 0,
    matches: u64 = 0,
};

fn listNumbers(gpa: std.mem.Allocator, io: Io, root: Io.Dir, journal: []const u8, stats: *TraversalStats) ![]u32 {
    stats.lists += 1;
    var dir = try root.openDir(io, journal, .{ .iterate = true });
    defer dir.close(io);
    var numbers: std.ArrayList(u32) = .empty;
    errdefer numbers.deinit(gpa);
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const number = std.fmt.parseInt(u32, entry.name, 10) catch continue;
        try numbers.append(gpa, number);
    }
    std.mem.sort(u32, numbers.items, {}, std.sort.asc(u32));
    return numbers.toOwnedSlice(gpa);
}

fn runTraversal(
    gpa: std.mem.Allocator,
    io: Io,
    root: Io.Dir,
    journals: []const []const u8,
    request: TraversalRequest,
    matcher: *const search.Matcher,
    numbers_mode: bool,
) !TraversalStats {
    var stats: TraversalStats = .{};
    for (journals) |journal| {
        const numbers = try listNumbers(gpa, io, root, journal, &stats);
        defer gpa.free(numbers);
        var journal_dir = try root.openDir(io, journal, .{});
        defer journal_dir.close(io);
        for (numbers) |number| {
            var number_buf: [16]u8 = undefined;
            const entry_name = try std.fmt.bufPrint(&number_buf, "{d}", .{number});
            var entry = try journal_dir.openDir(io, entry_name, .{});
            defer entry.close(io);
            stats.entries += 1;
            var entry_matched = false;
            for ([_]struct { enabled: bool, name: []const u8 }{
                .{ .enabled = request.commands, .name = "cmd" },
                .{ .enabled = request.output, .name = "out" },
            }) |resource| {
                if (!resource.enabled) continue;
                var file = entry.openFile(io, resource.name, .{}) catch |err| switch (err) {
                    error.FileNotFound => continue,
                    else => return err,
                };
                defer file.close(io);
                stats.resources += 1;
                var search_stats: search.Stats = .{};
                if (numbers_mode) {
                    if (try search.fileContainsMeasured(io, file, matcher, &search_stats)) {
                        entry_matched = true;
                        stats.matches += 1;
                    }
                } else {
                    var sink: DiscardSink = .{};
                    stats.matches += try search.scanFileMeasured(
                        io,
                        file,
                        matcher,
                        .{ .context = &sink, .emit = DiscardSink.emit },
                        &search_stats,
                    );
                    entry_matched = entry_matched or sink.matches != 0;
                }
                stats.reads += search_stats.calls.load(.monotonic);
                stats.bytes += search_stats.bytes.load(.monotonic);
                if (numbers_mode and entry_matched) break;
            }
            if (!numbers_mode and entry_matched) {
                stats.rc += 1;
                stats.pin += 1;
                _ = entry.statFile(io, "rc", .{}) catch {};
                _ = entry.statFile(io, "pin", .{}) catch {};
            }
        }
    }
    return stats;
}

fn reportTraversal(
    out: *Io.Writer,
    gpa: std.mem.Allocator,
    io: Io,
    root: Io.Dir,
    label: []const u8,
    journals: []const []const u8,
    request: TraversalRequest,
    matcher: *const search.Matcher,
    numbers_mode: bool,
) !void {
    var samples: [repetitions]u64 = undefined;
    var last: TraversalStats = undefined;
    for (&samples) |*sample| {
        const before = Io.Clock.Timestamp.now(io, .awake);
        last = try runTraversal(gpa, io, root, journals, request, matcher, numbers_mode);
        sample.* = elapsedNs(io, before);
    }
    const middle = median(&samples);
    try out.print(
        "{s}: median-us={d} journals={d} entries={d} resources={d} " ++
            "matches={d} lists={d} rc={d} pin={d} out-length={d} " ++
            "reads={d} bytes={d} max-workers={d}\n",
        .{
            label,
            middle / 1000,
            journals.len,
            last.entries,
            last.resources,
            last.matches,
            last.lists,
            last.rc,
            last.pin,
            @as(usize, 0),
            last.reads,
            last.bytes,
            @as(usize, 1),
        },
    );
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    var out_buffer: [4096]u8 = undefined;
    var stdout = Io.File.Writer.initStreaming(.stdout(), io, &out_buffer);
    defer stdout.interface.flush() catch {};

    const cwd = Io.Dir.cwd();
    cwd.deleteTree(io, ".zig-cache/tj-grep-benchmark") catch {};
    var tmp = try cwd.createDirPathOpen(io, ".zig-cache/tj-grep-benchmark", .{});
    defer {
        tmp.close(io);
        cwd.deleteTree(io, ".zig-cache/tj-grep-benchmark") catch {};
    }

    const tiny_count = 10_000;
    try tmp.createDirPath(io, "journal-a");
    var tiny = try gpa.alloc(Io.File, tiny_count);
    defer gpa.free(tiny);
    var made: usize = 0;
    defer for (tiny[0..made]) |file| file.close(io);
    for (tiny, 0..) |*file, i| {
        var name_buf: [32]u8 = undefined;
        const number = i + 1;
        const entry = try std.fmt.bufPrint(&name_buf, "journal-a/{d}", .{number});
        try tmp.createDirPath(io, entry);
        var path_buf: [48]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/cmd", .{entry});
        file.* = try tmp.createFile(io, path, .{ .read = true, .truncate = true });
        made += 1;
        try file.writePositionalAll(io, if (i == tiny_count - 1) "late needle\n" else "small command\n", 0);
    }

    try tmp.createDirPath(io, "journal-large/1");
    var large = try tmp.createFile(io, "journal-large/1/out", .{ .read = true, .truncate = true });
    defer large.close(io);
    var block: [search.chunk_size]u8 = undefined;
    @memset(&block, 'x');
    const large_bytes = 32 * 1024 * 1024;
    var offset: u64 = 0;
    while (offset < large_bytes) : (offset += block.len) try large.writePositionalAll(io, &block, offset);
    try large.writePositionalAll(io, "late-needle\n", large_bytes - "late-needle\n".len);

    try tmp.createDirPath(io, "journal-format/1");
    var common = try tmp.createFile(io, "journal-format/1/out", .{ .read = true, .truncate = true });
    defer common.close(io);
    const common_line = "common match and ordinary text\n";
    offset = 0;
    while (offset < large_bytes) : (offset += common_line.len) try common.writePositionalAll(io, common_line, offset);

    var parallel_files: [64]Io.File = undefined;
    var parallel_made: usize = 0;
    defer for (parallel_files[0..parallel_made]) |file| file.close(io);
    try tmp.createDirPath(io, "journal-b");
    for (&parallel_files, 0..) |*file, i| {
        var name_buf: [32]u8 = undefined;
        const entry = try std.fmt.bufPrint(&name_buf, "journal-b/{d}", .{i + 1});
        try tmp.createDirPath(io, entry);
        var path_buf: [48]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/out", .{entry});
        file.* = try tmp.createFile(io, path, .{ .read = true, .truncate = true });
        parallel_made += 1;
        offset = 0;
        while (offset < 1024 * 1024) : (offset += block.len) try file.writePositionalAll(io, &block, offset);
    }

    const cases = [_]struct { label: []const u8, pattern: []const u8, ignore_case: bool, file: Io.File }{
        .{ .label = "large-absent-sensitive", .pattern = "not-present", .ignore_case = false, .file = large },
        .{ .label = "large-early-sensitive", .pattern = "xxxx", .ignore_case = false, .file = large },
        .{ .label = "large-late-sensitive", .pattern = "late-needle", .ignore_case = false, .file = large },
        .{ .label = "large-absent-ignore-case", .pattern = "NOT-PRESENT", .ignore_case = true, .file = large },
    };
    for (cases) |item| {
        var matcher = try search.Matcher.init(gpa, item.pattern, item.ignore_case);
        defer matcher.deinit();
        try report(&stdout.interface, io, item.label, large_bytes, 1, &.{item.file}, null, null, &matcher, false);
    }
    var tiny_matcher = try search.Matcher.init(gpa, "needle", false);
    defer tiny_matcher.deinit();
    try report(&stdout.interface, io, "tiny-10000-numbers", tiny_count * "small command\n".len, tiny_count, tiny, null, null, &tiny_matcher, false);

    var common_matcher = try search.Matcher.init(gpa, "common", false);
    defer common_matcher.deinit();
    try report(&stdout.interface, io, "large-common-formatted", large_bytes, 1, &.{}, tmp, "journal-format/1/out", &common_matcher, true);

    var small = try tmp.createFile(io, "small", .{ .read = true, .truncate = true });
    defer small.close(io);
    try small.writePositionalAll(io, "one needle\n", 0);
    try report(&stdout.interface, io, "one-entry-small", 11, 1, &.{small}, null, null, &tiny_matcher, false);

    var absent_matcher = try search.Matcher.init(gpa, "parallel-absent", false);
    defer absent_matcher.deinit();
    for ([_]usize{ 2, 4, 8 }) |workers| {
        try reportParallel(&stdout.interface, io, "parallel-large-cached", 64 * 1024 * 1024, &parallel_files, &absent_matcher, workers);
        try reportParallel(&stdout.interface, io, "parallel-tiny-cached", tiny_count * "small command\n".len, tiny, &absent_matcher, workers);
    }

    try reportTraversal(
        &stdout.interface,
        gpa,
        io,
        tmp,
        "journal-current-numbers",
        &.{"journal-a"},
        .{ .commands = true, .output = false },
        &tiny_matcher,
        true,
    );
    try reportTraversal(
        &stdout.interface,
        gpa,
        io,
        tmp,
        "journal-current-formatted",
        &.{"journal-format"},
        .{ .commands = false, .output = true },
        &common_matcher,
        false,
    );
    try reportTraversal(
        &stdout.interface,
        gpa,
        io,
        tmp,
        "journal-all-formatted-absent",
        &.{ "journal-a", "journal-b" },
        .{ .commands = true, .output = true },
        &absent_matcher,
        false,
    );
}
