//! Shell reference parsing, expansion, validation, and completion.

const std = @import("std");
const plain = @import("../plain.zig");

const options = @import("build_options");
const support = @import("it_support.zig");

// Shell integration and basic reference parsing.

test "the tj zle hooks preserve prompt and tui widgets when sourced again" {
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

    // Sourcing TJ again must not duplicate either hook.
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

    var shorthand = try support.run(gpa, &.{ "--home", home, "@1/out" }, 24, 80);
    defer shorthand.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), shorthand.code);
    try std.testing.expectEqualStrings(ok.out.items, shorthand.out.items);
}

test "a direct tj reference remains literal in an interactive zsh" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try support.Journal.open(gpa);
    defer journal.close();
    try support.recordJournal(gpa, &journal, &.{"echo first"});

    const name = try journal.journalName(gpa);
    defer gpa.free(name);
    const child = try support.spawnContinuedJournalZsh(gpa, &journal, name);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try support.setupJournalZsh(gpa, child, &out);

    const from = out.items.len;
    try child.write("tj @1/out\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, "/1/out", support.timeout_ms));
    try child.write("exit 0\n");
    try std.testing.expectEqual(@as(u8, 0), try child.finish(gpa, &out, support.timeout_ms));
}

test "accepting a bare reference expands it in zsh" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try support.Journal.open(gpa);
    defer journal.close();
    const child = try support.spawnJournalZsh(gpa, &journal);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try support.setupJournalZsh(gpa, child, &out);

    var from = out.items.len;
    try child.write("printf 'accept-marker\\n'\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, support.test_prompt, support.timeout_ms));

    from = out.items.len;
    try child.write("cat @1/out\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, "accept-marker", support.timeout_ms));
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, support.test_prompt, support.timeout_ms));

    try child.write("exit 0\n");
    try std.testing.expectEqual(@as(u8, 0), try child.finish(gpa, &out, support.timeout_ms));

    const command = try journal.read(gpa, "2/cmd");
    defer gpa.free(command);
    try std.testing.expectEqualStrings("cat @1/out", command);
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

    var bad = try support.run(gpa, &.{ "--home", home, "resolve", "@0" }, 24, 80);
    defer bad.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), bad.code);
    try std.testing.expect(std.mem.indexOf(u8, bad.out.items, "tj: not a journal reference") != null);

    // Well formed, but there is no interaction 999.
    var missing = try support.run(gpa, &.{ "--home", home, "resolve", "@999/out" }, 24, 80);
    defer missing.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 2), missing.code);
    try std.testing.expect(std.mem.indexOf(u8, missing.out.items, "tj: no such entry") != null);
}

// Reference expansion, validation, and completion.

