//! Resources a program publishes into its own entry.

const std = @import("std");
const posix = std.posix;
const noout = @import("noout.zig");
const plain = @import("plain.zig");
const journal_name = @import("journal_name.zig");

const options = @import("build_options");
const tj = options.tj_exe;
const support = @import("it_support.zig");

test "a noout OSC region stays visible but is replaced in out" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try support.Journal.open(gpa);
    defer journal.close();
    const producer = try journal.fixture(
        gpa,
        "noout-producer.sh",
        "printf 'ordinary-before\\n'\n" ++
            "printf '\\033]5107;NOOUT\\033\\\\'\n" ++
            "printf 'VISIBLE-BUT-OMITTED\\n'\n" ++
            "printf '\\033]5107;END\\033\\\\'\n" ++
            "printf 'ordinary-after\\n'\n",
    );
    defer gpa.free(producer);

    const child = try support.spawnJournalZsh(gpa, &journal);
    var transcript: std.ArrayList(u8) = .empty;
    defer transcript.deinit(gpa);
    try support.setupJournalZsh(gpa, child, &transcript);
    const command = try std.fmt.allocPrint(gpa, "/bin/sh '{s}'", .{producer});
    defer gpa.free(command);
    const from = transcript.items.len;
    try child.write(command);
    try child.write("\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, support.test_prompt, support.timeout_ms));
    try child.write("exit 0\n");
    try std.testing.expectEqual(@as(u8, 0), try child.finish(gpa, &transcript, support.timeout_ms));

    const visible = transcript.items[from..];
    try std.testing.expect(std.mem.indexOf(u8, visible, "VISIBLE-BUT-OMITTED") != null);
    try std.testing.expect(std.mem.indexOf(u8, visible, "5107;") == null);

    const out = try journal.read(gpa, "1/out");
    defer gpa.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "ordinary-before") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<tj:noout>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "ordinary-after") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "VISIBLE-BUT-OMITTED") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "5107;") == null);

    const meta = try journal.read(gpa, "1/meta.json");
    defer gpa.free(meta);
    try std.testing.expect(std.mem.indexOf(u8, meta, "noout") == null);
    try std.testing.expect(std.mem.indexOf(u8, meta, "VISIBLE-BUT-OMITTED") == null);
}

test "an unfinished noout OSC region cannot suppress the next entry" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try support.Journal.open(gpa);
    defer journal.close();
    const producer = try journal.fixture(
        gpa,
        "unfinished-noout.sh",
        "printf '\\033]5107;NOOUT\\033\\\\'\n" ++
            "printf 'OMITTED-UNTIL-BOUNDARY\\n'\n",
    );
    defer gpa.free(producer);
    const first = try std.fmt.allocPrint(gpa, "/bin/sh '{s}'", .{producer});
    defer gpa.free(first);
    try support.recordJournal(gpa, &journal, &.{ first, "printf 'NEXT-INTERACTION-RECORDED\\n'" });

    const first_out = try journal.read(gpa, "1/out");
    defer gpa.free(first_out);
    try std.testing.expect(std.mem.indexOf(u8, first_out, "<tj:noout>") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_out, "OMITTED-UNTIL-BOUNDARY") == null);
    const second_out = try journal.read(gpa, "2/out");
    defer gpa.free(second_out);
    try std.testing.expect(std.mem.indexOf(u8, second_out, "NEXT-INTERACTION-RECORDED") != null);
}

