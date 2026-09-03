//! Full-screen programs and reading recorded resources back.

const std = @import("std");
const posix = std.posix;
const plain = @import("plain.zig");

const options = @import("build_options");
const tj = options.tj_exe;
const support = @import("it_support.zig");

test "a full-screen program leaves nothing in the journal" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try support.Journal.open(gpa);
    defer journal.close();

    // The sequences a pager or editor sends, without the unpredictability of
    // driving a real one.
    try support.recordJournal(gpa, &journal, &.{
        "printf 'BEFORE\\n\\033[?1049hHIDDEN-PAINTING\\033[?1049lAFTER\\n'",
    });

    const out = try journal.read(gpa, "1/out");
    defer gpa.free(out);

    // What the terminal keeps in scrollback is kept; the rest is not.
    try std.testing.expect(std.mem.indexOf(u8, out, "BEFORE") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "AFTER") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "HIDDEN-PAINTING") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "1049") == null);

    // A near-empty `out` should be explainable from the metadata alone.
    const meta = try journal.read(gpa, "1/meta.json");
    defer gpa.free(meta);
    try std.testing.expect(std.mem.indexOf(u8, meta, "\"fullscreen\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, meta, "\"regions\":1") != null);
}

test "the terminal still sees the full-screen program" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try support.Journal.open(gpa);
    defer journal.close();

    const child = try support.spawnJournalZsh(gpa, &journal);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    try support.setupJournalZsh(gpa, child, &out);
    const from = out.items.len;
    try child.write("printf '\\033[?1049hHIDDEN-PAINTING\\033[?1049l'\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, support.test_prompt, support.timeout_ms));
    try child.write("exit\n");
    try std.testing.expectEqual(@as(u8, 0), try child.finish(gpa, &out, support.timeout_ms));

    // Filtering applies to the journal only: the program must render exactly
    // as it would without support.tj.
    try std.testing.expect(std.mem.indexOf(u8, out.items, "HIDDEN-PAINTING") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[?1049h") != null);
}

test "tj cat renders recorded output as readable text" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try support.Journal.open(gpa);
    defer journal.close();
    try support.recordJournal(gpa, &journal, &.{"printf '\\033[31mred\\033[0m\\r\\n10%%\\r100%% done\\r\\n'"});
    try journal.enter(gpa);

    const home = try journal.homeArg(gpa);
    defer gpa.free(home);
    const id = try journal.journalName(gpa);
    defer gpa.free(id);

    var rendered = try support.run(gpa, &.{ "--home", home, "cat", "--plain", "@1" }, 24, 80);
    defer rendered.out.deinit(gpa);

    // Colours gone, and only what survived the carriage returns.
    try std.testing.expect(std.mem.indexOf(u8, rendered.out.items, "red") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.out.items, "\x1b[31m") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.out.items, "100% done") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.out.items, "10%\r") == null);
}

test "tj cat --raw gives back exactly what was recorded" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try support.Journal.open(gpa);
    defer journal.close();
    try support.recordJournal(gpa, &journal, &.{"printf '\\033[31mred\\033[0m\\n'"});
    try journal.enter(gpa);

    const home = try journal.homeArg(gpa);
    defer gpa.free(home);

    var raw = try support.run(gpa, &.{ "--home", home, "cat", "--raw", "@1" }, 24, 80);
    defer raw.out.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, raw.out.items, "\x1b[31m") != null);
}

test "tj cat defaults to the output and reads other resources by name" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try support.Journal.open(gpa);
    defer journal.close();
    try support.recordJournal(gpa, &journal, &.{"echo marker-text"});
    try journal.enter(gpa);

    const home = try journal.homeArg(gpa);
    defer gpa.free(home);

    var output = try support.run(gpa, &.{ "--home", home, "cat", "@1" }, 24, 80);
    defer output.out.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, output.out.items, "marker-text") != null);

    var command = try support.run(gpa, &.{ "--home", home, "cat", "@1/cmd" }, 24, 80);
    defer command.out.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, command.out.items, "echo marker-text") != null);

    var missing = try support.run(gpa, &.{ "--home", home, "cat", "@1/nope" }, 24, 80);
    defer missing.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), missing.code);
}

