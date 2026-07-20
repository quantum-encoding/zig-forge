const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zuptime",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run zuptime");
    run_step.dependOn(&run_cmd.step);

    // --- Tests ---------------------------------------------------------------
    // Externally-anchored parity tests (src/gnu_parity_test.zig): pure-function
    // FORMAT checks against procps-ng reference output, plus live BEHAVIOR
    // checks that run the freshly-built binary. The binary path is threaded
    // through build options so the test never depends on an install location.
    const test_opts = b.addOptions();
    test_opts.addOptionPath("zuptime_bin", exe.getEmittedBin());

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gnu_parity_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    tests.root_module.addOptions("build_options", test_opts);

    const run_tests = b.addRunArtifact(tests);
    // The behavior tests execute the built binary, so ensure it exists first.
    run_tests.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run zuptime parity tests (procps-anchored)");
    test_step.dependOn(&run_tests.step);
}
