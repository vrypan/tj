//! Fish shell integration.

const std = @import("std");
const support = @import("it_support.zig");

test "fish records UTF-8 commands and resolves canonical path substitutions" {
    if (support.fishExecutable() == null) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try support.Journal.open(gpa);
    defer journal.close();
    const child = try support.spawnJournalFish(gpa, &journal);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try support.setupJournalFish(gpa, child, &out);

    var from = out.items.len;
    try child.write("printf 'fish-π\\n'\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, "fish-π", support.timeout_ms));
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, support.test_prompt, support.timeout_ms));

    from = out.items.len;
    try child.write("cat (tj @1/out)\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, "fish-π", support.timeout_ms));
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, support.test_prompt, support.timeout_ms));

    from = out.items.len;
    try child.write("complete -C 'tj cat @1/'\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, "@1/out", support.timeout_ms));
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, support.test_prompt, support.timeout_ms));

    try child.write("exit\n");
    try std.testing.expectEqual(@as(u8, 0), try child.finish(gpa, &out, support.timeout_ms));

    const first = try journal.read(gpa, "1/cmd");
    defer gpa.free(first);
    try std.testing.expectEqualStrings("printf 'fish-π\\n'", first);
    const second = try journal.read(gpa, "2/cmd");
    defer gpa.free(second);
    try std.testing.expectEqualStrings("cat (tj @1/out)", second);
    const rc = try journal.read(gpa, "2/rc");
    defer gpa.free(rc);
    try std.testing.expectEqualStrings("0\n", rc);
}
