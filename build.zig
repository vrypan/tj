const std = @import("std");
const manifest = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Omit debug information from installed binaries") orelse false;
    const zecli = b.dependency("zecli", .{});
    const zooi = b.dependency("zooi", .{});

    const exe_mod = applicationModule(b, zecli, "src/main.zig", target, optimize, strip);
    exe_mod.addImport("zooi", zooi.module("zooi"));
    const tjctl_mod = applicationModule(b, zecli, "src/tjctl_main.zig", target, optimize, strip);
    tjctl_mod.addImport("zooi", zooi.module("zooi"));

    const version_options = b.addOptions();
    version_options.addOption([]const u8, "version", manifest.version);
    exe_mod.addOptions("build_options", version_options);
    tjctl_mod.addOptions("build_options", version_options);

    const exe = b.addExecutable(.{ .name = "tj", .root_module = exe_mod });
    const tjctl_exe = b.addExecutable(.{ .name = "tjctl", .root_module = tjctl_mod });
    b.installArtifact(exe);
    b.installArtifact(tjctl_exe);

    // Runtime files belong to the Zig install graph so local installation,
    // cross-build prefixes, and release archives all contain the same files.
    b.installFile("shell/zsh/tj.plugin.zsh", "share/tj/tj.plugin.zsh");
    b.installFile("shell/fish/tj.plugin.fish", "share/tj/tj.plugin.fish");

    // Generate command, option, and runtime-reference completion scripts with
    // a host executable even when `tj` itself is being cross-compiled; the
    // helper is not part of the installed artifacts.
    const completion_generator_mod = b.createModule(.{
        .root_source_file = b.path("src/completion_main.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    completion_generator_mod.addImport("zecli", zecli.module("cli"));
    completion_generator_mod.addImport("completion", zecli.module("completion"));
    const completion_generator = b.addExecutable(.{
        .name = "tj-completion",
        .root_module = completion_generator_mod,
    });

    const completion_scripts = [_]struct {
        app: []const u8,
        shell: []const u8,
        basename: []const u8,
        install_path: []const u8,
    }{
        .{ .app = "tj", .shell = "bash", .basename = "tj", .install_path = "share/bash-completion/completions/tj" },
        .{ .app = "tj", .shell = "zsh", .basename = "_tj", .install_path = "share/zsh/site-functions/_tj" },
        .{ .app = "tj", .shell = "fish", .basename = "tj.fish", .install_path = "share/fish/vendor_completions.d/tj.fish" },
        .{ .app = "tjctl", .shell = "bash", .basename = "tjctl", .install_path = "share/bash-completion/completions/tjctl" },
        .{ .app = "tjctl", .shell = "zsh", .basename = "_tjctl", .install_path = "share/zsh/site-functions/_tjctl" },
        .{ .app = "tjctl", .shell = "fish", .basename = "tjctl.fish", .install_path = "share/fish/vendor_completions.d/tjctl.fish" },
    };
    var completion_runs: [completion_scripts.len]*std.Build.Step.Run = undefined;
    var completion_outputs: [completion_scripts.len]std.Build.LazyPath = undefined;
    for (completion_scripts, 0..) |script, i| {
        const generate = b.addRunArtifact(completion_generator);
        generate.addArg(script.app);
        generate.addArg(script.shell);
        const output = generate.captureStdOut(.{
            .basename = script.basename,
            .trim_whitespace = .none,
        });
        const install = b.addInstallFile(output, script.install_path);
        b.getInstallStep().dependOn(&install.step);
        completion_runs[i] = generate;
        completion_outputs[i] = output;
    }

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run tj");
    run_step.dependOn(&run_cmd.step);

    // The integration tests drive the real binary through a pty, so they need
    // to know where it landed.
    const selftest_options = b.addOptions();
    selftest_options.addOptionPath("tj_exe", exe.getEmittedBin());
    selftest_options.addOptionPath("tjctl_exe", tjctl_exe.getEmittedBin());

    const selftest_mod = b.createModule(.{
        .root_source_file = b.path("src/tests/selftest.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    selftest_mod.addOptions("build_options", selftest_options);
    selftest_mod.addImport("sys", b.createModule(.{
        .root_source_file = b.path("src/sys.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }));
    const selftest = b.addExecutable(.{ .name = "tj-selftest", .root_module = selftest_mod });

    const integration_options = b.addOptions();
    // Exercise the installed pair. Unlike independently emitted artifacts,
    // these binaries are stable siblings, matching the runtime contract used
    // to export TJ and TJCTL from the proxy.
    integration_options.addOption([]const u8, "tj_exe", b.getInstallPath(.bin, "tj"));
    integration_options.addOption([]const u8, "tjctl_exe", b.getInstallPath(.bin, "tjctl"));
    integration_options.addOption([]const u8, "version", manifest.version);
    integration_options.addOptionPath("selftest_exe", selftest.getEmittedBin());
    integration_options.addOptionPath("plugin", b.path("shell/zsh/tj.plugin.zsh"));
    integration_options.addOptionPath("fish_plugin", b.path("shell/fish/tj.plugin.fish"));
    integration_options.addOptionPath("bash_completion", completion_outputs[0]);
    integration_options.addOptionPath("zsh_completion", completion_outputs[1]);
    integration_options.addOptionPath("fish_completion", completion_outputs[2]);
    integration_options.addOptionPath("tjctl_bash_completion", completion_outputs[3]);
    integration_options.addOptionPath("tjctl_zsh_completion", completion_outputs[4]);
    integration_options.addOptionPath("tjctl_fish_completion", completion_outputs[5]);

    // Integration tests import the same command and storage modules as the
    // binaries, including embedded SQLite. Give their root module the exact
    // same C sources, include paths, and package imports.
    const integration_mod = applicationModule(b, zecli, "src/integration_test.zig", target, optimize, false);
    integration_mod.addImport("zooi", zooi.module("zooi"));
    integration_mod.addOptions("build_options", integration_options);

    // Use one explicit root for both executables. This exercises every inline
    // unit test once, including modules only reachable from tjctl.
    const unit_test_mod = applicationModule(b, zecli, "src/unit_test.zig", target, optimize, false);
    unit_test_mod.addImport("zooi", zooi.module("zooi"));
    unit_test_mod.addOptions("build_options", version_options);
    const unit_tests = b.addTest(.{ .root_module = unit_test_mod });

    // Imported production modules contain inline unit tests. Filter the PTY
    // binaries to their own filenames so those unit tests are not run again.
    const integration_tests = b.addTest(.{
        .root_module = integration_mod,
        .filters = &.{"it_"},
    });

    const splash_integration_mod = b.createModule(.{
        .root_source_file = b.path("src/splash_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    splash_integration_mod.addOptions("build_options", integration_options);
    const splash_integration_tests = b.addTest(.{
        .root_module = splash_integration_mod,
        .filters = &.{"it_splash"},
    });

    // The integration fixture changes process-wide environment variables and
    // uses PTYs. Run its test binary directly so Zig's terminal runner invokes
    // its test functions serially, rather than the build-server runner which
    // dispatches them concurrently.
    const run_integration_tests = b.addSystemCommand(&.{"env"});
    run_integration_tests.addFileArg(integration_tests.getEmittedBin());
    run_integration_tests.step.dependOn(b.getInstallStep());
    const run_splash_integration_tests = b.addSystemCommand(&.{"env"});
    run_splash_integration_tests.addFileArg(splash_integration_tests.getEmittedBin());
    run_splash_integration_tests.step.dependOn(b.getInstallStep());
    // Both suites allocate controlling PTYs. Serialize them: concurrent
    // session-leader probes make macOS deny /dev/tty to otherwise unrelated
    // children even though each suite uses independent descriptors.
    run_splash_integration_tests.step.dependOn(&run_integration_tests.step);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const unit_test_step = b.step("test-unit", "Run unit tests");
    unit_test_step.dependOn(&run_unit_tests.step);

    const integration_test_step = b.step("test-integration", "Run PTY integration tests");
    integration_test_step.dependOn(&run_splash_integration_tests.step);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_splash_integration_tests.step);
    for (completion_runs) |generate| test_step.dependOn(&generate.step);
}

fn applicationModule(
    b: *std.Build,
    zecli: *std.Build.Dependency,
    source: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    strip: bool,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path(source),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .link_libc = true,
    });
    module.addImport("zecli", zecli.module("cli"));
    module.addIncludePath(b.path("vendor/sqlite"));
    module.addIncludePath(b.path("src/sqlite"));
    module.addCSourceFile(.{
        .file = b.path("vendor/sqlite/sqlite3.c"),
        .flags = &.{ "-std=c99", "-DSQLITE_THREADSAFE=1", "-DSQLITE_OMIT_LOAD_EXTENSION", "-DSQLITE_DQS=0" },
    });
    module.addCSourceFile(.{ .file = b.path("src/sqlite/shim.c"), .flags = &.{"-std=c99"} });
    return module;
}