test "tj noout preserves output argv and child statuses while omitting bytes" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try support.Journal.open(gpa);
    defer journal.close();
    const producer = try journal.fixture(
        gpa,
        "wrapper-producer.sh",
        "printf 'WRAPPER-STDOUT:%s|%s|%s|%s\\n' \"$1\" \"$2\" \"$3\" \"$4\"\n" ++
            "printf 'WRAPPER-STDERR\\n' >&2\n" ++
            "printf 'WRAPPER-CONTEXT:%s|%s|' \"$PWD\" \"$NOOUT_TEST_ENV\"\n" ++
            "if test -t 0 && test -t 1 && test -t 2; then printf 'tty\\n'; else printf 'not-tty\\n'; fi\n",
    );
    defer gpa.free(producer);

    const child = try support.spawnJournalZsh(gpa, &journal);
    var transcript: std.ArrayList(u8) = .empty;
    defer transcript.deinit(gpa);
    try support.setupJournalZsh(gpa, child, &transcript);
    const command = try std.fmt.allocPrint(
        gpa,
        "cd /; NOOUT_TEST_ENV=preserved command \"$TJ\" noout -- /bin/sh '{s}' 'two words' '*' --flag --help",
        .{producer},
    );
    defer gpa.free(command);
    const visible_from = transcript.items.len;
    var from = visible_from;
    try child.write(command);
    try child.write("\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, support.test_prompt, support.timeout_ms));
    from = transcript.items.len;
    try child.write("command \"$TJ\" noout -- /bin/sh -c 'exit 7'\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, support.test_prompt, support.timeout_ms));
    from = transcript.items.len;
    try child.write("command \"$TJ\" noout -- /bin/sh -c 'kill -TERM $$'\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, support.test_prompt, support.timeout_ms));
    from = transcript.items.len;
    try child.write("command \"$TJ\" noout -- /definitely/not/a/tj-command\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, support.test_prompt, support.timeout_ms));
    try child.write("exit 0\n");
    try std.testing.expectEqual(@as(u8, 0), try child.finish(gpa, &transcript, support.timeout_ms));

    const visible = transcript.items[visible_from..];
    if (std.mem.indexOf(u8, visible, "WRAPPER-STDOUT:two words|*|--flag|--help") == null) {
        std.debug.print("noout wrapper transcript follows:\n{s}\n", .{visible});
    }
    try std.testing.expect(std.mem.indexOf(u8, visible, "WRAPPER-STDOUT:two words|*|--flag|--help") != null);
    try std.testing.expect(std.mem.indexOf(u8, visible, "WRAPPER-STDERR") != null);
    try std.testing.expect(std.mem.indexOf(u8, visible, "WRAPPER-CONTEXT:/|preserved|tty") != null);
    try std.testing.expect(std.mem.indexOf(u8, visible, "5107;") == null);

    const first_out = try journal.read(gpa, "1/out");
    defer gpa.free(first_out);
    try std.testing.expect(std.mem.indexOf(u8, first_out, "<tj:noout>") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_out, "WRAPPER-STDOUT") == null);
    try std.testing.expect(std.mem.indexOf(u8, first_out, "WRAPPER-STDERR") == null);
    for ([_]struct { path: []const u8, want: []const u8 }{
        .{ .path = "1/rc", .want = "0\n" },
        .{ .path = "2/rc", .want = "7\n" },
        .{ .path = "3/rc", .want = "143\n" },
        .{ .path = "4/rc", .want = "127\n" },
    }) |case| {
        const rc = try journal.read(gpa, case.path);
        defer gpa.free(rc);
        try std.testing.expectEqualStrings(case.want, rc);
    }
}

test "tj noout syntax and journal preconditions fail without emitting OSC" {
    const gpa = std.testing.allocator;
    support.leaveJournal();

    const missing_separator = try support.runNonTty(gpa, &.{"noout"});
    defer gpa.free(missing_separator.stdout);
    defer gpa.free(missing_separator.stderr);
    try std.testing.expectEqual(@as(u8, 2), missing_separator.term.exited);
    try std.testing.expect(std.mem.indexOf(u8, missing_separator.stdout, "5107;") == null);
    try std.testing.expect(std.mem.indexOf(u8, missing_separator.stderr, "requires `--`") != null);

    const misplaced_command = try support.runNonTty(gpa, &.{ "noout", "/bin/true" });
    defer gpa.free(misplaced_command.stdout);
    defer gpa.free(misplaced_command.stderr);
    try std.testing.expectEqual(@as(u8, 2), misplaced_command.term.exited);
    try std.testing.expect(std.mem.indexOf(u8, misplaced_command.stdout, "5107;") == null);
    try std.testing.expect(std.mem.indexOf(u8, misplaced_command.stderr, "too many arguments") != null);

    const outside = try support.runNonTty(gpa, &.{ "noout", "--", "/bin/true" });
    defer gpa.free(outside.stdout);
    defer gpa.free(outside.stderr);
    try std.testing.expectEqual(@as(u8, 1), outside.term.exited);
    try std.testing.expect(std.mem.indexOf(u8, outside.stdout, "5107;") == null);
    try std.testing.expect(std.mem.indexOf(u8, outside.stderr, "inside a tj journal writer") != null);
}

test "native grep searches literal command and output lines with stable statuses" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var journal = try support.Journal.open(gpa);
    defer journal.close();
    const producer = try journal.fixture(gpa, "grep-producer.sh", "printf 'OUTPUT_LITERAL_012\\nMixedAscii012\\n'\n");
    defer gpa.free(producer);
    const producer_command = try std.fmt.allocPrint(gpa, "/bin/sh '{s}'", .{producer});
    defer gpa.free(producer_command);
    try support.recordJournal(gpa, &journal, &.{ ": COMMAND_LITERAL_012", producer_command, ": '[x].*'", "printf 'BOTH_LITERAL_012\\n'" });
    try journal.enter(gpa);
    defer support.leaveJournal();
    support.sys.setEnv("TJ_NEXT", "");
    const home = try journal.homeArg(gpa);
    defer gpa.free(home);
    const id = try journal.journalName(gpa);
    defer gpa.free(id);

    const command_only = try support.runNonTtyInJournal(gpa, &.{ "--home", home, "grep", "--cmd", "COMMAND_LITERAL_012" }, id, "");
    defer gpa.free(command_only.stdout);
    defer gpa.free(command_only.stderr);
    try std.testing.expectEqual(@as(u8, 0), command_only.term.exited);
    try std.testing.expectEqualStrings("     1 > : COMMAND_LITERAL_012\n", command_only.stdout);
    try std.testing.expectEqualStrings("", command_only.stderr);

    const automatic_pipe = try support.runNonTtyInJournal(gpa, &.{ "--home", home, "grep", "--cmd", "--color", "auto", "COMMAND_LITERAL_012" }, id, "");
    defer gpa.free(automatic_pipe.stdout);
    defer gpa.free(automatic_pipe.stderr);
    try std.testing.expectEqualStrings(command_only.stdout, automatic_pipe.stdout);

    const forced_color = try support.runNonTtyInJournal(gpa, &.{ "--home", home, "grep", "--cmd", "--color=always", "COMMAND_LITERAL_012" }, id, "");
    defer gpa.free(forced_color.stdout);
    defer gpa.free(forced_color.stderr);
    try std.testing.expectEqualStrings("     1 > :\x1b[01;31m COMMAND_LITERAL_012\x1b[m\n", forced_color.stdout);

    const disabled_color = try support.runNonTtyInJournal(gpa, &.{ "--home", home, "grep", "--cmd", "--color=never", "COMMAND_LITERAL_012" }, id, "");
    defer gpa.free(disabled_color.stdout);
    defer gpa.free(disabled_color.stderr);
    try std.testing.expectEqualStrings(command_only.stdout, disabled_color.stdout);

    const output_only = try support.runNonTtyInJournal(gpa, &.{ "--home", home, "grep", "--out", "OUTPUT_LITERAL_012" }, id, "");
    defer gpa.free(output_only.stdout);
    defer gpa.free(output_only.stderr);
    try std.testing.expectEqual(@as(u8, 0), output_only.term.exited);
    try std.testing.expectEqualStrings("     2 < OUTPUT_LITERAL_012\n", output_only.stdout);

    const folded = try support.runNonTtyInJournal(gpa, &.{ "--home", home, "grep", "-i", "mixedascii012" }, id, "");
    defer gpa.free(folded.stdout);
    defer gpa.free(folded.stderr);
    try std.testing.expectEqual(@as(u8, 0), folded.term.exited);
    try std.testing.expect(std.mem.indexOf(u8, folded.stdout, "     2 < MixedAscii012") != null);

    const literal = try support.runNonTtyInJournal(gpa, &.{ "--home", home, "grep", "--cmd", "[x].*" }, id, "");
    defer gpa.free(literal.stdout);
    defer gpa.free(literal.stderr);
    try std.testing.expectEqual(@as(u8, 0), literal.term.exited);
    try std.testing.expectEqualStrings("     3 > : '[x].*'\n", literal.stdout);

    const missing = try support.runNonTtyInJournal(gpa, &.{ "--home", home, "grep", "absent-literal-012" }, id, "");
    defer gpa.free(missing.stdout);
    defer gpa.free(missing.stderr);
    try std.testing.expectEqual(@as(u8, 1), missing.term.exited);
    try std.testing.expectEqualStrings("", missing.stdout);
    try std.testing.expectEqualStrings("", missing.stderr);

    const bad = try support.runNonTtyInJournal(gpa, &.{ "--home", home, "grep", "--unknown", "x" }, id, "");
    defer gpa.free(bad.stdout);
    defer gpa.free(bad.stderr);
    try std.testing.expectEqual(@as(u8, 2), bad.term.exited);
    try std.testing.expect(std.mem.indexOf(u8, bad.stderr, "Usage: tj grep") != null);

    const leading = try support.runNonTtyInJournal(gpa, &.{ "--home", home, "grep", "--", "-not-present" }, id, "");
    defer gpa.free(leading.stdout);
    defer gpa.free(leading.stderr);
    try std.testing.expectEqual(@as(u8, 1), leading.term.exited);

    const both = try support.runNonTtyInJournal(gpa, &.{ "--home", home, "grep", "--cmd", "--out", "BOTH_LITERAL_012" }, id, "");
    defer gpa.free(both.stdout);
    defer gpa.free(both.stderr);
    try std.testing.expectEqual(@as(u8, 0), both.term.exited);
    try std.testing.expect(std.mem.indexOf(u8, both.stdout, "     4 >") != null);
    try std.testing.expect(std.mem.indexOf(u8, both.stdout, "     4 <") != null);

    const outside = try support.runNonTtyInJournal(gpa, &.{ "--home", home, "grep", "x" }, "", "");
    defer gpa.free(outside.stdout);
    defer gpa.free(outside.stderr);
    try std.testing.expectEqual(@as(u8, 2), outside.term.exited);
    try std.testing.expectEqualStrings("tj grep: no current journal; use --all\n", outside.stderr);

    const help = try support.runNonTtyInJournal(gpa, &.{ "grep", "--help" }, "", "");
    defer gpa.free(help.stdout);
    defer gpa.free(help.stderr);
    try std.testing.expectEqual(@as(u8, 0), help.term.exited);
    try std.testing.expect(std.mem.indexOf(u8, help.stdout, "Usage: tj grep") != null);

    var dir = try journal.journalDir();
    defer dir.close(io);
    try dir.deleteFile(io, "2/out");
    try dir.deleteTree(io, "3");
    const removed = try support.runNonTtyInJournal(gpa, &.{ "--home", home, "grep", "OUTPUT_LITERAL_012" }, id, "");
    defer gpa.free(removed.stdout);
    defer gpa.free(removed.stderr);
    try std.testing.expectEqual(@as(u8, 1), removed.term.exited);
}

test "native grep all uses complete journal names in lexical order" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var journal = try support.Journal.open(gpa);
    defer journal.close();
    try support.recordJournal(gpa, &journal, &.{": SHARED_GREP_012"});
    const older = try journal.journalName(gpa);
    defer gpa.free(older);
    const lexical_last = journal_name.legacy(std.math.maxInt(u48), .{0} ** 10);

    var root = try journal.tmp.dir.openDir(io, support.journal_dir, .{});
    defer root.close(io);
    try root.createDir(io, &lexical_last, @enumFromInt(0o700));
    var lexical_last_dir = try root.openDir(io, &lexical_last, .{});
    defer lexical_last_dir.close(io);
    try lexical_last_dir.createDir(io, "1", @enumFromInt(0o700));
    var interaction = try lexical_last_dir.openDir(io, "1", .{});
    defer interaction.close(io);
    try interaction.writeFile(io, .{ .sub_path = "cmd", .data = ": SHARED_GREP_012" });
    try interaction.writeFile(io, .{ .sub_path = "out", .data = "SHARED_GREP_012\n" });
    try interaction.writeFile(io, .{ .sub_path = "rc", .data = "0\n" });

    support.leaveJournal();
    const home = try journal.homeArg(gpa);
    defer gpa.free(home);
    const result = try support.runNonTtyInJournal(gpa, &.{ "--home", home, "grep", "--all", "SHARED_GREP_012" }, "", "");
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
    const older_ref = try std.fmt.allocPrint(gpa, "@{s}.1 > : SHARED_GREP_012", .{older});
    defer gpa.free(older_ref);
    const last_cmd = try std.fmt.allocPrint(gpa, "@{s}.1 > : SHARED_GREP_012", .{&lexical_last});
    defer gpa.free(last_cmd);
    const last_out = try std.fmt.allocPrint(gpa, "@{s}.1 < SHARED_GREP_012", .{&lexical_last});
    defer gpa.free(last_out);
    const older_at = std.mem.indexOf(u8, result.stdout, older_ref) orelse return error.TestUnexpectedResult;
    const last_cmd_at = std.mem.indexOf(u8, result.stdout, last_cmd) orelse return error.TestUnexpectedResult;
    const last_out_at = std.mem.indexOf(u8, result.stdout, last_out) orelse return error.TestUnexpectedResult;
    try std.testing.expect(older_at < last_cmd_at and last_cmd_at < last_out_at);
}

