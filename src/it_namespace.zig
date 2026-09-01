//! The `@` namespace: references, completion, annotations, and removal.

const std = @import("std");
const posix = std.posix;
const harness = @import("harness.zig");
const noout = @import("noout.zig");
const plain = @import("plain.zig");
const report = @import("report.zig");
const journal_name = @import("journal_name.zig");

const options = @import("build_options");
const tj = options.tj_exe;
const support = @import("it_support.zig");

test "the tj zle hooks preserve existing widgets and register once" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try support.Journal.open(gpa);
    defer journal.close();

    const child = try support.spawnJournalZsh(gpa, &journal);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const prefix =
        "typeset -gi TJ_PRIOR_ACCEPT_COUNT=0; " ++
        "typeset -gi TJ_PRIOR_LINE_INIT_COUNT=0; " ++
        "_tj_prior_accept_line() { (( TJ_PRIOR_ACCEPT_COUNT++ )); zle .accept-line; }; " ++
        "_tj_prior_line_init() { (( TJ_PRIOR_LINE_INIT_COUNT++ )); }; " ++
        "zle -N accept-line _tj_prior_accept_line; " ++
        "zle -N zle-line-init _tj_prior_line_init";
    try support.setupJournalZshWithPrefix(gpa, child, &out, prefix);

    // Sourcing TJ again must neither replace the saved widget nor make TJ's
    // wrapper save and invoke itself recursively.
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(gpa);
    try source.appendSlice(gpa, ". ");
    try support.appendShellQuoted(gpa, &source, options.plugin);
    try source.append(gpa, '\n');
    var from = out.items.len;
    try child.write(source.items);
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, support.test_prompt, support.timeout_ms));

    from = out.items.len;
    try child.write("print -r -- TJ_PRIOR_ACCEPT_COUNT=$TJ_PRIOR_ACCEPT_COUNT TJ_PRIOR_LINE_INIT_COUNT=$TJ_PRIOR_LINE_INIT_COUNT\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, "TJ_PRIOR_ACCEPT_COUNT=2", support.timeout_ms));
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, "TJ_PRIOR_LINE_INIT_COUNT=2", support.timeout_ms));
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, support.test_prompt, support.timeout_ms));

    from = out.items.len;
    try child.write("print -r -- \"TJ_TUI_WIDGET=${widgets[_tj_tui_widget]}\"; bindkey -L '^X^T'\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, "TJ_TUI_WIDGET=user:_tj_tui_widget", support.timeout_ms));
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, "bindkey \"^X^T\" _tj_tui_widget", support.timeout_ms));
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, support.test_prompt, support.timeout_ms));

    try child.write("exit 0\n");
    const status = try child.finish(gpa, &out, support.timeout_ms);
    if (status != 0) std.debug.print("zle registration shell failed ({d}): {s}\n", .{ status, out.items });
    try std.testing.expectEqual(@as(u8, 0), status);
}

test "zsh preexec precedes dynamic named-directory expansion" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try support.Journal.open(gpa);
    defer journal.close();

    const child = try support.spawnJournalZsh(gpa, &journal);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try support.setupJournalZsh(gpa, child, &out);

    const from = out.items.len;
    try child.write("_tj_probe_directory_name() { if [[ $1 == n && $2 == @probe ]]; then print -r -- TJ_PROBE_DIRECTORY; typeset -ga reply; reply=(/tmp/tj-probe); return 0; fi; return 1; }; typeset -ga zsh_directory_name_functions; zsh_directory_name_functions+=(_tj_probe_directory_name)\n");
    try child.write("_tj_probe_preexec() { print -r -- \"TJ_PROBE_1=<$1>\"; print -r -- \"TJ_PROBE_2=<$2>\"; print -r -- \"TJ_PROBE_3=<$3>\"; }; add-zsh-hook preexec _tj_probe_preexec; alias tj_probe_alias='print -r --'\n");
    try child.write("tj_probe_alias ~[@probe]/out\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, "/tmp/tj-probe/out", support.timeout_ms));

    const transcript = out.items[from..];
    try std.testing.expect(std.mem.indexOf(u8, transcript, "TJ_PROBE_1=<tj_probe_alias ~[@probe]/out>") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "TJ_PROBE_2=<print -r -- ~[@probe]/out>") != null);
    const preexec_full = std.mem.indexOf(u8, transcript, "TJ_PROBE_3=<print -r -- ~[@probe]/out>") orelse return error.MissingPreexecProbe;
    const directory_call = std.mem.lastIndexOf(u8, transcript, "TJ_PROBE_DIRECTORY") orelse return error.MissingDirectoryProbe;
    try std.testing.expect(preexec_full < directory_call);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "/tmp/tj-probe/out") != null);

    try child.write("exit 0\n");
    try std.testing.expectEqual(@as(u8, 0), try child.finish(gpa, &out, support.timeout_ms));
}

