//! Journals that recorded nothing, and the errors that say so.

const std = @import("std");
const posix = std.posix;
const harness = @import("harness.zig");
const noout = @import("noout.zig");
const plain = @import("plain.zig");
const ulid = @import("ulid.zig");

const options = @import("build_options");
const tj = options.tj_exe;
const support = @import("it_support.zig");

test "legacy and corrupt journal metadata fail with explicit diagnostics" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var scratch = try support.Scratch.open();
    defer scratch.close();

    const legacy = ulid.encode(37, .{2} ** 10);
    const corrupt = ulid.encode(38, .{3} ** 10);
    try scratch.makeJournal(legacy, &.{"1"});
    try scratch.makeJournal(corrupt, &.{"1"});
    var legacy_dir = try scratch.tmp.dir.openDir(io, &legacy, .{});
    defer legacy_dir.close(io);
    try legacy_dir.writeFile(io, .{ .sub_path = "annotations.json", .data = "{}\n" });
    var corrupt_dir = try scratch.tmp.dir.openDir(io, &corrupt, .{});
    defer corrupt_dir.close(io);
    try corrupt_dir.writeFile(io, .{ .sub_path = "journal.sqlite3", .data = "not sqlite" });

    for ([_]struct { id: ulid.Ulid, diagnostic: []const u8 }{
        .{ .id = legacy, .diagnostic = "legacy annotations.json is unsupported" },
        .{ .id = corrupt, .diagnostic = "invalid or incompatible journal.sqlite3" },
    }) |case| {
        const result = try support.runNonTtyInJournal(gpa, &.{ "--home", scratch.path(), "name" }, &case.id, "2");
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        try std.testing.expectEqual(@as(u8, 1), result.term.exited);
        try std.testing.expectEqualStrings("", result.stdout);
        try std.testing.expect(std.mem.indexOf(u8, result.stderr, case.diagnostic) != null);
    }
}