test "history and grep never replay stored terminal controls" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var scratch = try support.Scratch.open();
    defer scratch.close();

    const id = journal_name.legacy(48, .{8} ** 10);
    try scratch.makeJournal(id, &.{"1"});
    var journal = try scratch.tmp.dir.openDir(io, &id, .{});
    defer journal.close(io);
    const dangerous = "needle before\x1b[2J\x1b[Hneedle after\rneedle title\x1b]0;PWNED\x07 tail\x01";
    try journal.writeFile(io, .{ .sub_path = "1/cmd", .data = dangerous });
    try journal.writeFile(io, .{ .sub_path = "1/out", .data = dangerous ++ "\n" });
    try journal.writeFile(io, .{ .sub_path = "1/rc", .data = "0\n" });

    const history = try support.runNonTtyInJournal(gpa, &.{ "--home", scratch.path(), "hist" }, &id, "3");
    defer gpa.free(history.stdout);
    defer gpa.free(history.stderr);
    try std.testing.expectEqual(@as(u8, 0), history.term.exited);
    try support.expectSafeStoredReport(history.stdout);
    try std.testing.expect(std.mem.indexOf(u8, history.stdout, "needle beforeneedle after needle title tail") != null);

    const grep = try support.runNonTtyInJournal(gpa, &.{ "--home", scratch.path(), "grep", "needle" }, &id, "3");
    defer gpa.free(grep.stdout);
    defer gpa.free(grep.stderr);
    try std.testing.expectEqual(@as(u8, 0), grep.term.exited);
    try support.expectSafeStoredReport(grep.stdout);
    try std.testing.expect(std.mem.indexOf(u8, grep.stdout, "needle beforeneedle after needle title tail") != null);

    const colored = try support.runNonTtyInJournal(
        gpa,
        &.{ "--home", scratch.path(), "grep", "--color", "always", "needle" },
        &id,
        "3",
    );
    defer gpa.free(colored.stdout);
    defer gpa.free(colored.stderr);
    try std.testing.expectEqual(@as(u8, 0), colored.term.exited);
    try std.testing.expect(std.mem.indexOf(u8, colored.stdout, "\x1b[01;31mneedle\x1b[m") != null);
    try std.testing.expect(std.mem.indexOf(u8, colored.stdout, "\x1b[2J") == null);
    try std.testing.expect(std.mem.indexOf(u8, colored.stdout, "\x1b]0;") == null);
    try std.testing.expect(std.mem.indexOf(u8, colored.stdout, "PWNED") == null);
}

