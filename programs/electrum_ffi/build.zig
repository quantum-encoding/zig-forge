const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // =============================================================================
    // Static Library (for FFI integration with Rust/C/etc.)
    // =============================================================================

    const ffi_module = b.createModule(.{
        .root_source_file = b.path("src/ffi.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "electrum_ffi",
        .root_module = ffi_module,
        .linkage = .static,
    });

    // Link with libc for C compatibility
    lib.root_module.link_libc = true;

    // Strip debug symbols for production (reduces binary size)
    lib.root_module.strip = optimize != .Debug;

    // Install to zig-out/lib/
    b.installArtifact(lib);

    // Install the committed C header alongside the artifact so consumers have
    // a single source of truth for the exported symbols and struct layouts
    // (the "lockstep consumers" rule in zig-forge/CLAUDE.md).
    b.installFile("include/electrum_ffi.h", "include/electrum_ffi.h");

    // =============================================================================
    // Android ARM64 Cross-Compilation Target
    // =============================================================================

    const android_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .linux,
        .abi = .android,
    });

    const android_module = b.createModule(.{
        .root_source_file = b.path("src/ffi.zig"),
        .target = android_target,
        .optimize = .ReleaseFast,
    });

    const android_lib = b.addLibrary(.{
        .name = "electrum_ffi",
        .root_module = android_module,
        .linkage = .static,
    });

    android_lib.root_module.link_libc = true;
    android_lib.root_module.strip = true;

    const android_install = b.addInstallArtifact(android_lib, .{
        .dest_dir = .{ .override = .{ .custom = "lib/android-arm64" } },
    });

    const android_step = b.step("android", "Build for Android ARM64 (aarch64-linux-android)");
    android_step.dependOn(&android_install.step);

    // =============================================================================
    // Tests
    // =============================================================================

    // Test the core electrum module
    const electrum_test_module = b.createModule(.{
        .root_source_file = b.path("src/electrum.zig"),
        .target = target,
        .optimize = optimize,
    });

    const electrum_tests = b.addTest(.{
        .root_module = electrum_test_module,
    });

    // Test the FFI layer
    const ffi_test_module = b.createModule(.{
        .root_source_file = b.path("src/ffi.zig"),
        .target = target,
        .optimize = optimize,
    });

    const ffi_tests = b.addTest(.{
        .root_module = ffi_test_module,
    });
    ffi_tests.root_module.link_libc = true;

    // Default `test` step runs BOTH the core and FFI suites so the entire
    // exported surface is gated by `zig build test` (was: FFI tests lived in
    // a separate `test-ffi` step the default gate never ran).
    const test_step = b.step("test", "Run all unit tests (core + FFI)");
    test_step.dependOn(&b.addRunArtifact(electrum_tests).step);
    test_step.dependOn(&b.addRunArtifact(ffi_tests).step);

    // Retained as an alias for FFI-only runs.
    const ffi_test_step = b.step("test-ffi", "Run FFI unit tests only");
    ffi_test_step.dependOn(&b.addRunArtifact(ffi_tests).step);
}
