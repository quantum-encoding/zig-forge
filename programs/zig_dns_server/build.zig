//! DNS Server Build Configuration
//! Authoritative DNS Server with DNSSEC and DoH/DoT support
//!
//! Build: zig build
//! Run:   zig build run -- --config dns.conf
//! Test:  zig build test

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // =========================================================================
    // DNS SERVER LIBRARY MODULE
    // =========================================================================
    const dns_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // =========================================================================
    // DNS SERVER EXECUTABLE
    // =========================================================================
    const cli_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    cli_module.addImport("dns", dns_module);

    const dns_exe = b.addExecutable(.{
        .name = "dns-server",
        .root_module = cli_module,
    });
    b.installArtifact(dns_exe);

    // Run command
    const run_cmd = b.addRunArtifact(dns_exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the DNS server");
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