test "terminal native grep omits its results while redirected output stays plain" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var journal = try support.Journal.open(gpa);
    defer journal.close();
    const producer = try journal.fixture(
        gpa,
        "native-grep-producer.sh",
        "printf '  NOOUT_GREP_PAYLOAD_012    padded\\tresult  \\n'\n",
    );
    defer gpa.free(producer);
    const redirected_path = try journal.fixture(gpa, "redirected-grep", "");
    defer gpa.free(redirected_path);

    const child = try support.spawnJournalZsh(gpa, &journal);
    var transcript: std.ArrayList(u8) = .empty;
    defer transcript.deinit(gpa);
    try support.setupJournalZsh(gpa, child, &transcript);
    const command = try std.fmt.allocPrint(gpa, "/bin/sh '{s}'", .{producer});
    defer gpa.free(command);
    var from = transcript.items.len;
    try child.write(command);
    try child.write("\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, support.test_prompt, support.timeout_ms));

    // Grep rows share history's entry annotation and failure markers.
    var journal_dir_handle = try journal.journalDir();
    defer journal_dir_handle.close(std.testing.io);
    try journal_dir_handle.writeFile(std.testing.io, .{ .sub_path = "1/rc", .data = "7\n" });
    try journal.enter(gpa);
    defer support.leaveJournal();
    const home = try journal.homeArg(gpa);
    defer gpa.free(home);
    for ([_][]const []const u8{
        &.{ "--home", home, "name", "@1", "grep-hit" },
        &.{ "--home", home, "tag", "@1", "bug", "parser" },
        &.{ "--home", home, "pin", "@1" },
    }) |annotation_args| {
        var result = try support.run(gpa, annotation_args, 24, 100);
        defer result.out.deinit(gpa);
        try std.testing.expectEqual(@as(u8, 0), result.code);
    }

    from = transcript.items.len;
    try child.write("env -u NO_COLOR TERM=xterm-256color GREP_COLORS='mt=4;32' \"$TJ\" grep --color auto --out NOOUT_GREP_PAYLOAD_012\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, "*@#\x1b[31m!\x1b[0m \x1b[33m1\x1b[0m \x1b[2m<\x1b[0m", support.timeout_ms));
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, "\x1b[4;32mNOOUT_GREP_PAYLOAD_012\x1b[m", support.timeout_ms));
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, "\x1b[32m@grep-hit #bug #parser\x1b[0m", support.timeout_ms));
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, "\x1b[31m!7\x1b[0m", support.timeout_ms));
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, support.test_prompt, support.timeout_ms));

    from = transcript.items.len;
    try child.write("command \"$TJ\" grep --out NOOUT_GREP_PAYLOAD_012\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, support.test_prompt, support.timeout_ms));

    const redirect_command = try std.fmt.allocPrint(
        gpa,
        "command \"$TJ\" grep --out NOOUT_GREP_PAYLOAD_012 >'{s}'",
        .{redirected_path},
    );
    defer gpa.free(redirect_command);
    from = transcript.items.len;
    try child.write(redirect_command);
    try child.write("\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, support.test_prompt, support.timeout_ms));

    from = transcript.items.len;
    try child.write("command \"$TJ\" grep --cmd SELF_ONLY_GREP_012; printf 'SELF-STATUS=%s\\n' $?\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, "SELF-STATUS=1", support.timeout_ms));
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, support.test_prompt, support.timeout_ms));
    try child.write("exit 0\n");
    try std.testing.expectEqual(@as(u8, 0), try child.finish(gpa, &transcript, support.timeout_ms));

    for ([_][]const u8{ "2/out", "3/out" }) |path| {
        const recorded = try journal.read(gpa, path);
        defer gpa.free(recorded);
        try std.testing.expect(std.mem.indexOf(u8, recorded, "<tj:noout>") != null);
        try std.testing.expect(std.mem.indexOf(u8, recorded, "NOOUT_GREP_PAYLOAD_012") == null);
        try std.testing.expect(std.mem.indexOf(u8, recorded, "5107;") == null);
    }
    const redirected = try journal.tmp.dir.readFileAlloc(std.testing.io, "redirected-grep", gpa, .limited(4096));
    defer gpa.free(redirected);
    try std.testing.expectEqualStrings(
        "*@#! 1 < NOOUT_GREP_PAYLOAD_012 padded result @grep-hit #bug #parser !7\n",
        redirected,
    );
    const redirected_out = try journal.read(gpa, "4/out");
    defer gpa.free(redirected_out);
    try std.testing.expect(std.mem.indexOf(u8, redirected_out, "<tj:noout>") == null);
    try std.testing.expect(std.mem.indexOf(u8, redirected_out, "5107;") == null);
    const self_out = try journal.read(gpa, "5/out");
    defer gpa.free(self_out);
    try std.testing.expect(std.mem.indexOf(u8, self_out, "SELF-STATUS=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, self_out, "<tj:noout>") == null);
}

test "a program can publish parts of its output as named resources" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try support.Journal.open(gpa);
    defer journal.close();

    const script = try support.publisher(gpa, "before\\n" ++
        "\\033]5107;RESOURCE;files/data.csv;text/csv\\033\\\\" ++
        "date,amount\\n2026-08-01,12.50\\n" ++
        "\\033]5107;END\\033\\\\" ++
        "after\\n");
    defer gpa.free(script);
    try support.recordJournal(gpa, &journal, &.{script});

    const resource = try journal.read(gpa, "1/files/data.csv");
    defer gpa.free(resource);
    try std.testing.expectEqualStrings("date,amount\n2026-08-01,12.50\n", resource);

    // The resource is a span of the output, not a replacement for it.
    const out = try journal.read(gpa, "1/out");
    defer gpa.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "2026-08-01,12.50") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "before") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "after") != null);
    // The markers themselves are protocol, not output.
    try std.testing.expect(std.mem.indexOf(u8, out, "5107") == null);

    const meta = try journal.read(gpa, "1/meta.json");
    defer gpa.free(meta);
    try std.testing.expect(std.mem.indexOf(u8, meta, "\"files/data.csv\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, meta, "\"text/csv\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, meta, "\"truncated\":false") != null);
}

