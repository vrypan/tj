//! Command-line surface: help, schema errors, exit statuses, and stdio.

const std = @import("std");
const posix = std.posix;
const noout = @import("noout.zig");
const plain = @import("plain.zig");

const options = @import("build_options");
const tj = options.tj_exe;
const support = @import("it_support.zig");

test "both binaries report the manifest version" {
    const gpa = std.testing.allocator;

    const tj_version = try support.runNonTty(gpa, &.{"--version"});
    defer gpa.free(tj_version.stdout);
    defer gpa.free(tj_version.stderr);
    try std.testing.expectEqual(@as(u8, 0), tj_version.term.exited);
    try std.testing.expectEqualStrings("", tj_version.stderr);
    const expected_tj = try std.fmt.allocPrint(gpa, "tj {s}\n", .{options.version});
    defer gpa.free(expected_tj);
    try std.testing.expectEqualStrings(expected_tj, tj_version.stdout);

    const tjctl_version = try support.runTjctlNonTty(gpa, &.{"--version"});
    defer gpa.free(tjctl_version.stdout);
    defer gpa.free(tjctl_version.stderr);
    try std.testing.expectEqual(@as(u8, 0), tjctl_version.term.exited);
    try std.testing.expectEqualStrings("", tjctl_version.stderr);
    const expected_tjctl = try std.fmt.allocPrint(gpa, "tjctl {s}\n", .{options.version});
    defer gpa.free(expected_tjctl);
    try std.testing.expectEqualStrings(expected_tjctl, tjctl_version.stdout);
}

test "application and every command expose generated help" {
    const gpa = std.testing.allocator;
    support.leaveJournal();

    const root_cases = [_][]const []const u8{ &.{}, &.{"--help"} };
    for (root_cases) |args| {
        const result = try support.runNonTty(gpa, args);
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        try std.testing.expectEqual(@as(u8, 0), result.term.exited);
        try std.testing.expectEqualStrings("", result.stderr);
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Usage: tj [options] <command|@REF>") != null);
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Commands:") != null);
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, "hist, history") != null);
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, "--home <DIR>") != null);
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, "@release-build.42/out") != null);
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, "source /path/to/tj.plugin.zsh") != null);
    }

    const command_names = [_][]const u8{ "tui", "noout", "hist", "last", "cat", "resolve", "complete", "name", "tag", "pin", "rm", "grep" };
    for (command_names) |name| {
        const result = try support.runNonTty(gpa, &.{ name, "--help" });
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        try std.testing.expectEqual(@as(u8, 0), result.term.exited);
        try std.testing.expectEqualStrings("", result.stderr);
        const usage = try std.fmt.allocPrint(gpa, "Usage: tj {s}", .{name});
        defer gpa.free(usage);
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, usage) != null);
        if (std.mem.eql(u8, name, "grep")) {
            try std.testing.expect(std.mem.indexOf(u8, result.stdout, "--tui") != null);
        }
    }

    const control_names = [_][]const u8{ "new", "save", "use", "ls", "mv", "rm", "du", "replay", "current", "complete" };
    for (control_names) |name| {
        const result = try support.runTjctlNonTty(gpa, &.{ name, "--help" });
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        try std.testing.expectEqual(@as(u8, 0), result.term.exited);
        const usage = try std.fmt.allocPrint(gpa, "Usage: tjctl {s}", .{name});
        defer gpa.free(usage);
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, usage) != null);
        if (std.mem.eql(u8, name, "new")) try std.testing.expect(std.mem.indexOf(u8, result.stdout, "--temp") != null);
        if (std.mem.eql(u8, name, "use")) try std.testing.expect(std.mem.indexOf(u8, result.stdout, "--temp") == null);
    }

    const alias = try support.runNonTty(gpa, &.{ "history", "--help" });
    defer gpa.free(alias.stdout);
    defer gpa.free(alias.stderr);
    try std.testing.expectEqual(@as(u8, 0), alias.term.exited);
    try std.testing.expect(std.mem.indexOf(u8, alias.stdout, "Usage: tj hist") != null);

    const grep = try support.runNonTty(gpa, &.{ "grep", "--help" });
    defer gpa.free(grep.stdout);
    defer gpa.free(grep.stderr);
    try std.testing.expect(std.mem.indexOf(u8, grep.stdout, "Arguments:") != null);
    try std.testing.expect(std.mem.indexOf(u8, grep.stdout, "Options:") != null);
    try std.testing.expect(std.mem.indexOf(u8, grep.stdout, "--color, --colour <WHEN>") != null);
    try std.testing.expect(std.mem.indexOf(u8, grep.stdout, "choices: never, auto, always") != null);
    try std.testing.expect(std.mem.indexOf(u8, grep.stdout, "default: never") != null);
}

