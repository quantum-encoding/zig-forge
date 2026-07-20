const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zzstd",
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

    const run_step = b.step("run", "Run zzstd");
    run_step.dependOn(&run_cmd.step);

    // ---- Tests --------------------------------------------------------------
    // Externally-anchored parity tests. The test binary shells out to the
    // freshly-built zzstd and to the system zstd (the real Zstandard CLI by
    // Yann Collet), using it to produce compressed inputs and to cross-check
    // outputs. Anchoring to the reference implementation's bytes.
    const parity_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gnu_parity_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    const test_opts = b.addOptions();
    test_opts.addOptionPath("zzstd_bin", exe.getEmittedBin());
    parity_tests.root_module.addOptions("build_options", test_opts);

    const run_tests = b.addRunArtifact(parity_tests);
    run_tests.has_side_effects = true; // spawns child processes; never cache-skip

    const test_step = b.step("test", "Run externally-anchored parity tests");
    test_step.dependOn(&run_tests.step);
}
