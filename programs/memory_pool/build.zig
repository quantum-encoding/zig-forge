const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ========================================================================
    // Core FFI Static Library (ZERO DEPENDENCIES)
    // ========================================================================

    const core_module = b.createModule(.{
        .root_source_file = b.path("src/memory_pool_core.zig"),
        .target = target,
        .optimize = optimize,
    });

    const core_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "memory_pool_core",
        .root_module = core_module,
    });

    core_lib.root_module.link_libc = true;
    // NO EXTERNAL DEPS

    b.installArtifact(core_lib);

    const core_step = b.step("core", "Build core FFI static library (zero deps)");
    core_step.dependOn(&b.addInstallArtifact(core_lib, .{}).step);

    // ========================================================================
    // Android ARM64 Cross-Compilation Target
    // ========================================================================

    const android_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .linux,
        .abi = .android,
    });

    const android_module = b.createModule(.{
        .root_source_file = b.path("src/memory_pool_core.zig"),
        .target = android_target,
        .optimize = .ReleaseFast,
    });

    const android_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "memory_pool_core",
        .root_module = android_module,
    });

    android_lib.root_module.link_libc = true;
    android_lib.root_module.strip = true;

    const android_install = b.addInstallArtifact(android_lib, .{
        .dest_dir = .{ .override = .{ .custom = "lib/android-arm64" } },
    });

    const android_step = b.step("android", "Build for Android ARM64 (aarch64-linux-android)");
    android_step.dependOn(&android_install.step);

    // ========================================================================
    // Pool library module (used by tests, benchmarks)
    // ========================================================================

    // Consumable module for other in-tree projects (e.g. quantum_vault).
    // Additive: does not alter the exported C-ABI static library above.
    const pool_module = b.addModule("memory_pool", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{
        .root_module = test_module,
    });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // FFI-layer tests (memory_pool_core.zig). These are NOT reachable from
    // src/main.zig's refAllDecls graph, so without a dedicated test root the
    // entire exported C-API test suite is silently skipped. Handles use
    // std.heap.c_allocator, so this module must link libc.
    const ffi_test_module = b.createModule(.{
        .root_source_file = b.path("src/memory_pool_core.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const ffi_tests = b.addTest(.{
        .root_module = ffi_test_module,
    });

    test_step.dependOn(&b.addRunArtifact(ffi_tests).step);

    // Benchmarks
    const bench = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmarks/bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "memory-pool", .module = pool_module },
            },
        }),
    });

    const bench_install = b.addInstallArtifact(bench, .{});
    const bench_run = b.addRunArtifact(bench);

    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&bench_install.step);
    bench_step.dependOn(&bench_run.step);
}
