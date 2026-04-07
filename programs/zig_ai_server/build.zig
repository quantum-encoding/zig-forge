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

    // Server executable
    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
    });
    exe_module.addImport("http-sentinel", http_sentinel_module);

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

    const tests = b.addTest(.{
        .root_module = test_module,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run server tests");
    test_step.dependOn(&run_tests.step);
}
