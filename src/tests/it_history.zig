//! Entry annotations, history presentation, filtering, and ranges.

const std = @import("std");
const noout = @import("../protocol/noout.zig");
const report = @import("../presentation/report.zig");

const support = @import("it_support.zig");

// Annotations and history display.

test "names tags pins and tagged history use journal-local annotations" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try support.Journal.open(gpa);
    defer journal.close();
    try support.recordJournal(gpa, &journal, &.{ "echo first-entry", "false # second-entry" });
    try journal.enter(gpa);
    const home = try journal.homeArg(gpa);
    defer gpa.free(home);

    var named = try support.run(gpa, &.{ "--home", home, "name", "@1", "build-failure" }, 24, 100);
    defer named.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), named.code);

    var tagged = try support.run(gpa, &.{ "--home", home, "tag", "@1", "BUG", "parser", "bug" }, 24, 100);
    defer tagged.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), tagged.code);
    var second_tagged = try support.run(gpa, &.{ "--home", home, "tag", "@2", "bug" }, 24, 100);
    defer second_tagged.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), second_tagged.code);

    var pinned = try support.run(gpa, &.{ "--home", home, "pin", "@1" }, 24, 100);
    defer pinned.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), pinned.code);

    var names = try support.run(gpa, &.{ "--home", home, "name" }, 24, 100);
    defer names.out.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, names.out.items, "build-failure  @1") != null);

    var tags = try support.run(gpa, &.{ "--home", home, "tag", "@1" }, 24, 100);
    defer tags.out.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, tags.out.items, "@1  bug  parser") != null);

    var pins = try support.run(gpa, &.{ "--home", home, "pin" }, 24, 100);
    defer pins.out.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, pins.out.items, "@1") != null);

    var resolved = try support.run(gpa, &.{ "--home", home, "resolve", "@build-failure/out" }, 24, 100);
    defer resolved.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), resolved.code);
    try std.testing.expect(std.mem.indexOf(u8, resolved.out.items, "/1/out") != null);

    var completed = try support.run(gpa, &.{ "--home", home, "complete", "@build" }, 24, 100);
    defer completed.out.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, completed.out.items, "@build-failure") != null);

    var filtered = try support.run(gpa, &.{ "--home", home, "hist", "--tag", "bug", "--tag=parser" }, 24, 120);
    defer filtered.out.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, filtered.out.items, "first-entry") != null);
    try std.testing.expect(std.mem.indexOf(u8, filtered.out.items, "second-entry") == null);
    try std.testing.expect(std.mem.indexOf(u8, filtered.out.items, "@build-failure") != null);
    try std.testing.expect(std.mem.indexOf(u8, filtered.out.items, "*@#") != null);
    try std.testing.expect(std.mem.indexOf(u8, filtered.out.items, "#bug #parser") != null);
    try std.testing.expect(std.mem.indexOf(u8, filtered.out.items, "!1") == null);

    var history = try support.run(gpa, &.{ "--home", home, "hist" }, 24, 120);
    defer history.out.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, history.out.items, "false # second-entry") != null);
    try std.testing.expect(std.mem.indexOf(u8, history.out.items, "#bug") != null);
    try std.testing.expect(std.mem.indexOf(u8, history.out.items, "!1") != null);

    var pinned_hist = try support.run(gpa, &.{ "--home", home, "hist", "--pinned" }, 24, 120);
    defer pinned_hist.out.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, pinned_hist.out.items, "first-entry") != null);
    try std.testing.expect(std.mem.indexOf(u8, pinned_hist.out.items, "second-entry") == null);
    var pin_alias = try support.run(gpa, &.{ "--home", home, "hist", "--pin", "--tag", "bug" }, 24, 120);
    defer pin_alias.out.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, pin_alias.out.items, "first-entry") != null);
    try std.testing.expect(std.mem.indexOf(u8, pin_alias.out.items, "second-entry") == null);

    var duplicate = try support.run(gpa, &.{ "--home", home, "name", "@2", "build-failure" }, 24, 100);
    defer duplicate.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), duplicate.code);

    var untag = try support.run(gpa, &.{ "--home", home, "tag", "--remove", "@1", "missing", "parser" }, 24, 100);
    defer untag.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), untag.code);
    var unpin = try support.run(gpa, &.{ "--home", home, "pin", "--remove", "@1" }, 24, 100);
    defer unpin.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), unpin.code);
}

