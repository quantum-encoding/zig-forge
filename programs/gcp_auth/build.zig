const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // HTTP Sentinel dependency (for token exchange HTTP calls)
    const http_sentinel_dep = b.dependency("http_sentinel", .{
        .target = target,
        .optimize = optimize,
    });
    const http_sentinel_module = http_sentinel_dep.module("http-sentinel");

    // GCP Auth library module
    const gcp_auth_module = b.addModule("gcp-auth", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
    });
    gcp_auth_module.addImport("http-sentinel", http_sentinel_module);

    // Tests
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
    });
    test_module.addImport("gcp-auth", gcp_auth_module);
    test_module.addImport("http-sentinel", http_sentinel_module);

    const tests = b.addTest(.{
        .root_module = test_module,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run GCP auth tests");
    test_step.dependOn(&run_tests.step);
}
