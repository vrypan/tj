//! Journal lifecycle and management commands owned by `tjctl`.

const std = @import("std");
const Io = std.Io;
const zecli = @import("zecli");

const cli = @import("tjctl_cli.zig");
const proxy = @import("proxy.zig");
const store = @import("store.zig");
const sys = @import("sys.zig");
const cmd_history = @import("cmd_history.zig");
const cmd_remove = @import("cmd_remove.zig");
const cmd_replay = @import("cmd_replay.zig");

pub fn run(
    gpa: std.mem.Allocator,
    io: Io,
    which: cli.CommandName,
    root_home: ?[]const u8,
    child: []const [:0]const u8,
    parsed: *const zecli.Parsed,
    out: *Io.Writer,
) !u8 {
    const home = if (parsed.present("home")) parsed.last("home") else root_home orelse parsed.last("home");
    const title = parsed.last("title") orelse "TJ | %3~";
    const splash_enabled = !parsed.present("no-splash") and sys.env("TJ_NO_SPLASH") == null;
    const title_blink_ms = if (which == .new or which == .use) blk: {
        const configured = try parseTitleBlink(parsed.last("title-blink").?);
        if (std.mem.eql(u8, title, "none")) {
            break :blk 0;
        }
        break :blk configured;
    } else 0;
    switch (which) {
        .new => {
            const result = try proxy.run(gpa, io, .{
                .journal = .{ .new = if (parsed.positionals.items.len == 0) null else parsed.positionals.items[0] },
                .argv = child,
                .keep_osc = parsed.present("keep-osc"),
                .splash = splash_enabled,
                .title = title,
                .title_blink_ms = title_blink_ms,
                .home = home,
            });
            return result.exit_code;
        },
        .use => {
            const result = try proxy.run(gpa, io, .{
                .journal = .{ .existing = parsed.positionals.items[0] },
                .argv = child,
                .keep_osc = parsed.present("keep-osc"),
                .replay_before_start = !parsed.present("no-replay"),
                .splash = splash_enabled,
                .title = title,
                .title_blink_ms = title_blink_ms,
                .home = home,
            });
            return result.exit_code;
        },
        .ls => try cmd_history.listJournals(gpa, io, home, out),
        .mv => {
            if (sys.env("TJ_JOURNAL")) |current| if (current.len != 0) return error.InsideJournalRename;
            var root = try store.openRoot(io, home);
            defer root.close(io);
            try store.renameJournal(gpa, io, root, parsed.positionals.items[0], parsed.positionals.items[1]);
        },
        .rm => try cmd_remove.removeJournal(gpa, io, home, parsed.positionals.items[0], parsed.present("force"), out),
        .du => try cmd_history.usageJournal(
            gpa,
            io,
            home,
            if (parsed.positionals.items.len == 0) null else parsed.positionals.items[0],
            parsed,
            out,
        ),
        .replay => try cmd_replay.replayJournal(gpa, io, home, parsed, out),
        .current => try out.print("{s}\n", .{sys.env("TJ_JOURNAL") orelse return error.NotInJournal}),
        .complete => try completeJournals(gpa, io, home, if (parsed.positionals.items.len == 0) "" else parsed.positionals.items[0], out),
    }
    return 0;
}

fn parseTitleBlink(text: []const u8) !u32 {
    const millis = std.fmt.parseInt(u32, text, 10) catch return error.BadTitleBlink;
    if (millis > @as(u32, std.math.maxInt(i32))) return error.BadTitleBlink;
    return millis;
}

test "title blink intervals accept zero and fit poll timeouts" {
    try std.testing.expectEqual(@as(u32, 0), try parseTitleBlink("0"));
    try std.testing.expectEqual(@as(u32, 1500), try parseTitleBlink("1500"));
    try std.testing.expectError(error.BadTitleBlink, parseTitleBlink("fast"));
    try std.testing.expectError(error.BadTitleBlink, parseTitleBlink("2147483648"));
}

fn completeJournals(gpa: std.mem.Allocator, io: Io, home: ?[]const u8, prefix: []const u8, out: *Io.Writer) !void {
    var root = store.openRoot(io, home) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer root.close(io);
    const journals = try store.listJournals(gpa, io, root);
    defer {
        for (journals) |name| gpa.free(name);
        gpa.free(journals);
    }
    for (journals) |name| {
        if (prefix.len == 0 or std.mem.startsWith(u8, name, prefix)) {
            try out.print("{s}\n", .{name});
        }
    }
}
