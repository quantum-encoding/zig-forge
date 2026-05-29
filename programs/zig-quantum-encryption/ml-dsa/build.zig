const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ========================================================================
    // ML-DSA-65 Library (Digital Signatures, FIPS 204)
    // ========================================================================

    // Static library (Zig 0.16: addLibrary + .linkage, replacing the removed
    // addStaticLibrary). Sources live in this directory — no src/ prefix.
    const dsa_lib = b.addLibrary(.{
        .name = "quantum-dsa",
        .root_module = b.createModule(.{
            .root_source_file = b.path("ml_dsa_complete.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .linkage = .static,
    });
    b.installArtifact(dsa_lib);

    // Shared library for FFI (Tauri/Rust integration); replaces the removed
    // addSharedLibrary with addLibrary + .linkage = .dynamic.
    const dsa_shared = b.addLibrary(.{
        .name = "quantum-dsa",
        .root_module = b.createModule(.{
            .root_source_file = b.path("ml_dsa_ffi.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .linkage = .dynamic,
    });
    b.installArtifact(dsa_shared);

    // ========================================================================
    // Unit Tests
    // ========================================================================

    const dsa_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("ml_dsa_complete.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_dsa_tests = b.addRunArtifact(dsa_tests);

    const dsa_ffi_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("ml_dsa_ffi.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_dsa_ffi_tests = b.addRunArtifact(dsa_ffi_tests);

    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&run_dsa_tests.step);
    test_step.dependOn(&run_dsa_ffi_tests.step);

    // ========================================================================
    // Benchmarks
    // ========================================================================

    const dsa_bench = b.addExecutable(.{
        .name = "bench-dsa",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench_dsa.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    // bench_dsa.zig @cImports <time.h> for the monotonic clock.
    dsa_bench.root_module.link_libc = true;
    b.installArtifact(dsa_bench);

    const run_dsa_bench = b.addRunArtifact(dsa_bench);

    const bench_step = b.step("bench", "Run ML-DSA-65 benchmarks");
    bench_step.dependOn(&run_dsa_bench.step);

    const bench_dsa_step = b.step("bench-dsa", "Run ML-DSA-65 benchmarks only");
    bench_dsa_step.dependOn(&run_dsa_bench.step);
}
