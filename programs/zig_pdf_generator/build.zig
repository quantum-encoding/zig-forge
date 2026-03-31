//! Zig PDF Generator Build Configuration
//!
//! Builds a high-performance PDF generation library with C FFI for cross-platform use.
//! Target platforms: Linux, Android, iOS, macOS, Windows, WebAssembly (Edge)
//!
//! Usage:
//!   zig build              - Build native library and CLI
//!   zig build android      - Build for Android ARM64
//!   zig build wasm         - Build WebAssembly module for edge deployment
//!   zig build test         - Run all tests
//!   zig build -Dtarget=aarch64-linux-android  - Cross-compile for Android ARM64
//!
//! WASM Output:
//!   zig-out/lib/zigpdf.wasm - WebAssembly module for Cloudflare Workers, Deno, etc.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ==========================================================================
    // Core Library (Static) - Uses ffi.zig as root for C FFI exports
    // ==========================================================================
    const lib = b.addLibrary(.{
        .name = "zigpdf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ffi.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .linkage = .static,
    });

    // Link libc for Android/iOS FFI compatibility
    lib.root_module.link_libc = true;

    b.installArtifact(lib);

    // ==========================================================================
    // Shared Library (libzigpdf.so for JNI/FFI/Crypto Apps)
    // Build with: zig build shared
    // Output: zig-out/lib/libzigpdf.so
    // ==========================================================================
    const shared_lib = b.addLibrary(.{
        .name = "zigpdf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ffi.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .linkage = .dynamic,
    });

    shared_lib.root_module.link_libc = true;

    const install_shared = b.addInstallArtifact(shared_lib, .{
        .dest_dir = .{ .override = .{ .custom = "lib" } },
    });
    const shared_step = b.step("shared", "Build shared library (libzigpdf.so) for FFI");
    shared_step.dependOn(&install_shared.step);

    // ==========================================================================
    // Android ARM64 Cross-Compilation Target (Static Library with FFI)
    // ==========================================================================
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
        .linkage = .static,
        .name = "zigpdf",
        .root_module = android_module,
    });

    android_lib.root_module.link_libc = true;
    android_lib.root_module.strip = true;

    const android_install = b.addInstallArtifact(android_lib, .{
        .dest_dir = .{ .override = .{ .custom = "lib/android-arm64" } },
    });

    const android_step = b.step("android", "Build for Android ARM64 (aarch64-linux-android)");
    android_step.dependOn(&android_install.step);

    // ==========================================================================
    // Android ARM64 Shared Library (libzigpdf.so for JNI)
    // Uses Android ABI (Bionic libc) for proper symbol resolution
    // ==========================================================================
    const android_shared_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .linux,
        .abi = .android,
    });

    const android_shared_module = b.createModule(.{
        .root_source_file = b.path("src/ffi.zig"),
        .target = android_shared_target,
        .optimize = .ReleaseFast,
    });

    const android_shared_lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "zigpdf",
        .root_module = android_shared_module,
    });

    // Don't link libc - Android's Bionic will provide symbols at runtime
    android_shared_lib.root_module.link_libc = false;
    android_shared_lib.root_module.strip = true;

    const android_shared_install = b.addInstallArtifact(android_shared_lib, .{
        .dest_dir = .{ .override = .{ .custom = "lib/android-arm64" } },
    });

    const android_shared_step = b.step("android-shared", "Build shared library for Android ARM64");
    android_shared_step.dependOn(&android_shared_install.step);

    // ==========================================================================
    // Android ARM64 CLI Sidecar Executable (uses musl for static linking)
    // Note: Android doesn't have a system libc we can link against dynamically,
    // so we use musl for a fully static executable that runs on Android.
    // ==========================================================================
    const android_exe_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .linux,
        .abi = .musl,
    });

    const android_exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = android_exe_target,
        .optimize = .ReleaseFast,
    });

    const android_exe = b.addExecutable(.{
        .name = "pdf-gen",
        .root_module = android_exe_module,
    });

    android_exe.root_module.strip = true;

    const android_exe_install = b.addInstallArtifact(android_exe, .{
        .dest_dir = .{ .override = .{ .custom = "bin/android-arm64" } },
    });

    const android_exe_step = b.step("android-exe", "Build CLI for Android ARM64");
    android_exe_step.dependOn(&android_exe_install.step);

    // Combined Android step builds both library and executable
    android_step.dependOn(&android_exe_install.step);

    // ==========================================================================
    // iOS ARM64 Cross-Compilation Target (Static Library with FFI)
    // ==========================================================================
    const ios_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .ios,
        .abi = .none,
    });

    const ios_module = b.createModule(.{
        .root_source_file = b.path("src/ffi.zig"),
        .target = ios_target,
        .optimize = .ReleaseFast,
    });

    const ios_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "zigpdf",
        .root_module = ios_module,
    });

    ios_lib.root_module.strip = true;

    const ios_install = b.addInstallArtifact(ios_lib, .{
        .dest_dir = .{ .override = .{ .custom = "lib/ios-arm64" } },
    });

    const ios_step = b.step("ios", "Build for iOS ARM64 (aarch64-ios)");
    ios_step.dependOn(&ios_install.step);

    // ==========================================================================
    // iOS Simulator ARM64 (for Apple Silicon Macs running simulator)
    // ==========================================================================
    const ios_sim_arm_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .ios,
        .abi = .simulator,
    });

    const ios_sim_arm_module = b.createModule(.{
        .root_source_file = b.path("src/ffi.zig"),
        .target = ios_sim_arm_target,
        .optimize = .ReleaseFast,
    });

    const ios_sim_arm_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "zigpdf",
        .root_module = ios_sim_arm_module,
    });

    ios_sim_arm_lib.root_module.strip = true;

    const ios_sim_arm_install = b.addInstallArtifact(ios_sim_arm_lib, .{
        .dest_dir = .{ .override = .{ .custom = "lib/ios-sim-arm64" } },
    });

    const ios_sim_arm_step = b.step("ios-sim", "Build for iOS Simulator ARM64");
    ios_sim_arm_step.dependOn(&ios_sim_arm_install.step);

    // ==========================================================================
    // WebAssembly (WASM) Target for Edge Deployment
    // Cloudflare Workers, Deno, Node.js, Browser
    // Build with: zig build wasm
    // Output: zig-out/lib/zigpdf.wasm
    // ==========================================================================
    // Use WASI for basic system interface support (fd_write for debug, etc.)
    // For pure freestanding WASM without WASI, remove os_tag and abi
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
        .abi = .none,
    });

    const wasm_module = b.createModule(.{
        .root_source_file = b.path("src/wasm.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });

    const wasm_lib = b.addExecutable(.{
        .name = "zigpdf",
        .root_module = wasm_module,
    });

    // WASM-specific settings
    wasm_lib.entry = .disabled; // No _start entry point, just exports
    wasm_lib.rdynamic = true; // Export all `export fn` functions

    // Stack size for WASM (1MB should be plenty for PDF generation)
    wasm_lib.stack_size = 1024 * 1024;

    const wasm_install = b.addInstallArtifact(wasm_lib, .{
        .dest_dir = .{ .override = .{ .custom = "lib" } },
    });

    const wasm_step = b.step("wasm", "Build WebAssembly module for edge deployment");
    wasm_step.dependOn(&wasm_install.step);

    // ==========================================================================
    // CLI Tool
    // ==========================================================================
    const exe = b.addExecutable(.{
        .name = "pdf-gen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.root_module.link_libc = true;

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the PDF generator CLI");
    run_step.dependOn(&run_cmd.step);

    // ==========================================================================
    // Tests
    // ==========================================================================
    const lib_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    lib_unit_tests.root_module.link_libc = true;

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}
