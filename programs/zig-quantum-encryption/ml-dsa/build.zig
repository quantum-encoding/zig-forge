const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ========================================================================
    // ML-KEM-768 Library (Key Encapsulation)
    // ========================================================================

    const ml_kem_lib = b.addStaticLibrary(.{
        .name = "quantum-kem",
        .root_source_file = b.path("src/ml_kem_api.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(ml_kem_lib);

    // ========================================================================
    // ML-DSA-65 Library (Digital Signatures)
    // ========================================================================

    const ml_dsa_mod = b.createModule(.{
        .root_source_file = b.path("src/ml_dsa_complete.zig"),
        .target = target,
        .optimize = optimize,
    });

    const ml_dsa_lib = b.addStaticLibrary(.{
        .name = "quantum-dsa",
        .root_module = ml_dsa_mod,
    });
    b.installArtifact(ml_dsa_lib);

    // Shared library for FFI (Tauri/Rust integration)
    const ml_dsa_shared = b.addSharedLibrary(.{
        .name = "quantum-dsa",
        .root_source_file = b.path("src/ml_dsa_ffi.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(ml_dsa_shared);

    // ========================================================================
    // Unit Tests
    // ========================================================================

    // ML-KEM core NTT tests
    const ntt_tests = b.addTest(.{
        .root_source_file = b.path("src/ml_kem.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_ntt_tests = b.addRunArtifact(ntt_tests);

    // ML-KEM API tests
    const kem_api_tests = b.addTest(.{
        .root_source_file = b.path("src/ml_kem_api.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_kem_api_tests = b.addRunArtifact(kem_api_tests);

    // ML-DSA-65 core tests
    const dsa_tests = b.addTest(.{
        .root_source_file = b.path("src/ml_dsa_complete.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_dsa_tests = b.addRunArtifact(dsa_tests);

    // ML-DSA FFI tests
    const dsa_ffi_mod = b.createModule(.{
        .root_source_file = b.path("src/ml_dsa_ffi.zig"),
        .target = target,
        .optimize = optimize,
    });
    const dsa_ffi_tests = b.addTest(.{
        .root_module = dsa_ffi_mod,
    });
    const run_dsa_ffi_tests = b.addRunArtifact(dsa_ffi_tests);

    // Test step
    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&run_ntt_tests.step);
    test_step.dependOn(&run_kem_api_tests.step);
    test_step.dependOn(&run_dsa_tests.step);
    test_step.dependOn(&run_dsa_ffi_tests.step);

    // ========================================================================
    // Benchmarks
    // ========================================================================

    // ML-KEM benchmarks
    const kem_bench = b.addExecutable(.{
        .name = "bench-kem",
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    kem_bench.linkLibC();
    b.installArtifact(kem_bench);

    // ML-DSA benchmarks
    const dsa_bench = b.addExecutable(.{
        .name = "bench-dsa",
        .root_source_file = b.path("src/bench_dsa.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    dsa_bench.linkLibC();
    b.installArtifact(dsa_bench);

    const run_kem_bench = b.addRunArtifact(kem_bench);
    const run_dsa_bench = b.addRunArtifact(dsa_bench);

    const bench_step = b.step("bench", "Run all benchmarks");
    bench_step.dependOn(&run_kem_bench.step);
    bench_step.dependOn(&run_dsa_bench.step);

    const bench_kem_step = b.step("bench-kem", "Run ML-KEM-768 benchmarks only");
    bench_kem_step.dependOn(&run_kem_bench.step);

    const bench_dsa_step = b.step("bench-dsa", "Run ML-DSA-65 benchmarks only");
    bench_dsa_step.dependOn(&run_dsa_bench.step);
}
