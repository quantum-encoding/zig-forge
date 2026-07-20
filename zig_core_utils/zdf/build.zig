const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zdf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = if (target.result.abi == .android) false else true,
        }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run zdf");
    run_step.dependOn(&run_cmd.step);

    // -------------------------------------------------------------------
    // Tests: externally anchored against the real GNU `df` binary (gdf).
    // -------------------------------------------------------------------
    const opts = b.addOptions();
    // Absolute path to the compiled zdf, embedded as a string constant so the
    // test can spawn the real binary and diff it against GNU df.
    opts.addOptionPath("zdf_exe", exe.getEmittedBin());

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/gnu_parity_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = if (target.result.abi == .android) false else true,
    });
    test_mod.addImport("build_options", opts.createModule());

    const unit_tests = b.addTest(.{ .root_module = test_mod });
    // The test spawns the compiled zdf, so it must exist first.
    unit_tests.step.dependOn(b.getInstallStep());

    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run GNU-df parity tests");
    test_step.dependOn(&run_tests.step);
}
