//! Entry and journal mutation semantics, including concurrency.

const std = @import("std");
const posix = std.posix;
const harness = @import("harness.zig");
const journal_name = @import("../journal_name.zig");

const support = @import("it_support.zig");

// Entry and journal mutation semantics.

test "entry mutations reject qualified journals while reads still work" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var journal = try support.Journal.open(gpa);
    defer journal.close();
    try support.recordJournal(gpa, &journal, &.{"echo current"});
    try journal.enter(gpa);
    const home = try journal.homeArg(gpa);
    defer gpa.free(home);

    const foreign = journal_name.legacy(999, .{7} ** 10);
    var root = try journal.tmp.dir.openDir(io, support.journal_dir, .{ .iterate = true });
    try root.createDir(io, &foreign, @enumFromInt(0o700));
    var foreign_dir = try root.openDir(io, &foreign, .{});
    try foreign_dir.createDir(io, "1", @enumFromInt(0o700));
    var interaction = try foreign_dir.openDir(io, "1", .{});
    try interaction.writeFile(io, .{ .sub_path = "cmd", .data = "foreign" });
    try interaction.writeFile(io, .{ .sub_path = "out", .data = "foreign-output\n" });
    try interaction.writeFile(io, .{ .sub_path = "rc", .data = "0\n" });
    try interaction.writeFile(io, .{ .sub_path = "meta.json", .data = "{\"v\":1}\n" });
    interaction.close(io);
    foreign_dir.close(io);
    root.close(io);

    const qualified = try std.fmt.allocPrint(gpa, "@{s}.1", .{foreign});
    defer gpa.free(qualified);
    var resolved = try support.run(gpa, &.{ "--home", home, "resolve", qualified }, 24, 100);
    defer resolved.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), resolved.code);

    for ([_][]const []const u8{
        &.{ "name", qualified, "forbidden" },
        &.{ "tag", qualified, "forbidden" },
        &.{ "pin", qualified },
        &.{ "rm", qualified },
    }) |command_args| {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.appendSlice(gpa, &.{ "--home", home });
        try argv.appendSlice(gpa, command_args);
        var result = try support.run(gpa, argv.items, 24, 100);
        defer result.out.deinit(gpa);
        try std.testing.expectEqual(@as(u8, 1), result.code);
    }

    var check_root = try journal.tmp.dir.openDir(io, support.journal_dir, .{});
    defer check_root.close(io);
    var annotations_path_buf: [64]u8 = undefined;
    const annotations_path = try std.fmt.bufPrint(&annotations_path_buf, "{s}/journal.sqlite3", .{foreign});
    try std.testing.expectError(error.FileNotFound, check_root.openFile(io, annotations_path, .{}));
    var interaction_path_buf: [64]u8 = undefined;
    const interaction_path = try std.fmt.bufPrint(&interaction_path_buf, "{s}/1", .{foreign});
    var still_there = try check_root.openDir(io, interaction_path, .{});
    still_there.close(io);
}