test "the tj dynamic-directory handler composes and registers once" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try support.Journal.open(gpa);
    defer journal.close();

    const child = try support.spawnJournalZsh(gpa, &journal);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const prefix =
        "zsh_directory_name() { [[ $1 == n && $2 == @standalone ]] || return 1; typeset -ga reply; reply=(/tmp/standalone); }; " ++
        "_tj_existing_directory_name() { [[ $1 == n && $2 == @array ]] || return 1; typeset -ga reply; reply=(/tmp/array); }; " ++
        "typeset -ga zsh_directory_name_functions=(_tj_existing_directory_name)";
    try support.setupJournalZshWithPrefix(gpa, child, &out, prefix);

    var command: std.ArrayList(u8) = .empty;
    defer command.deinit(gpa);
    try command.appendSlice(gpa, ". ");
    try support.appendShellQuoted(gpa, &command, options.plugin);
    try command.appendSlice(
        gpa,
        "; typeset -i tj_handler_count=0; " ++
            "for tj_handler in \"${zsh_directory_name_functions[@]}\"; do [[ $tj_handler == _tj_directory_name ]] && (( tj_handler_count++ )); done; " ++
            "print -r -- \"TJ_HANDLERS=${(j:,:)zsh_directory_name_functions}\"; " ++
            "print -r -- \"TJ_HANDLER_COUNT=$tj_handler_count\"; " ++
            "print -rn -- TJ_STANDALONE=; print -r -- ~[@standalone]; " ++
            "print -rn -- TJ_ARRAY=; print -r -- ~[@array]; " ++
            "_tj_directory_name d /tmp; print -r -- \"TJ_D_STATUS=$?\"\n",
    );

    const from = out.items.len;
    try child.write(command.items);
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, "TJ_D_STATUS=1", support.timeout_ms));
    const transcript = out.items[from..];
    try std.testing.expect(std.mem.indexOf(u8, transcript, "TJ_HANDLERS=_tj_existing_directory_name,_tj_directory_name") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "TJ_HANDLER_COUNT=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "TJ_STANDALONE=/tmp/standalone") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "TJ_ARRAY=/tmp/array") != null);

    try child.write("exit 0\n");
    try std.testing.expectEqual(@as(u8, 0), try child.finish(gpa, &out, support.timeout_ms));
}

test "references resolve to paths inside the journal" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try support.Journal.open(gpa);
    defer journal.close();
    try support.recordJournal(gpa, &journal, &.{ "echo first", "echo second" });
    try journal.enter(gpa);

    const home = try journal.homeArg(gpa);
    defer gpa.free(home);

    var ok = try support.run(gpa, &.{ "--home", home, "resolve", "@1/out" }, 24, 80);
    defer ok.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), ok.code);
    try std.testing.expect(std.mem.indexOf(u8, ok.out.items, "/1/out") != null);
    try std.testing.expect(std.mem.startsWith(u8, ok.out.items, "/"));
}

