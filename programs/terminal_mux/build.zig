//! Terminal Multiplexer Build Configuration
//!
//! A modern tmux alternative with:
//! - PTY management
//! - Session persistence
//! - Zig-native configuration
//!
//! Usage:
//!   zig build              - Build the tmux executable
//!   zig build test         - Run all tests
//!   zig build run          - Run the terminal multiplexer

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ==========================================================================
    // Core Library (Static)
    // ==========================================================================
    const lib = b.addLibrary(.{
        .name = "terminal_mux",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .linkage = .static,
    });

    lib.root_module.link_libc = true;
    b.installArtifact(lib);

    // ==========================================================================
    // Main Executable
    // ==========================================================================
    const exe = b.addExecutable(.{
        .name = "tmux",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.root_module.link_libc = true;
    b.installArtifact(exe);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the terminal multiplexer");
    run_step.dependOn(&run_cmd.step);

    // ==========================================================================
    // Tests
    // ==========================================================================
    const lib_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    lib_tests.root_module.link_libc = true;

    const run_lib_tests = b.addRunArtifact(lib_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_tests.step);
}
