const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ========================================================================
    // Shared modules (used by all targets)
    // ========================================================================

    // Socket abstraction module
    const socket_module = b.addModule("socket", .{
        .root_source_file = b.path("src/socket.zig"),
        .target = target,
        .optimize = optimize,
    });

    // I/O backend module
    const io_backend_module = b.addModule("io_backend", .{
        .root_source_file = b.path("src/io_backend.zig"),
        .target = target,
        .optimize = optimize,
    });
    io_backend_module.addImport("socket", socket_module);

    // Bitcoin protocol module
    const bitcoin_module = b.addModule("bitcoin_protocol", .{
        .root_source_file = b.path("src/bitcoin_protocol.zig"),
        .target = target,
        .optimize = optimize,
    });
    bitcoin_module.addImport("socket", socket_module);

    // Core module
    const core_module = b.addModule("mempool_sniffer_core", .{
        .root_source_file = b.path("src/mempool_sniffer_core.zig"),
        .target = target,
        .optimize = optimize,
    });
    core_module.addImport("socket", socket_module);
    core_module.addImport("io_backend", io_backend_module);
    core_module.addImport("bitcoin_protocol", bitcoin_module);

    // ========================================================================
    // Native (host) build
    // ========================================================================

    const core_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "mempool_sniffer_core",
        .root_module = core_module,
    });

    core_lib.root_module.link_libc = true;

    b.installArtifact(core_lib);

    const core_step = b.step("core", "Build mempool_sniffer_core static library");
    core_step.dependOn(&b.addInstallArtifact(core_lib, .{}).step);

    // Default build
    b.default_step.dependOn(core_step);

    // ========================================================================
    // macOS (x86_64) Cross-Compilation Target
    // Uses kqueue for async I/O
    // ========================================================================

    const macos_x64_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .macos,
    });

    const macos_x64_socket = b.createModule(.{
        .root_source_file = b.path("src/socket.zig"),
        .target = macos_x64_target,
        .optimize = .ReleaseFast,
    });

    const macos_x64_io_backend = b.createModule(.{
        .root_source_file = b.path("src/io_backend.zig"),
        .target = macos_x64_target,
        .optimize = .ReleaseFast,
    });
    macos_x64_io_backend.addImport("socket", macos_x64_socket);

    const macos_x64_bitcoin = b.createModule(.{
        .root_source_file = b.path("src/bitcoin_protocol.zig"),
        .target = macos_x64_target,
        .optimize = .ReleaseFast,
    });
    macos_x64_bitcoin.addImport("socket", macos_x64_socket);

    const macos_x64_module = b.createModule(.{
        .root_source_file = b.path("src/mempool_sniffer_core.zig"),
        .target = macos_x64_target,
        .optimize = .ReleaseFast,
    });
    macos_x64_module.addImport("socket", macos_x64_socket);
    macos_x64_module.addImport("io_backend", macos_x64_io_backend);
    macos_x64_module.addImport("bitcoin_protocol", macos_x64_bitcoin);

    const macos_x64_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "mempool_sniffer_core",
        .root_module = macos_x64_module,
    });

    macos_x64_lib.root_module.link_libc = true;
    macos_x64_lib.root_module.strip = true;

    const macos_x64_install = b.addInstallArtifact(macos_x64_lib, .{
        .dest_dir = .{ .override = .{ .custom = "lib/macos-x64" } },
    });

    const macos_x64_step = b.step("macos-x64", "Build for macOS x86_64");
    macos_x64_step.dependOn(&macos_x64_install.step);

    // ========================================================================
    // macOS (ARM64/Apple Silicon) Cross-Compilation Target
    // Uses kqueue for async I/O
    // ========================================================================

    const macos_arm64_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .macos,
    });

    const macos_arm64_socket = b.createModule(.{
        .root_source_file = b.path("src/socket.zig"),
        .target = macos_arm64_target,
        .optimize = .ReleaseFast,
    });

    const macos_arm64_io_backend = b.createModule(.{
        .root_source_file = b.path("src/io_backend.zig"),
        .target = macos_arm64_target,
        .optimize = .ReleaseFast,
    });
    macos_arm64_io_backend.addImport("socket", macos_arm64_socket);

    const macos_arm64_bitcoin = b.createModule(.{
        .root_source_file = b.path("src/bitcoin_protocol.zig"),
        .target = macos_arm64_target,
        .optimize = .ReleaseFast,
    });
    macos_arm64_bitcoin.addImport("socket", macos_arm64_socket);

    const macos_arm64_module = b.createModule(.{
        .root_source_file = b.path("src/mempool_sniffer_core.zig"),
        .target = macos_arm64_target,
        .optimize = .ReleaseFast,
    });
    macos_arm64_module.addImport("socket", macos_arm64_socket);
    macos_arm64_module.addImport("io_backend", macos_arm64_io_backend);
    macos_arm64_module.addImport("bitcoin_protocol", macos_arm64_bitcoin);

    const macos_arm64_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "mempool_sniffer_core",
        .root_module = macos_arm64_module,
    });

    macos_arm64_lib.root_module.link_libc = true;
    macos_arm64_lib.root_module.strip = true;

    const macos_arm64_install = b.addInstallArtifact(macos_arm64_lib, .{
        .dest_dir = .{ .override = .{ .custom = "lib/macos-arm64" } },
    });

    const macos_arm64_step = b.step("macos-arm64", "Build for macOS ARM64 (Apple Silicon)");
    macos_arm64_step.dependOn(&macos_arm64_install.step);

    // Combined macOS step (builds both architectures)
    const macos_step = b.step("macos", "Build for macOS (both x64 and ARM64)");
    macos_step.dependOn(&macos_x64_install.step);
    macos_step.dependOn(&macos_arm64_install.step);

    // ========================================================================
    // Android ARM64 Cross-Compilation Target
    // Uses poll fallback (io_uring not available on Android)
    // ========================================================================

    const android_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .linux,
        .abi = .android,
    });

    const android_socket = b.createModule(.{
        .root_source_file = b.path("src/socket.zig"),
        .target = android_target,
        .optimize = .ReleaseFast,
    });

    const android_io_backend = b.createModule(.{
        .root_source_file = b.path("src/io_backend.zig"),
        .target = android_target,
        .optimize = .ReleaseFast,
    });
    android_io_backend.addImport("socket", android_socket);

    const android_bitcoin_module = b.createModule(.{
        .root_source_file = b.path("src/bitcoin_protocol.zig"),
        .target = android_target,
        .optimize = .ReleaseFast,
    });
    android_bitcoin_module.addImport("socket", android_socket);

    const android_module = b.createModule(.{
        .root_source_file = b.path("src/mempool_sniffer_core.zig"),
        .target = android_target,
        .optimize = .ReleaseFast,
    });
    android_module.addImport("socket", android_socket);
    android_module.addImport("io_backend", android_io_backend);
    android_module.addImport("bitcoin_protocol", android_bitcoin_module);

    const android_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "mempool_sniffer_core",
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
    // iOS ARM64 Cross-Compilation Target
    // Uses kqueue for async I/O (same as macOS)
    // ========================================================================

    const ios_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .ios,
    });

    const ios_socket = b.createModule(.{
        .root_source_file = b.path("src/socket.zig"),
        .target = ios_target,
        .optimize = .ReleaseFast,
    });

    const ios_io_backend = b.createModule(.{
        .root_source_file = b.path("src/io_backend.zig"),
        .target = ios_target,
        .optimize = .ReleaseFast,
    });
    ios_io_backend.addImport("socket", ios_socket);

    const ios_bitcoin_module = b.createModule(.{
        .root_source_file = b.path("src/bitcoin_protocol.zig"),
        .target = ios_target,
        .optimize = .ReleaseFast,
    });
    ios_bitcoin_module.addImport("socket", ios_socket);

    const ios_module = b.createModule(.{
        .root_source_file = b.path("src/mempool_sniffer_core.zig"),
        .target = ios_target,
        .optimize = .ReleaseFast,
    });
    ios_module.addImport("socket", ios_socket);
    ios_module.addImport("io_backend", ios_io_backend);
    ios_module.addImport("bitcoin_protocol", ios_bitcoin_module);

    const ios_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "mempool_sniffer_core",
        .root_module = ios_module,
    });

    ios_lib.root_module.link_libc = true;
    ios_lib.root_module.strip = true;

    const ios_install = b.addInstallArtifact(ios_lib, .{
        .dest_dir = .{ .override = .{ .custom = "lib/ios-arm64" } },
    });

    const ios_step = b.step("ios", "Build for iOS ARM64");
    ios_step.dependOn(&ios_install.step);

    // ========================================================================
    // Build all targets
    // ========================================================================

    const all_step = b.step("all", "Build for all platforms");
    all_step.dependOn(core_step);
    all_step.dependOn(macos_step);
    all_step.dependOn(android_step);
    all_step.dependOn(ios_step);

    // ========================================================================
    // Tests
    // ========================================================================

    // Socket module tests
    const socket_test_mod = b.createModule(.{
        .root_source_file = b.path("src/socket.zig"),
        .target = target,
        .optimize = optimize,
    });
    socket_test_mod.link_libc = true;

    const socket_tests = b.addTest(.{
        .root_module = socket_test_mod,
    });

    // I/O backend module tests
    const io_backend_test_mod = b.createModule(.{
        .root_source_file = b.path("src/io_backend.zig"),
        .target = target,
        .optimize = optimize,
    });
    io_backend_test_mod.link_libc = true;
    io_backend_test_mod.addImport("socket", socket_test_mod);

    const io_backend_tests = b.addTest(.{
        .root_module = io_backend_test_mod,
    });

    // Bitcoin protocol module tests
    const bitcoin_test_mod = b.createModule(.{
        .root_source_file = b.path("src/bitcoin_protocol.zig"),
        .target = target,
        .optimize = optimize,
    });
    bitcoin_test_mod.link_libc = true;
    bitcoin_test_mod.addImport("socket", socket_test_mod);

    const bitcoin_tests = b.addTest(.{
        .root_module = bitcoin_test_mod,
    });

    // Core module tests
    const core_test_mod = b.createModule(.{
        .root_source_file = b.path("src/mempool_sniffer_core.zig"),
        .target = target,
        .optimize = optimize,
    });
    core_test_mod.link_libc = true;
    core_test_mod.addImport("socket", socket_test_mod);
    core_test_mod.addImport("io_backend", io_backend_test_mod);
    core_test_mod.addImport("bitcoin_protocol", bitcoin_test_mod);

    const core_tests = b.addTest(.{
        .root_module = core_test_mod,
    });

    // Run test artifacts
    const run_socket_tests = b.addRunArtifact(socket_tests);
    const run_io_backend_tests = b.addRunArtifact(io_backend_tests);
    const run_bitcoin_tests = b.addRunArtifact(bitcoin_tests);
    const run_core_tests = b.addRunArtifact(core_tests);

    // Test step
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_socket_tests.step);
    test_step.dependOn(&run_io_backend_tests.step);
    test_step.dependOn(&run_bitcoin_tests.step);
    test_step.dependOn(&run_core_tests.step);

    // Individual test steps for targeted testing
    const test_socket_step = b.step("test-socket", "Run socket module tests");
    test_socket_step.dependOn(&run_socket_tests.step);

    const test_io_step = b.step("test-io", "Run I/O backend module tests");
    test_io_step.dependOn(&run_io_backend_tests.step);

    const test_bitcoin_step = b.step("test-bitcoin", "Run Bitcoin protocol module tests");
    test_bitcoin_step.dependOn(&run_bitcoin_tests.step);

    const test_core_step = b.step("test-core", "Run core module tests");
    test_core_step.dependOn(&run_core_tests.step);
}