test "output and entry removal clean data without reusing numbers" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var journal = try support.Journal.open(gpa);
    defer journal.close();
    try support.recordJournal(gpa, &journal, &.{ "echo first", "echo second", "echo third" });
    try journal.enter(gpa);
    const home = try journal.homeArg(gpa);
    defer gpa.free(home);

    for ([_][]const []const u8{
        &.{ "name", "@1", "kept-name" },
        &.{ "name", "@2", "removed-name" },
        &.{ "tag", "@2", "old" },
        &.{ "pin", "@1" },
        &.{ "pin", "@2" },
    }) |command_args| {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.appendSlice(gpa, &.{ "--home", home });
        try argv.appendSlice(gpa, command_args);
        var result = try support.run(gpa, argv.items, 24, 100);
        defer result.out.deinit(gpa);
        try std.testing.expectEqual(@as(u8, 0), result.code);
    }

    // Pins protect both the complete interaction and output-only removal.
    var skipped_out = try support.run(gpa, &.{ "--home", home, "rm", "@1/out" }, 24, 100);
    defer skipped_out.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), skipped_out.code);
    try std.testing.expect(std.mem.indexOf(u8, skipped_out.out.items, "skipped pinned entry @1") != null);
    var skipped_interaction = try support.run(gpa, &.{ "--home", home, "rm", "@2" }, 24, 100);
    defer skipped_interaction.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), skipped_interaction.code);
    try std.testing.expect(std.mem.indexOf(u8, skipped_interaction.out.items, "skipped pinned entry @2") != null);

    var protected_dir = try journal.journalDir();
    var protected_out = try protected_dir.openFile(io, "1/out", .{});
    protected_out.close(io);
    var protected_two = try protected_dir.openDir(io, "2", .{});
    protected_two.close(io);
    protected_dir.close(io);

    for ([_][]const []const u8{
        &.{ "rm", "--force", "@1/out" },
        &.{ "rm", "--force", "@2" },
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
    try std.testing.expectError(error.FileNotFound, dir.openFile(io, "1/out", .{}));
    var cmd = try dir.openFile(io, "1/cmd", .{});
    cmd.close(io);
    var marker = try dir.openFile(io, "1/out.removed", .{});
    marker.close(io);
    try std.testing.expectError(error.FileNotFound, dir.openDir(io, "2", .{}));

    var names = try support.run(gpa, &.{ "--home", home, "name" }, 24, 100);
    defer names.out.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, names.out.items, "kept-name  @1") != null);
    try std.testing.expect(std.mem.indexOf(u8, names.out.items, "removed-name") == null);

    const id = try journal.journalName(gpa);
    defer gpa.free(id);
    const child = try support.spawnContinuedJournalZsh(gpa, &journal, id);
    var continued: std.ArrayList(u8) = .empty;
    defer continued.deinit(gpa);
    try support.setupJournalZsh(gpa, child, &continued);
    const from = continued.items.len;
    try child.write("echo after-hole\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &continued, from, support.test_prompt, support.timeout_ms));
    try child.write("exit 0\n");
    try std.testing.expectEqual(@as(u8, 0), try child.finish(gpa, &continued, support.timeout_ms));
    var after = try journal.journalDir();
    defer after.close(io);
    const next_cmd = try after.readFileAlloc(io, "5/cmd", gpa, .limited(4096));
    defer gpa.free(next_cmd);
    try std.testing.expectEqualStrings("echo after-hole", next_cmd);
}