test "usage sums logical journal bytes and charts every entry in number order" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var scratch = try support.Scratch.open();
    defer scratch.close();

    const id = ulid.encode(39, .{1} ** 10);
    try scratch.makeJournal(id, &.{ "1", "3", "10" });
    var journal = try scratch.tmp.dir.openDir(io, &id, .{});
    defer journal.close(io);

    try journal.writeFile(io, .{ .sub_path = "journal.sqlite3", .data = &([_]u8{'a'} ** 100) });
    try journal.writeFile(io, .{ .sub_path = "journal.sqlite3-wal", .data = &([_]u8{'w'} ** 11) });
    try journal.writeFile(io, .{ .sub_path = "journal.sqlite3-shm", .data = &([_]u8{'s'} ** 13) });
    try journal.writeFile(io, .{ .sub_path = "log", .data = &([_]u8{'l'} ** 105) });

    var one = try journal.openDir(io, "1", .{});
    defer one.close(io);
    try one.writeFile(io, .{ .sub_path = "cmd", .data = "cmd" });
    try one.createDir(io, "files", @enumFromInt(0o700));
    var files = try one.openDir(io, "files", .{});
    defer files.close(io);
    try files.writeFile(io, .{ .sub_path = "blob", .data = &([_]u8{'x'} ** 1021) });

    var three = try journal.openDir(io, "3", .{});
    defer three.close(io);
    try three.writeFile(io, .{ .sub_path = "cmd", .data = "four" });
    try three.writeFile(io, .{ .sub_path = "out", .data = &([_]u8{'y'} ** 2044) });

    const total = try support.runNonTtyInJournal(gpa, &.{ "--home", scratch.path(), "usage" }, &id, "11");
    defer gpa.free(total.stdout);
    defer gpa.free(total.stderr);
    try std.testing.expectEqual(@as(u8, 0), total.term.exited);
    try std.testing.expectEqualStrings("3.2k\n", total.stdout);
    try std.testing.expectEqualStrings("", total.stderr);

    const bytes = try support.runNonTtyInJournal(gpa, &.{ "--home", scratch.path(), "usage", "--bytes" }, &id, "11");
    defer gpa.free(bytes.stdout);
    defer gpa.free(bytes.stderr);
    try std.testing.expectEqual(@as(u8, 0), bytes.term.exited);
    try std.testing.expectEqualStrings("@1 1024\n@3 2048\n@10 0\n", bytes.stdout);
    try std.testing.expectEqualStrings("", bytes.stderr);

    const chart = try support.runNonTtyInJournal(gpa, &.{ "--home", scratch.path(), "usage", "--chart" }, &id, "11");
    defer gpa.free(chart.stdout);
    defer gpa.free(chart.stderr);
    try std.testing.expectEqual(@as(u8, 0), chart.term.exited);
    try std.testing.expect(std.mem.startsWith(u8, chart.stdout, "Total 3.2k\n\nEntry Size Chart\n"));
    const one_at = std.mem.indexOf(u8, chart.stdout, " @1 1.0k ") orelse return error.TestUnexpectedResult;
    const three_at = std.mem.indexOf(u8, chart.stdout, " @3 2.0k ") orelse return error.TestUnexpectedResult;
    const ten_at = std.mem.indexOf(u8, chart.stdout, "@10   0b\n") orelse return error.TestUnexpectedResult;
    try std.testing.expect(one_at < three_at and three_at < ten_at);
    try std.testing.expectEqual(@as(usize, 107), std.mem.count(u8, chart.stdout, "█"));
    try std.testing.expect(std.mem.indexOfScalar(u8, chart.stdout, 0x1b) == null);
    try std.testing.expectEqualStrings("", chart.stderr);

    const exact_chart = try support.runNonTtyInJournal(
        gpa,
        &.{ "--home", scratch.path(), "usage", "--chart", "--bytes" },
        &id,
        "11",
    );
    defer gpa.free(exact_chart.stdout);
    defer gpa.free(exact_chart.stderr);
    try std.testing.expectEqual(@as(u8, 0), exact_chart.term.exited);
    try std.testing.expect(std.mem.startsWith(u8, exact_chart.stdout, "Total 3301\n\nEntry Size Chart\n"));
    try std.testing.expect(std.mem.indexOf(u8, exact_chart.stdout, " @1 1024 ") != null);
    try std.testing.expect(std.mem.indexOf(u8, exact_chart.stdout, " @3 2048 ") != null);
    try std.testing.expect(std.mem.indexOf(u8, exact_chart.stdout, "@10    0\n") != null);
    try std.testing.expectEqual(@as(usize, 107), std.mem.count(u8, exact_chart.stdout, "█"));
    try std.testing.expectEqualStrings("", exact_chart.stderr);

    var id_buf: [id.len + 1]u8 = undefined;
    @memcpy(id_buf[0..id.len], &id);
    id_buf[id.len] = 0;
    support.sys.setEnv("TJ_JOURNAL", id_buf[0..id.len :0]);
    defer support.leaveJournal();
    const terminal_child = try support.spawnTj(gpa, &.{
        "/usr/bin/env", "-u",           "NO_COLOR", "TERM=xterm-256color", support.tj,
        "--home",       scratch.path(), "usage",    "--chart",
    }, 24, 40);
    var terminal: std.ArrayList(u8) = .empty;
    defer terminal.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), try terminal_child.finish(gpa, &terminal, support.timeout_ms));
    try std.testing.expect(std.mem.indexOf(u8, terminal.items, noout.begin_marker) != null);
    try std.testing.expect(std.mem.indexOf(u8, terminal.items, noout.end_marker) != null);
    try std.testing.expect(std.mem.indexOf(u8, terminal.items, "\x1b[33m@1\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, terminal.items, "\x1b[32m1.0k\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, terminal.items, "\x1b[34m") == null);
    try std.testing.expectEqual(@as(usize, 47), std.mem.count(u8, terminal.items, "█"));
}

