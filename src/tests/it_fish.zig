//! Fish shell integration.

const std = @import("std");
const support = @import("it_support.zig");

test "fish records UTF-8 commands and resolves canonical path substitutions" {
    if (!support.fishSupportsNativeMarkers()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try support.Journal.open(gpa);
    defer journal.close();
    const child = try support.spawnJournalFish(gpa, &journal);
    var terminal = support.TerminalSession.init(gpa, child);
    defer terminal.deinit();
    const out = &terminal.transcript;
    try terminal.setupFish();

    var from = out.items.len;
    try terminal.write("printf 'fish-π\\n'\n");
    try terminal.expectFrom(from, "fish-π");
    try terminal.expectPromptFrom(from);

    from = out.items.len;
    try terminal.write("cat (tj @1/out)\n");
    try terminal.expectFrom(from, "fish-π");
    try terminal.expectPromptFrom(from);

    from = out.items.len;
    try terminal.write("complete -C 'cat (tj @1/'\n");
    try terminal.expectFrom(from, "@1/out");
    try terminal.expectPromptFrom(from);

    try terminal.write("exit 0\n");
    _ = try terminal.finish();

    const first = try journal.read(gpa, "1/cmd");
    defer gpa.free(first);
    try std.testing.expectEqualStrings("printf 'fish-π\\n'", first);
    const second = try journal.read(gpa, "2/cmd");
    defer gpa.free(second);
    try std.testing.expectEqualStrings("cat (tj @1/out)", second);
    const rc = try journal.read(gpa, "2/rc");
    defer gpa.free(rc);
    try std.testing.expectEqualStrings("0\n", rc);
    const third = try journal.read(gpa, "3/cmd");
    defer gpa.free(third);
    try std.testing.expectEqualStrings("complete -C 'cat (tj @1/'", third);
}

test "fish handoff refreshes its journal reference" {
    if (!support.fishSupportsNativeMarkers()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try support.Journal.open(gpa);
    defer journal.close();
    const child = try support.spawnJournalFish(gpa, &journal);
    var terminal = support.TerminalSession.init(gpa, child);
    defer terminal.deinit();
    try terminal.setupFish();

    var from = terminal.mark();
    try terminal.write("tj-new fish-target\n");
    try terminal.expectPromptFrom(from);

    from = terminal.mark();
    try terminal.write("printf 'FISH_HANDOFF=%s:%s\\n' \"$TJ_JOURNAL\" \"$TJ_REF\"\n");
    try terminal.expectFrom(from, "FISH_HANDOFF=fish-target:@fish-target.2");
    try terminal.expectPromptFrom(from);

    try terminal.write("exit 0\n");
    try std.testing.expectEqual(@as(u8, 0), try terminal.finish());
}

test "fish key binding keeps the tui attached to its terminal" {
    if (!support.fishSupportsNativeMarkers()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try support.Journal.open(gpa);
    defer journal.close();
    const child = try support.spawnJournalFish(gpa, &journal);
    var terminal = support.TerminalSession.init(gpa, child);
    defer terminal.deinit();
    const out = &terminal.transcript;
    try terminal.setupFish();

    var from = out.items.len;
    try terminal.write("echo FISH_TUI_FIXTURE\n");
    try terminal.expectPromptFrom(from);

    from = out.items.len;
    try terminal.write("\x18\x14");
    try terminal.expectFrom(from, " entries");
    const drawn = out.items.len;
    try std.testing.expect(!try terminal.waitFrom(drawn, "\x00", 300));
    try std.testing.expect(std.mem.indexOf(u8, out.items[from..], "\x1b[?1049l") == null);

    from = out.items.len;
    try terminal.write("q");
    try terminal.expectPromptFrom(from);

    try terminal.write("exit 0\n");
    _ = try terminal.finish();
}
