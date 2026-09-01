//! Replaying a journal into a terminal.

const std = @import("std");
const posix = std.posix;
const journal_name = @import("journal_name.zig");

const options = @import("build_options");
const tj = options.tj_exe;
const support = @import("it_support.zig");

test "invalid replay numeric options exit cleanly" {
    const gpa = std.testing.allocator;
    support.leaveJournal();

    const cases = [_][]const []const u8{
        &.{ "replay", "journal", "--from", "4294967296" },
        &.{ "replay", "journal", "--speed", "nan" },
        &.{ "replay", "journal", "--typing", "18446744073709551616" },
    };
    for (cases) |args| {
        var r = try support.runTjctl(gpa, args, 24, 80);
        defer r.out.deinit(gpa);

        try std.testing.expectEqual(@as(u8, 2), r.code);
        try std.testing.expect(std.mem.indexOf(u8, r.out.items, "invalid replay numeric option") != null);
        try std.testing.expect(std.mem.indexOf(u8, r.out.items, "panic") == null);
        try std.testing.expect(std.mem.indexOf(u8, r.out.items, "error return trace") == null);
    }
}

test "replay prefers recorded prompts and permits an explicit override" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    support.leaveJournal();
    var scratch = try support.Scratch.open();
    defer scratch.close();

    const id = journal_name.legacy(44, .{7} ** 10);
    try scratch.makeJournal(id, &.{"1"});
    var journal = try scratch.tmp.dir.openDir(io, &id, .{});
    defer journal.close(io);
    var interaction = try journal.openDir(io, "1", .{});
    defer interaction.close(io);
    try interaction.writeFile(io, .{ .sub_path = "prompt", .data = "\x1b[36mCAPTURED-PROMPT> \x1b[0m" });
    try interaction.writeFile(io, .{ .sub_path = "cmd", .data = "recorded-command" });
    try interaction.writeFile(io, .{ .sub_path = "out", .data = "RECORDED-OUTPUT\r\n" });

    var recorded = try support.runTjctl(gpa, &.{
        "--home", scratch.path(), "replay", &id, "--typing", "0", "--max-pause", "0",
    }, 24, 80);
    defer recorded.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), recorded.code);
    const prompt_at = std.mem.indexOf(u8, recorded.out.items, "CAPTURED-PROMPT") orelse return error.TestUnexpectedResult;
    const command_at = std.mem.indexOf(u8, recorded.out.items, "recorded-command") orelse return error.TestUnexpectedResult;
    try std.testing.expect(prompt_at < command_at);
    try std.testing.expect(std.mem.indexOf(u8, recorded.out.items, "\x1b[36m") != null);

    var overridden = try support.runTjctl(gpa, &.{
        "--home", scratch.path(), "replay", &id, "--typing", "0", "--max-pause", "0", "--prompt", "OVERRIDE> ",
    }, 24, 80);
    defer overridden.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), overridden.code);
    try std.testing.expect(std.mem.indexOf(u8, overridden.out.items, "OVERRIDE> recorded-command") != null);
    try std.testing.expect(std.mem.indexOf(u8, overridden.out.items, "CAPTURED-PROMPT") == null);
}

test "a journal replays the commands and output it recorded" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try support.Journal.open(gpa);
    defer journal.close();
    try support.recordJournal(gpa, &journal, &.{ "echo first-marker", "echo second-marker" });
    support.leaveJournal();

    const home = try journal.homeArg(gpa);
    defer gpa.free(home);
    const id = try journal.journalName(gpa);
    defer gpa.free(id);

    // No pacing: a test must not wait for a demo to play out.
    var r = try support.runTjctl(gpa, &.{
        "--home", home, "replay", id, "--typing", "0", "--max-pause", "0", "--prompt", "% ",
    }, 24, 80);
    defer r.out.deinit(gpa);

    // Each command is shown, then what it printed, in the order they ran.
    const first_cmd = std.mem.indexOf(u8, r.out.items, "echo first-marker") orelse return error.TestUnexpectedResult;
    const first_out = std.mem.indexOf(u8, r.out.items, "first-marker\r") orelse return error.TestUnexpectedResult;
    const second_cmd = std.mem.indexOf(u8, r.out.items, "echo second-marker") orelse return error.TestUnexpectedResult;
    try std.testing.expect(first_cmd < first_out);
    try std.testing.expect(first_out < second_cmd);

    // An explicit prompt replaces the captured one.
    try std.testing.expect(std.mem.indexOf(u8, r.out.items, "% ") != null);
}

test "replay can be narrowed to a range of entries" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try support.Journal.open(gpa);
    defer journal.close();
    try support.recordJournal(gpa, &journal, &.{ "echo alpha", "echo beta", "echo gamma" });
    support.leaveJournal();

    const home = try journal.homeArg(gpa);
    defer gpa.free(home);
    const id = try journal.journalName(gpa);
    defer gpa.free(id);

    var r = try support.runTjctl(gpa, &.{
        "--home", home, "replay", id, "--typing", "0", "--max-pause", "0", "--from", "2", "--to", "2",
    }, 24, 80);
    defer r.out.deinit(gpa);

    try std.testing.expect(std.mem.indexOf(u8, r.out.items, "echo beta") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out.items, "alpha") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.out.items, "gamma") == null);
}

test "replay names a journal by suffix, like every other reference" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try support.Journal.open(gpa);
    defer journal.close();
    try support.recordJournal(gpa, &journal, &.{"echo by-suffix"});
    support.leaveJournal();

    const name = try journal.journalName(gpa);
    defer gpa.free(name);
    const home = try journal.homeArg(gpa);
    defer gpa.free(home);

    var r = try support.runTjctl(gpa, &.{
        "--home", home, "replay", name[name.len - 4 ..], "--typing", "0", "--max-pause", "0",
    }, 24, 80);
    defer r.out.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, r.out.items, "echo by-suffix") != null);
}

test "replay refuses to run inside a journal writer" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try support.Journal.open(gpa);
    defer journal.close();
    try support.recordJournal(gpa, &journal, &.{"echo recorded"});
    // Being inside a journal writer is exactly what TJ_JOURNAL means.
    try journal.enter(gpa);

    const home = try journal.homeArg(gpa);
    defer gpa.free(home);
    const id = try journal.journalName(gpa);
    defer gpa.free(id);

    var refused = try support.runTjctl(gpa, &.{ "--home", home, "replay", id, "--typing", "0" }, 24, 80);
    defer refused.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), refused.code);
    // The recording must not have been replayed into the live writer.
    try std.testing.expect(std.mem.indexOf(u8, refused.out.items, "echo recorded") == null);

    // Asking only how long it would take prints no recording, so it is allowed:
    // support.tj-tape needs it, and is usually support.run from inside a writer.
    var duration = try support.runTjctl(gpa, &.{ "--home", home, "replay", id, "--duration" }, 24, 80);
    defer duration.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), duration.code);
}

test "replay requires a journal selector" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try support.Journal.open(gpa);
    defer journal.close();
    try support.recordJournal(gpa, &journal, &.{"echo only-child"});
    support.leaveJournal();

    const home = try journal.homeArg(gpa);
    defer gpa.free(home);

    var r = try support.runTjctl(gpa, &.{ "--home", home, "replay", "--typing", "0", "--max-pause", "0" }, 24, 80);
    defer r.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 2), r.code);
}