test "history wraps to terminal width and pipes remain one entry per line" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const command = "echo one two three four five six seven eight nine ten eleven twelve";

    var journal = try support.Journal.open(gpa);
    defer journal.close();
    try support.recordJournal(gpa, &journal, &.{command});
    try journal.enter(gpa);
    const home = try journal.homeArg(gpa);
    defer gpa.free(home);

    var wrapped = try support.run(gpa, &.{ "--home", home, "hist" }, 24, 48);
    defer wrapped.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), wrapped.code);
    const begin_at = std.mem.indexOf(u8, wrapped.out.items, noout.begin_marker) orelse return error.TestUnexpectedResult;
    const content_start = begin_at + noout.begin_marker.len;
    const end_at = std.mem.indexOfPos(u8, wrapped.out.items, content_start, noout.end_marker) orelse
        return error.TestUnexpectedResult;
    const visible = wrapped.out.items[content_start..end_at];
    try std.testing.expect(std.mem.indexOf(u8, visible, "\r\n") != null);
    var physical_lines = std.mem.splitScalar(u8, visible, '\n');
    while (physical_lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (line.len != 0) {
            const displayed = try report.sanitizeDisplayText(gpa, line);
            defer gpa.free(displayed);
            try std.testing.expect(displayed.len <= 48);
        }
    }

    var empty = try support.run(gpa, &.{ "--home", home, "hist", "--tag", "not-present" }, 24, 48);
    defer empty.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), empty.code);
    try std.testing.expect(std.mem.indexOf(u8, empty.out.items, noout.begin_marker) == null);

    const id = try journal.journalName(gpa);
    defer gpa.free(id);
    const piped = try support.runNonTtyInJournal(gpa, &.{ "--home", home, "hist" }, id, "3");
    defer gpa.free(piped.stdout);
    defer gpa.free(piped.stderr);
    try std.testing.expectEqual(@as(u8, 0), piped.term.exited);
    try std.testing.expect(std.mem.indexOf(u8, piped.stdout, command) != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, piped.stdout, 0x1b) == null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.countScalar(u8, piped.stdout, '\n'));
    try std.testing.expect(std.mem.indexOf(u8, piped.stdout, noout.begin_marker) == null);
}

test "terminal history omits its listing while piped history remains recordable" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var journal = try support.Journal.open(gpa);
    defer journal.close();

    const child = try support.spawnJournalZsh(gpa, &journal);
    var terminal = support.TerminalSession.init(gpa, child);
    defer terminal.deinit();
    const transcript = &terminal.transcript;
    try terminal.setupZsh("");

    var from = transcript.items.len;
    try terminal.write("printf 'HIST_NOOUT_PAYLOAD_012\\n'\n");
    try terminal.expectPromptFrom(from);

    from = transcript.items.len;
    try terminal.write("command \"$TJ\" hist\n");
    try terminal.expectFrom(from, "HIST_NOOUT_PAYLOAD_012");
    try terminal.expectPromptFrom(from);

    from = transcript.items.len;
    try terminal.write("command \"$TJ\" hist | cat\n");
    try terminal.expectFrom(from, "HIST_NOOUT_PAYLOAD_012");
    try terminal.expectPromptFrom(from);
    try terminal.write("exit 0\n");
    try std.testing.expectEqual(@as(u8, 0), try terminal.finish());

    const direct_out = try journal.read(gpa, "2/out");
    defer gpa.free(direct_out);
    try std.testing.expect(std.mem.indexOf(u8, direct_out, "<tj:noout>") != null);
    try std.testing.expect(std.mem.indexOf(u8, direct_out, "HIST_NOOUT_PAYLOAD_012") == null);
    try std.testing.expect(std.mem.indexOf(u8, direct_out, "3110;") == null);

    const piped_out = try journal.read(gpa, "3/out");
    defer gpa.free(piped_out);
    try std.testing.expect(std.mem.indexOf(u8, piped_out, "HIST_NOOUT_PAYLOAD_012") != null);
    try std.testing.expect(std.mem.indexOf(u8, piped_out, "<tj:noout>") == null);
    try std.testing.expect(std.mem.indexOf(u8, piped_out, "3110;") == null);
}

