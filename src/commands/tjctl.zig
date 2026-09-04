//! Journal lifecycle and management commands owned by `tjctl`.

const std = @import("std");
const Io = std.Io;
const zecli = @import("zecli");
const posix = std.posix;

const cli = @import("../cli/tjctl.zig");
const proxy = @import("../terminal/proxy.zig");
const store = @import("../journal/store.zig");
const sys = @import("../sys.zig");
const cmd_journal_report = @import("journal_report.zig");
const cmd_remove = @import("remove.zig");
const cmd_replay = @import("replay.zig");
const handoff = @import("../protocol/handoff.zig");

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
                return emitHandoff(gpa, io, .{
                    .operation = .new,
                    .selector = if (parsed.positionals.items.len == 0) null else parsed.positionals.items[0],
                    .temporary = parsed.enabled("temp"),
                }, parsed, root_home_explicit, child, out);
            }
            return (try proxy.run(gpa, io, opts)).exit_code;
        },
        .save => return saveTemporary(io),
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
                return emitHandoff(gpa, io, .{
                    .operation = .use,
                    .selector = parsed.positionals.items[0],
                    .replay_before_start = !parsed.enabled("no-replay"),
                }, parsed, root_home_explicit, child, out);
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

/// A handoff switches which journal the running writer records into, and
/// nothing else. It carries no proxy configuration, so `home`, the title
/// lifecycle, and the scanner mode all stay as the live writer set them.
const HandoffSpec = struct {
    operation: handoff.Operation,
    /// `use`: the required target selector. `new`: an optional requested name,
    /// null for a generated one.
    selector: ?[]const u8 = null,
    temporary: bool = false,
    replay_before_start: bool = false,
};

fn emitHandoff(
    gpa: std.mem.Allocator,
    io: Io,
    spec: HandoffSpec,
    parsed: *const zecli.Parsed,
    root_home_explicit: bool,
    child: []const [:0]const u8,
    out: *Io.Writer,
) !u8 {
    if (sys.env("TMUX") != null or sys.env("STY") != null) return error.InsideMultiplexer;
    // A handoff cannot reconfigure the writer, only move it. Options that
    // would only take effect when starting a fresh writer are refused here
    // rather than silently ignored.
    if (root_home_explicit or parsed.present("home") or child.len != 0) return error.InsideJournalHandoffOptions;
    for ([_][]const u8{ "keep-osc", "title", "title-blink", "no-splash" }) |flag| {
        if (parsed.present(flag)) return error.InsideJournalHandoffOptions;
    }
    var resolved_selector: ?[]u8 = null;
    defer if (resolved_selector) |selected| gpa.free(selected);
    const requested_selector = if (spec.operation == .use) blk: {
        var root = try store.openRoot(io, null);
        defer root.close(io);
        resolved_selector = try store.findUniqueJournal(gpa, io, root, spec.selector.?);
        if (sys.env("TJ_JOURNAL")) |current| {
            if (std.mem.eql(u8, resolved_selector.?, current)) return error.CurrentJournal;
        }
        break :blk resolved_selector.?;
    } else spec.selector orelse "";

    // A handoff refuses an explicit `--home`, so the target resolves against
    // the inherited root the live writer already uses (`TJ_HOME`, else ~/.tj).
    // Reject a bad, ambiguous, or locked target while the source shell is
    // still alive. The proxy repeats acquisition after it owns the handoff;
    // this short preflight keeps a failed request from terminating the source.
    var target = switch (spec.operation) {
        // This is only name selection and lock validation. Do not mark the
        // short-lived preflight journal temporary: closing it must leave the
        // target directory available for the proxy that owns the handoff.
        .new => try store.Store.createNamedJournal(gpa, io, null, spec.selector, false),
        .use => try store.Store.continueJournal(gpa, io, null, requested_selector),
    };
    var preflight_open = true;
    errdefer if (preflight_open) target.close();
    const selected = try gpa.dupe(u8, target.journalId());
    defer gpa.free(selected);
    const selected_next = target.next_number.?;
    // The proxy must acquire this same target while the helper waits for its
    // acknowledgement, so release the short-lived CLI preflight lock now.
    target.close();
    preflight_open = false;

    if (selected.len > handoff.max_field) return error.RequestTooLarge;
    // The proxy only honours requests carrying the writer's session token,
    // which reaches `tjctl` through the inherited environment.
    const session = sys.env("TJ_SESSION_ID") orelse return error.NotInJournal;
    if (session.len != handoff.session_len) return error.NotInJournal;
    var request: handoff.Request = .{
        .operation = spec.operation,
        .temporary = spec.temporary,
        .replay_before_start = spec.replay_before_start,
        .selector_len = selected.len,
    };
    @memcpy(&request.session, session);
    @memcpy(request.selector[0..selected.len], selected);
    var marker: [handoff.max_wire * 2]u8 = undefined;
    const text = try handoff.encode(&request, &marker);
    const flags: posix.O = .{ .ACCMODE = .WRONLY, .CLOEXEC = true };
    const tty_fd = posix.openatZ(posix.AT.FDCWD, "/dev/tty", flags, 0) catch return error.NoControllingTerminal;
    defer sys.close(io, tty_fd);
    try sys.writeAll(io, tty_fd, text);
    var reply: [1]u8 = undefined;
    const handoff_fd_text = sys.env("TJ_HANDOFF_FD") orelse return error.NotInJournal;
    const handoff_fd: sys.Fd = std.fmt.parseInt(sys.Fd, handoff_fd_text, 10) catch return error.NotInJournal;
    if (try sys.read(handoff_fd, &reply) != 1 or reply[0] != 0) return error.JournalLocked;
    // Only the journal identity changed; the title lifecycle and every other
    // proxy setting stay as the live writer established them.
    const fish_syntax = if (sys.env("TJ_SHELL_HANDOFF")) |shell|
        std.mem.eql(u8, shell, "fish")
    else
        false;
    try writeShellExport(out, "TJ_JOURNAL", selected, fish_syntax);
    var next: [16]u8 = undefined;
    const next_text = try std.fmt.bufPrint(&next, "{d}", .{selected_next});
    try writeShellExport(out, "TJ_NEXT", next_text, fish_syntax);
    if (spec.temporary) {
        try writeShellExport(out, "TJ_TEMPORARY", "1", fish_syntax);
    } else {
        try out.writeAll(if (fish_syntax) "set -e TJ_TEMPORARY\n" else "unset TJ_TEMPORARY\n");
    }
    return 0;
}