test "tj cat takes a resolved path as well as the reference" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try support.Journal.open(gpa);
    defer journal.close();
    try support.recordJournal(gpa, &journal, &.{"echo path-or-ref"});
    try journal.enter(gpa);

    const home = try journal.homeArg(gpa);
    defer gpa.free(home);

    // The zsh integration resolves shorthand through `tj @1`; this is the
    // resulting path support.tj receives.
    var resolved = try support.run(gpa, &.{ "--home", home, "resolve", "@1" }, 24, 80);
    defer resolved.out.deinit(gpa);
    const path = std.mem.trim(u8, resolved.out.items, " \r\n");

    var by_path = try support.run(gpa, &.{ "--home", home, "cat", path }, 24, 80);
    defer by_path.out.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, by_path.out.items, "path-or-ref") != null);

    var by_ref = try support.run(gpa, &.{ "--home", home, "cat", "@1" }, 24, 80);
    defer by_ref.out.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, by_ref.out.items, "path-or-ref") != null);

    // A word shaped like a reference but invalid is still reported as one,
    // rather than being tried as a filename.
    var malformed = try support.run(gpa, &.{ "--home", home, "cat", "@0" }, 24, 80);
    defer malformed.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), malformed.code);
}

test "cat windows and replay stream output beyond sixty-four mibibytes" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const beyond_old_limit = 64 * 1024 * 1024 + 4096;

    var journal = try support.Journal.open(gpa);
    defer journal.close();
    try support.recordJournal(gpa, &journal, &.{"echo replace-this-output"});

    var selected_dir = try journal.journalDir();
    defer selected_dir.close(io);
    var file = try selected_dir.createFile(io, "1/out", .{});
    try file.writePositionalAll(io, "FIRST-LINE\n", 0);
    try file.setLength(io, beyond_old_limit);
    try file.writePositionalAll(io, "\nTAIL-A\nREPLAY-BEYOND-LIMIT\n", beyond_old_limit);
    file.close(io);

    try journal.enter(gpa);
    const home = try journal.homeArg(gpa);
    defer gpa.free(home);
    const replay_id = try journal.journalName(gpa);
    defer gpa.free(replay_id);

    var head = try support.run(gpa, &.{ "--home", home, "cat", "--raw", "--head", "1", "@1" }, 24, 80);
    defer head.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), head.code);
    try std.testing.expect(std.mem.indexOf(u8, head.out.items, "FIRST-LINE") != null);
    try std.testing.expect(std.mem.indexOf(u8, head.out.items, "REPLAY-BEYOND-LIMIT") == null);
    try std.testing.expect(std.mem.indexOf(u8, head.out.items, "showing 1 of 4 lines") != null);

    var tail = try support.run(gpa, &.{ "--home", home, "cat", "--plain", "--tail", "2", "@1" }, 24, 80);
    defer tail.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), tail.code);
    try std.testing.expect(std.mem.indexOf(u8, tail.out.items, "FIRST-LINE") == null);
    try std.testing.expect(std.mem.indexOf(u8, tail.out.items, "TAIL-A") != null);
    try std.testing.expect(std.mem.indexOf(u8, tail.out.items, "REPLAY-BEYOND-LIMIT") != null);
    try std.testing.expect(std.mem.indexOf(u8, tail.out.items, "showing 2 of 4 lines") != null);

    support.leaveJournal();
    const replay = try support.spawnTjctl(gpa, &.{
        support.tjctl, "--home", home, "replay", replay_id, "--typing", "0", "--max-pause", "0", "--prompt", "",
    }, 24, 80);
    var replayed = try support.finishKeepingTail(gpa, replay, 8192, 30_000);
    defer replayed.tail.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), replayed.code);
    try std.testing.expect(replayed.total > 64 * 1024 * 1024);
    try std.testing.expect(std.mem.indexOf(u8, replayed.tail.items, "REPLAY-BEYOND-LIMIT") != null);
}
