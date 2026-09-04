//! What a recording writer captures and how it behaves at a terminal.

const std = @import("std");
const posix = std.posix;
const journal_name = @import("../journal_name.zig");

const options = @import("build_options");
const tj = options.tj_exe;
const support = @import("it_support.zig");

test "commands are recorded as cmd, out and rc" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try support.Journal.open(gpa);
    defer journal.close();

    try support.recordJournal(gpa, &journal, &.{ "echo hello-journal", "false" });

    const first_cmd = try journal.read(gpa, "1/cmd");
    defer gpa.free(first_cmd);
    try std.testing.expectEqualStrings("echo hello-journal", first_cmd);

    const first_out = try journal.read(gpa, "1/out");
    defer gpa.free(first_out);
    try std.testing.expect(std.mem.indexOf(u8, first_out, "hello-journal") != null);

    const first_rc = try journal.read(gpa, "1/rc");
    defer gpa.free(first_rc);
    try std.testing.expectEqualStrings("0\n", first_rc);

    const second_cmd = try journal.read(gpa, "2/cmd");
    defer gpa.free(second_cmd);
    try std.testing.expectEqualStrings("false", second_cmd);

    const second_rc = try journal.read(gpa, "2/rc");
    defer gpa.free(second_rc);
    try std.testing.expectEqualStrings("1\n", second_rc);
}

test "each entry records the fully rendered zsh prompt" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try support.Journal.open(gpa);
    defer journal.close();
    // GitHub Actions does not guarantee a useful inherited TERM. Start zsh
    // with a known terminal description so this test exercises RPROMPT rather
    // than legitimately having zsh omit it for a dumb terminal.
    const home = try journal.homeArg(gpa);
    defer gpa.free(home);
    const child = try support.spawnTjctl(gpa, &.{
        support.tjctl, "--home", home, "new", "--", "/usr/bin/env", "TERM=xterm-256color", "/bin/zsh", "-f", "-i",
    }, 24, 80);
    var terminal = support.TerminalSession.init(gpa, child);
    defer terminal.deinit();
    const out = &terminal.transcript;
    try terminal.setupZsh("");

    // This stands in for prompt engines such as Starship: command and
    // parameter substitutions support.run while zsh renders a coloured, multiline
    // prompt with a right-hand side. TJ must retain those terminal bytes, not
    // the PROMPT source text and not a later re-evaluation of it.
    var from = out.items.len;
    try terminal.write("setopt promptsubst; PROMPT='%F{magenta}TJ_DYNAMIC_$(print -rn -- STARSHIP_LIKE)_${TJ_NEXT}%f\nTJ_SECOND> '; RPROMPT='TJ_RIGHT'\n");
    try terminal.expectFrom(from, "TJ_DYNAMIC_STARSHIP_LIKE_2");
    try terminal.expectFrom(from, "TJ_RIGHT");

    from = out.items.len;
    try terminal.write("echo PROMPT_CAPTURE_BODY\n");
    try terminal.expectFrom(from, "PROMPT_CAPTURE_BODY");
    try terminal.expectFrom(from, "TJ_DYNAMIC_STARSHIP_LIKE_3");
    try terminal.write("exit 0\n");
    try std.testing.expectEqual(@as(u8, 0), try terminal.finish());

    // Interaction 1 changes the prompt; interaction 2 is the command entered
    // at the rendered dynamic prompt whose TJ_NEXT value was 2.
    const prompt = try journal.read(gpa, "2/prompt");
    defer gpa.free(prompt);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "TJ_DYNAMIC_STARSHIP_LIKE_2") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "TJ_SECOND> ") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "TJ_RIGHT") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "\x1b[35m") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "$(print") == null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "PROMPT_CAPTURE_BODY") == null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "133;B") == null);
}