test "entry ranges remove existing entries across holes and reject the running boundary" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var journal = try support.Journal.open(gpa);
    defer journal.close();
    try support.recordJournal(gpa, &journal, &.{
        "echo one",
        "echo two",
        "echo three",
        "echo four",
        "echo five",
    });
    try journal.enter(gpa);
    const home = try journal.homeArg(gpa);
    defer gpa.free(home);

    for ([_][]const []const u8{
        &.{ "name", "@2", "range-name" },
        &.{ "tag", "@3", "range-tag" },
        &.{ "pin", "@4" },
    }) |command_args| {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.appendSlice(gpa, &.{ "--home", home });
        try argv.appendSlice(gpa, command_args);
        var result = try support.run(gpa, argv.items, 24, 100);
        defer result.out.deinit(gpa);
        try std.testing.expectEqual(@as(u8, 0), result.code);
    }

    // support.recordJournal leaves its `exit` interaction as the protected highest
    // directory. A range containing it must fail before removing @2.
    var protected = try support.run(gpa, &.{ "--home", home, "rm", "@2..@6" }, 24, 120);
    defer protected.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), protected.code);
    try std.testing.expect(std.mem.indexOf(u8, protected.out.items, "currently running") != null);
    var before = try journal.journalDir();
    var still_two = try before.openDir(io, "2", .{});
    still_two.close(io);
    before.close(io);

    // Make a pre-existing hole inside the successful interval.
    var hole = try support.run(gpa, &.{ "--home", home, "rm", "@3" }, 24, 100);
    defer hole.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), hole.code);

    // Drive the range through real zsh. @4 is pinned, so the
    // ordinary range leaves it in place while removing the other members.
    const id = try journal.journalName(gpa);
    defer gpa.free(id);
    const child = try support.spawnContinuedJournalZsh(gpa, &journal, id);
    var transcript: std.ArrayList(u8) = .empty;
    defer transcript.deinit(gpa);
    try support.setupJournalZsh(gpa, child, &transcript);
    const from = transcript.items.len;
    try child.write("command \"$TJ\" rm @2..@5\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, support.test_prompt, support.timeout_ms));
    try child.write("exit 0\n");
    try std.testing.expectEqual(@as(u8, 0), try child.finish(gpa, &transcript, support.timeout_ms));

    var dir = try journal.journalDir();
    defer dir.close(io);
    for ([_][]const u8{ "2", "3", "5" }) |number| {
        try std.testing.expectError(error.FileNotFound, dir.openDir(io, number, .{}));
    }
    for ([_][]const u8{ "1", "4", "6", "7" }) |number| {
        var kept = try dir.openDir(io, number, .{});
        kept.close(io);
    }
    const range_cmd = try dir.readFileAlloc(io, "7/cmd", gpa, .limited(4096));
    defer gpa.free(range_cmd);
    try std.testing.expectEqualStrings("command \"$TJ\" rm @2..@5", range_cmd);

    var remaining_names = try support.run(gpa, &.{ "--home", home, "name" }, 24, 100);
    defer remaining_names.out.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, remaining_names.out.items, "range-name") == null);
    var remaining_tags = try support.run(gpa, &.{ "--home", home, "tag" }, 24, 100);
    defer remaining_tags.out.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, remaining_tags.out.items, "range-tag") == null);
    var remaining_pins = try support.run(gpa, &.{ "--home", home, "pin" }, 24, 100);
    defer remaining_pins.out.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, remaining_pins.out.items, "@4") != null);

    var forced = try support.run(gpa, &.{ "--home", home, "rm", "--force", "@4" }, 24, 100);
    defer forced.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), forced.code);
    try std.testing.expectError(error.FileNotFound, dir.openDir(io, "4", .{}));
}

test "rm accepts mixed target lists and applies force to every target" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var journal = try support.Journal.open(gpa);
    defer journal.close();
    try support.recordJournal(gpa, &journal, &.{
        "echo one",
        "echo two",
        "echo three",
        "echo four",
        "echo five",
        "echo six",
    });
    try journal.enter(gpa);
    const home = try journal.homeArg(gpa);
    defer gpa.free(home);

    var pinned = try support.run(gpa, &.{ "--home", home, "pin", "@3" }, 24, 100);
    defer pinned.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), pinned.code);

    var mixed = try support.run(gpa, &.{
        "--home", home, "rm", "@1", "@2/out", "@3", "@4..@5",
    }, 24, 120);
    defer mixed.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), mixed.code);
    try std.testing.expect(std.mem.indexOf(u8, mixed.out.items, "skipped pinned entry @3") != null);

    var dir = try journal.journalDir();
    defer dir.close(io);
    try std.testing.expectError(error.FileNotFound, dir.openDir(io, "1", .{}));
    try std.testing.expectError(error.FileNotFound, dir.openFile(io, "2/out", .{}));
    var two_cmd = try dir.openFile(io, "2/cmd", .{});
    two_cmd.close(io);
    var removed_marker = try dir.openFile(io, "2/out.removed", .{});
    removed_marker.close(io);
    var three = try dir.openDir(io, "3", .{});
    three.close(io);
    try std.testing.expectError(error.FileNotFound, dir.openDir(io, "4", .{}));
    try std.testing.expectError(error.FileNotFound, dir.openDir(io, "5", .{}));
    var six = try dir.openDir(io, "6", .{});
    six.close(io);

    var forced = try support.run(gpa, &.{ "--home", home, "rm", "--force", "@3", "@6" }, 24, 100);
    defer forced.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), forced.code);
    try std.testing.expectError(error.FileNotFound, dir.openDir(io, "3", .{}));
    try std.testing.expectError(error.FileNotFound, dir.openDir(io, "6", .{}));
}

