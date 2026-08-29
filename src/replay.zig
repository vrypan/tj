//! Shared journal replay renderer.
//!
//! `tj replay` uses the recorded rhythm by default. `tj continue` uses the
//! same renderer with both delay controls set to zero before its child starts.

const std = @import("std");
const Io = std.Io;

const store = @import("store.zig");
const sys = @import("sys.zig");

const read_chunk_size = 64 * 1024;

/// Terminal queries are not visual output. Replaying them would make the
/// terminal send their answers to stdin, where a newly continued shell would
/// receive the replies as if the user had typed them.
const replay_queries = [_][]const u8{
    "\x1b]11;?\x07",
    "\x1b]11;?\x1b\\",
    "\x1b[6n",
};

const max_replay_query_len = blk: {
    var longest: usize = 0;
    for (replay_queries) |query| longest = @max(longest, query.len);
    break :blk longest;
};

const ReplayOutput = struct {
    out: *Io.Writer,
    pending: [max_replay_query_len]u8 = undefined,
    pending_len: usize = 0,

    fn writeAll(self: *ReplayOutput, bytes: []const u8) !void {
        var plain_start: usize = 0;
        for (bytes, 0..) |byte, i| {
            if (self.pending_len == 0) {
                if (byte != 0x1b) continue;
                if (plain_start < i) try self.out.writeAll(bytes[plain_start..i]);
                self.pending[0] = byte;
                self.pending_len = 1;
                plain_start = i + 1;
                continue;
            }

            self.pending[self.pending_len] = byte;
            self.pending_len += 1;
            plain_start = i + 1;

            const status = queryStatus(self.pending[0..self.pending_len]);
            if (status == .complete) {
                self.pending_len = 0;
            } else if (status == .not_query) {
                // An ESC that ended the failed candidate may begin a real
                // query of its own, so retain that one byte for reconsidering.
                if (byte == 0x1b) {
                    try self.out.writeAll(self.pending[0 .. self.pending_len - 1]);
                    self.pending[0] = 0x1b;
                    self.pending_len = 1;
                } else {
                    try self.out.writeAll(self.pending[0..self.pending_len]);
                    self.pending_len = 0;
                }
            }
        }

        if (self.pending_len == 0 and plain_start < bytes.len) {
            try self.out.writeAll(bytes[plain_start..]);
        }
    }

    fn flush(self: *ReplayOutput) !void {
        try self.out.flush();
    }

    /// An incomplete candidate remains ordinary recorded data. Resource and
    /// interaction boundaries cannot complete an escape sequence.
    fn boundary(self: *ReplayOutput) !void {
        if (self.pending_len == 0) return;
        try self.out.writeAll(self.pending[0..self.pending_len]);
        self.pending_len = 0;
    }
};

const QueryStatus = enum { prefix, complete, not_query };

fn queryStatus(candidate: []const u8) QueryStatus {
    var prefix = false;
    for (replay_queries) |query| {
        if (std.mem.eql(u8, candidate, query)) return .complete;
        if (candidate.len < query.len and std.mem.eql(u8, candidate, query[0..candidate.len])) prefix = true;
    }
    return if (prefix) .prefix else .not_query;
}

/// How a recording is played back. The recorded timings give the rhythm; the
/// defaults keep standalone replay watchable.
pub const Options = struct {
    /// Divides every delay. 2 means twice as fast.
    speed: f64 = 1.0,
    /// Per character of the command line. 0 shows it at once.
    typing_ms: u64 = 35,
    /// No single pause runs longer than this, however long the real one was.
    max_pause_ms: u64 = 2000,
    prompt: []const u8 = "$ ",
    /// Prefer each interaction's captured prompt. `prompt` remains the
    /// fallback for old journals and an explicit CLI override.
    use_recorded_prompt: bool = true,
    from: u32 = 1,
    to: u32 = std.math.maxInt(u32),
    /// Report how long the replay would take instead of playing it.
    duration_only: bool = false,

    /// A recorded gap, capped and scaled into something watchable.
    fn delay(self: Options, millis: i64) !u64 {
        if (millis <= 0) return 0;
        const capped = @min(@as(u64, @intCast(millis)), self.max_pause_ms);
        return scaleMillis(capped, self.speed);
    }

    /// Sleeps unless only the total was asked for. Returns what it cost
    /// either way, so duration reporting and playback cannot drift apart.
    fn wait(self: Options, millis: i64) !u64 {
        const ms = try self.delay(millis);
        if (!self.duration_only) sys.sleepMs(ms);
        return ms;
    }
};