test "a malformed reference and a missing one are told apart" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try support.Journal.open(gpa);
    defer journal.close();
    try support.recordJournal(gpa, &journal, &.{"echo only"});
    try journal.enter(gpa);

    const home = try journal.homeArg(gpa);
    defer gpa.free(home);

    // A valid interaction name that has not been assigned.
    var bad = try support.run(gpa, &.{ "--home", home, "resolve", "@nope" }, 24, 80);
    defer bad.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 2), bad.code);

    // Well formed, but there is no interaction 999.
    var missing = try support.run(gpa, &.{ "--home", home, "resolve", "@999/out" }, 24, 80);
    defer missing.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 2), missing.code);
}

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
    var transcript: std.ArrayList(u8) = .empty;
    defer transcript.deinit(gpa);
    try support.setupJournalZsh(gpa, child, &transcript);

    var from = transcript.items.len;
    try child.write("printf 'HIST_NOOUT_PAYLOAD_012\\n'\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, support.test_prompt, support.timeout_ms));

    from = transcript.items.len;
    try child.write("command \"$TJ\" hist\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, "HIST_NOOUT_PAYLOAD_012", support.timeout_ms));
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, support.test_prompt, support.timeout_ms));

    from = transcript.items.len;
    try child.write("command \"$TJ\" hist | cat\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, "HIST_NOOUT_PAYLOAD_012", support.timeout_ms));
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, support.test_prompt, support.timeout_ms));
    try child.write("exit 0\n");
    try std.testing.expectEqual(@as(u8, 0), try child.finish(gpa, &transcript, support.timeout_ms));

    const direct_out = try journal.read(gpa, "2/out");
    defer gpa.free(direct_out);
    try std.testing.expect(std.mem.indexOf(u8, direct_out, "<tj:noout>") != null);
    try std.testing.expect(std.mem.indexOf(u8, direct_out, "HIST_NOOUT_PAYLOAD_012") == null);
    try std.testing.expect(std.mem.indexOf(u8, direct_out, "5107;") == null);

    const piped_out = try journal.read(gpa, "3/out");
    defer gpa.free(piped_out);
    try std.testing.expect(std.mem.indexOf(u8, piped_out, "HIST_NOOUT_PAYLOAD_012") != null);
    try std.testing.expect(std.mem.indexOf(u8, piped_out, "<tj:noout>") == null);
    try std.testing.expect(std.mem.indexOf(u8, piped_out, "5107;") == null);
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
    var transcript: std.ArrayList(u8) = .empty;
    defer transcript.deinit(gpa);
    try support.setupJournalZsh(gpa, child, &transcript);
    const from = transcript.items.len;
    try child.write("command \"$TJ\" tag @1 @2 @3..@4 BUG parser\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &transcript, from, support.test_prompt, support.timeout_ms));
    try child.write("exit 0\n");
    try std.testing.expectEqual(@as(u8, 0), try child.finish(gpa, &transcript, support.timeout_ms));

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

    // Drive the range through real zsh: its shorthand canonicalizer must leave
    // the range word intact for the rm-specific parser. @4 is pinned, so the
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
        "printf '\\033]5107;BOGUS\\033\\\\'",
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

test "named shorthand expands only after a name is assigned" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var journal = try support.Journal.open(gpa);
    defer journal.close();

    const child = try support.spawnJournalZsh(gpa, &journal);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try support.setupJournalZsh(gpa, child, &out);

    for ([_][]const u8{
        "echo seed",
        "command \"$TJ\" name @1 build-failure",
        "printf 'NAMED=%s\\n' @build-failure/out",
        "printf 'HANDLE=%s\\n' @someone",
    }) |line| {
        const from = out.items.len;
        try child.write(line);
        try child.write("\n");
        try std.testing.expect(try child.readUntilFrom(gpa, &out, from, support.test_prompt, support.timeout_ms));
    }
    try child.write("exit 0\n");
    try std.testing.expectEqual(@as(u8, 0), try child.finish(gpa, &out, support.timeout_ms));

    try std.testing.expect(std.mem.indexOf(u8, out.items, "NAMED=") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "/1/out") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "HANDLE=@someone") != null);
    const typed = try journal.read(gpa, "3/cmd");
    defer gpa.free(typed);
    try std.testing.expect(std.mem.indexOf(u8, typed, "@build-failure/out") != null);
}

test "a reference cannot escape its entry directory" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try support.Journal.open(gpa);
    defer journal.close();
    try support.recordJournal(gpa, &journal, &.{"echo only"});
    try journal.enter(gpa);

    const home = try journal.homeArg(gpa);
    defer gpa.free(home);

    for ([_][]const u8{ "@1/../../../etc/passwd", "@1//etc/passwd", "@1/./out" }) |attempt| {
        var r = try support.run(gpa, &.{ "--home", home, "resolve", attempt }, 24, 80);
        defer r.out.deinit(gpa);
        try std.testing.expectEqual(@as(u8, 1), r.code);
        try std.testing.expect(std.mem.indexOf(u8, r.out.items, "/etc/passwd") == null);
    }
}

test "completion offers resources but never tj's own bookkeeping" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try support.Journal.open(gpa);
    defer journal.close();
    try support.recordJournal(gpa, &journal, &.{"echo one"});
    try journal.enter(gpa);

    const home = try journal.homeArg(gpa);
    defer gpa.free(home);

    var r = try support.run(gpa, &.{ "--home", home, "complete", "@1/" }, 24, 80);
    defer r.out.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, r.out.items, "@1/cmd") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out.items, "@1/cwd") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out.items, "@1/out") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out.items, "@1/prompt") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out.items, "@1/rc") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out.items, "meta.json") == null);
}

