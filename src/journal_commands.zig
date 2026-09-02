//! Journal lifecycle and management commands owned by `tjctl`.

const std = @import("std");
const Io = std.Io;
const zecli = @import("zecli");
const posix = std.posix;

const cli = @import("tjctl_cli.zig");
const proxy = @import("proxy.zig");
const store = @import("store.zig");
const sys = @import("sys.zig");
const cmd_journal_report = @import("cmd_journal_report.zig");
const cmd_remove = @import("cmd_remove.zig");
const cmd_replay = @import("cmd_replay.zig");
const handoff = @import("handoff.zig");

pub fn run(
    gpa: std.mem.Allocator,
    io: Io,
    which: cli.CommandName,
    root_home: ?[]const u8,
    root_home_explicit: bool,
    child: []const [:0]const u8,
    parsed: *const zecli.Parsed,
    out: *Io.Writer,
) !u8 {
    const home = if (parsed.present("home")) parsed.last("home") else root_home orelse parsed.last("home");
    const title = parsed.last("title") orelse "TJ | %3~";
    const splash_enabled = !parsed.enabled("no-splash");
    const title_blink_ms = if (which == .new or which == .use) blk: {
        const configured = try parseTitleBlink(parsed.last("title-blink").?);
        if (std.mem.eql(u8, title, "none")) {
            break :blk 0;
        }
        break :blk configured;
    } else 0;
    // Lifecycle commands are the recovery point for a temporary writer killed
    // before it could finish. Entry commands deliberately never do this work.
    if (which != .save and which != .current) try store.sweepTemporaryJournals(gpa, io, home);
    switch (which) {
        .new => {
            const opts: proxy.Options = .{
                .journal = .{ .new = if (parsed.positionals.items.len == 0) null else parsed.positionals.items[0] },
                .argv = child,
                .keep_osc = parsed.enabled("keep-osc"),
                .splash = splash_enabled,
                .title = title,
                .title_blink_ms = title_blink_ms,
                .home = home,
                .temporary = parsed.enabled("temp"),
            };
            if (insideWriter()) {
                if (!sys.envPresent("TJ_SHELL_HANDOFF")) return error.UseShellHandoff;
                return emitHandoff(gpa, io, .new, parsed, root_home_explicit, child, title, title_blink_ms, opts, out);
            }
            return (try proxy.run(gpa, io, opts)).exit_code;
        },
        .save => return saveTemporary(),
        .use => {
            const opts: proxy.Options = .{
                .journal = .{ .existing = parsed.positionals.items[0] },
                .argv = child,
                .keep_osc = parsed.enabled("keep-osc"),
                .replay_before_start = !parsed.enabled("no-replay"),
                .splash = splash_enabled,
                .title = title,
                .title_blink_ms = title_blink_ms,
                .home = home,
            };
            if (insideWriter()) {
                if (!sys.envPresent("TJ_SHELL_HANDOFF")) return error.UseShellHandoff;
                return emitHandoff(gpa, io, .use, parsed, root_home_explicit, child, title, title_blink_ms, opts, out);
            }
            return (try proxy.run(gpa, io, opts)).exit_code;
        },
        .ls => try cmd_journal_report.listJournals(gpa, io, home, parsed.enabled("long"), parsed.last("number"), out),
        .mv => {
            if (sys.env("TJ_JOURNAL")) |current| if (current.len != 0) return error.InsideJournalRename;
            var root = try store.openRoot(io, home);
            defer root.close(io);
            try store.renameJournal(gpa, io, root, parsed.positionals.items[0], parsed.positionals.items[1]);
        },
        .rm => try cmd_remove.removeJournal(gpa, io, home, parsed.positionals.items[0], parsed.enabled("force"), out),
        .du => try cmd_journal_report.usageJournal(
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

fn insideWriter() bool {
    return sys.env("TJ_JOURNAL") != null;
}

fn emitHandoff(
    gpa: std.mem.Allocator,
    io: Io,
    operation: handoff.Operation,
    parsed: *const zecli.Parsed,
    root_home_explicit: bool,
    child: []const [:0]const u8,
    title: []const u8,
    title_blink_ms: u32,
    opts: proxy.Options,
    out: *Io.Writer,
) !u8 {
    if (sys.env("TMUX") != null or sys.env("STY") != null) return error.InsideMultiplexer;
    if (root_home_explicit or parsed.present("home")) return error.InsideJournalHandoffOptions;
    if (child.len != 0) return error.InsideJournalHandoffOptions;
    const requested_selector = switch (opts.journal) {
        .new => |name| name orelse "",
        .existing => |name| name,
    };
    if (operation == .use) if (sys.env("TJ_JOURNAL")) |current| {
        if (std.mem.eql(u8, requested_selector, current) or std.mem.endsWith(u8, current, requested_selector)) return error.CurrentJournal;
    };
    // Reject a bad, ambiguous, or locked target while the source shell is
    // still alive. The proxy repeats acquisition after it owns the handoff;
    // this short preflight keeps a failed request from terminating the source.
    var target = switch (opts.journal) {
        // This is only name selection and lock validation. Do not mark the
        // short-lived preflight journal temporary: closing it must leave the
        // target directory available for the proxy that owns the handoff.
        .new => |name| try store.Store.createNamedJournal(gpa, io, opts.home, name, false),
        .existing => |selector| try store.Store.continueJournal(gpa, io, opts.home, selector),
    };
    errdefer target.close();
    const selected = try gpa.dupe(u8, target.journalId());
    defer gpa.free(selected);
    const selected_next = target.next_number.?;
    // The proxy must acquire this same target while the helper waits for its
    // acknowledgement, so release the short-lived CLI preflight lock now.
    target.close();

    if (title.len > handoff.max_field or selected.len > handoff.max_field) return error.RequestTooLarge;
    var request: handoff.Request = .{
        .operation = operation,
        .keep_osc = opts.keep_osc,
        .replay_before_start = opts.replay_before_start,
        .splash = opts.splash,
        .temporary = opts.temporary,
        .title_blink_ms = title_blink_ms,
        .title_len = title.len,
        .selector_len = selected.len,
    };
    @memcpy(request.title[0..title.len], title);
    @memcpy(request.selector[0..selected.len], selected);
    var marker: [handoff.max_wire * 2]u8 = undefined;
    const text = try handoff.encode(&request, &marker);
    const flags: posix.O = .{ .ACCMODE = .WRONLY, .CLOEXEC = true };
    const tty_fd = posix.openatZ(posix.AT.FDCWD, "/dev/tty", flags, 0) catch return error.NoControllingTerminal;
    defer sys.close(tty_fd);
    try sys.writeAll(tty_fd, text);
    var reply: [1]u8 = undefined;
    const handoff_fd_text = sys.env("TJ_HANDOFF_FD") orelse return error.NotInJournal;
    const handoff_fd: sys.Fd = std.fmt.parseInt(sys.Fd, handoff_fd_text, 10) catch return error.NotInJournal;
    if (try sys.read(handoff_fd, &reply) != 1 or reply[0] != 0) return error.JournalLocked;
    try writeShellExport(out, "TJ_JOURNAL", selected);
    var next: [16]u8 = undefined;
    const next_text = try std.fmt.bufPrint(&next, "{d}", .{selected_next});
    try writeShellExport(out, "TJ_NEXT", next_text);
    try writeShellExport(out, "TJ_TITLE", title);
    var blink: [16]u8 = undefined;
    const blink_text = try std.fmt.bufPrint(&blink, "{d}", .{title_blink_ms});
    try writeShellExport(out, "TJ_TITLE_BLINK", blink_text);
    if (opts.temporary) {
        try writeShellExport(out, "TJ_TEMPORARY", "1");
    } else {
        try out.writeAll("unset TJ_TEMPORARY\n");
    }
    return 0;
}

fn saveTemporary() !u8 {
    if (!insideWriter() or !sys.envPresent("TJ_TEMPORARY")) return error.NotTemporaryJournal;
    const flags: posix.O = .{ .ACCMODE = .WRONLY, .CLOEXEC = true };
    const tty_fd = posix.openatZ(posix.AT.FDCWD, "/dev/tty", flags, 0) catch return error.NoControllingTerminal;
    defer sys.close(tty_fd);
    try sys.writeAll(tty_fd, "\x1b]3110;SAVE\x1b\\");
    var reply: [1]u8 = undefined;
    const fd_text = sys.env("TJ_HANDOFF_FD") orelse return error.NotTemporaryJournal;
    const fd: sys.Fd = std.fmt.parseInt(sys.Fd, fd_text, 10) catch return error.NotTemporaryJournal;
    if (try sys.read(fd, &reply) != 1 or reply[0] != 0) return error.NotTemporaryJournal;
    return 0;
}

fn writeShellExport(out: *Io.Writer, name: []const u8, value: []const u8) !void {
    try out.print("export {s}=", .{name});
    try out.writeByte('\'');
    for (value) |byte| {
        if (byte == '\'') try out.writeAll("'\\''") else try out.writeByte(byte);
    }
    try out.writeAll("'\n");
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