test "history shows positional annotation flags size UTC date and wrapped commands" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var journal = try support.Journal.open(gpa);
    defer journal.close();
    try support.recordJournal(gpa, &journal, &.{
        "printf 1234567890 # alpha beta gamma delta epsilon",
        "false",
    });
    try journal.enter(gpa);
    const home = try journal.homeArg(gpa);
    defer gpa.free(home);

    for ([_][]const []const u8{
        &.{ "name", "@1", "display-name" },
        &.{ "tag", "@1", "bug" },
        &.{ "pin", "@1" },
        &.{ "tag", "@2", "failure" },
    }) |command_args| {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.appendSlice(gpa, &.{ "--home", home });
        try argv.appendSlice(gpa, command_args);
        var result = try support.run(gpa, argv.items, 24, 100);
        defer result.out.deinit(gpa);
        try std.testing.expectEqual(@as(u8, 0), result.code);
    }

    var dir = try journal.journalDir();
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = "1/out", .data = "1234567890" });
    try dir.writeFile(io, .{ .sub_path = "2/out", .data = "" });
    try dir.writeFile(io, .{
        .sub_path = "1/meta.json",
        .data = "{\"v\":1,\"started\":\"2001-08-29T10:14:00.000Z\",\"ended\":\"2001-08-29T10:15:00.000Z\"}\n",
    });
    try dir.writeFile(io, .{
        .sub_path = "2/meta.json",
        .data = "{\"v\":1,\"started\":\"2002-03-14T09:00:00.000Z\",\"ended\":\"2002-03-14T09:01:00.000Z\"}\n",
    });

    const id = try journal.journalName(gpa);
    defer gpa.free(id);
    const plain_result = try support.runNonTtyInJournal(gpa, &.{ "--home", home, "hist" }, id, "4");
    defer gpa.free(plain_result.stdout);
    defer gpa.free(plain_result.stderr);
    try std.testing.expectEqual(@as(u8, 0), plain_result.term.exited);
    try std.testing.expect(std.mem.indexOf(u8, plain_result.stdout, "*@#  1   10b Aug 29  2001 printf 1234567890 # alpha beta gamma delta epsilon @display-name #bug\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain_result.stdout, "  #! 2    0b Mar 14  2002 false #failure !1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain_result.stdout, noout.begin_marker) == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, plain_result.stdout, 0x1b) == null);

    // Keep this child raw: the PTY-rendered byte stream itself is the subject,
    // not an interactive journal shell that needs setup or prompt handling.
    const terminal_child = try support.spawnTj(gpa, &.{
        "/usr/bin/env", "-u", "NO_COLOR", "TERM=xterm-256color", support.tj, "--home", home, "hist",
    }, 24, 48);
    var terminal: std.ArrayList(u8) = .empty;
    defer terminal.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), try terminal_child.finish(gpa, &terminal, support.timeout_ms));
    const begin_at = std.mem.indexOf(u8, terminal.items, noout.begin_marker) orelse return error.TestUnexpectedResult;
    const content_start = begin_at + noout.begin_marker.len;
    const end_at = std.mem.indexOfPos(u8, terminal.items, content_start, noout.end_marker) orelse
        return error.TestUnexpectedResult;
    const visible = terminal.items[content_start..end_at];
    try std.testing.expect(std.mem.indexOf(u8, visible, "*@#  \x1b[33m1\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, visible, "  #\x1b[31m!\x1b[0m \x1b[33m2\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, visible, "\x1b[33m1\x1b[0m   \x1b[32m10b\x1b[0m \x1b[34mAug 29  2001\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, visible, "\x1b[32m@display-name\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, visible, "\x1b[32m#bug\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, visible, "\x1b[31m!1\x1b[0m") != null);
    const first_wrap = std.mem.indexOf(u8, visible, "\r\n") orelse return error.TestUnexpectedResult;
    const continuation = first_wrap + 2;
    try std.testing.expect(visible.len >= continuation + 23);
    for (visible[continuation .. continuation + 23]) |byte| try std.testing.expectEqual(@as(u8, ' '), byte);

    const pinned = try support.runNonTtyInJournal(gpa, &.{ "--home", home, "hist", "--pinned" }, id, "4");
    defer gpa.free(pinned.stdout);
    defer gpa.free(pinned.stderr);
    try std.testing.expect(std.mem.indexOf(u8, pinned.stdout, "display-name") != null);
    try std.testing.expect(std.mem.indexOf(u8, pinned.stdout, "false") == null);

    // Columns are fixed rather than fitted to whatever a filter matched, so a
    // narrowed listing lines up with the full one instead of shifting left.
    const whole_line = "*@#  1   10b Aug 29  2001 printf";
    try std.testing.expect(std.mem.indexOf(u8, plain_result.stdout, whole_line) != null);
    for ([_][]const []const u8{
        &.{ "--home", home, "hist", "--pinned" },
        &.{ "--home", home, "hist", "@1" },
        &.{ "--home", home, "hist", "@1..@1" },
    }) |args| {
        const narrowed = try support.runNonTtyInJournal(gpa, args, id, "4");
        defer gpa.free(narrowed.stdout);
        defer gpa.free(narrowed.stderr);
        try std.testing.expect(std.mem.indexOf(u8, narrowed.stdout, whole_line) != null);
    }
}

test "history accepts ordered entry ranges and trailing-dot journal selectors" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var journal = try support.Journal.open(gpa);
    defer journal.close();
    try support.recordJournal(gpa, &journal, &.{
        "echo HIST_TARGET_ONE",
        "echo HIST_TARGET_TWO",
        "echo HIST_TARGET_THREE",
        "echo HIST_TARGET_FOUR",
    });
    try journal.enter(gpa);
    const home = try journal.homeArg(gpa);
    defer gpa.free(home);
    const id = try journal.journalName(gpa);
    defer gpa.free(id);

    var removed = try support.run(gpa, &.{ "--home", home, "rm", "@3" }, 24, 100);
    defer removed.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), removed.code);

    const selected = try support.runNonTtyInJournal(
        gpa,
        &.{ "--home", home, "hist", "@4", "@1..@3" },
        id,
        "5",
    );
    defer gpa.free(selected.stdout);
    defer gpa.free(selected.stderr);
    try std.testing.expectEqual(@as(u8, 0), selected.term.exited);
    const four_at = std.mem.indexOf(u8, selected.stdout, "HIST_TARGET_FOUR") orelse return error.TestUnexpectedResult;
    const one_at = std.mem.indexOf(u8, selected.stdout, "HIST_TARGET_ONE") orelse return error.TestUnexpectedResult;
    const two_at = std.mem.indexOf(u8, selected.stdout, "HIST_TARGET_TWO") orelse return error.TestUnexpectedResult;
    try std.testing.expect(four_at < one_at and one_at < two_at);
    try std.testing.expect(std.mem.indexOf(u8, selected.stdout, "HIST_TARGET_THREE") == null);

    const foreign = "release-build";
    var root = try journal.tmp.dir.openDir(io, support.journal_dir, .{});
    defer root.close(io);
    try root.createDir(io, foreign, @enumFromInt(0o700));
    var foreign_dir = try root.openDir(io, foreign, .{});
    defer foreign_dir.close(io);
    try foreign_dir.createDir(io, "1", @enumFromInt(0o700));
    var foreign_entry = try foreign_dir.openDir(io, "1", .{});
    defer foreign_entry.close(io);
    try foreign_entry.writeFile(io, .{ .sub_path = "cmd", .data = "echo HIST_TARGET_FOREIGN" });
    try foreign_entry.writeFile(io, .{ .sub_path = "out", .data = "HIST_TARGET_FOREIGN\n" });
    try foreign_entry.writeFile(io, .{ .sub_path = "rc", .data = "0\n" });

    const suffix = foreign[foreign.len - 4 ..];
    const journal_selector = try std.fmt.allocPrint(gpa, "@{s}.", .{suffix});
    defer gpa.free(journal_selector);
    const mixed = try support.runNonTtyInJournal(
        gpa,
        &.{ "--home", home, "hist", "@2", journal_selector, "@1" },
        id,
        "5",
    );
    defer gpa.free(mixed.stdout);
    defer gpa.free(mixed.stderr);
    try std.testing.expectEqual(@as(u8, 0), mixed.term.exited);
    const mixed_two = std.mem.indexOf(u8, mixed.stdout, "HIST_TARGET_TWO") orelse return error.TestUnexpectedResult;
    const mixed_foreign = std.mem.indexOf(u8, mixed.stdout, "HIST_TARGET_FOREIGN") orelse return error.TestUnexpectedResult;
    const mixed_one = std.mem.indexOf(u8, mixed.stdout, "HIST_TARGET_ONE") orelse return error.TestUnexpectedResult;
    try std.testing.expect(mixed_two < mixed_foreign and mixed_foreign < mixed_one);
    const qualified = try std.fmt.allocPrint(gpa, "@{s}.1", .{foreign});
    defer gpa.free(qualified);
    try std.testing.expect(std.mem.indexOf(u8, mixed.stdout, qualified) != null);

    const bare = try support.runNonTtyInJournal(gpa, &.{ "--home", home, "hist", suffix }, id, "5");
    defer gpa.free(bare.stdout);
    defer gpa.free(bare.stderr);
    try std.testing.expectEqual(@as(u8, 1), bare.term.exited);
    try std.testing.expect(std.mem.indexOf(u8, bare.stderr, "not a journal reference") != null);
}