test "shorthand and canonical references become paths" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try support.Journal.open(gpa);
    defer journal.close();

    try support.recordJournal(gpa, &journal, &.{
        "printf 'alpha-marker\\n'",
        "cat @1/out",
        "cat ~[@1]/out",
        "cat @-/out",
        "test -d @1 && printf 'directory-marker\\n'",
        "grep alpha-marker < @1/out | cat",
        "cmp @1/out @1/out && printf 'multiple-marker\\n'",
        "alias tj_show='cat'",
        "tj_show @1/out",
        "cat @0001/out",
    });

    const second_out = try journal.read(gpa, "2/out");
    defer gpa.free(second_out);
    try std.testing.expect(std.mem.indexOf(u8, second_out, "alpha-marker") != null);

    const canonical_out = try journal.read(gpa, "3/out");
    defer gpa.free(canonical_out);
    try std.testing.expect(std.mem.indexOf(u8, canonical_out, "alpha-marker") != null);

    const previous_out = try journal.read(gpa, "4/out");
    defer gpa.free(previous_out);
    try std.testing.expect(std.mem.indexOf(u8, previous_out, "alpha-marker") != null);

    const directory_out = try journal.read(gpa, "5/out");
    defer gpa.free(directory_out);
    try std.testing.expect(std.mem.indexOf(u8, directory_out, "directory-marker") != null);

    const pipeline_out = try journal.read(gpa, "6/out");
    defer gpa.free(pipeline_out);
    try std.testing.expect(std.mem.indexOf(u8, pipeline_out, "alpha-marker") != null);

    const multiple_out = try journal.read(gpa, "7/out");
    defer gpa.free(multiple_out);
    try std.testing.expect(std.mem.indexOf(u8, multiple_out, "multiple-marker") != null);

    const alias_out = try journal.read(gpa, "9/out");
    defer gpa.free(alias_out);
    try std.testing.expect(std.mem.indexOf(u8, alias_out, "alpha-marker") != null);

    // The journal records what was typed, not what ran.
    const second_cmd = try journal.read(gpa, "2/cmd");
    defer gpa.free(second_cmd);
    try std.testing.expectEqualStrings("cat @1/out", second_cmd);

    const canonical_cmd = try journal.read(gpa, "3/cmd");
    defer gpa.free(canonical_cmd);
    try std.testing.expectEqualStrings("cat ~[@1]/out", canonical_cmd);

    // ...and what ran is kept alongside it.
    const meta = try journal.read(gpa, "2/meta.json");
    defer gpa.free(meta);
    try std.testing.expect(std.mem.indexOf(u8, meta, "expanded_cmd") != null);
    try std.testing.expect(std.mem.indexOf(u8, meta, "/1/out") != null);

    const canonical_meta = try journal.read(gpa, "3/meta.json");
    defer gpa.free(canonical_meta);
    try std.testing.expect(std.mem.indexOf(u8, canonical_meta, "expanded_cmd") != null);
    try std.testing.expect(std.mem.indexOf(u8, canonical_meta, "/1/out") != null);

    const alias_cmd = try journal.read(gpa, "9/cmd");
    defer gpa.free(alias_cmd);
    try std.testing.expectEqualStrings("tj_show @1/out", alias_cmd);
    const alias_meta = try journal.read(gpa, "9/meta.json");
    defer gpa.free(alias_meta);
    try std.testing.expect(std.mem.indexOf(u8, alias_meta, "cat ") != null);
    try std.testing.expect(std.mem.indexOf(u8, alias_meta, "/1/out") != null);

    const leading_zero_out = try journal.read(gpa, "10/out");
    defer gpa.free(leading_zero_out);
    try std.testing.expect(std.mem.indexOf(u8, leading_zero_out, "alpha-marker") != null);
}