test "resolved bare references expand while unknown handles stay literal" {
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
    try std.testing.expectEqualStrings("printf 'NAMED=%s\\n' @build-failure/out", typed);
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

test "command substitutions resolve entry paths" {
    if (!support.haveZsh()) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var journal = try support.Journal.open(gpa);
    defer journal.close();

    try support.recordJournal(gpa, &journal, &.{
        "printf 'alpha-marker\\n'",
        "cat \"$(tj @1/out)\"",
        "cat \"$(tj @-/out)\"",
        "test -d \"$(tj @1)\" && printf 'directory-marker\\n'",
        "grep alpha-marker < \"$(tj @1/out)\" | cat",
        "cmp \"$(tj @1/out)\" \"$(tj @1/out)\" && printf 'multiple-marker\\n'",
        "alias tj_show='cat'",
        "tj_show \"$(tj @1/out)\"",
        "cat \"$(tj @0001/out)\"",
    });

    const second_out = try journal.read(gpa, "2/out");
    defer gpa.free(second_out);
    try std.testing.expect(std.mem.indexOf(u8, second_out, "alpha-marker") != null);

    const previous_out = try journal.read(gpa, "3/out");
    defer gpa.free(previous_out);
    try std.testing.expect(std.mem.indexOf(u8, previous_out, "alpha-marker") != null);

    const directory_out = try journal.read(gpa, "4/out");
    defer gpa.free(directory_out);
    try std.testing.expect(std.mem.indexOf(u8, directory_out, "directory-marker") != null);

    const pipeline_out = try journal.read(gpa, "5/out");
    defer gpa.free(pipeline_out);
    try std.testing.expect(std.mem.indexOf(u8, pipeline_out, "alpha-marker") != null);

    const multiple_out = try journal.read(gpa, "6/out");
    defer gpa.free(multiple_out);
    try std.testing.expect(std.mem.indexOf(u8, multiple_out, "multiple-marker") != null);

    const alias_out = try journal.read(gpa, "8/out");
    defer gpa.free(alias_out);
    try std.testing.expect(std.mem.indexOf(u8, alias_out, "alpha-marker") != null);

    // The journal records what was typed, not what ran.
    const second_cmd = try journal.read(gpa, "2/cmd");
    defer gpa.free(second_cmd);
    try std.testing.expectEqualStrings("cat \"$(tj @1/out)\"", second_cmd);

    // Explicit command substitutions do not add expanded metadata.
    const meta = try journal.read(gpa, "2/meta.json");
    defer gpa.free(meta);
    try std.testing.expect(std.mem.indexOf(u8, meta, "expanded_cmd") == null);

    const alias_cmd = try journal.read(gpa, "8/cmd");
    defer gpa.free(alias_cmd);
    try std.testing.expectEqualStrings("tj_show \"$(tj @1/out)\"", alias_cmd);
    const alias_meta = try journal.read(gpa, "8/meta.json");
    defer gpa.free(alias_meta);
    try std.testing.expect(std.mem.indexOf(u8, alias_meta, "cat ") != null);

    const leading_zero_out = try journal.read(gpa, "9/out");
    defer gpa.free(leading_zero_out);
    try std.testing.expect(std.mem.indexOf(u8, leading_zero_out, "alpha-marker") != null);
}

test "qualified command substitution resolves through a reused journal" {
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

    const command = try std.fmt.allocPrint(gpa, "cat \"$(tj @{s}.1/out)\"", .{"release-build"});
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
    try std.testing.expect(std.mem.indexOf(u8, meta, "expanded_cmd") == null);
}

test "history contains the accepted reference substitution" {
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
    var rendered: std.ArrayList(u8) = .empty;
    defer rendered.deinit(gpa);
    var rendered_writer = support.Io.Writer.Allocating.fromArrayList(gpa, &rendered);
    try plain.render(gpa, accepted, &rendered_writer.writer);
    rendered = rendered_writer.toArrayList();
    const home = try journal.homeArg(gpa);
    defer gpa.free(home);
    try std.testing.expect(std.mem.indexOf(u8, accepted, home) == null);

    from = out.items.len;
    try child.write("fc -ln -1\n");
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, "cat \"$(tj @1/out)\" >/dev/null", support.timeout_ms));
    try child.write("exit 0\n");
    try std.testing.expectEqual(@as(u8, 0), try child.finish(gpa, &out, support.timeout_ms));

    const command = try journal.read(gpa, "2/cmd");
    defer gpa.free(command);
    try std.testing.expectEqualStrings("cat @1/out >/dev/null", command);
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
        "echo \"literal @1/out here\"",
        "echo @0 @4294967296 @not-a-reference",
    });

    const quoted = try journal.read(gpa, "2/out");
    defer gpa.free(quoted);
    try std.testing.expect(std.mem.indexOf(u8, quoted, "literal @1/out here") != null);

    const address = try journal.read(gpa, "3/out");
    defer gpa.free(address);
    try std.testing.expect(std.mem.indexOf(u8, address, "user@host") != null);

    const malformed = try journal.read(gpa, "5/out");
    defer gpa.free(malformed);
    try std.testing.expect(std.mem.indexOf(u8, malformed, "@0 @4294967296 @not-a-reference") != null);

    // None of these lines contains an eligible unquoted shell-word reference.
    for ([_][]const u8{ "2/meta.json", "3/meta.json", "4/meta.json", "5/meta.json" }) |path| {
        const meta = try journal.read(gpa, path);
        defer gpa.free(meta);
        try std.testing.expect(std.mem.indexOf(u8, meta, "expanded_cmd") == null);
    }
}