test "use appends to the same journal at its next unused number" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try support.Journal.open(gpa);
    defer journal.close();
    try support.recordJournal(gpa, &journal, &.{"echo original-entry"});

    const name = try journal.journalName(gpa);
    defer gpa.free(name);
    const child = try support.spawnContinuedJournalZsh(gpa, &journal, name);
    var terminal = support.TerminalSession.init(gpa, child);
    defer terminal.deinit();
    const out = &terminal.transcript;
    try terminal.setupZsh("");

    const from = out.items.len;
    try terminal.write("echo continued-entry\n");
    try terminal.expectPromptFrom(from);

    const env_from = out.items.len;
    try terminal.write("printf 'JENV=%s NEXT=%s REF=%s SHORT=%s\\n' \"$TJ_JOURNAL\" \"$TJ_NEXT\" \"$TJ_REF\" \"${TJ_JOURNAL_SHORT-unset}\"; command \"$TJCTL\" current\n");
    try terminal.expectFrom(env_from, name);
    try std.testing.expect(std.mem.indexOf(u8, out.items[env_from..], "SHORT=unset") != null);
    const expected_ref = try std.fmt.allocPrint(gpa, "REF=@{s}.", .{name});
    defer gpa.free(expected_ref);
    try std.testing.expect(std.mem.indexOf(u8, out.items[env_from..], expected_ref) != null);
    try terminal.expectPromptFrom(env_from);

    try terminal.write("exit 0\n");
    try std.testing.expectEqual(@as(u8, 0), try terminal.finish());

    const first = try journal.read(gpa, "1/cmd");
    defer gpa.free(first);
    const unfinished = try journal.read(gpa, "2/cmd");
    defer gpa.free(unfinished);
    const continued = try journal.read(gpa, "3/cmd");
    defer gpa.free(continued);
    try std.testing.expectEqualStrings("echo original-entry", first);
    try std.testing.expectEqualStrings("exit 0", unfinished);
    try std.testing.expectEqualStrings("echo continued-entry", continued);

    const home = try journal.homeArg(gpa);
    defer gpa.free(home);
    var listed = try support.runTjctl(gpa, &.{ "--home", home, "ls" }, 24, 80);
    defer listed.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), listed.code);
    try std.testing.expect(std.mem.indexOf(u8, listed.out.items, name) != null);
}

test "new exports the journal environment" {
    const gpa = std.testing.allocator;
    var scratch = try support.Scratch.open();
    defer scratch.close();

    var r = try support.runTjctl(gpa, &.{
        "--home",
        scratch.path(),
        "new",
        "--",
        "/bin/sh",
        "-c",
        "printf 'J=%s N=%s TJ=%s TJCTL=%s TITLE=%s BLINK=%s\\n' \"$TJ_JOURNAL\" \"$TJ_NEXT\" \"$TJ\" \"$TJCTL\" \"$TJ_TITLE\" \"$TJ_TITLE_BLINK\"",
    }, 24, 80);
    defer r.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.out.items, " N=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out.items, support.tj) != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out.items, support.tjctl) != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out.items, "TITLE=none") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out.items, "BLINK=0") != null);
}

test "the zsh plugin evaluates the configured title at each prompt" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try support.Journal.open(gpa);
    defer journal.close();
    const home = try journal.homeArg(gpa);
    defer gpa.free(home);
    const format = "FORMAT:$TJ_REF:$((40 + 2)):$(printf COMMAND):$PWD:%1~";
    const child = try support.spawnTjctl(gpa, &.{
        support.tjctl, "--home", home, "new", "--title", format, "--", "/bin/zsh", "-f", "-i",
    }, 24, 80);
    var terminal = support.TerminalSession.init(gpa, child);
    defer terminal.deinit();
    const out = &terminal.transcript;
    try terminal.setupZsh("");

    try terminal.expectFrom(0, "FORMAT:@");
    try std.testing.expect(std.mem.indexOf(u8, out.items, ":42:COMMAND:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "$TJ_REF") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "%1~") == null);
    try terminal.write("exit 0\n");
    try std.testing.expectEqual(@as(u8, 0), try terminal.finish());
    try std.testing.expect(std.mem.indexOf(u8, out.items, "exit 0\x1b\\") != null);
}

test "use preserves unfinished numbers and gaps" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var scratch = try support.Scratch.open();
    defer scratch.close();

    const id = journal_name.legacy(20, .{8} ** 10);
    try scratch.makeJournal(id, &.{ "1", "3" });
    const child = try support.spawnTjctl(gpa, &.{ support.tjctl, "--home", scratch.path(), "use", &id, "--", "/bin/zsh", "-f", "-i" }, 24, 80);
    var terminal = support.TerminalSession.init(gpa, child);
    defer terminal.deinit();
    const out = &terminal.transcript;
    try terminal.setupZsh("");
    const from = out.items.len;
    try terminal.write("echo after-gap\n");
    try terminal.expectPromptFrom(from);
    try terminal.write("exit 0\n");
    try std.testing.expectEqual(@as(u8, 0), try terminal.finish());

    var dir = try scratch.tmp.dir.openDir(io, &id, .{});
    defer dir.close(io);
    const cmd = try dir.readFileAlloc(io, "4/cmd", gpa, .limited(1024));
    defer gpa.free(cmd);
    try std.testing.expectEqualStrings("echo after-gap", cmd);
    var unfinished = try dir.openDir(io, "3", .{});
    unfinished.close(io);
}

