//! Full-screen entry browser behavior through a real zsh and PTY proxy.

const std = @import("std");
const store = @import("store.zig");
const support = @import("it_support.zig");

test "tui shows details, confirms deletion, and shares annotation semantics" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try support.Journal.open(gpa);
    defer journal.close();
    const child = try support.spawnJournalZsh(gpa, &journal);
    var transcript: std.ArrayList(u8) = .empty;
    defer transcript.deinit(gpa);
    try support.setupJournalZsh(gpa, child, &transcript);

    var from = transcript.items.len;
    try child.write("printf '%s\\n' DETAIL_STDOUT\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, support.test_prompt, support.timeout_ms));

    from = transcript.items.len;
    try child.write("echo DELETE_UNPINNED\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, support.test_prompt, support.timeout_ms));

    from = transcript.items.len;
    try child.write("echo DELETE_THREE\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, support.test_prompt, support.timeout_ms));

    from = transcript.items.len;
    try child.write("echo DELETE_FOUR\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, support.test_prompt, support.timeout_ms));

    from = transcript.items.len;
    try child.write("command \"$TJ\" tui\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, "4 entries", support.timeout_ms));

    // The browser starts on the newest completed entry, excluding its own
    // running command. Select entries 3..4, then apply pin and tag once to
    // the complete selection before accepting one collective pin override.
    from = transcript.items.len;
    try child.write(" ");
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, "1 selected", support.timeout_ms));
    from = transcript.items.len;
    try child.write("\x1b[1;2Ap");
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, "entries pinned", support.timeout_ms));
    from = transcript.items.len;
    try child.write("tParser\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, "tagged #Parser", support.timeout_ms));
    from = transcript.items.len;
    try child.write("d");
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, "pinned entries too?", support.timeout_ms));
    from = transcript.items.len;
    try child.write("y");
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, "deleted 2 entries", support.timeout_ms));

    // The cursor lands on unpinned entry 2. It deletes immediately, without
    // entering the pinned confirmation mode; the following p therefore
    // reaches and pins entry 1.
    from = transcript.items.len;
    try child.write("dp");
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, "pinned", support.timeout_ms));

    // Exercise every annotation mutation, including an untag, and open the
    // selected entry's full detail view before returning to the browser.
    from = transcript.items.len;
    try child.write("tBug\nTbug\ntParser\nntui-target\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, "named entry 1 @tui-target", support.timeout_ms));
    from = transcript.items.len;
    try child.write("\r");
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, "DETAIL_STDOUT", support.timeout_ms));
    from = transcript.items.len;
    try child.write("qq");
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, support.test_prompt, support.timeout_ms));

    try child.write("exit 0\r");
    try std.testing.expectEqual(@as(u8, 0), try child.finish(gpa, &transcript, support.timeout_ms));
    try std.testing.expect(std.mem.indexOf(u8, transcript.items, "5107;tj") == null);

    const home = try journal.homeArg(gpa);
    defer gpa.free(home);
    const id = try journal.journalName(gpa);
    defer gpa.free(id);
    const pinned = try support.runNonTtyInJournal(gpa, &.{ "--home", home, "pin" }, id, "");
    defer gpa.free(pinned.stdout);
    defer gpa.free(pinned.stderr);
    try std.testing.expect(std.mem.indexOf(u8, pinned.stdout, "@1") != null);
    const tagged = try support.runNonTtyInJournal(gpa, &.{ "--home", home, "tag", "@1" }, id, "");
    defer gpa.free(tagged.stdout);
    defer gpa.free(tagged.stderr);
    try std.testing.expect(std.mem.indexOf(u8, tagged.stdout, "parser") != null);
    try std.testing.expect(std.mem.indexOf(u8, tagged.stdout, "bug") == null);
    const named = try support.runNonTtyInJournal(gpa, &.{ "--home", home, "name", "@1" }, id, "");
    defer gpa.free(named.stdout);
    defer gpa.free(named.stderr);
    try std.testing.expect(std.mem.indexOf(u8, named.stdout, "tui-target") != null);

    try std.testing.expectError(error.FileNotFound, journal.read(gpa, "2/cmd"));
    try std.testing.expectError(error.FileNotFound, journal.read(gpa, "3/cmd"));
    try std.testing.expectError(error.FileNotFound, journal.read(gpa, "4/cmd"));

    const tui_out = try journal.read(gpa, "5/out");
    defer gpa.free(tui_out);
    try std.testing.expect(std.mem.startsWith(u8, tui_out, store.noout_placeholder));
    try std.testing.expect(std.mem.indexOf(u8, tui_out, "DETAIL_STDOUT") == null);
    try std.testing.expect(std.mem.indexOf(u8, tui_out, "entries") == null);
}
