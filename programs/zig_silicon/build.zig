//! Zig Silicon - Educational Hardware Visualization
//!
//! Tools for visualizing how Zig code maps to machine instructions
//! and hardware register operations.
//!
//! Features:
//! - Disassemble Zig code to see generated machine instructions
//! - Visualize packed struct bit layouts as SVG diagrams
//! - Show register read-modify-write operations step by step
//! - Generate interactive HTML documentation for register maps
//!
//! Usage:
//!   zig build                    - Build the CLI tool
//!   zig build run -- disasm      - Disassemble a function
//!   zig build run -- bitfield    - Generate bit layout SVG
//!   zig build run -- regmap      - Generate register map HTML

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main CLI tool
    const exe = b.addExecutable(.{
        .name = "zig-silicon",
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

    const run_step = b.step("run", "Run the visualization tool");
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
