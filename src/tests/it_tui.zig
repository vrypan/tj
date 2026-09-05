//! Full-screen entry browser behavior through a real zsh and PTY proxy.

const std = @import("std");
const store = @import("../journal/store.zig");
const support = @import("it_support.zig");

test "zsh widget keeps tui open and inserts its stdout" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try support.Journal.open(gpa);
    defer journal.close();
    const child = try support.spawnJournalZsh(gpa, &journal);
    var terminal = support.TerminalSession.init(gpa, child);
    defer terminal.deinit();
    const transcript = &terminal.transcript;
    const prefix =
        "_tj_probe_buffer() { zle -I; print -r -- \"TJ_WIDGET_BUFFER=<$BUFFER>\"; BUFFER=; zle reset-prompt; }; " ++
        "zle -N _tj_probe_buffer; bindkey '^X^B' _tj_probe_buffer";
    try terminal.setupZsh(prefix);

    var from = transcript.items.len;
    try terminal.write("echo WIDGET_FIXTURE\n");
    try terminal.expectPromptFrom(from);

    // The browser must remain active without input. This catches attempts to
    // poll a freshly opened /dev/tty descriptor on macOS, which looks like an
    // immediate end-of-input from a ZLE-launched child.
    from = transcript.items.len;
    try terminal.write("\x18\x14");
    try terminal.expectFrom(from, " entries");
    const drawn = transcript.items.len;
    try std.testing.expect(!try terminal.waitFrom(drawn, "\x00", 300));
    try std.testing.expect(std.mem.indexOf(u8, transcript.items[from..], "\x1b[?1049l") == null);

    from = transcript.items.len;
    try terminal.write("q");
    try terminal.expectPromptFrom(from);

    // The direct TUI test below covers Enter choosing detail values. Isolate
    // the ZLE half here by substituting a deterministic command whose stdout
    // is what the real TUI would return.
    from = transcript.items.len;
    try terminal.write("TJ=/bin/echo\n");
    try terminal.expectPromptFrom(from);

    from = transcript.items.len;
    try terminal.write("\x18\x14\x18\x02");
    try terminal.expectFrom(from, "TJ_WIDGET_BUFFER=<tui>");
    try terminal.expectPromptFrom(from);

    try terminal.write("exit 0\n");
    const status = try terminal.finish();
    if (status != 0) std.debug.print("tui widget shell failed ({d}): {s}\n", .{ status, transcript.items });
    try std.testing.expectEqual(@as(u8, 0), status);
}

test "tui exports an explicit selection as space-separated entry numbers" {
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
    try terminal.write("echo EXPORT_ONE\n");
    try terminal.expectPromptFrom(from);
    from = transcript.items.len;
    try terminal.write("echo EXPORT_TWO\n");
    try terminal.expectPromptFrom(from);
    from = transcript.items.len;
    try terminal.write("echo EXPORT_THREE\n");
    try terminal.expectPromptFrom(from);

    from = transcript.items.len;
    try terminal.write("command \"$TJ\" tui | /bin/sh -c 'IFS= read -r entries; printf \"TUI_EXPORT=<%s>\\n\" \"$entries\"'\n");
    try terminal.expectFrom(from, "3 entries");

    from = transcript.items.len;
    try terminal.write(" \x1b[1;2Ae");
    try terminal.expectFrom(from, "TUI_EXPORT=<2 3>");
    try terminal.expectPromptFrom(from);
    const finished = transcript.items[from..];
    const restored_at = std.mem.lastIndexOf(u8, finished, "\x1b[?1049l") orelse return error.TestUnexpectedResult;
    const exported_at = std.mem.lastIndexOf(u8, finished, "TUI_EXPORT=<2 3>") orelse return error.TestUnexpectedResult;
    try std.testing.expect(restored_at < exported_at);

    try terminal.write("exit 0\n");
    try std.testing.expectEqual(@as(u8, 0), try terminal.finish());
}

