const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Public module — consumers import via b.dependency("zig_json_util", …)
    //                                     .module("json-util")
    _ = b.addModule("json-util", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Standalone test target.
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tests = b.addTest(.{ .root_module = test_module });
    const test_step = b.step("test", "Run zig_json_util tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