test "a new journal that recorded nothing leaves nothing behind" {
    const gpa = std.testing.allocator;

    var scratch = try support.Scratch.open();
    defer scratch.close();

    // /bin/sh loads no support.tj integration, so no command boundaries are ever
    // reported and the new journal records nothing.
    var r = try support.run(gpa, &.{ "--home", scratch.path(), "new", "--", "/bin/sh", "-c", "true" }, 24, 80);
    defer r.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), r.code);

    try std.testing.expectEqual(@as(usize, 0), try scratch.journals());
}

test "new and continue leave child help flags after the argv boundary" {
    const gpa = std.testing.allocator;
    var scratch = try support.Scratch.open();
    defer scratch.close();

    var created = try support.run(gpa, &.{
        "--home",                          scratch.path(), "new",    "--", "/bin/sh", "-c",
        "printf 'NEW-CHILD:%s\\n' \"$1\"", "sh",           "--help",
    }, 24, 80);
    defer created.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), created.code);
    try std.testing.expect(std.mem.indexOf(u8, created.out.items, "NEW-CHILD:--help") != null);

    const id = ulid.encode(40, .{2} ** 10);
    try scratch.makeJournal(id, &.{});
    var continued = try support.run(gpa, &.{
        "--home",                               scratch.path(), "continue", &id, "--", "/bin/sh", "-c",
        "printf 'CONTINUE-CHILD:%s\\n' \"$1\"", "sh",           "--help",
    }, 24, 80);
    defer continued.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), continued.code);
    try std.testing.expect(std.mem.indexOf(u8, continued.out.items, "CONTINUE-CHILD:--help") != null);
}

test "a new journal that recorded something is kept" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try support.Journal.open(gpa);
    defer journal.close();
    try support.recordJournal(gpa, &journal, &.{"echo kept"});

    const cmd = try journal.read(gpa, "1/cmd");
    defer gpa.free(cmd);
    try std.testing.expectEqualStrings("echo kept", cmd);
}

test "a new journal that could not record but said why is kept" {
    const gpa = std.testing.allocator;

    var scratch = try support.Scratch.open();
    defer scratch.close();

    // A malformed support.tj sequence: no interaction is opened, but the journal log
    // records that something was ignored, and that is worth keeping.
    var r = try support.run(gpa, &.{
        "--home",                                scratch.path(),
        "new",                                   "--",
        "/bin/sh",                               "-c",
        "printf '\\033]5107;tj;bogus\\033\\\\'",
    }, 24, 80);
    defer r.out.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), try scratch.journals());
}

test "continue rejects missing ambiguous and full journals before exec" {
    const gpa = std.testing.allocator;
    var scratch = try support.Scratch.open();
    defer scratch.close();

    const first = ulid.encode(30, .{0} ** 10);
    const second = ulid.encode(31, .{0} ** 10);
    const full = ulid.encode(32, .{1} ** 10);
    try scratch.makeJournal(first, &.{});
    try scratch.makeJournal(second, &.{});
    try scratch.makeJournal(full, &.{"4294967295"});

    var missing = try support.run(gpa, &.{ "--home", scratch.path(), "continue", "does-not-exist", "--", "/bin/sh", "-c", "echo CHILD-RAN" }, 24, 80);
    defer missing.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), missing.code);
    try std.testing.expect(std.mem.indexOf(u8, missing.out.items, "no journal matches") != null);
    try std.testing.expect(std.mem.indexOf(u8, missing.out.items, "CHILD-RAN") == null);

    var ambiguous = try support.run(gpa, &.{ "--home", scratch.path(), "continue", "0000", "--", "/bin/sh", "-c", "echo CHILD-RAN" }, 24, 80);
    defer ambiguous.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), ambiguous.code);
    try std.testing.expect(std.mem.indexOf(u8, ambiguous.out.items, "suffix is ambiguous") != null);
    try std.testing.expect(std.mem.indexOf(u8, ambiguous.out.items, "CHILD-RAN") == null);

    var exhausted = try support.run(gpa, &.{ "--home", scratch.path(), "continue", &full, "--", "/bin/sh", "-c", "echo CHILD-RAN" }, 24, 80);
    defer exhausted.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), exhausted.code);
    try std.testing.expect(std.mem.indexOf(u8, exhausted.out.items, "no entry numbers left") != null);
    try std.testing.expect(std.mem.indexOf(u8, exhausted.out.items, "CHILD-RAN") == null);
}

