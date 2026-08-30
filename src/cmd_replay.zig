//! `tjctl replay` - playing a recorded journal back into the terminal.

const std = @import("std");
const Io = std.Io;
const zecli = @import("zecli");

const cli = @import("cli.zig");
const store = @import("store.zig");
const sys = @import("sys.zig");
const reference = @import("reference.zig");
const plain = @import("plain.zig");
const annotations = @import("annotations.zig");
const mutation_lock = @import("mutation_lock.zig");
const search = @import("search.zig");
const noout = @import("noout.zig");
const report = @import("report.zig");
const replay_engine = @import("replay.zig");
const context = @import("context.zig");
const tjctl_spec = @import("tjctl_spec.zig");

pub const ReplayRequest = struct {
    replay: replay_engine.Options,
    wanted: ?[]const u8,
};

pub fn replayRequest(parsed: *const zecli.Parsed) !ReplayRequest {
    var request: ReplayRequest = .{ .replay = .{}, .wanted = null };
    if (parsed.last("typing")) |text| request.replay.typing_ms = parseReplayMillis(text) catch return error.BadReplayOption;
    if (parsed.last("max-pause")) |text| request.replay.max_pause_ms = parseReplayMillis(text) catch return error.BadReplayOption;
    if (parsed.last("from")) |text| request.replay.from = parseReplayNumber(text) catch return error.BadReplayOption;
    if (parsed.last("to")) |text| request.replay.to = parseReplayNumber(text) catch return error.BadReplayOption;
    if (parsed.present("prompt")) {
        request.replay.prompt = parsed.last("prompt") orelse return error.BadReplayOption;
        request.replay.use_recorded_prompt = false;
    }
    if (parsed.last("speed")) |text| request.replay.speed = parseReplaySpeed(text) catch return error.BadReplayOption;
    request.replay.duration_only = parsed.present("duration");
    if (parsed.positionals.items.len == 1) request.wanted = parsed.positionals.items[0];
    return request;
}

pub fn replayRequestFromArgs(args: []const [:0]const u8) !ReplayRequest {
    var discard_buf: [1024]u8 = undefined;
    var discarding = Io.Writer.Discarding.init(&discard_buf);
    const spec = tjctl_spec.findCommand("replay") orelse unreachable;
    var parsed = try zecli.parseCommand(std.testing.allocator, &discarding.writer, args, spec);
    defer parsed.deinit(std.testing.allocator);
    return replayRequest(&parsed);
}

/// `tjctl replay <journal>` - play a recording back into the terminal.
///
/// Nothing is re-executed: this is the visual output that was captured, with
/// colours and cursor controls intact. Terminal queries and window-title
/// changes are omitted because they are not screen content and can affect the
/// newly attached shell. What cannot be
/// reconstructed is when each byte arrived, since only the start and end of
/// each interaction were recorded - so output appears at once, and the pacing
/// comes from the real durations and the real gaps between commands.
pub fn replayJournal(
    gpa: std.mem.Allocator,
    io: Io,
    home: ?[]const u8,
    parsed: *const zecli.Parsed,
    out: *Io.Writer,
) !void {
    const request = try replayRequest(parsed);
    const replay = request.replay;
    const wanted = request.wanted;

    // Replaying inside a live journal writer would feed the recording back
    // into the journal: the replayed shell-integration markers read as real command
    // boundaries, which truncates the recording of the replay itself and
    // pins the replayed exit status onto it. Asking for the duration prints
    // no recording, so it stays allowed - `tj-tape` needs it.
    if (!replay.duration_only and sys.env("TJ_JOURNAL") != null) return error.InsideJournal;

    var root = try store.openRoot(io, home);
    defer root.close(io);

    // Exact names and unique suffixes work here as everywhere else. Replay
    // deliberately has no implicit journal because names carry no recency.
    var owned: ?[]u8 = null;
    defer if (owned) |name| gpa.free(name);

    const journal: []const u8 = if (wanted) |name| blk: {
        owned = try store.findUniqueJournal(gpa, io, root, name);
        break :blk owned.?;
    } else return error.MissingArgument;

    try replay_engine.play(gpa, io, root, journal, replay, out);
}

pub fn parseReplayNumber(text: []const u8) !u32 {
    const number = std.fmt.parseInt(u32, text, 10) catch return error.BadReplayOption;
    if (number == 0) return error.BadReplayOption;
    return number;
}

pub fn parseReplayMillis(text: []const u8) !u64 {
    return std.fmt.parseInt(u64, text, 10) catch error.BadReplayOption;
}

pub fn parseReplaySpeed(text: []const u8) !f64 {
    const speed = std.fmt.parseFloat(f64, text) catch return error.BadReplayOption;
    if (!std.math.isFinite(speed) or speed <= 0) return error.BadReplayOption;
    return speed;
}

test "replay entry ranges parse directly into u32" {
    const minimum = try replayRequestFromArgs(&.{ "journal", "--from", "1", "--to=4294967295" });
    try std.testing.expectEqual(@as(u32, 1), minimum.replay.from);
    try std.testing.expectEqual(std.math.maxInt(u32), minimum.replay.to);

    try std.testing.expectError(error.BadReplayOption, replayRequestFromArgs(&.{ "journal", "--from", "0" }));
    try std.testing.expectError(error.BadReplayOption, replayRequestFromArgs(&.{ "journal", "--to=4294967296" }));
}

test "replay accepts only finite positive speeds" {
    for ([_][]const u8{ "0.5", "1", "2" }) |text| {
        const speed = try parseReplaySpeed(text);
        try std.testing.expect(speed > 0);
        try std.testing.expect(std.math.isFinite(speed));
    }

    for ([_][]const u8{ "nan", "inf", "-inf", "0", "-1" }) |text| {
        try std.testing.expectError(error.BadReplayOption, parseReplaySpeed(text));
    }
}

test "replay millisecond options use their final u64 type" {
    const parsed = try replayRequestFromArgs(&.{ "journal", "--typing=18446744073709551615", "--max-pause", "0" });
    try std.testing.expectEqual(std.math.maxInt(u64), parsed.replay.typing_ms);
    try std.testing.expectEqual(@as(u64, 0), parsed.replay.max_pause_ms);
    try std.testing.expectError(
        error.BadReplayOption,
        replayRequestFromArgs(&.{ "journal", "--typing", "18446744073709551616" }),
    );
}

test "replay rejects more than one journal name" {
    try std.testing.expectError(error.ReportedCliError, replayRequestFromArgs(&.{ "first", "second" }));
}