test "concurrent annotation commands preserve every update" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var journal = try support.Journal.open(gpa);
    defer journal.close();
    try support.recordJournal(gpa, &journal, &.{"echo concurrent"});
    try journal.enter(gpa);
    const home = try journal.homeArg(gpa);
    defer gpa.free(home);

    const tags = [_][]const u8{ "alpha", "beta", "gamma", "delta", "epsilon", "zeta" };
    var children: [tags.len]harness.PtyChild = undefined;
    for (tags, 0..) |tag, i| {
        children[i] = try support.spawnTj(gpa, &.{ support.tj, "--home", home, "tag", "@1", tag }, 24, 80);
    }
    for (children) |child| {
        var transcript: std.ArrayList(u8) = .empty;
        defer transcript.deinit(gpa);
        const status = try child.finish(gpa, &transcript, support.timeout_ms);
        if (status != 0) std.debug.print("concurrent annotation child failed ({d}): {s}\n", .{ status, transcript.items });
        try std.testing.expectEqual(@as(u8, 0), status);
    }

    var listed = try support.run(gpa, &.{ "--home", home, "tag", "@1" }, 24, 120);
    defer listed.out.deinit(gpa);
    for (tags) |tag| try std.testing.expect(std.mem.indexOf(u8, listed.out.items, tag) != null);

    const first = try support.spawnTj(gpa, &.{ support.tj, "--home", home, "name", "@1", "first-name" }, 24, 80);
    const second = try support.spawnTj(gpa, &.{ support.tj, "--home", home, "name", "@1", "second-name" }, 24, 80);
    var first_out: std.ArrayList(u8) = .empty;
    defer first_out.deinit(gpa);
    var second_out: std.ArrayList(u8) = .empty;
    defer second_out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), try first.finish(gpa, &first_out, support.timeout_ms));
    try std.testing.expectEqual(@as(u8, 0), try second.finish(gpa, &second_out, support.timeout_ms));

    var named = try support.run(gpa, &.{ "--home", home, "name", "@1" }, 24, 100);
    defer named.out.deinit(gpa);
    const first_won = std.mem.indexOf(u8, named.out.items, "first-name") != null;
    const second_won = std.mem.indexOf(u8, named.out.items, "second-name") != null;
    try std.testing.expect(first_won != second_won);
}

test "whole-journal removal is outside-writer only and refuses active journals" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var journal = try support.Journal.open(gpa);
    defer journal.close();
    try support.recordJournal(gpa, &journal, &.{"echo removable"});
    const home = try journal.homeArg(gpa);
    defer gpa.free(home);
    const id = try journal.journalName(gpa);
    defer gpa.free(id);

    // A journal environment, even without an active writer in this test
    // process, is sufficient to reject the lifecycle operation.
    try journal.enter(gpa);
    var pinned = try support.run(gpa, &.{ "--home", home, "pin", "@1" }, 24, 100);
    defer pinned.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), pinned.code);
    var inside = try support.runTjctl(gpa, &.{ "--home", home, "rm", id, "--force" }, 24, 100);
    defer inside.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), inside.code);
    var inside_rename = try support.runTjctl(gpa, &.{ "--home", home, "mv", id, "renamed-journal" }, 24, 100);
    defer inside_rename.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), inside_rename.code);
    try std.testing.expect(std.mem.indexOf(u8, inside_rename.out.items, "cannot rename") != null);

    support.leaveJournal();
    const non_tty = try support.runTjctlNonTty(gpa, &.{ "--home", home, "rm", id });
    defer gpa.free(non_tty.stdout);
    defer gpa.free(non_tty.stderr);
    try std.testing.expectEqual(@as(u8, 1), non_tty.term.exited);
    try std.testing.expect(std.mem.indexOf(u8, non_tty.stderr, "pinned entries protected") != null);
    try std.testing.expect(std.mem.indexOf(u8, non_tty.stderr, "use --force") != null);

    const writer = try support.spawnTjctl(gpa, &.{ support.tjctl, "--home", home, "use", id, "--", "/bin/sh", "-c", "echo READY; sleep 30" }, 24, 80);
    var writer_out: std.ArrayList(u8) = .empty;
    defer writer_out.deinit(gpa);
    try std.testing.expect(try writer.readUntil(gpa, &writer_out, "READY", support.timeout_ms));

    var active = try support.runTjctl(gpa, &.{ "--home", home, "rm", id, "--force" }, 24, 100);
    defer active.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), active.code);
    try std.testing.expect(std.mem.indexOf(u8, active.out.items, "already being written") != null);
    var active_rename = try support.runTjctl(gpa, &.{ "--home", home, "mv", id, "renamed-journal" }, 24, 100);
    defer active_rename.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), active_rename.code);
    try std.testing.expect(std.mem.indexOf(u8, active_rename.out.items, "already being written") != null);
    _ = std.c.kill(writer.pid, posix.SIG.TERM);
    _ = try writer.finish(gpa, &writer_out, support.timeout_ms);

    var renamed = try support.runTjctl(gpa, &.{ "--home", home, "mv", id, "renamed-journal" }, 24, 100);
    defer renamed.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), renamed.code);

    var removed = try support.runTjctl(gpa, &.{ "--home", home, "rm", "renamed-journal", "--force" }, 24, 100);
    defer removed.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), removed.code);
    var root = try journal.tmp.dir.openDir(std.testing.io, support.journal_dir, .{});
    defer root.close(std.testing.io);
    try std.testing.expectError(error.FileNotFound, root.openDir(std.testing.io, "renamed-journal", .{}));
}

