const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zecli = b.dependency("zecli", .{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addImport("zecli", zecli.module("cli"));

    const exe = b.addExecutable(.{ .name = "tj", .root_module = exe_mod });
    b.installArtifact(exe);

    // Completion scripts describe only TJ's static CLI grammar. Generate them
    // during the build with a host executable even when `tj` itself is being
    // cross-compiled; the helper is not part of the installed artifacts.
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
        shell: []const u8,
        basename: []const u8,
        install_path: []const u8,
    }{
        .{ .shell = "bash", .basename = "tj", .install_path = "share/bash-completion/completions/tj" },
        .{ .shell = "zsh", .basename = "_tj", .install_path = "share/zsh/site-functions/_tj" },
        .{ .shell = "fish", .basename = "tj.fish", .install_path = "share/fish/vendor_completions.d/tj.fish" },
    };
    var completion_runs: [completion_scripts.len]*std.Build.Step.Run = undefined;
    var completion_outputs: [completion_scripts.len]std.Build.LazyPath = undefined;
    for (completion_scripts, 0..) |script, i| {
        const generate = b.addRunArtifact(completion_generator);
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

    const selftest_mod = b.createModule(.{
        .root_source_file = b.path("src/selftest.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    selftest_mod.addOptions("build_options", selftest_options);
    const selftest = b.addExecutable(.{ .name = "tj-selftest", .root_module = selftest_mod });

    const integration_options = b.addOptions();
    integration_options.addOptionPath("tj_exe", exe.getEmittedBin());
    integration_options.addOptionPath("selftest_exe", selftest.getEmittedBin());
    integration_options.addOptionPath("plugin", b.path("tj.plugin.zsh"));
    integration_options.addOptionPath("bash_completion", completion_outputs[0]);
    integration_options.addOptionPath("zsh_completion", completion_outputs[1]);
    integration_options.addOptionPath("fish_completion", completion_outputs[2]);

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

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    test_step.dependOn(&run_integration_tests.step);
    for (completion_runs) |generate| test_step.dependOn(&generate.step);
}
