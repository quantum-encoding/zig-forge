const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // HTTP Sentinel dependency (for outbound AI provider calls)
    const http_sentinel_dep = b.dependency("http_sentinel", .{
        .target = target,
        .optimize = optimize,
    });
    const http_sentinel_module = http_sentinel_dep.module("http-sentinel");

    // GCP Auth dependency (for Google Cloud service authentication)
    const gcp_auth_dep = b.dependency("gcp_auth", .{
        .target = target,
        .optimize = optimize,
    });
    const gcp_auth_module = gcp_auth_dep.module("gcp-auth");

    // JSON utilities — shared jsonEscape + appendQuotedString for safely
    // interpolating user-controlled strings into JSON payloads.
    const json_util_dep = b.dependency("zig_json_util", .{
        .target = target,
        .optimize = optimize,
    });
    const json_util_module = json_util_dep.module("json-util");

    // Server executable
    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
    });
    exe_module.addImport("http-sentinel", http_sentinel_module);
    exe_module.addImport("gcp-auth", gcp_auth_module);
    exe_module.addImport("json-util", json_util_module);

    const exe = b.addExecutable(.{
        .name = "zig-ai-server",
        .root_module = exe_module,
    });
    b.installArtifact(exe);

    // Run step
    const run = b.addRunArtifact(exe);
    if (b.args) |args| {
        run.addArgs(args);
    }
    const run_step = b.step("run", "Start the AI API server");
    run_step.dependOn(&run.step);

    // Tests — dedicated test file covering security, billing, store, models
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
    });
    test_module.addImport("http-sentinel", http_sentinel_module);
    test_module.addImport("gcp-auth", gcp_auth_module);
    test_module.addImport("json-util", json_util_module);

    const tests = b.addTest(.{
        .root_module = test_module,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run server tests");
    test_step.dependOn(&run_tests.step);
}
