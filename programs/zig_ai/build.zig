const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build options
    const build_lib = b.option(bool, "lib", "Build library instead of executable") orelse false;
    const static_lib = b.option(bool, "static", "Build static library (default: shared)") orelse false;

    // HTTP Sentinel dependency (provides AI client implementations)
    const http_sentinel_dep = b.dependency("http_sentinel", .{
        .target = target,
        .optimize = optimize,
    });
    const http_sentinel_module = http_sentinel_dep.module("http-sentinel");

    // TOML parser dependency
    const zig_toml_dep = b.dependency("zig_toml", .{
        .target = target,
        .optimize = optimize,
    });
    const zig_toml_module = zig_toml_dep.module("zig_toml");

    // zig-ai CLI module
    const zig_ai_module = b.addModule("zig-ai", .{
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
    });
    zig_ai_module.addImport("http-sentinel", http_sentinel_module);
    zig_ai_module.addImport("zig_toml", zig_toml_module);

    if (build_lib) {
        // ============================================================
        // Library Builds
        // ============================================================

        // Library module (uses lib.zig as root, which provides all modules to FFI)
        const lib_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        });
        lib_module.addImport("http-sentinel", http_sentinel_module);
        lib_module.addImport("zig_toml", zig_toml_module);
        lib_module.link_libc = true;

        const lib = b.addLibrary(.{
            .name = "zig_ai",
            .root_module = lib_module,
            .linkage = if (static_lib) .static else .dynamic,
        });
        b.installArtifact(lib);

        // Install header
        b.installFile("include/zig_ai.h", "include/zig_ai.h");

        // Lib step for convenience
        const lib_step = b.step("lib", "Build zig_ai library");
        lib_step.dependOn(b.getInstallStep());
    } else {
        // ============================================================
        // Executable Build
        // ============================================================

        const exe_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        });
        exe_module.addImport("http-sentinel", http_sentinel_module);
        exe_module.addImport("zig_toml", zig_toml_module);
        exe_module.link_libc = true;

        const exe = b.addExecutable(.{
            .name = "zig-ai",
            .root_module = exe_module,
        });
        b.installArtifact(exe);

        // Run step
        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
        const run_step = b.step("run", "Run zig-ai CLI");
        run_step.dependOn(&run_cmd.step);
    }

    // ============================================================
    // Tests
    // ============================================================

    const test_root_module = b.createModule(.{
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_root_module.addImport("http-sentinel", http_sentinel_module);

    const test_compile = b.addTest(.{
        .root_module = test_root_module,
    });

    const run_tests = b.addRunArtifact(test_compile);
    const test_step = b.step("test", "Run zig-ai tests");
    test_step.dependOn(&run_tests.step);

    // FFI module tests
    const ffi_test_module = b.createModule(.{
        .root_source_file = b.path("src/ffi/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    ffi_test_module.addImport("http-sentinel", http_sentinel_module);
    ffi_test_module.link_libc = true;

    const ffi_test_compile = b.addTest(.{
        .root_module = ffi_test_module,
    });

    const run_ffi_tests = b.addRunArtifact(ffi_test_compile);
    const ffi_test_step = b.step("test-ffi", "Run FFI module tests");
    ffi_test_step.dependOn(&run_ffi_tests.step);

    // ============================================================
    // Model Connectivity Tests
    // ============================================================

    // Config module for tests
    const config_module = b.addModule("config", .{
        .root_source_file = b.path("src/config.zig"),
        .target = target,
        .optimize = optimize,
    });
    config_module.addImport("zig_toml", zig_toml_module);

    const model_test_module = b.createModule(.{
        .root_source_file = b.path("tests/model_connectivity.zig"),
        .target = target,
        .optimize = optimize,
    });
    model_test_module.addImport("http-sentinel", http_sentinel_module);
    model_test_module.addImport("zig_toml", zig_toml_module);
    model_test_module.addImport("config", config_module);
    model_test_module.link_libc = true;

    const model_test_exe = b.addExecutable(.{
        .name = "test-models",
        .root_module = model_test_module,
    });
    b.installArtifact(model_test_exe);

    const run_model_tests = b.addRunArtifact(model_test_exe);
    run_model_tests.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_model_tests.addArgs(args);
    }
    const model_test_step = b.step("test-models", "Run model connectivity tests");
    model_test_step.dependOn(&run_model_tests.step);

    // ============================================================
    // Tool Calling Smoke Test
    // ============================================================

    const tool_test_module = b.createModule(.{
        .root_source_file = b.path("tests/tool_calling_smoke.zig"),
        .target = target,
        .optimize = optimize,
    });
    tool_test_module.addImport("http-sentinel", http_sentinel_module);
    tool_test_module.addImport("zig_toml", zig_toml_module);
    tool_test_module.addImport("config", config_module);
    tool_test_module.link_libc = true;

    const tool_test_exe = b.addExecutable(.{
        .name = "test-tools",
        .root_module = tool_test_module,
    });
    b.installArtifact(tool_test_exe);

    const run_tool_tests = b.addRunArtifact(tool_test_exe);
    run_tool_tests.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_tool_tests.addArgs(args);
    }
    const tool_test_step = b.step("test-tools", "Run tool calling smoke tests");
    tool_test_step.dependOn(&run_tool_tests.step);
}
