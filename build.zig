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
}
