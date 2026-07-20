const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main zwc executable
    const exe = b.addExecutable(.{
        .name = "zwc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    b.installArtifact(exe);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run zwc");
    run_step.dependOn(&run_cmd.step);

    // Unit tests
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // GNU-parity differential tests: shell out to the built zwc binary and to
    // the real GNU wc, comparing byte-for-byte. The zwc binary path is injected
    // as a build option (resolves to the compiled artifact), which also makes
    // the parity test depend on the exe being built.
    const parity_opts = b.addOptions();
    parity_opts.addOptionPath("zwc_exe", exe.getEmittedBin());

    const parity_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gnu_parity_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    parity_tests.root_module.addOptions("build_options", parity_opts);

    const run_parity_tests = b.addRunArtifact(parity_tests);
    test_step.dependOn(&run_parity_tests.step);

    // Benchmark build (release-fast)
    const bench_exe = b.addExecutable(.{
        .name = "zwc-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });

    const bench_install = b.addInstallArtifact(bench_exe, .{});
    const bench_step = b.step("bench", "Build optimized benchmark binary");
    bench_step.dependOn(&bench_install.step);
}