test "cat reads a plain file before any journal exists" {
    const gpa = std.testing.allocator;

    var scratch = try support.Scratch.open();
    defer scratch.close();
    try scratch.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "notes.txt", .data = "plain\n" });
    const file_path = try std.fmt.allocPrint(gpa, "{s}/notes.txt", .{scratch.path()});
    defer gpa.free(file_path);

    // A home that has never held a journal. Reading a filesystem path must not
    // depend on one existing; only a reference needs the journal root.
    const empty_home = try std.fmt.allocPrint(gpa, "{s}/never-recorded", .{scratch.path()});
    defer gpa.free(empty_home);

    const file_result = try support.runNonTty(gpa, &.{ "--home", empty_home, "cat", "--raw", file_path });
    defer gpa.free(file_result.stdout);
    defer gpa.free(file_result.stderr);
    try std.testing.expectEqualStrings("", file_result.stderr);
    try std.testing.expectEqual(@as(u8, 0), file_result.term.exited);
    try std.testing.expectEqualStrings("plain\n", file_result.stdout);

    // A reference with no journal still says so rather than silently passing.
    const reference = try support.runNonTty(gpa, &.{ "--home", empty_home, "cat", "@1/out" });
    defer gpa.free(reference.stdout);
    defer gpa.free(reference.stderr);
    try std.testing.expect(reference.term.exited != 0);
}

test "tui requires the current journal and an interactive terminal" {
    const gpa = std.testing.allocator;
    support.leaveJournal();

    const outside = try support.runNonTty(gpa, &.{"tui"});
    defer gpa.free(outside.stdout);
    defer gpa.free(outside.stderr);
    try std.testing.expectEqual(@as(u8, 1), outside.term.exited);
    try std.testing.expect(std.mem.indexOf(u8, outside.stderr, "inside a tj journal writer") != null);
    try std.testing.expect(std.mem.indexOf(u8, outside.stdout, "3110;") == null);

    const redirected = try support.runNonTtyInJournal(gpa, &.{"tui"}, "test-journal", "2");
    defer gpa.free(redirected.stdout);
    defer gpa.free(redirected.stderr);
    try std.testing.expectEqual(@as(u8, 1), redirected.term.exited);
    try std.testing.expect(std.mem.indexOf(u8, redirected.stderr, "interactive terminal") != null);
    try std.testing.expect(std.mem.indexOf(u8, redirected.stdout, "3110;") == null);
}

test "a closed stdout pipe exits quietly" {
    const gpa = std.testing.allocator;

    var scratch = try support.Scratch.open();
    defer scratch.close();
    const large = try gpa.alloc(u8, 1024 * 1024);
    defer gpa.free(large);
    @memset(large, 'x');
    large[0..6].* = "first\n".*;
    try scratch.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "large-output", .data = large });
    const large_path = try std.fmt.allocPrint(gpa, "{s}/large-output", .{scratch.path()});
    defer gpa.free(large_path);

    const cases = [_][]const []const u8{
        &.{"--help"},
        &.{"--version"},
        &.{ "hist", "--help" },
        &.{ "cat", "--raw", large_path },
    };
    for (cases) |args| {
        const result = try support.runWithClosedStdout(gpa, args);
        defer gpa.free(result.stderr);
        // Name the case and show what support.tj said. Without this a failure reports
        // only "expected 0, found 1", which identifies neither the argument
        // list nor the diagnostic that explains it.
        if (result.term != .exited or result.term.exited != 0 or result.stderr.len != 0) {
            std.debug.print(
                "closed-stdout case failed: argv={any} term={any} stderr=\"{s}\"\n",
                .{ args, result.term, result.stderr },
            );
        }
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
        try std.testing.expectEqualStrings("", result.stderr);
    }

    for ([_][]const []const u8{ &.{"--help"}, &.{"--version"}, &.{ "ls", "--help" } }) |args| {
        const result = try support.runTjctlWithClosedStdout(gpa, args);
        defer gpa.free(result.stderr);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
        try std.testing.expectEqualStrings("", result.stderr);
    }
}