test "a resource name cannot escape the entry or overwrite tj's own files" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try support.Journal.open(gpa);
    defer journal.close();

    const script = try support.publisher(gpa, "\\033]5107;RESOURCE;../../escape\\033\\\\PWNED\\033]5107;END\\033\\\\" ++
        "\\033]5107;RESOURCE;out\\033\\\\CLOBBER\\033]5107;END\\033\\\\" ++
        "\\033]5107;RESOURCE;/etc/passwd\\033\\\\ROOT\\033]5107;END\\033\\\\" ++
        "\\033]5107;RESOURCE;ok/kept.txt\\033\\\\legit\\033]5107;END\\033\\\\");
    defer gpa.free(script);
    try support.recordJournal(gpa, &journal, &.{script});

    // The one valid name is published.
    const kept = try journal.read(gpa, "1/ok/kept.txt");
    defer gpa.free(kept);
    try std.testing.expectEqualStrings("legit", kept);

    // The rest are refused, and `out` still holds what support.tj put there.
    var dir = try journal.journalDir();
    defer dir.close(std.testing.io);
    try std.testing.expectError(error.FileNotFound, dir.openFile(std.testing.io, "1/escape", .{}));

    const out = try journal.read(gpa, "1/out");
    defer gpa.free(out);
    // Present as output, because the program printed it; not as the file.
    try std.testing.expect(std.mem.indexOf(u8, out, "CLOBBER") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "PWNED") != null);

    // And every refusal is on the record.
    const log = try journal.read(gpa, "log");
    defer gpa.free(log);
    try std.testing.expect(std.mem.indexOf(u8, log, "../../escape") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "refused resource name out") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "/etc/passwd") != null);
}

