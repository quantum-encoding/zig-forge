const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ============================================================
    // DOCX Library Module
    // ============================================================
    const docx_module = b.addModule("docx", .{
        .root_source_file = b.path("src/docx.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ============================================================
    // Executable
    // ============================================================
    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_module.addImport("docx", docx_module);
    exe_module.link_libc = true;

    const exe = b.addExecutable(.{
        .name = "zig-docx",
        .root_module = exe_module,
    });
    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run zig-docx");
    run_step.dependOn(&run_cmd.step);

    // ============================================================
    // Static Library (libzig_docx.a)
    // ============================================================
    const static_module = b.createModule(.{
        .root_source_file = b.path("src/ffi.zig"),
        .target = target,
        .optimize = optimize,
    });
    static_module.link_libc = true;

    const static_lib = b.addLibrary(.{
        .name = "zig_docx",
        .root_module = static_module,
        .linkage = .static,
    });
    b.installArtifact(static_lib);

    // ============================================================
    // Dynamic Library (libzig_docx.dylib / .so)
    // ============================================================
    const dylib_module = b.createModule(.{
        .root_source_file = b.path("src/ffi.zig"),
        .target = target,
        .optimize = optimize,
    });
    dylib_module.link_libc = true;

    const dynamic_lib = b.addLibrary(.{
        .name = "zig_docx",
        .root_module = dylib_module,
        .linkage = .dynamic,
    });
    b.installArtifact(dynamic_lib);

    // ============================================================
    // lib step — build both libraries
    // ============================================================
    const lib_step = b.step("lib", "Build static and dynamic libraries");
    lib_step.dependOn(&static_lib.step);
    lib_step.dependOn(&dynamic_lib.step);

    // ============================================================
    // Tests
    // ============================================================
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/docx.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.link_libc = true;

    const tests = b.addTest(.{
        .root_module = test_module,
    });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
