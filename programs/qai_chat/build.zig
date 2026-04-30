const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const http_sentinel_dep = b.dependency("http_sentinel", .{
        .target = target,
        .optimize = optimize,
    });
    const http_sentinel_module = http_sentinel_dep.module("http-sentinel");

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_module.addImport("http-sentinel", http_sentinel_module);

    const exe = b.addExecutable(.{
        .name = "qai",
        .root_module = exe_module,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the qai chat client");
    run_step.dependOn(&run_cmd.step);
}
