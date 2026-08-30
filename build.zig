const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zecli = b.dependency("zecli", .{});

    const exe_mod = applicationModule(b, zecli, "src/main.zig", target, optimize);
    const tjctl_mod = applicationModule(b, zecli, "src/tjctl_main.zig", target, optimize);

    const exe = b.addExecutable(.{ .name = "tj", .root_module = exe_mod });
    const tjctl_exe = b.addExecutable(.{ .name = "tjctl", .root_module = tjctl_mod });
    b.installArtifact(exe);
    b.installArtifact(tjctl_exe);

    // Runtime files belong to the Zig install graph so local installation,
    // cross-build prefixes, and release archives all contain the same tools.
    b.installFile("tj.plugin.zsh", "share/tj/tj.plugin.zsh");
    b.installBinFile("contrib/tj-fence", "tj-fence");
    b.installBinFile("contrib/tj-grep", "tj-grep");
    b.installBinFile("contrib/tj-tape", "tj-tape");

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
        .root_source_file = b.path("src/selftest.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    selftest_mod.addOptions("build_options", selftest_options);
    const selftest = b.addExecutable(.{ .name = "tj-selftest", .root_module = selftest_mod });

    const integration_options = b.addOptions();
    // Exercise the installed pair. Unlike independently emitted artifacts,
    // these binaries are stable siblings, matching the runtime contract used
    // to export TJ and TJCTL from the proxy.
    integration_options.addOption([]const u8, "tj_exe", b.getInstallPath(.bin, "tj"));
    integration_options.addOption([]const u8, "tjctl_exe", b.getInstallPath(.bin, "tjctl"));
    integration_options.addOptionPath("selftest_exe", selftest.getEmittedBin());
    integration_options.addOptionPath("plugin", b.path("tj.plugin.zsh"));
    integration_options.addOptionPath("bash_completion", completion_outputs[0]);
    integration_options.addOptionPath("zsh_completion", completion_outputs[1]);
    integration_options.addOptionPath("fish_completion", completion_outputs[2]);
    integration_options.addOptionPath("tjctl_bash_completion", completion_outputs[3]);
    integration_options.addOptionPath("tjctl_zsh_completion", completion_outputs[4]);
    integration_options.addOptionPath("tjctl_fish_completion", completion_outputs[5]);

    const integration_mod = b.createModule(.{
        .root_source_file = b.path("src/integration_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    integration_mod.addOptions("build_options", integration_options);

    const unit_tests = b.addTest(.{ .root_module = exe_mod });
    const integration_tests = b.addTest(.{ .root_module = integration_mod });

    // The integration fixture changes process-wide environment variables and
    // uses PTYs. Run its test binary directly so Zig's terminal runner invokes
    // its test functions serially, rather than the build-server runner which
    // dispatches them concurrently.
    const run_integration_tests = b.addSystemCommand(&.{"env"});
    run_integration_tests.addFileArg(integration_tests.getEmittedBin());
    run_integration_tests.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    test_step.dependOn(&run_integration_tests.step);
    for (completion_runs) |generate| test_step.dependOn(&generate.step);
}

fn applicationModule(
    b: *std.Build,
    zecli: *std.Build.Dependency,
    source: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path(source),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addImport("zecli", zecli.module("cli"));
    module.addIncludePath(b.path("vendor/sqlite"));
    module.addIncludePath(b.path("src"));
    module.addCSourceFile(.{
        .file = b.path("vendor/sqlite/sqlite3.c"),
        .flags = &.{ "-std=c99", "-DSQLITE_THREADSAFE=1", "-DSQLITE_OMIT_LOAD_EXTENSION", "-DSQLITE_DQS=0" },
    });
    module.addCSourceFile(.{ .file = b.path("src/sqlite_shim.c"), .flags = &.{"-std=c99"} });
    return module;
}
