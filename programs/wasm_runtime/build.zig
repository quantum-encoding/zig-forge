//! WASM Runtime Build Configuration
//! WebAssembly Interpreter
//!
//! Build: zig build
//! Run:   zig build run -- run module.wasm
//!        zig build run -- info module.wasm
//! Test:  zig build test

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // =========================================================================
    // WASM RUNTIME LIBRARY MODULE
    // =========================================================================
    const wasm_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    wasm_module.link_libc = true;

    // =========================================================================
    // WASM CLI EXECUTABLE
    // =========================================================================
    const cli_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_module.addImport("wasm_runtime", wasm_module);

    const wasm_exe = b.addExecutable(.{
        .name = "wasm",
        .root_module = cli_module,
    });
    b.installArtifact(wasm_exe);

    // Run command
    const run_cmd = b.addRunArtifact(wasm_exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the wasm CLI");
    run_step.dependOn(&run_cmd.step);

    // =========================================================================
    // TESTS
    // =========================================================================
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib_tests = b.addTest(.{
        .root_module = test_module,
    });

    const run_lib_tests = b.addRunArtifact(lib_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_tests.step);
}