test "an empty continue preserves its journal" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var scratch = try support.Scratch.open();
    defer scratch.close();

    const id = ulid.encode(40, .{2} ** 10);
    try scratch.makeJournal(id, &.{});
    var r = try support.run(gpa, &.{ "--home", scratch.path(), "continue", id[id.len - 6 ..], "--", "/bin/sh", "-c", "true" }, 24, 80);
    defer r.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), r.code);
    var dir = try scratch.tmp.dir.openDir(io, &id, .{});
    dir.close(io);
}

test "continue replays the journal immediately unless no-replay is set" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var scratch = try support.Scratch.open();
    defer scratch.close();

    const id = ulid.encode(45, .{2} ** 10);
    try scratch.makeJournal(id, &.{ "1", "2", "3" });
    var journal = try scratch.tmp.dir.openDir(io, &id, .{});
    defer journal.close(io);

    const entries = [_]struct {
        number: []const u8,
        command: []const u8,
        output: []const u8,
        meta: []const u8,
    }{
        .{ .number = "1", .command = "first-command", .output = "\x1b]11;?\x1b\\\x1b[6nREPLAY-FIRST\r\n", .meta = "{\"started\":\"2026-01-01T00:00:00.000Z\",\"ended\":\"2026-01-01T01:00:00.000Z\"}\n" },
        .{ .number = "2", .command = "second-command", .output = "REPLAY-SECOND\r\n", .meta = "{\"started\":\"2026-01-02T00:00:00.000Z\",\"ended\":\"2026-01-02T01:00:00.000Z\"}\n" },
        .{ .number = "3", .command = "third-command", .output = "REPLAY-THIRD\r\n", .meta = "{\"started\":\"2026-01-03T00:00:00.000Z\",\"ended\":\"2026-01-03T01:00:00.000Z\"}\n" },
    };
    for (entries) |entry| {
        var dir = try journal.openDir(io, entry.number, .{});
        defer dir.close(io);
        try dir.writeFile(io, .{ .sub_path = "cmd", .data = entry.command });
        try dir.writeFile(io, .{ .sub_path = "out", .data = entry.output });
        try dir.writeFile(io, .{ .sub_path = "meta.json", .data = entry.meta });
        if (std.mem.eql(u8, entry.number, "1")) {
            try dir.writeFile(io, .{ .sub_path = "prompt", .data = "CONTINUE-CAPTURED> " });
        }
    }

    // The recorded hour-long commands and day-long gaps must not delay
    // continuation. Its transcript appears before the fresh child output.
    var replayed = try support.run(gpa, &.{
        "--home", scratch.path(), "continue", &id, "--", "/bin/sh", "-c", "printf 'FRESH-CHILD\\n'",
    }, 24, 80);
    defer replayed.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), replayed.code);
    const first = std.mem.indexOf(u8, replayed.out.items, "REPLAY-FIRST") orelse return error.TestUnexpectedResult;
    const first_prompt = std.mem.indexOf(u8, replayed.out.items, "CONTINUE-CAPTURED> first-command") orelse return error.TestUnexpectedResult;
    const third = std.mem.indexOf(u8, replayed.out.items, "REPLAY-THIRD") orelse return error.TestUnexpectedResult;
    const child = std.mem.indexOf(u8, replayed.out.items, "FRESH-CHILD") orelse return error.TestUnexpectedResult;
    try std.testing.expect(first_prompt < first);
    try std.testing.expect(first < third);
    try std.testing.expect(third < child);
    try std.testing.expect(std.mem.indexOf(u8, replayed.out.items, "\x1b]11;?") == null);
    try std.testing.expect(std.mem.indexOf(u8, replayed.out.items, "\x1b[6n") == null);

    var skipped = try support.run(gpa, &.{
        "--home", scratch.path(), "continue", "--no-replay", &id, "--", "/bin/sh", "-c", "printf 'NO-REPLAY-CHILD\\n'",
    }, 24, 80);
    defer skipped.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), skipped.code);
    try std.testing.expect(std.mem.indexOf(u8, skipped.out.items, "NO-REPLAY-CHILD") != null);
    try std.testing.expect(std.mem.indexOf(u8, skipped.out.items, "REPLAY-FIRST") == null);
    try std.testing.expect(std.mem.indexOf(u8, skipped.out.items, "first-command") == null);
}

