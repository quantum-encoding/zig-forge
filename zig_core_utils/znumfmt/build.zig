const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "znumfmt",
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

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run znumfmt");
    run_step.dependOn(&run_cmd.step);

    // --- Tests: externally-anchored parity vs GNU numfmt. ---
    // The parity tests spawn the freshly-built znumfmt binary; embed its
    // install path as a build option so the test can find it.
    const test_opts = b.addOptions();
    test_opts.addOption([]const u8, "znumfmt_bin", b.getInstallPath(.bin, "znumfmt"));

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/gnu_parity_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addOptions("build_options", test_opts);

    const test_exe = b.addTest(.{ .root_module = test_module });
    const run_tests = b.addRunArtifact(test_exe);
    run_tests.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run GNU-parity tests");
    test_step.dependOn(&run_tests.step);
}