test "qualified shorthand resolves through a reused journal" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try support.Journal.open(gpa);
    defer journal.close();
    try support.recordJournal(gpa, &journal, &.{"echo qualified-marker"});

    const name = try journal.journalName(gpa);
    defer gpa.free(name);
    const home = try journal.homeArg(gpa);
    defer gpa.free(home);
    support.leaveJournal();
    const renamed = try support.runTjctlNonTty(gpa, &.{ "--home", home, "mv", name, "release-build" });
    defer gpa.free(renamed.stdout);
    defer gpa.free(renamed.stderr);
    try std.testing.expectEqual(@as(u8, 0), renamed.term.exited);

    const command = try std.fmt.allocPrint(gpa, "cat @{s}.1/out", .{"release-build"});
    defer gpa.free(command);

    const child = try support.spawnContinuedJournalZsh(gpa, &journal, "release-build");
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try support.setupJournalZsh(gpa, child, &out);

    const from = out.items.len;
    try child.write(command);
    try child.write("\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, "qualified-marker", support.timeout_ms));
    try child.write("exit 0\n");
    try std.testing.expectEqual(@as(u8, 0), try child.finish(gpa, &out, support.timeout_ms));

    // The first writer's unfinished `exit` consumed 2, so continuation starts
    // at 3 rather than reusing it.
    const recorded = try journal.read(gpa, "3/cmd");
    defer gpa.free(recorded);
    try std.testing.expectEqualStrings(command, recorded);
    const meta = try journal.read(gpa, "3/meta.json");
    defer gpa.free(meta);
    try std.testing.expect(std.mem.indexOf(u8, meta, "/1/out") != null);
}

test "history is canonical while journal metadata keeps shorthand and paths" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try support.Journal.open(gpa);
    defer journal.close();
    const child = try support.spawnJournalZsh(gpa, &journal);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try support.setupJournalZsh(gpa, child, &out);

    var from = out.items.len;
    try child.write("echo history-marker\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, support.test_prompt, support.timeout_ms));

    from = out.items.len;
    try child.write("cat @1/out >/dev/null\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, support.test_prompt, support.timeout_ms));
    const accepted = out.items[from..];
    var visible: std.ArrayList(u8) = .empty;
    defer visible.deinit(gpa);
    var visible_writer = support.Io.Writer.Allocating.fromArrayList(gpa, &visible);
    try plain.render(gpa, accepted, &visible_writer.writer);
    visible = visible_writer.toArrayList();
    try std.testing.expect(std.mem.indexOf(u8, visible.items, "~[@1]/out") != null);
    const home = try journal.homeArg(gpa);
    defer gpa.free(home);
    try std.testing.expect(std.mem.indexOf(u8, accepted, home) == null);

    from = out.items.len;
    try child.write("fc -ln -1\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, "cat ~[@1]/out >/dev/null", support.timeout_ms));
    try child.write("exit 0\n");
    try std.testing.expectEqual(@as(u8, 0), try child.finish(gpa, &out, support.timeout_ms));

    const command = try journal.read(gpa, "2/cmd");
    defer gpa.free(command);
    try std.testing.expectEqualStrings("cat @1/out >/dev/null", command);
    const meta = try journal.read(gpa, "2/meta.json");
    defer gpa.free(meta);
    try std.testing.expect(std.mem.indexOf(u8, meta, "/1/out") != null);
}

test "quoted references and addresses are left alone" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try support.Journal.open(gpa);
    defer journal.close();
    try support.recordJournal(gpa, &journal, &.{
        "echo start",
        "echo 'literal @1/out here'",
        "echo user@host",
        "echo 'literal ~[@1]/out here'",
        "echo \"literal ~[@1]/out here\"",
        "echo @0 @4294967296 @not-a-reference",
    });

    const quoted = try journal.read(gpa, "2/out");
    defer gpa.free(quoted);
    try std.testing.expect(std.mem.indexOf(u8, quoted, "literal @1/out here") != null);

    const address = try journal.read(gpa, "3/out");
    defer gpa.free(address);
    try std.testing.expect(std.mem.indexOf(u8, address, "user@host") != null);

    const malformed = try journal.read(gpa, "6/out");
    defer gpa.free(malformed);
    try std.testing.expect(std.mem.indexOf(u8, malformed, "@0 @4294967296 @not-a-reference") != null);

    // None of these lines contains an eligible unquoted shell-word reference.
    for ([_][]const u8{ "2/meta.json", "3/meta.json", "4/meta.json", "5/meta.json", "6/meta.json" }) |path| {
        const meta = try journal.read(gpa, path);
        defer gpa.free(meta);
        try std.testing.expect(std.mem.indexOf(u8, meta, "expanded_cmd") == null);
    }
}