test "tj's own control sequences never reach the terminal" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try support.Journal.open(gpa);
    defer journal.close();

    const child = try support.spawnJournalZsh(gpa, &journal);
    var terminal = support.TerminalSession.init(gpa, child);
    defer terminal.deinit();
    const out = &terminal.transcript;

    try terminal.setupZsh("");
    const from = out.items.len;
    try terminal.write("echo marker\n");
    try terminal.expectPromptFrom(from);
    try terminal.write("exit\n");
    try std.testing.expectEqual(@as(u8, 0), try terminal.finish());

    try std.testing.expect(std.mem.indexOf(u8, out.items, "marker") != null);
    // The command line travels inside an ELLO sequence; none of it may be shown.
    try std.testing.expect(std.mem.indexOf(u8, out.items, "3110") == null);
    // OSC 133 is another matter: it is forwarded, because the outer terminal
    // may implement shell integration itself.
    try std.testing.expect(std.mem.indexOf(u8, out.items, "133;") != null);
}

test "a command line with shell metacharacters survives the round trip" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try support.Journal.open(gpa);
    defer journal.close();

    // Semicolons would split the control sequence if it were not encoded.
    const tricky = "echo 'a;b' \"c;d\" | cat # trailing;comment";
    try support.recordJournal(gpa, &journal, &.{tricky});

    const recorded = try journal.read(gpa, "1/cmd");
    defer gpa.free(recorded);
    try std.testing.expectEqualStrings(tricky, recorded);
}

test "an interrupted writer leaves the entry without an rc" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try support.Journal.open(gpa);
    defer journal.close();

    const child = try support.spawnJournalZsh(gpa, &journal);
    var terminal = support.TerminalSession.init(gpa, child);
    defer terminal.deinit();
    const out = &terminal.transcript;

    try terminal.setupZsh("");
    const from = out.items.len;
    try terminal.write("sleep 30\n");
    // The echoed input arrives before preexec. Wait for the plugin's command
    // boundary so the proxy has opened the interaction before interrupting it.
    try terminal.expectFrom(from, "133;C");
    _ = std.c.kill(terminal.child.pid, posix.SIG.TERM);
    _ = try terminal.finish();

    const cmd = try journal.read(gpa, "1/cmd");
    defer gpa.free(cmd);
    try std.testing.expectEqualStrings("sleep 30", cmd);

    // No rc: readers must treat this as aborted, never as success.
    var dir = try journal.journalDir();
    defer dir.close(std.testing.io);
    try std.testing.expectError(error.FileNotFound, dir.openFile(std.testing.io, "1/rc", .{}));
}