test "build-time completions expose cli grammar and journal references" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const bash = try support.Dir.cwd().readFileAlloc(io, options.bash_completion, gpa, .limited(1 << 20));
    defer gpa.free(bash);
    try std.testing.expect(std.mem.indexOf(u8, bash, "complete -F _tj tj") != null);
    try std.testing.expect(std.mem.indexOf(u8, bash, "_tj__cmd_hist()") != null);
    try std.testing.expect(std.mem.indexOf(u8, bash, "_tj__cmd_ls()") == null);
    try std.testing.expect(std.mem.indexOf(u8, bash, "--tag") != null);
    try std.testing.expect(std.mem.indexOf(u8, bash, "never\\nauto\\nalways") != null);

    const zsh = try support.Dir.cwd().readFileAlloc(io, options.zsh_completion, gpa, .limited(1 << 20));
    defer gpa.free(zsh);
    try std.testing.expect(std.mem.startsWith(u8, zsh, "#compdef tj\n"));
    try std.testing.expect(std.mem.indexOf(u8, zsh, "'hist:List entries with annotations, size, and date'") != null);
    try std.testing.expect(std.mem.indexOf(u8, zsh, "'tui:Browse, inspect, annotate, and delete entries'") != null);
    try std.testing.expect(std.mem.indexOf(u8, zsh, "_tj__cmd_hist()") != null);
    try std.testing.expect(std.mem.indexOf(u8, zsh, "_tj__cmd_usage()") == null);
    try std.testing.expect(std.mem.indexOf(u8, zsh, "_tj__cmd_ls()") == null);
    try std.testing.expect(std.mem.indexOf(u8, zsh, "--tag=[") != null);
    try std.testing.expect(std.mem.indexOf(u8, zsh, "--pinned") != null);
    try std.testing.expect(std.mem.indexOf(u8, zsh, "--pin") != null);
    try std.testing.expect(std.mem.indexOf(u8, zsh, "WHEN:(never auto always)") != null);

    const fish = try support.Dir.cwd().readFileAlloc(io, options.fish_completion, gpa, .limited(1 << 20));
    defer gpa.free(fish);
    try std.testing.expect(std.mem.startsWith(u8, fish, "# fish completion for tj\n"));
    try std.testing.expect(std.mem.indexOf(u8, fish, "-a 'hist' -d 'List entries with annotations, size, and date'") != null);
    try std.testing.expect(std.mem.indexOf(u8, fish, "-a 'ls'") == null);
    try std.testing.expect(std.mem.indexOf(u8, fish, "__tj_using_command hist history") != null);
    try std.testing.expect(std.mem.indexOf(u8, fish, "__tj_vals_cmd_grep_f_color") != null);
    try std.testing.expect(std.mem.indexOf(u8, fish, "__tj_vals_cmd_journal_a_ACTION") == null);

    const ctl_zsh = try support.Dir.cwd().readFileAlloc(io, options.tjctl_zsh_completion, gpa, .limited(1 << 20));
    defer gpa.free(ctl_zsh);
    try std.testing.expect(std.mem.startsWith(u8, ctl_zsh, "#compdef tjctl\n"));
    try std.testing.expect(std.mem.indexOf(u8, ctl_zsh, "_tjctl__cmd_use()") != null);
    try std.testing.expect(std.mem.indexOf(u8, ctl_zsh, "--no-replay[") != null);
    try std.testing.expect(std.mem.indexOf(u8, ctl_zsh, "--no-splash[") != null);
    try std.testing.expect(std.mem.indexOf(u8, ctl_zsh, "--title=") != null);
    try std.testing.expect(std.mem.indexOf(u8, ctl_zsh, "--title-blink=") != null);
    try std.testing.expect(std.mem.indexOf(u8, ctl_zsh, "'tjctl' 'complete'") != null);

    // Positional entry-reference slots use the same runtime resolver as the
    // plugin's global shorthand completion.
    for ([_][]const u8{ bash, zsh, fish }) |script| {
        try std.testing.expect(std.mem.indexOf(u8, script, "'tj' 'complete'") != null);
    }
}