test "only one process writes a journal and descendants do not retain its lock" {
    const gpa = std.testing.allocator;
    var scratch = try support.Scratch.open();
    defer scratch.close();

    const id = ulid.encode(50, .{3} ** 10);
    try scratch.makeJournal(id, &.{"1"});
    const holder = try support.spawnTj(gpa, &.{ support.tj, "--home", scratch.path(), "continue", &id, "--", "/bin/sh", "-c", "echo LOCK-READY; sleep 30" }, 24, 80);
    var holder_out: std.ArrayList(u8) = .empty;
    defer holder_out.deinit(gpa);
    try std.testing.expect(try holder.readUntil(gpa, &holder_out, "LOCK-READY", support.timeout_ms));

    var blocked = try support.run(gpa, &.{ "--home", scratch.path(), "continue", &id, "--", "/bin/sh", "-c", "echo SECOND-RAN" }, 24, 80);
    defer blocked.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), blocked.code);
    try std.testing.expect(std.mem.indexOf(u8, blocked.out.items, "already being written") != null);
    try std.testing.expect(std.mem.indexOf(u8, blocked.out.items, "SECOND-RAN") == null);

    _ = std.c.kill(holder.pid, posix.SIG.TERM);
    _ = try holder.finish(gpa, &holder_out, support.timeout_ms);

    var background = try support.run(gpa, &.{ "--home", scratch.path(), "continue", &id, "--", "/bin/sh", "-c", "(sleep 3) </dev/null >/dev/null 2>&1 &" }, 24, 80);
    defer background.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), background.code);

    var after = try support.run(gpa, &.{ "--home", scratch.path(), "continue", &id, "--", "/bin/sh", "-c", "true" }, 24, 80);
    defer after.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), after.code);
}

test "continue starts from the caller state instead of restoring writer state" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var scratch = try support.Scratch.open();
    defer scratch.close();

    const id = ulid.encode(60, .{4} ** 10);
    try scratch.makeJournal(id, &.{});
    var prior = try support.run(gpa, &.{ "--home", scratch.path(), "continue", &id, "--", "/bin/zsh", "-f", "-c", "cd /; export PRIOR_WRITER_STATE=secret; setopt extendedglob; prior_fn() { :; }; sleep 2 </dev/null >/dev/null 2>&1 &" }, 24, 80);
    defer prior.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), prior.code);

    var fresh = try support.run(gpa, &.{ "--home", scratch.path(), "continue", &id, "--", "/bin/zsh", "-f", "-c", "printf 'PWD=%s PRIOR=%s OPT=%s FUNC=%s JOBS=%s\\n' \"$PWD\" \"${PRIOR_WRITER_STATE-unset}\" \"${options[extendedglob]}\" \"${+functions[prior_fn]}\" \"${#jobstates}\"" }, 24, 80);
    defer fresh.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), fresh.code);
    try std.testing.expect(std.mem.indexOf(u8, fresh.out.items, "PRIOR=unset") != null);
    try std.testing.expect(std.mem.indexOf(u8, fresh.out.items, "OPT=off FUNC=0 JOBS=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, fresh.out.items, "PWD=/ PR") == null);
}