test "tag pin and cat ranges are inclusive and skip numbering holes" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try support.Journal.open(gpa);
    defer journal.close();
    try support.recordJournal(gpa, &journal, &.{
        "echo RANGE_ONE",
        "echo RANGE_TWO",
        "echo RANGE_THREE",
        "echo RANGE_FOUR",
        "echo RANGE_FIVE",
    });
    try journal.enter(gpa);
    const home = try journal.homeArg(gpa);
    defer gpa.free(home);

    var hole = try support.run(gpa, &.{ "--home", home, "rm", "@3" }, 24, 100);
    defer hole.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), hole.code);

    var tagged = try support.run(gpa, &.{ "--home", home, "tag", "@2..@4", "BATCH", "extra" }, 24, 100);
    defer tagged.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), tagged.code);
    var queried = try support.run(gpa, &.{ "--home", home, "tag", "@2..@4" }, 24, 100);
    defer queried.out.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, queried.out.items, "@2  batch  extra") != null);
    try std.testing.expect(std.mem.indexOf(u8, queried.out.items, "@4  batch  extra") != null);
    try std.testing.expect(std.mem.indexOf(u8, queried.out.items, "@3") == null);

    var untagged = try support.run(gpa, &.{ "--home", home, "tag", "--remove", "@3..@4", "extra" }, 24, 100);
    defer untagged.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), untagged.code);
    var fourth_tags = try support.run(gpa, &.{ "--home", home, "tag", "@4" }, 24, 100);
    defer fourth_tags.out.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, fourth_tags.out.items, "@4  batch") != null);
    try std.testing.expect(std.mem.indexOf(u8, fourth_tags.out.items, "extra") == null);

    var pinned = try support.run(gpa, &.{ "--home", home, "pin", "@1..@4" }, 24, 100);
    defer pinned.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), pinned.code);
    var unpinned = try support.run(gpa, &.{ "--home", home, "pin", "--remove", "@2..@3" }, 24, 100);
    defer unpinned.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), unpinned.code);
    var pins = try support.run(gpa, &.{ "--home", home, "pin" }, 24, 100);
    defer pins.out.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, pins.out.items, "@1\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, pins.out.items, "@4\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, pins.out.items, "@2\r\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, pins.out.items, "@3\r\n") == null);

    var concatenated = try support.run(gpa, &.{ "--home", home, "cat", "--plain", "@2..@4" }, 24, 100);
    defer concatenated.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), concatenated.code);
    const second = std.mem.indexOf(u8, concatenated.out.items, "RANGE_TWO") orelse return error.TestUnexpectedResult;
    const fourth = std.mem.indexOf(u8, concatenated.out.items, "RANGE_FOUR") orelse return error.TestUnexpectedResult;
    try std.testing.expect(second < fourth);
    try std.testing.expect(std.mem.indexOf(u8, concatenated.out.items, "RANGE_THREE") == null);

    var empty = try support.run(gpa, &.{ "--home", home, "tag", "@20..@30", "missing" }, 24, 100);
    defer empty.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 2), empty.code);

    // A broad cat range inside the writer would otherwise read and append to
    // its own `out` indefinitely. Reject it before any resource is emitted.
    const id = try journal.journalName(gpa);
    defer gpa.free(id);
    const recursive = try support.runNonTtyInJournal(gpa, &.{ "--home", home, "cat", "@1..@999" }, id, "7");
    defer gpa.free(recursive.stdout);
    defer gpa.free(recursive.stderr);
    try std.testing.expectEqual(@as(u8, 1), recursive.term.exited);
    try std.testing.expectEqualStrings("", recursive.stdout);
    try std.testing.expect(std.mem.indexOf(u8, recursive.stderr, "currently running entry") != null);
}