test "tui exports output that matches its structural separator" {
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
    try terminal.write("printf '%s\\n' '=== out ==='\n");
    try terminal.expectPromptFrom(from);

    from = transcript.items.len;
    try terminal.write("command \"$TJ\" tui | od -An -tx1 | tr -d '[:space:]'; print\n");
    try terminal.expectFrom(from, "1 entries");
    try terminal.write("\rjjjjjjjjjjjjj\r");
    try terminal.expectFrom(from, "3d3d3d206f7574203d3d3d0d0a");
    try terminal.expectPromptFrom(from);

    try terminal.write("exit 0\n");
    try std.testing.expectEqual(@as(u8, 0), try terminal.finish());
}

test "tui wraps one long output line without splitting its export" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const output = "WRAPPED_OUTPUT_abcdefghijklmnopqrstuvwxyz_ABCDEFGHIJKLMNOPQRSTUVWXYZ_0123456789_abcdefghijklmnopqrstuvwxyz";

    var journal = try support.Journal.open(gpa);
    defer journal.close();
    const child = try support.spawnJournalZsh(gpa, &journal);
    var terminal = support.TerminalSession.init(gpa, child);
    defer terminal.deinit();
    const transcript = &terminal.transcript;
    try terminal.setupZsh("");

    var command_buf: [256]u8 = undefined;
    const command = try std.fmt.bufPrint(&command_buf, "printf '%s\\n' '{s}'\n", .{output});
    var from = transcript.items.len;
    try terminal.write(command);
    try terminal.expectPromptFrom(from);

    from = transcript.items.len;
    try terminal.write("command \"$TJ\" tui | wc -c | tr -d ' '; print\n");
    try terminal.expectFrom(from, "1 entries");
    try terminal.write("\rjjjjjjjjjjjjj");
    try terminal.expectFrom(from, output[output.len - 20 ..]);

    from = transcript.items.len;
    try terminal.write("\r");
    var length_buf: [32]u8 = undefined;
    const expected_length = try std.fmt.bufPrint(&length_buf, "{d}", .{output.len + 2});
    try terminal.expectFrom(from, expected_length);
    try terminal.expectPromptFrom(from);

    try terminal.write("exit 0\n");
    try std.testing.expectEqual(@as(u8, 0), try terminal.finish());
}

