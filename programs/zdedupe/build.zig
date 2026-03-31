const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ============================================================
    // Core Module
    // ============================================================

    const lib_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ============================================================
    // Static Library (for FFI integration with Rust/Tauri)
    // ============================================================

    const static_lib = b.addLibrary(.{
        .name = "zdedupe",
        .root_module = lib_module,
        .linkage = .static,
    });
    static_lib.root_module.link_libc = true;
    static_lib.root_module.strip = optimize != .Debug;
    b.installArtifact(static_lib);

    // ============================================================
    // Shared Library (for dynamic linking)
    // ============================================================

    const shared_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const shared_lib = b.addLibrary(.{
        .name = "zdedupe",
        .root_module = shared_module,
        .linkage = .dynamic,
    });
    shared_lib.root_module.link_libc = true;
    shared_lib.root_module.strip = optimize != .Debug;

    const shared_install = b.addInstallArtifact(shared_lib, .{
        .dest_dir = .{ .override = .{ .custom = "lib/shared" } },
    });

    const shared_step = b.step("shared", "Build shared library");
    shared_step.dependOn(&shared_install.step);

    // ============================================================
    // CLI Tool
    // ============================================================

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "zdedupe",
        .root_module = exe_module,
    });
    exe.root_module.link_libc = true;
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the CLI tool");
    run_step.dependOn(&run_cmd.step);

    // ============================================================
    // Tests
    // ============================================================

    const test_step = b.step("test", "Run unit tests");

    // Test each module
    const test_modules = [_][]const u8{
        "src/types.zig",
        "src/hasher.zig",
        "src/walker.zig",
        "src/dedupe.zig",
        "src/compare.zig",
        "src/report.zig",
        "src/lib.zig",
    };

    for (test_modules) |mod| {
        const test_mod = b.createModule(.{
            .root_source_file = b.path(mod),
            .target = target,
            .optimize = optimize,
        });

        const mod_test = b.addTest(.{
            .root_module = test_mod,
        });
        mod_test.root_module.link_libc = true;
        test_step.dependOn(&b.addRunArtifact(mod_test).step);
    }

    // ============================================================
    // Format check
    // ============================================================

    const fmt_step = b.step("fmt", "Format source files");
    const fmt = b.addFmt(.{
        .paths = &.{"src"},
    });
    fmt_step.dependOn(&fmt.step);

    // ============================================================
    // Header install
    // ============================================================

    const header_step = b.step("header", "Install C header for FFI");
    const header_install = b.addInstallFile(b.path("include/zdedupe.h"), "include/zdedupe.h");
    header_step.dependOn(&header_install.step);
}
