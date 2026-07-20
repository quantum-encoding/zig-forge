const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main zdu executable
    const exe = b.addExecutable(.{
        .name = "zdu",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = if (target.result.abi == .android) false else true,
        }),
    });

    b.installArtifact(exe);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run zdu");
    run_step.dependOn(&run_cmd.step);

    // Unit tests
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = if (target.result.abi == .android) false else true,
        }),
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Externally-anchored parity tests: diff zdu's output against the real GNU
    // coreutils `du` binary. The zdu executable's installed path is passed in as
    // a build option so the test can shell out to it; the parity step depends on
    // the install so the binary exists when the tests run.
    const parity_opts = b.addOptions();
    parity_opts.addOption([]const u8, "zdu_bin", b.getInstallPath(.bin, "zdu"));

    const parity_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gnu_parity_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = if (target.result.abi == .android) false else true,
        }),
    });
    parity_tests.root_module.addOptions("build_options", parity_opts);

    const run_parity_tests = b.addRunArtifact(parity_tests);
    run_parity_tests.step.dependOn(b.getInstallStep());
    // Parity diffing is only meaningful against the freshly-built binary; never
    // let a cached pass hide a regression.
    run_parity_tests.has_side_effects = true;
    test_step.dependOn(&run_parity_tests.step);

    // Benchmark build (release-fast for accurate benchmarking)
    const bench_exe = b.addExecutable(.{
        .name = "zdu-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .link_libc = if (target.result.abi == .android) false else true,
        }),
    });

    const bench_install = b.addInstallArtifact(bench_exe, .{});
    const bench_step = b.step("bench", "Build optimized benchmark binary");
    bench_step.dependOn(&bench_install.step);
}