test "a resource the program never closed is flagged truncated" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try support.Journal.open(gpa);
    defer journal.close();

    const script = try support.publisher(gpa, "\\033]5107;RESOURCE;partial\\033\\\\half a file");
    defer gpa.free(script);
    try support.recordJournal(gpa, &journal, &.{script});

    const resource = try journal.read(gpa, "1/partial");
    defer gpa.free(resource);
    try std.testing.expect(std.mem.indexOf(u8, resource, "half a file") != null);

    const meta = try journal.read(gpa, "1/meta.json");
    defer gpa.free(meta);
    try std.testing.expect(std.mem.indexOf(u8, meta, "\"truncated\":true") != null);
}

test "published resources are addressable and completable" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try support.Journal.open(gpa);
    defer journal.close();

    const script = try support.publisher(gpa, "\\033]5107;RESOURCE;files/note.txt;text/plain\\033\\\\hello resource\\033]5107;END\\033\\\\");
    defer gpa.free(script);
    try support.recordJournal(gpa, &journal, &.{script});
    try journal.enter(gpa);

    const home = try journal.homeArg(gpa);
    defer gpa.free(home);

    var read = try support.run(gpa, &.{ "--home", home, "cat", "@1/files/note.txt" }, 24, 80);
    defer read.out.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, read.out.items, "hello resource") != null);

    var offered = try support.run(gpa, &.{ "--home", home, "complete", "@1/files/" }, 24, 80);
    defer offered.out.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, offered.out.items, "@1/files/note.txt") != null);

    // `files/` shows up as a directory alongside the core resources.
    var top = try support.run(gpa, &.{ "--home", home, "complete", "@1/" }, 24, 80);
    defer top.out.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, top.out.items, "@1/files/") != null);
}

