const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Zig 0.16: Create module with explicit target/optimize
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "zig-port-scanner",
        .root_module = mod,
    });

    // Link libc for getaddrinfo() DNS resolution
    exe.root_module.link_libc = true;

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the port scanner");
    run_step.dependOn(&run_cmd.step);

    // Test configuration
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/test.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{
        .root_module = test_mod,
    });

    // Tests also need libc for DNS resolution
    tests.root_module.link_libc = true;

    const test_run = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&test_run.step);

    // Unit tests only (no network required)
    const unit_test_step = b.step("test-unit", "Run unit tests only (no network)");
    const unit_test_run = b.addRunArtifact(tests);
    unit_test_run.addArg("--test-filter");
    unit_test_run.addArg("parse");
    unit_test_run.addArg("--test-filter");
    unit_test_run.addArg("service");
    unit_test_run.addArg("--test-filter");
    unit_test_run.addArg("status");
    unit_test_step.dependOn(&unit_test_run.step);

    // Integration tests (require network)
    const integration_test_step = b.step("test-integration", "Run integration tests (requires network)");
    const integration_test_run = b.addRunArtifact(tests);
    integration_test_run.addArg("--test-filter");
    integration_test_run.addArg("integration");
    integration_test_step.dependOn(&integration_test_run.step);
}