test "tui shows details, confirms deletion, and shares pin semantics" {
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
    try terminal.write("printf '%s\\n' DETAIL_STDOUT DETAIL_SECOND\n");
    try terminal.expectPromptFrom(from);

    from = transcript.items.len;
    try terminal.write("echo DELETE_UNPINNED\n");
    try terminal.expectPromptFrom(from);

    from = transcript.items.len;
    try terminal.write("echo DELETE_THREE\n");
    try terminal.expectPromptFrom(from);

    from = transcript.items.len;
    try terminal.write("echo DELETE_FOUR\n");
    try terminal.expectPromptFrom(from);

    from = transcript.items.len;
    try terminal.write("command \"$TJ\" tui\n");
    try terminal.expectFrom(from, "4 entries");

    // The browser starts on the newest completed entry, excluding its own
    // running command. Select entries 3..4, pin the complete selection, then
    // accept one collective pin override.
    from = transcript.items.len;
    try terminal.write(" ");
    try terminal.expectFrom(from, "1 selected");
    from = transcript.items.len;
    try terminal.write("\x1b[1;2Ap");
    try terminal.expectFrom(from, "entries pinned");
    from = transcript.items.len;
    try terminal.write("d");
    try terminal.expectFrom(from, "pinned entries too?");
    from = transcript.items.len;
    try terminal.write("y");
    try terminal.expectFrom(from, "deleted 2 entries");

    // The cursor lands on unpinned entry 2. It deletes immediately, without
    // entering the pinned confirmation mode; the following p therefore
    // reaches and pins entry 1.
    from = transcript.items.len;
    try terminal.write("dp");
    try terminal.expectFrom(from, "pinned");

    // Open the selected entry's full detail view. Focus its first output line,
    // extend through the second, then print both and exit the browser.
    from = transcript.items.len;
    try terminal.write("\r");
    try terminal.expectFrom(from, "DETAIL_SECOND");
    try std.testing.expect(std.mem.indexOf(u8, transcript.items[from..], "cwd") != null);
    from = transcript.items.len;
    try terminal.write("jjjjjjjjjjjjj\x1b[1;2B\r");
    try terminal.expectPromptFrom(from);
    const printed = transcript.items[from..];
    const restored_at = std.mem.lastIndexOf(u8, printed, "\x1b[?1049l") orelse return error.TestUnexpectedResult;
    const stdout_at = std.mem.lastIndexOf(u8, printed, "DETAIL_STDOUT") orelse return error.TestUnexpectedResult;
    const second_at = std.mem.lastIndexOf(u8, printed, "DETAIL_SECOND") orelse return error.TestUnexpectedResult;
    try std.testing.expect(restored_at < stdout_at and stdout_at < second_at);

    try terminal.write("exit 0\r");
    try std.testing.expectEqual(@as(u8, 0), try terminal.finish());
    try std.testing.expect(std.mem.indexOf(u8, transcript.items, "3110;") == null);

    const home = try journal.homeArg(gpa);
    defer gpa.free(home);
    const id = try journal.journalName(gpa);
    defer gpa.free(id);
    const pinned = try support.runNonTtyInJournal(gpa, &.{ "--home", home, "pin" }, id, "");
    defer gpa.free(pinned.stdout);
    defer gpa.free(pinned.stderr);
    try std.testing.expect(std.mem.indexOf(u8, pinned.stdout, "@1") != null);
    try std.testing.expectError(error.FileNotFound, journal.read(gpa, "2/cmd"));
    try std.testing.expectError(error.FileNotFound, journal.read(gpa, "3/cmd"));
    try std.testing.expectError(error.FileNotFound, journal.read(gpa, "4/cmd"));

    const tui_out = try journal.read(gpa, "5/out");
    defer gpa.free(tui_out);
    try std.testing.expect(std.mem.startsWith(u8, tui_out, store.noout_placeholder));
    try std.testing.expect(std.mem.indexOf(u8, tui_out, "DETAIL_STDOUT") == null);
    try std.testing.expect(std.mem.indexOf(u8, tui_out, "DETAIL_SECOND") == null);
    try std.testing.expect(std.mem.indexOf(u8, tui_out, "entries") == null);
}

test "grep tui deduplicates matching entries" {
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
    try terminal.write("printf '%s\\n' DEDUP_TUI_HIT DEDUP_TUI_HIT\n");
    try terminal.expectPromptFrom(from);
    from = transcript.items.len;
    try terminal.write("echo DEDUP_TUI_HIT\n");
    try terminal.expectPromptFrom(from);
    from = transcript.items.len;
    try terminal.write("echo UNRELATED_TUI_ENTRY\n");
    try terminal.expectPromptFrom(from);

    from = transcript.items.len;
    try terminal.write("command \"$TJ\" grep --tui DEDUP_TUI_HIT\n");
    try terminal.expectFrom(from, "2 matches");
    const browser = transcript.items[from..];
    try std.testing.expect(std.mem.indexOf(u8, browser, "UNRELATED_TUI_ENTRY") == null);
    try terminal.write("q");
    try terminal.expectPromptFrom(from);

    try terminal.write("exit 0\r");
    try std.testing.expectEqual(@as(u8, 0), try terminal.finish());

    const grep_out = try journal.read(gpa, "4/out");
    defer gpa.free(grep_out);
    try std.testing.expect(std.mem.startsWith(u8, grep_out, store.noout_placeholder));
    try std.testing.expect(std.mem.indexOf(u8, grep_out, "DEDUP_TUI_HIT") == null);
    try std.testing.expect(std.mem.indexOf(u8, grep_out, "3110;") == null);
}