test "zsh completion keeps special resource names as one inert argument" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var journal = try support.Journal.open(gpa);
    defer journal.close();
    var journal_root = try journal.tmp.dir.openDir(io, support.journal_dir, .{});
    try journal_root.createDir(io, "release-build", @enumFromInt(0o700));
    journal_root.close(io);

    const child = try support.spawnJournalZsh(gpa, &journal);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try support.setupJournalZsh(gpa, child, &out);

    const publish = try support.publisher(gpa, "\\033]5107;RESOURCE;files/note *$ file.txt;text/plain\\033\\\\" ++
        "special-resource-content\\033]5107;END\\033\\\\" ++
        "\\033]5107;RESOURCE;top *$ note.txt;text/plain\\033\\\\" ++
        "top-resource-content\\033]5107;END\\033\\\\");
    defer gpa.free(publish);
    var from = out.items.len;
    try child.write(publish);
    try child.write("\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, support.test_prompt, support.timeout_ms));

    from = out.items.len;
    // `compinit` may otherwise stop for its insecure-directory question on a
    // CI image. This fixture tests TJ's completion functions, not compinit's
    // trust policy, so ignore insecure system entries instead of prompting.
    // Keep the readiness marker split in the typed command: terminal echo
    // must not satisfy the wait before setup actually reaches its end.
    var completion_setup: std.ArrayList(u8) = .empty;
    defer completion_setup.deinit(gpa);
    // Generated external completers invoke `support.tj complete`. Point that name at
    // the just-built binary instead of any older TJ installed on the host.
    try completion_setup.appendSlice(gpa, "tj() { command ");
    try support.appendShellQuoted(gpa, &completion_setup, support.tj);
    try completion_setup.appendSlice(gpa, " \"$@\"; }; tjctl() { command ");
    try support.appendShellQuoted(gpa, &completion_setup, support.tjctl);
    try completion_setup.appendSlice(gpa, " \"$@\"; }; autoload -Uz compinit && compinit -D -i && . ");
    try support.appendShellQuoted(gpa, &completion_setup, options.zsh_completion);
    try completion_setup.appendSlice(gpa, " && . ");
    try support.appendShellQuoted(gpa, &completion_setup, options.tjctl_zsh_completion);
    try completion_setup.appendSlice(
        gpa,
        " && _tj_register_completion && print -r -- TJ_COMPINIT_\"\"READY\n",
    );
    try child.write(completion_setup.items);
    if (!try child.readUntilFrom(gpa, &out, from, "TJ_COMPINIT_READY", support.timeout_ms)) {
        std.debug.print("completion setup did not finish; transcript follows:\n{s}\n", .{out.items[from..]});
        return error.CompletionSetupDidNotFinish;
    }
    if (!try child.readUntilFrom(gpa, &out, from, support.test_prompt, support.timeout_ms)) {
        std.debug.print("completion setup did not return a prompt; transcript follows:\n{s}\n", .{out.items[from..]});
        return error.CompletionPromptMissing;
    }

    // Expose the exact editable buffer after completion without accepting it.
    from = out.items.len;
    try child.write(
        "_tj_test_buffer() { zle -M \"TJ_BUFFER=${(qqq)BUFFER} CURSOR=$CURSOR\"; }; " ++
            "zle -N _tj_test_buffer; " ++
            "bindkey -M emacs '^X^T' _tj_test_buffer; " ++
            "bindkey -M viins '^X^T' _tj_test_buffer\n",
    );
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, support.test_prompt, support.timeout_ms));

    // Zecli's generated script owns static command and option completion.
    from = out.items.len;
    try child.write("tjctl repla");
    try child.write("\t");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, "replay", support.timeout_ms));
    try support.cancelZleLine(gpa, child, &out);

    from = out.items.len;
    try child.write("tj hist --t");
    try child.write("\t");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, "--tag", support.timeout_ms));
    try support.cancelZleLine(gpa, child, &out);

    // A generated command completer must report success after adding matches.
    // Otherwise zsh retries it for every matcher and prints duplicate groups.
    from = out.items.len;
    try child.write(
        "zstyle ':completion:*' matcher-list '' " ++
            "'m:{a-zA-Z}={A-Za-z}' 'r:|[._-]=* r:|=*' 'l:|=* r:|=*'\n",
    );
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, support.test_prompt, support.timeout_ms));
    from = out.items.len;
    try child.write("tj grep -\t\x18\x14");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, "TJ_BUFFER=", support.timeout_ms));
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, out.items[from..], "Search every journal"),
    );
    try support.cancelZleLine(gpa, child, &out);

    from = out.items.len;
    try child.write("command \"$TJ\" name @1 build-failure\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, support.test_prompt, support.timeout_ms));

    // Expose preexec's exact command without changing the ZLE probe above.
    from = out.items.len;
    try child.write(
        "_tj_test_preexec() { print -r -- \"TJ_PREEXEC=${(qqq)1}\" > /dev/tty; }; " ++
            "add-zsh-hook preexec _tj_test_preexec\n",
    );
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, support.test_prompt, support.timeout_ms));

    // An unambiguous name gets its closing bracket and then behaves as a path.
    from = out.items.len;
    try child.write("cat ~[@1");
    try child.write("\t");
    if (!try child.readUntilFrom(gpa, &out, from, "~[@1]", support.timeout_ms)) {
        std.debug.print("numeric dynamic-directory completion failed; transcript follows:\n{s}\n", .{out.items[from..]});
        return error.NumericDirectoryCompletionMismatch;
    }
    try child.write("/out\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, "special-resource-content", support.timeout_ms));
    // Output can arrive before precmd has redrawn the prompt. Do not start the
    // next ZLE interaction until the shell is actually ready for input again.
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, support.test_prompt, support.timeout_ms));

    // Dynamic-directory name completion is offered inside ~[...].
    from = out.items.len;
    try child.write("cat ~[@");
    try child.write("\t");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, "@1", support.timeout_ms));
    try support.cancelZleLine(gpa, child, &out);

    // Assigned names participate in dynamic-directory name completion. First
    // inspect the completed path exactly as a user can with the probe widget.
    from = out.items.len;
    try child.write("cat ~[@build");
    try child.write("\t");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, "build-failure]", support.timeout_ms));
    try child.write("/out");
    try child.write("\x18\x14");
    if (!try child.readUntilFrom(
        gpa,
        &out,
        from,
        "TJ_BUFFER=\"cat ~[@build-failure]/out\" CURSOR=25",
        support.timeout_ms,
    )) {
        std.debug.print("named completion produced the wrong ZLE buffer; transcript follows:\n{s}\n", .{out.items[from..]});
        return error.NamedCompletionBufferMismatch;
    }
    try support.cancelZleLine(gpa, child, &out);

    // Repeat without the probe between completion and accept-line, then check
    // both what preexec received and what the resulting command produced.
    from = out.items.len;
    try child.write("cat ~[@build");
    try child.write("\t");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, "build-failure]", support.timeout_ms));
    try child.write("/out\n");
    if (!try child.readUntilFrom(
        gpa,
        &out,
        from,
        "TJ_PREEXEC=\"cat ~[@build-failure]/out\"",
        support.timeout_ms,
    )) {
        std.debug.print("named completion did not reach preexec intact; transcript follows:\n{s}\n", .{out.items[from..]});
        return error.NamedCompletionPreexecMismatch;
    }
    if (!try child.readUntilFrom(gpa, &out, from, "special-resource-content", support.timeout_ms)) {
        std.debug.print("named completion command produced no resource content; transcript follows:\n{s}\n", .{out.items[from..]});
        return error.NamedCompletionCommandFailed;
    }
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, support.test_prompt, support.timeout_ms));

    // Once the bracket is closed, ordinary filesystem completion lists the
    // interaction directory rather than going through the shorthand completer.
    from = out.items.len;
    try child.write("cat ~[@1]/");
    try child.write("\t");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, "files/", support.timeout_ms));
    try support.cancelZleLine(gpa, child, &out);

    from = out.items.len;
    try child.write("cat ~[@1]/files/note");
    try child.write("\t");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, "file.txt", support.timeout_ms));
    try child.write("\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, "special-resource-content", support.timeout_ms));
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, support.test_prompt, support.timeout_ms));

    // Shorthand resource completion works beneath a named interaction too.
    from = out.items.len;
    try child.write("cat @build-failure/files/note");
    try child.write("\t");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, "file.txt", support.timeout_ms));
    try child.write("\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, "special-resource-content", support.timeout_ms));
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, support.test_prompt, support.timeout_ms));

    from = out.items.len;
    try child.write("cat ~[@1]/top");
    try child.write("\t");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, "note.txt", support.timeout_ms));
    try child.write("\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, "top-resource-content", support.timeout_ms));
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, support.test_prompt, support.timeout_ms));

    // The original shorthand completion remains available.
    from = out.items.len;
    try child.write("cat @1/files/note");
    try child.write("\t");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, "file.txt", support.timeout_ms));
    try child.write("\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, "special-resource-content", support.timeout_ms));
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, support.test_prompt, support.timeout_ms));

    // Zecli's positional completion delegates back to `support.tj complete`, so TJ
    // commands get the same entry-resource candidates as arbitrary commands.
    // Keep this after the numeric dynamic-directory checks: cancelling a ZLE
    // line records a probe command and can create an otherwise-ambiguous @10.
    from = out.items.len;
    try child.write("tj cat @1/cw");
    try child.write("\t");
    if (!try child.readUntilFrom(gpa, &out, from, "@1/cwd", support.timeout_ms)) {
        std.debug.print("generated reference completion offered no cwd resource; transcript follows:\n{s}\n", .{out.items[from..]});
        return error.CommandReferenceCompletionMissing;
    }
    try child.write("\x18\x14");
    if (!try child.readUntilFrom(gpa, &out, from, "TJ_BUFFER=", support.timeout_ms)) {
        std.debug.print("generated reference completion produced the wrong ZLE buffer; transcript follows:\n{s}\n", .{out.items[from..]});
        return error.CommandReferenceCompletionMismatch;
    }
    try support.cancelZleLine(gpa, child, &out);

    // Journal operands delegate to tjctl's live canonical-name completer.
    // Keep this after @1 completion checks because cancelling ZLE lines records
    // probe entries and can make a numeric prefix ambiguous with @10.
    from = out.items.len;
    try child.write("tjctl use rel\t\x18\x14");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, "TJ_BUFFER=", support.timeout_ms));
    try std.testing.expect(std.mem.indexOf(u8, out.items[from..], "release-build") != null);
    try support.cancelZleLine(gpa, child, &out);

    try child.write("exit 0\n");
    try std.testing.expectEqual(@as(u8, 0), try child.finish(gpa, &out, support.timeout_ms));
}