test "tag accepts leading target lists before multiple tags" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var journal = try support.Journal.open(gpa);
    defer journal.close();
    try support.recordJournal(gpa, &journal, &.{
        "echo one",
        "echo two",
        "echo three",
        "echo four",
    });
    try journal.enter(gpa);
    const home = try journal.homeArg(gpa);
    defer gpa.free(home);
    const id = try journal.journalName(gpa);
    defer gpa.free(id);

    // Real zsh expands the first two shorthand references into journal paths;
    // the range remains @ syntax. Both forms must stay in the leading target
    // sequence, with BUG and parser recognized as tags.
    const child = try support.spawnContinuedJournalZsh(gpa, &journal, id);
    var terminal = support.TerminalSession.init(gpa, child);
    defer terminal.deinit();
    const transcript = &terminal.transcript;
    try terminal.setupZsh("");
    const from = transcript.items.len;
    try terminal.write("command \"$TJ\" tag @1 @2 @3..@4 BUG parser\n");
    try terminal.expectPromptFrom(from);
    try terminal.write("exit 0\n");
    try std.testing.expectEqual(@as(u8, 0), try terminal.finish());

    var queried = try support.run(gpa, &.{ "--home", home, "tag", "@1", "@2", "@3..@4" }, 24, 120);
    defer queried.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), queried.code);
    for (1..5) |number| {
        var expected_buf: [64]u8 = undefined;
        const expected = try std.fmt.bufPrint(&expected_buf, "@{d}  bug  parser", .{number});
        try std.testing.expect(std.mem.indexOf(u8, queried.out.items, expected) != null);
    }

    var removed = try support.run(gpa, &.{ "--home", home, "tag", "--remove", "@1", "@3..@4", "parser" }, 24, 120);
    defer removed.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), removed.code);
    var after = try support.run(gpa, &.{ "--home", home, "tag", "@1", "@2", "@3", "@4" }, 24, 120);
    defer after.out.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, after.out.items, "@1  bug\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, after.out.items, "@2  bug  parser") != null);
    try std.testing.expect(std.mem.indexOf(u8, after.out.items, "@3  bug\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, after.out.items, "@4  bug\r\n") != null);
}
