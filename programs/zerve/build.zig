const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Reusable server core, consumable by other in-tree programs.
    const zerve = b.addModule("zerve", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true, // kqueue/kevent via std.c
    });

    // Benchmark binary — serves the Anton Putra /api/devices endpoint.
    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_module.addImport("zerve", zerve);
    const exe = b.addExecutable(.{
        .name = "zerve-bench",
        .root_module = exe_module,
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    const run_step = b.step("run", "Run the zerve benchmark server");
    run_step.dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = zerve });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run zerve tests");
    test_step.dependOn(&run_tests.step);
}
