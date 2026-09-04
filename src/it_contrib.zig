//! Optional companion scripts run against a real journal writer.

const std = @import("std");
const store = @import("store.zig");
const support = @import("it_support.zig");

test "tj-md renders selected entries as a plain fenced transcript" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    const script = "contrib/tj-md";

    var journal = try support.Journal.open(gpa);
    defer journal.close();
    const child = try support.spawnJournalZsh(gpa, &journal);
    var transcript: std.ArrayList(u8) = .empty;
    defer transcript.deinit(gpa);
    try support.setupJournalZsh(gpa, child, &transcript);

    var from = transcript.items.len;
    try child.write("printf 'MD_ONE\\n```\\n'\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, support.test_prompt, support.timeout_ms));
    from = transcript.items.len;
    try child.write("printf '\\033[31mMD_RED\\033[0m\\n'\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, support.test_prompt, support.timeout_ms));

    var selected: [2]u32 = undefined;
    var selected_len: usize = 0;
    for (1..16) |number| {
        var resource: [32]u8 = undefined;
        const path = try std.fmt.bufPrint(&resource, "{d}/cmd", .{number});
        const cmd = journal.read(gpa, path) catch continue;
        defer gpa.free(cmd);
        if (std.mem.indexOf(u8, cmd, "MD_ONE") != null or std.mem.indexOf(u8, cmd, "MD_RED") != null) {
            selected[selected_len] = @intCast(number);
            selected_len += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), selected_len);

    var command: std.ArrayList(u8) = .empty;
    defer command.deinit(gpa);
    var selection_line: [64]u8 = undefined;
    try command.appendSlice(gpa, try std.fmt.bufPrint(&selection_line, "printf '{d} {d}\\n' | ", .{ selected[0], selected[1] }));
    try support.appendShellQuoted(gpa, &command, script);
    try command.append(gpa, '\n');
    from = transcript.items.len;
    try child.write(command.items);
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, support.test_prompt, support.timeout_ms));

    try child.write("exit 0\n");
    try std.testing.expectEqual(@as(u8, 0), try child.finish(gpa, &transcript, support.timeout_ms));

    var out_path: [32]u8 = undefined;
    const out = try journal.read(gpa, try std.fmt.bufPrint(&out_path, "{d}/out", .{selected[1] + 1}));
    defer gpa.free(out);
    try std.testing.expect(std.mem.startsWith(u8, out, store.noout_placeholder));
    try std.testing.expect(std.mem.indexOf(u8, out, "MD_ONE") == null);

    const home = try journal.homeArg(gpa);
    defer gpa.free(home);
    const journal_id = try journal.journalName(gpa);
    defer gpa.free(journal_id);
    const ids = try std.fmt.allocPrint(gpa, "{d} {d}\n", .{ selected[0], selected[1] });
    defer gpa.free(ids);
    var environ = try std.process.Environ.createMap(std.testing.environ, gpa);
    defer environ.deinit();
    try environ.put("TJ", support.tj);
    try environ.put("TJ_HOME", home);
    try environ.put("TJ_JOURNAL", journal_id);
    const rendered = try std.process.run(gpa, std.testing.io, .{
        .argv = &.{ "/bin/sh", "-c", "printf '%s' \"$1\" | \"$2\"", "sh", ids, script },
        .environ_map = &environ,
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
    });
    defer gpa.free(rendered.stdout);
    defer gpa.free(rendered.stderr);
    try std.testing.expectEqual(@as(u8, 0), rendered.term.exited);
    try std.testing.expectEqualStrings("", rendered.stderr);
    try std.testing.expect(std.mem.indexOf(u8, rendered.stdout, "````console\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.stdout, "$ printf 'MD_ONE\\n```\\n'") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.stdout, "MD_ONE\n```\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.stdout, "MD_RED\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.stdout, "\x1b[31mMD_RED") == null);

    const prompted = try std.process.run(gpa, std.testing.io, .{
        .argv = &.{ "/bin/sh", "-c", "printf '%s' \"$1\" | \"$2\" \"$3\"", "sh", ids, script, "--prompt" },
        .environ_map = &environ,
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
    });
    defer gpa.free(prompted.stdout);
    defer gpa.free(prompted.stderr);
    try std.testing.expectEqual(@as(u8, 0), prompted.term.exited);
    try std.testing.expectEqualStrings("", prompted.stderr);
    try std.testing.expect(std.mem.indexOf(u8, prompted.stdout, "TJ_TEST_PROMPT> printf 'MD_ONE") != null);
}