test "a published resource survives arbitrary bytes" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try support.Journal.open(gpa);
    defer journal.close();

    // Everything that could plausibly be mistaken for control information:
    // a complete OSC, an unterminated one, the alternate screen switches,
    // every combination of CR and LF, tabs, and all 256 byte values.
    var blob: std.ArrayList(u8) = .empty;
    defer blob.deinit(gpa);
    try blob.appendSlice(gpa, "\x1b]0;title\x07");
    try blob.appendSlice(gpa, "\x1b]");
    try blob.appendSlice(gpa, &[_]u8{0} ** 8);
    try blob.appendSlice(gpa, "\x1b[?1049hpainted\x1b[?1049l");
    try blob.appendSlice(gpa, "\x1b]5108;other;x\x1b\\");
    try blob.appendSlice(gpa, "\r\n\n\r\r\n\t\t");
    for (0..256) |byte| try blob.append(gpa, @intCast(byte));

    const path = try journal.fixture(gpa, "blob.bin", blob.items);
    defer gpa.free(path);

    const script = try std.fmt.allocPrint(gpa, "printf '\\033]5107;RESOURCE;files/blob.bin;application/octet-stream\\033\\\\'; " ++
        "cat {s}; " ++
        "printf '\\033]5107;END\\033\\\\'", .{path});
    defer gpa.free(script);
    try support.recordJournal(gpa, &journal, &.{script});

    const recovered = try journal.read(gpa, "1/files/blob.bin");
    defer gpa.free(recovered);

    // The terminal's newline translation is undone exactly, so even a
    // carriage return the data really contained comes back.
    try std.testing.expectEqualSlices(u8, blob.items, recovered);
}