/// Play one exact journal through `out`. Selection and locking belong to the
/// caller; this function only reads the journal's numbered interactions.
pub fn play(
    gpa: std.mem.Allocator,
    io: Io,
    root: store.Dir,
    journal: []const u8,
    options: Options,
    out: *Io.Writer,
) !void {
    const numbers = store.listNumbers(gpa, io, root, journal) catch return error.NoSuchJournal;
    defer gpa.free(numbers);

    var previous_end: ?i64 = null;
    var total_ms: u64 = 0;
    var replay_out: ReplayOutput = .{ .out = out };

    for (numbers) |number| {
        if (number < options.from or number > options.to) continue;

        const timing = store.readTiming(gpa, io, root, journal, number);

        if (previous_end) |ended| {
            if (timing) |value| try addDuration(&total_ms, try options.wait(value.started - ended));
        }

        if (!options.duration_only) {
            const recorded = options.use_recorded_prompt and
                try writeResource(io, root, journal, number, "prompt", &replay_out);
            if (!recorded) try replay_out.writeAll(options.prompt);
        }
        try addDuration(&total_ms, try typeOut(io, root, journal, number, options, &replay_out));

        if (timing) |value| try addDuration(&total_ms, try options.wait(value.duration()));

        if (!options.duration_only) {
            _ = try writeResource(io, root, journal, number, "out", &replay_out);
            try replay_out.boundary();
            try replay_out.flush();
        }

        previous_end = if (timing) |value| value.ended else null;
    }

    // Rounded up, so a tape that waits this long never cuts the end off.
    if (options.duration_only) try out.print("{d}\n", .{(try std.math.add(u64, total_ms, 999)) / 1000});
}

fn scaleMillis(value: u64, speed: f64) !u64 {
    if (!std.math.isFinite(speed) or speed <= 0) return error.BadReplayOption;
    const scaled = @as(f64, @floatFromInt(value)) / speed;
    // maxInt(u64) rounds to 2^64 as an f64, so equality is already outside
    // the integer range accepted by @intFromFloat.
    if (!std.math.isFinite(scaled) or scaled < 0 or scaled >= @as(f64, @floatFromInt(std.math.maxInt(u64)))) {
        return error.BadReplayOption;
    }
    return @intFromFloat(scaled);
}

fn addDuration(total: *u64, value: u64) !void {
    total.* = std.math.add(u64, total.*, value) catch return error.BadReplayOption;
}

fn typingDuration(per_char: u64, command_len: u64) !u64 {
    return std.math.mul(u64, per_char, command_len) catch return error.BadReplayOption;
}

/// Types the command line out a character at a time, the way it was typed.
fn typeOut(
    io: Io,
    root: store.Dir,
    journal: []const u8,
    number: u32,
    options: Options,
    out: anytype,
) !u64 {
    var path_buf: [64]u8 = undefined;
    const sub = try std.fmt.bufPrint(&path_buf, "{s}/{d}/cmd", .{ journal, number });
    const per_char: u64 = if (options.typing_ms == 0) 0 else try scaleMillis(options.typing_ms, options.speed);
    var file = root.openFile(io, sub, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            if (!options.duration_only) {
                try out.writeAll("\r\n");
                try out.flush();
            }
            return 0;
        },
        else => |other| return other,
    };
    defer file.close(io);

    const total = try typingDuration(per_char, (try file.stat(io)).size);
    if (options.duration_only) return total;

    if (per_char == 0) {
        try copyFile(io, file, out);
    } else {
        var reader_buffer: [read_chunk_size]u8 = undefined;
        var bytes: [read_chunk_size]u8 = undefined;
        var reader = file.readerStreaming(io, &reader_buffer);
        while (true) {
            const n = try reader.interface.readSliceShort(&bytes);
            if (n == 0) break;
            for (bytes[0..n]) |char| {
                try out.writeAll(&[_]u8{char});
                try out.flush();
                sys.sleepMs(per_char);
            }
        }
    }
    try out.writeAll("\r\n");
    try out.flush();
    return total;
}

