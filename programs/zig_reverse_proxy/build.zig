//! Quantum Reverse Proxy Build Configuration
//!
//! High-performance reverse proxy with WASM edge function support
//!
//! Build: zig build
//! Run:   zig build run -- --config proxy.json
//! Test:  zig build test

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // =========================================================================
    // REVERSE PROXY LIBRARY MODULE
    // =========================================================================
    const proxy_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // =========================================================================
    // REVERSE PROXY EXECUTABLE
    // =========================================================================
    const cli_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    cli_module.addImport("proxy", proxy_module);

    const proxy_exe = b.addExecutable(.{
        .name = "edge-proxy",
        .root_module = cli_module,
    });
    b.installArtifact(proxy_exe);

    // Run command
    const run_cmd = b.addRunArtifact(proxy_exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the edge proxy");
    run_step.dependOn(&run_cmd.step);

    // =========================================================================
    // TESTS
    // =========================================================================
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const lib_tests = b.addTest(.{
        .root_module = test_module,
    });

    const run_lib_tests = b.addRunArtifact(lib_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_tests.step);
}
