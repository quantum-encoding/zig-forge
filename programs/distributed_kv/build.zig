//! Distributed KV Store Build Configuration
//!
//! Raft-based distributed key-value store with:
//! - Consensus-based replication
//! - Persistent WAL with crash recovery
//! - Client library with connection pooling
//!
//! Usage:
//!   zig build              - Build server and client library
//!   zig build test         - Run all tests
//!   zig build run          - Run the KV server

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ==========================================================================
    // Core Library (Static)
    // ==========================================================================
    const lib = b.addLibrary(.{
        .name = "distributed_kv",
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
    // KV Server Executable
    // ==========================================================================
    const server_exe = b.addExecutable(.{
        .name = "kv-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/server.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    server_exe.root_module.link_libc = true;
    b.installArtifact(server_exe);

    const run_cmd = b.addRunArtifact(server_exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the KV server");
    run_step.dependOn(&run_cmd.step);

    // ==========================================================================
    // Client CLI Tool
    // ==========================================================================
    const client_exe = b.addExecutable(.{
        .name = "kv-client",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/client_cli.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    client_exe.root_module.link_libc = true;
    b.installArtifact(client_exe);

    const client_run = b.addRunArtifact(client_exe);
    client_run.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        client_run.addArgs(args);
    }

    const client_step = b.step("client", "Run the KV client CLI");
    client_step.dependOn(&client_run.step);

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

    lib_unit_tests.root_module.link_libc = true;

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}