test "schema errors use status two and command help" {
    const gpa = std.testing.allocator;
    support.leaveJournal();

    const cases = [_]struct {
        args: []const []const u8,
        diagnostic: []const u8,
        usage: []const u8,
    }{
        .{ .args = &.{ "rm", "--journal", "abcd" }, .diagnostic = "unknown option", .usage = "Usage: tj rm" },
        .{ .args = &.{ "grep", "--unknown", "x" }, .diagnostic = "unknown option", .usage = "Usage: tj grep" },
        .{ .args = &.{ "cat", "--head" }, .diagnostic = "requires <N>", .usage = "Usage: tj cat" },
        .{ .args = &.{"resolve"}, .diagnostic = "missing required argument", .usage = "Usage: tj resolve" },
        .{ .args = &.{ "complete", "@1", "@2" }, .diagnostic = "too many arguments", .usage = "Usage: tj complete" },
        .{ .args = &.{ "grep", "--color=sometimes", "x" }, .diagnostic = "invalid value", .usage = "Usage: tj grep" },
        .{ .args = &.{ "grep", "--tui", "--all", "x" }, .diagnostic = "invalid arguments", .usage = "Usage: tj grep" },
        .{ .args = &.{ "grep", "--tui", "--color=never", "x" }, .diagnostic = "invalid arguments", .usage = "Usage: tj grep" },
        .{ .args = &.{"grep"}, .diagnostic = "invalid arguments", .usage = "Usage: tj grep" },
        .{ .args = &.{ "grep", "needle", "--", "other" }, .diagnostic = "invalid arguments", .usage = "Usage: tj grep" },
        .{ .args = &.{ "grep", "--", "one", "two" }, .diagnostic = "invalid arguments", .usage = "Usage: tj grep" },
    };
    for (cases) |case| {
        const result = try support.runNonTty(gpa, case.args);
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        try std.testing.expectEqual(@as(u8, 2), result.term.exited);
        try std.testing.expectEqualStrings("", result.stdout);
        try std.testing.expect(std.mem.indexOf(u8, result.stderr, case.diagnostic) != null);
        try std.testing.expect(std.mem.indexOf(u8, result.stderr, case.usage) != null);
    }
}

test "lifecycle passthrough requires a non-empty child command" {
    const gpa = std.testing.allocator;
    for ([_][]const []const u8{ &.{ "new", "--" }, &.{ "use", "journal", "--" } }) |args| {
        const result = try support.runTjctlNonTty(gpa, args);
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        try std.testing.expectEqual(@as(u8, 2), result.term.exited);
        try std.testing.expectEqualStrings("", result.stdout);
        try std.testing.expect(std.mem.indexOf(u8, result.stderr, "command is required after `--`") != null);
    }
}

test "removed journal commands are unknown under tj" {
    const gpa = std.testing.allocator;
    support.leaveJournal();
    for ([_][]const u8{ "new", "continue", "journal", "usage", "current", "replay" }) |name| {
        const result = try support.runNonTty(gpa, &.{name});
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        try std.testing.expectEqual(@as(u8, 2), result.term.exited);
        try std.testing.expectEqualStrings("", result.stdout);
        try std.testing.expect(std.mem.indexOf(u8, result.stderr, "unknown command") != null);
    }
}