test "concurrent namespace operations leave one complete winner" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    support.leaveJournal();
    var scratch = try support.Scratch.open();
    defer scratch.close();

    try scratch.makeNamedJournal("remove-source", &.{"1"});
    const removing = try support.spawnTjctl(gpa, &.{ support.tjctl, "--home", scratch.path(), "rm", "remove-source", "--force" }, 24, 80);
    const moving = try support.spawnTjctl(gpa, &.{ support.tjctl, "--home", scratch.path(), "mv", "remove-source", "remove-destination" }, 24, 80);
    var remove_out: std.ArrayList(u8) = .empty;
    defer remove_out.deinit(gpa);
    var move_out: std.ArrayList(u8) = .empty;
    defer move_out.deinit(gpa);
    const remove_status = try removing.finish(gpa, &remove_out, support.timeout_ms);
    const move_status = try moving.finish(gpa, &move_out, support.timeout_ms);
    try std.testing.expect((remove_status == 0) != (move_status == 0));
    try std.testing.expectError(error.FileNotFound, scratch.tmp.dir.openDir(io, "remove-source", .{}));
    if (move_status == 0) {
        var destination = try scratch.tmp.dir.openDir(io, "remove-destination", .{});
        destination.close(io);
    } else {
        try std.testing.expectError(error.FileNotFound, scratch.tmp.dir.openDir(io, "remove-destination", .{}));
    }

    try scratch.makeNamedJournal("new-source", &.{"1"});
    const creating = try support.spawnTjctl(gpa, &.{
        support.tjctl,
        "--home",
        scratch.path(),
        "new",
        "shared-destination",
        "--",
        "/bin/sh",
        "-c",
        "printf '\\033]3110;BOGUS\\033\\\\'",
    }, 24, 80);
    const renaming = try support.spawnTjctl(gpa, &.{ support.tjctl, "--home", scratch.path(), "mv", "new-source", "shared-destination" }, 24, 80);
    var create_out: std.ArrayList(u8) = .empty;
    defer create_out.deinit(gpa);
    var rename_out: std.ArrayList(u8) = .empty;
    defer rename_out.deinit(gpa);
    const create_status = try creating.finish(gpa, &create_out, support.timeout_ms);
    const rename_status = try renaming.finish(gpa, &rename_out, support.timeout_ms);
    try std.testing.expect((create_status == 0) != (rename_status == 0));
    var destination = try scratch.tmp.dir.openDir(io, "shared-destination", .{});
    destination.close(io);
    if (create_status == 0) {
        var source = try scratch.tmp.dir.openDir(io, "new-source", .{});
        source.close(io);
    } else {
        try std.testing.expectError(error.FileNotFound, scratch.tmp.dir.openDir(io, "new-source", .{}));
    }
}
