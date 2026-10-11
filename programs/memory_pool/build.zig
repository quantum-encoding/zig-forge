const std = @import("std");

// Zig 0.17 renamed the optimize tags (Debug/ReleaseSafe/ReleaseFast/ReleaseSmall became
// debug/safe/fast/small) and keeps the old names only as declarations on the enum, which an
// enum literal cannot reach; naming them through the type compiles on 0.16 and 0.17.
const Optimize = std.builtin.OptimizeMode;

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

    // zig-out/lib/libmemory_pool_core.a is the archive other repos link (libs.toml
    // row `memory_pool_core`), stamped beside it by scripts/build-macos-lib.sh and
    // scripts/build-consumed-libs.sh. Only the `lib` step writes that path, and
    // only in a release mode; build-macos-lib.sh runs `zig build lib`. Every
    // other build — `zig build`, `zig build core`, any -Doptimize — installs its
    // archive under zig-out/lib/dev/, so a local build never replaces the stamped
    // release archive.
    const lib_step = b.step("lib", "Build the consumed archive zig-out/lib/libmemory_pool_core.a (release modes only; use scripts/build-macos-lib.sh)");
    switch (optimize) {
        Optimize.ReleaseSmall, Optimize.ReleaseFast => lib_step.dependOn(&b.addInstallArtifact(core_lib, .{}).step),
        Optimize.Debug, Optimize.ReleaseSafe => lib_step.dependOn(&b.addFail(b.fmt(
            "zig build lib writes zig-out/lib/libmemory_pool_core.a, the archive consumers link; " ++
                "a {t} build keeps Zig's panic machinery and is never that archive. " ++
                "Run scripts/build-macos-lib.sh programs/memory_pool from the repo root " ++
                "(ReleaseSmall, stamped), or plain `zig build` for zig-out/lib/dev/libmemory_pool_core.a",
            .{optimize},
        )).step),
    }
    const dev_install = b.addInstallArtifact(core_lib, .{
        .dest_dir = .{ .override = .{ .custom = "lib/dev" } },
    });
    b.getInstallStep().dependOn(&dev_install.step);

    const core_step = b.step("core", "Build core FFI static library (zero deps) into zig-out/lib/dev/");
    core_step.dependOn(&dev_install.step);

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
        .optimize = Optimize.ReleaseFast,
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
