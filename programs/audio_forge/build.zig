//! Audio Forge Build Configuration
//!
//! Real-time audio DSP engine with sub-millisecond latency.
//!
//! Build:
//!   zig build              - Build audio-forge CLI
//!   zig build test         - Run all tests
//!   zig build bench        - Run benchmarks
//!
//! Dependencies:
//!   libasound2-dev (ALSA)

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ==========================================================================
    // Library Module
    // ==========================================================================
    const lib_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ==========================================================================
    // Static Library
    // ==========================================================================
    const lib = b.addLibrary(.{
        .name = "audioforge",
        .root_module = lib_module,
        .linkage = .static,
    });

    lib.root_module.link_libc = true;
    lib.root_module.linkSystemLibrary("asound", .{});

    b.installArtifact(lib);

    // ==========================================================================
    // CLI Executable
    // ==========================================================================
    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "audio-forge",
        .root_module = exe_module,
    });

    exe.root_module.link_libc = true;
    exe.root_module.linkSystemLibrary("asound", .{});

    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the audio-forge CLI");
    run_step.dependOn(&run_cmd.step);

    // ==========================================================================
    // Tests
    // ==========================================================================
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib_unit_tests = b.addTest(.{
        .root_module = test_module,
    });

    lib_unit_tests.root_module.link_libc = true;
    // Note: Tests don't need ALSA - audio tests are isolated and don't require backend

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    // ==========================================================================
    // Benchmarks
    // ==========================================================================
    const bench_module = b.createModule(.{
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });

    const bench_exe = b.addExecutable(.{
        .name = "audio-forge-bench",
        .root_module = bench_module,
    });

    bench_exe.root_module.link_libc = true;

    const run_bench = b.addRunArtifact(bench_exe);
    run_bench.step.dependOn(b.getInstallStep());

    const bench_step = b.step("bench", "Run performance benchmarks");
    bench_step.dependOn(&run_bench.step);
}