test "exit status of the wrapped command is tj's exit status" {
    const gpa = std.testing.allocator;
    for ([_]u8{ 0, 3, 42 }) |want| {
        var script_buf: [32]u8 = undefined;
        const script = try std.fmt.bufPrint(&script_buf, "exit {d}", .{want});
        var r = try support.runTjctl(gpa, &.{ "new", "--", "/bin/sh", "-c", script }, 24, 80);
        defer r.out.deinit(gpa);
        try std.testing.expectEqual(want, r.code);
    }
}

test "a command killed by a signal reports 128+signal" {
    const gpa = std.testing.allocator;
    var r = try support.runTjctl(gpa, &.{ "new", "--", "/bin/sh", "-c", "kill -TERM $$" }, 24, 80);
    defer r.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 128 + 15), r.code);
}

test "the outer window size reaches the wrapped command" {
    const gpa = std.testing.allocator;
    var r = try support.runTjctl(gpa, &.{ "new", "--", "/bin/sh", "-c", "stty size" }, 31, 113);
    defer r.out.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, r.out.items, "31 113") != null);
}

test "the wrapped command sees a tty" {
    const gpa = std.testing.allocator;
    var r = try support.runTjctl(gpa, &.{ "new", "--", "/bin/sh", "-c", "test -t 0 && test -t 1 && echo ISTTY" }, 24, 80);
    defer r.out.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, r.out.items, "ISTTY") != null);
}

test "a command that cannot be executed exits 127" {
    const gpa = std.testing.allocator;
    var r = try support.runTjctl(gpa, &.{ "new", "--", "/nonexistent/program" }, 24, 80);
    defer r.out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 127), r.code);
}

test "input typed at the outer terminal reaches the shell" {
    const gpa = std.testing.allocator;
    const child = try support.spawnTjctl(gpa, &.{ support.tjctl, "new", "--", "/bin/sh" }, 24, 80);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    try child.write("echo ROUNDTRIP-$((6*7))\n");
    _ = try child.readUntil(gpa, &out, "ROUNDTRIP-42", support.timeout_ms);
    try child.write("exit\n");
    _ = try child.finish(gpa, &out, support.timeout_ms);

    try std.testing.expect(std.mem.indexOf(u8, out.items, "ROUNDTRIP-42") != null);
}

test "resizing the outer terminal resizes the inner one" {
    const gpa = std.testing.allocator;
    const child = try support.spawnTjctl(
        gpa,
        &.{ support.tjctl, "new", "--", "/bin/sh", "-c", "trap 'stty size; exit 0' WINCH; echo READY; while :; do sleep 1; done" },
        24,
        80,
    );
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    try std.testing.expect(try child.readUntil(gpa, &out, "READY", support.timeout_ms));
    const from = out.items.len;
    try child.resize(40, 100);
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, "40 100", support.timeout_ms));
    _ = try child.finish(gpa, &out, support.timeout_ms);

    try std.testing.expect(std.mem.indexOf(u8, out.items, "40 100") != null);
}

test "signals sent to tj are forwarded to the shell" {
    const gpa = std.testing.allocator;
    const child = try support.spawnTjctl(
        gpa,
        &.{ support.tjctl, "new", "--", "/bin/sh", "-c", "trap 'echo GOTTERM; exit 9' TERM; echo READY; while :; do sleep 1; done" },
        24,
        80,
    );
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    try std.testing.expect(try child.readUntil(gpa, &out, "READY", support.timeout_ms));
    // A shell that defers traps until its foreground child finishes must not
    // need longer than the test budget to get there, so the shell sleeps in
    // short steps instead of one long one.
    const from = out.items.len;
    _ = std.c.kill(child.pid, posix.SIG.TERM);
    try std.testing.expect(try child.readUntilFrom(gpa, &out, from, "GOTTERM", support.timeout_ms));
    _ = try child.finish(gpa, &out, support.timeout_ms);
}

test "the terminal is raw while tj is active and restored afterwards" {
    const gpa = std.testing.allocator;
    const child = try support.spawnTj(gpa, &.{options.selftest_exe}, 24, 80);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const code = try child.finish(gpa, &out, support.timeout_ms);
    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "RAW=yes") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "RESTORED=yes") != null);
}