test "entries record cwd and tjcd changes zsh without expanding its reference" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var journal = try support.Journal.open(gpa);
    defer journal.close();
    try journal.tmp.dir.createDir(io, "cwd target", @enumFromInt(0o700));
    const target = try std.fmt.allocPrint(gpa, "{s}/cwd target", .{journal.path()});
    defer gpa.free(target);

    const child = try support.spawnJournalZsh(gpa, &journal);
    var terminal = support.TerminalSession.init(gpa, child);
    defer terminal.deinit();
    const transcript = &terminal.transcript;
    try terminal.setupZsh("");

    var cd_command: std.ArrayList(u8) = .empty;
    defer cd_command.deinit(gpa);
    try cd_command.appendSlice(gpa, "cd ");
    try support.appendShellQuoted(gpa, &cd_command, target);
    try cd_command.append(gpa, '\n');
    var from = transcript.items.len;
    try terminal.write(cd_command.items);
    try terminal.expectPromptFrom(from);

    from = transcript.items.len;
    try terminal.write("print -r -- CWD_CAPTURE_BODY\n");
    try terminal.expectFrom(from, "CWD_CAPTURE_BODY");
    try terminal.expectPromptFrom(from);

    from = transcript.items.len;
    try terminal.write("cd /\n");
    try terminal.expectPromptFrom(from);

    from = transcript.items.len;
    try terminal.write("tjcd @2\n");
    try terminal.expectPromptFrom(from);

    const expected = try std.fmt.allocPrint(gpa, "TJCD_PWD={s}", .{target});
    defer gpa.free(expected);
    from = transcript.items.len;
    try terminal.write("print -r -- \"TJCD_PWD=$PWD\"\n");
    try terminal.expectFrom(from, expected);
    try terminal.expectPromptFrom(from);

    from = transcript.items.len;
    try terminal.write("cd /\n");
    try terminal.expectPromptFrom(from);

    const compound = "tjcd @2 && print -r -- \"TJCD_COMPOUND=$PWD\"";
    const compound_expected = try std.fmt.allocPrint(gpa, "TJCD_COMPOUND={s}", .{target});
    defer gpa.free(compound_expected);
    from = transcript.items.len;
    try terminal.write(compound ++ "\n");
    try terminal.expectFrom(from, compound_expected);
    try terminal.expectPromptFrom(from);

    try terminal.write("exit 0\n");
    try std.testing.expectEqual(@as(u8, 0), try terminal.finish());

    const recorded_target = try journal.read(gpa, "2/cwd");
    defer gpa.free(recorded_target);
    try std.testing.expectEqualStrings(target, recorded_target);
    const tjcd_cmd = try journal.read(gpa, "4/cmd");
    defer gpa.free(tjcd_cmd);
    try std.testing.expectEqualStrings("tjcd @2", tjcd_cmd);
    const tjcd_start = try journal.read(gpa, "4/cwd");
    defer gpa.free(tjcd_start);
    try std.testing.expectEqualStrings("/", tjcd_start);
    const after_tjcd = try journal.read(gpa, "5/cwd");
    defer gpa.free(after_tjcd);
    try std.testing.expectEqualStrings(target, after_tjcd);
    const compound_cmd = try journal.read(gpa, "7/cmd");
    defer gpa.free(compound_cmd);
    try std.testing.expectEqualStrings(compound, compound_cmd);

    // The lightweight function is defined even when recording hooks are
    // inactive, so a qualified reference works from an ordinary zsh too.
    const id = try journal.journalName(gpa);
    defer gpa.free(id);
    const home = try journal.homeArg(gpa);
    defer gpa.free(home);
    var outside_script: std.ArrayList(u8) = .empty;
    defer outside_script.deinit(gpa);
    try outside_script.appendSlice(gpa, ". ");
    try support.appendShellQuoted(gpa, &outside_script, options.plugin);
    try outside_script.appendSlice(gpa, "; tjcd ");
    const qualified = try std.fmt.allocPrint(gpa, "@{s}.2", .{id});
    defer gpa.free(qualified);
    try support.appendShellQuoted(gpa, &outside_script, qualified);
    try outside_script.appendSlice(gpa, " || exit; print -r -- \"OUTSIDE_TJCD=$PWD\"");
    var environ = try std.process.Environ.createMap(std.testing.environ, gpa);
    defer environ.deinit();
    try environ.put("TJ_HOME", home);
    try environ.put("TJ_JOURNAL", "");
    try environ.put("TJ", support.tj);
    const outside = try std.process.run(gpa, io, .{
        .argv = &.{ "/bin/zsh", "-f", "-c", outside_script.items },
        .environ_map = &environ,
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
    });
    defer gpa.free(outside.stdout);
    defer gpa.free(outside.stderr);
    try std.testing.expectEqual(@as(u8, 0), outside.term.exited);
    const outside_expected = try std.fmt.allocPrint(gpa, "OUTSIDE_TJCD={s}\n", .{target});
    defer gpa.free(outside_expected);
    try std.testing.expectEqualStrings(outside_expected, outside.stdout);
    try std.testing.expectEqualStrings("", outside.stderr);
}
