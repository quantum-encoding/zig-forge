//! Zig Charts Build Configuration
//!
//! High-performance charting library for financial and general data visualization.
//! Outputs SVG (text-based) with PNG support planned.
//!
//! Usage:
//!   zig build              - Build library and CLI demo
//!   zig build test         - Run all tests
//!   zig build run          - Run demo chart generation
//!
//! Output:
//!   zig-out/lib/libzigcharts.a  - Static library
//!   zig-out/bin/chart-demo      - Demo CLI

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ==========================================================================
    // Core Library (Static)
    // ==========================================================================
    const lib = b.addLibrary(.{
        .name = "zigcharts",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .linkage = .static,
    });

    b.installArtifact(lib);

    // ==========================================================================
    // Demo CLI
    // ==========================================================================
    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_module.link_libc = true;

    const exe = b.addExecutable(.{
        .name = "chart-demo",
        .root_module = exe_module,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run demo chart generation");
    run_step.dependOn(&run_cmd.step);

    // ==========================================================================
    // WASM Module (for browser/edge deployment)
    // ==========================================================================
    const wasm_mod = b.createModule(.{
        .root_source_file = b.path("src/wasm.zig"),
        .target = b.resolveTargetQuery(.{
            .cpu_arch = .wasm32,
            .os_tag = .freestanding,
            .abi = .none,
        }),
        .optimize = .ReleaseSmall,
    });

    const wasm = b.addExecutable(.{
        .name = "zigcharts",
        .root_module = wasm_mod,
        .use_lld = true,
        .use_llvm = true,
    });
    wasm.entry = .disabled;
    wasm.root_module.export_symbol_names = &.{
        "wasm_alloc",
        "wasm_free",
        "zigcharts_render",
        "zigcharts_get_output",
        "zigcharts_get_error",
        "zigcharts_get_error_len",
        "zigcharts_reset",
        "zigcharts_version",
    };

    const wasm_install = b.addInstallArtifact(wasm, .{
        .dest_dir = .{ .override = .{ .custom = "lib" } },
    });
    const wasm_step = b.step("wasm", "Build WASM module for browser deployment");
    wasm_step.dependOn(&wasm_install.step);

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

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}
