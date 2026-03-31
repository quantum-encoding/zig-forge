//! Warp Gate Build Configuration
//! Peer-to-peer code transfer without cloud intermediaries
//!
//! Build: zig build
//! Run:   zig build run -- send ./my-project
//!        zig build run -- recv warp-729-alpha
//! Test:  zig build test

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // =========================================================================
    // WARP GATE LIBRARY MODULE
    // =========================================================================
    const warp_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // =========================================================================
    // WARP CLI EXECUTABLE
    // =========================================================================
    const cli_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    cli_module.addImport("warp_gate", warp_module);

    const warp_exe = b.addExecutable(.{
        .name = "warp",
        .root_module = cli_module,
    });
    b.installArtifact(warp_exe);

    // Run command
    const run_cmd = b.addRunArtifact(warp_exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the warp CLI");
    run_step.dependOn(&run_cmd.step);

    // =========================================================================
    // TESTS
    // =========================================================================
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const lib_tests = b.addTest(.{
        .root_module = test_module,
    });

    const run_lib_tests = b.addRunArtifact(lib_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_tests.step);

    // =========================================================================
    // BENCHMARKS
    // =========================================================================
    const bench_module = b.createModule(.{
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    bench_module.addImport("warp_gate", warp_module);

    const bench_exe = b.addExecutable(.{
        .name = "warp-bench",
        .root_module = bench_module,
    });
    b.installArtifact(bench_exe);

    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&b.addRunArtifact(bench_exe).step);
}