/// Writes a recorded resource through verbatim. `out` is what the terminal
/// saw, so replaying it raw is what makes colours and terminal state return.
fn writeResource(
    io: Io,
    root: store.Dir,
    journal: []const u8,
    number: u32,
    name: []const u8,
    out: anytype,
) !bool {
    var path_buf: [64]u8 = undefined;
    const sub = try std.fmt.bufPrint(&path_buf, "{s}/{d}/{s}", .{ journal, number, name });
    var file = root.openFile(io, sub, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |other| return other,
    };
    defer file.close(io);
    try copyFile(io, file, out);
    return true;
}

fn copyFile(io: Io, file: Io.File, out: anytype) !void {
    var reader_buffer: [read_chunk_size]u8 = undefined;
    var bytes: [read_chunk_size]u8 = undefined;
    var reader = file.readerStreaming(io, &reader_buffer);
    while (true) {
        const n = try reader.interface.readSliceShort(&bytes);
        if (n == 0) break;
        try out.writeAll(bytes[0..n]);
    }
}

test "a recorded gap is capped so a demo stays watchable" {
    const options: Options = .{ .max_pause_ms = 2000, .speed = 1.0 };
    try std.testing.expectEqual(@as(u64, 0), try options.delay(0));
    try std.testing.expectEqual(@as(u64, 0), try options.delay(-5));
    try std.testing.expectEqual(@as(u64, 500), try options.delay(500));
    try std.testing.expectEqual(@as(u64, 2000), try options.delay(60_000));
}

test "speed divides every delay" {
    const fast: Options = .{ .max_pause_ms = 4000, .speed = 4.0 };
    try std.testing.expectEqual(@as(u64, 250), try fast.delay(1000));
    const slow: Options = .{ .max_pause_ms = 4000, .speed = 0.5 };
    try std.testing.expectEqual(@as(u64, 2000), try slow.delay(1000));
}

test "replay timing arithmetic rejects unrepresentable durations" {
    try std.testing.expectError(error.BadReplayOption, scaleMillis(std.math.maxInt(u64), 1));
    try std.testing.expectError(error.BadReplayOption, scaleMillis(1, 0));
    try std.testing.expectError(error.BadReplayOption, typingDuration(std.math.maxInt(u64), 2));

    var total: u64 = std.math.maxInt(u64);
    try std.testing.expectError(error.BadReplayOption, addDuration(&total, 1));
}

test "replay drops terminal queries without changing visual controls" {
    const input = "before\x1b]11;?\x1b\\middle\x1b[6nafter\x1b[31mred\x1b[0m";
    const expected = "beforemiddleafter\x1b[31mred\x1b[0m";

    for (1..input.len + 1) |split| {
        var bytes: std.ArrayList(u8) = .empty;
        var allocating = Io.Writer.Allocating.fromArrayList(std.testing.allocator, &bytes);
        defer {
            bytes = allocating.toArrayList();
            bytes.deinit(std.testing.allocator);
        }

        var output: ReplayOutput = .{ .out = &allocating.writer };
        try output.writeAll(input[0..split]);
        try output.writeAll(input[split..]);
        try output.boundary();
        try std.testing.expectEqualStrings(expected, allocating.writer.buffered());
    }
}

test "replay preserves incomplete and similar escape sequences" {
    const input = "\x1b]10;?\x1b\\ \x1b[5n \x1b]11;?";
    var bytes: std.ArrayList(u8) = .empty;
    var allocating = Io.Writer.Allocating.fromArrayList(std.testing.allocator, &bytes);
    defer {
        bytes = allocating.toArrayList();
        bytes.deinit(std.testing.allocator);
    }

    var output: ReplayOutput = .{ .out = &allocating.writer };
    for (input) |byte| try output.writeAll(&.{byte});
    try output.boundary();
    try std.testing.expectEqualStrings(input, allocating.writer.buffered());
}
