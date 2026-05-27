const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // In-tree dependency: zig_toml provides the parser the rule
    // engine uses to load `analyzers/default_rules.toml` (embedded via
    // @embedFile) and any caller-supplied ruleset passed with
    // `--rules <path>`.
    const zig_toml_module = b.createModule(.{
        .root_source_file = b.path("../zig_toml/src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // =============================================================================
    // CLI Executable
    // =============================================================================

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_module.addImport("zig_toml", zig_toml_module);

    const exe = b.addExecutable(.{
        .name = "zig-lens",
        .root_module = exe_module,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run zig-lens");
    run_step.dependOn(&run_cmd.step);

    // =============================================================================
    // Static Library (FFI for Rust/C/etc.)
    // =============================================================================

    const ffi_module = b.createModule(.{
        .root_source_file = b.path("src/ffi.zig"),
        .target = target,
        .optimize = optimize,
    });
    ffi_module.addImport("zig_toml", zig_toml_module);

    const lib = b.addLibrary(.{
        .name = "zig_lens",
        .root_module = ffi_module,
        .linkage = .static,
    });

    lib.root_module.link_libc = true;
    lib.root_module.strip = optimize != .Debug;

    b.installArtifact(lib);

    const lib_step = b.step("lib", "Build static library (libzig_lens.a)");
    lib_step.dependOn(&b.addInstallArtifact(lib, .{}).step);

    // =============================================================================
    // Android ARM64 Cross-Compilation
    // =============================================================================

    const android_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .linux,
        .abi = .android,
    });

    const android_toml_module = b.createModule(.{
        .root_source_file = b.path("../zig_toml/src/lib.zig"),
        .target = android_target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });

    const android_module = b.createModule(.{
        .root_source_file = b.path("src/ffi.zig"),
        .target = android_target,
        .optimize = .ReleaseFast,
    });
    android_module.addImport("zig_toml", android_toml_module);

    const android_lib = b.addLibrary(.{
        .name = "zig_lens",
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

    const unit_test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    unit_test_module.addImport("zig_toml", zig_toml_module);

    const unit_tests = b.addTest(.{
        .root_module = unit_test_module,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // FFI layer tests
    const ffi_test_module = b.createModule(.{
        .root_source_file = b.path("src/ffi.zig"),
        .target = target,
        .optimize = optimize,
    });
    ffi_test_module.addImport("zig_toml", zig_toml_module);

    const ffi_tests = b.addTest(.{
        .root_module = ffi_test_module,
    });
    ffi_tests.root_module.link_libc = true;

    const ffi_test_step = b.step("test-ffi", "Run FFI unit tests");
    ffi_test_step.dependOn(&b.addRunArtifact(ffi_tests).step);
}
