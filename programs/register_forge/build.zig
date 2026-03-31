//! Register Forge - SVD to Zig Codegen
//!
//! Parses SVD (System View Description) files and generates type-safe
//! Zig code for hardware register access.
//!
//! SVD files are the ARM standard for describing microcontroller peripherals
//! and registers. Most chip manufacturers provide SVD files for their products.
//!
//! Usage:
//!   zig build                          - Build the CLI tool
//!   zig build run -- <file.svd>        - Generate Zig code from SVD
//!   zig build run -- --output out.zig  - Specify output file
//!
//! Example:
//!   register-forge STM32F401.svd --output stm32f401_regs.zig

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main CLI tool
    const exe = b.addExecutable(.{
        .name = "register-forge",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the register forge tool");
    run_step.dependOn(&run_cmd.step);

    // Tests
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