fn saveTemporary(io: Io) !u8 {
    if (!insideWriter() or !sys.envPresent("TJ_TEMPORARY")) return error.NotTemporaryJournal;
    const session = sys.env("TJ_SESSION_ID") orelse return error.NotTemporaryJournal;
    if (session.len != handoff.session_len) return error.NotTemporaryJournal;
    const flags: posix.O = .{ .ACCMODE = .WRONLY, .CLOEXEC = true };
    const tty_fd = posix.openatZ(posix.AT.FDCWD, "/dev/tty", flags, 0) catch return error.NoControllingTerminal;
    defer sys.close(io, tty_fd);
    var marker_buf: [handoff.session_len + 16]u8 = undefined;
    const marker = std.fmt.bufPrint(&marker_buf, "\x1b]3110;SAVE;{s}\x1b\\", .{session}) catch unreachable;
    try sys.writeAll(io, tty_fd, marker);
    var reply: [1]u8 = undefined;
    const fd_text = sys.env("TJ_HANDOFF_FD") orelse return error.NotTemporaryJournal;
    const fd: sys.Fd = std.fmt.parseInt(sys.Fd, fd_text, 10) catch return error.NotTemporaryJournal;
    if (try sys.read(fd, &reply) != 1 or reply[0] != 0) return error.NotTemporaryJournal;
    return 0;
}

fn writeShellExport(out: *Io.Writer, name: []const u8, value: []const u8, fish_syntax: bool) !void {
    if (fish_syntax) {
        try out.print("set -gx {s} '", .{name});
        for (value) |byte| {
            if (byte == '\'') try out.writeAll("\\'") else try out.writeByte(byte);
        }
        return out.writeAll("'\n");
    }
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
