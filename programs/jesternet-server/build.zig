const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // zigit as the git-correctness library. src/git/* are thin wrappers
    // over zigit's pure algorithms.
    const zigit_dep = b.dependency("zigit", .{
        .target = target,
        .optimize = optimize,
    });
    const zigit_module = zigit_dep.module("zigit");

    // Server executable.
    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
    });
    exe_module.addImport("zigit", zigit_module);

    const exe = b.addExecutable(.{
        .name = "jesternet-server",
        .root_module = exe_module,
    });
    b.installArtifact(exe);

    // Run step.
    const run = b.addRunArtifact(exe);
    forwardArgs(b, run);
    const run_step = b.step("run", "Start the jesternet server");
    run_step.dependOn(&run.step);

    // Test step. Each module's tests live alongside it; a single root
    // test entry pulls them all in.
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
    });
    test_module.addImport("zigit", zigit_module);

    const tests = b.addTest(.{ .root_module = test_module });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run server tests");
    test_step.dependOn(&run_tests.step);
}

/// Forwards `zig build <step> -- <args>` to a run step: `b.args` on Zig 0.16,
/// passthru args on 0.17+.
fn forwardArgs(b: *std.Build, run: *std.Build.Step.Run) void {
    if (comptime @hasField(std.Build, "args")) {
        if (b.args) |args| run.addArgs(args);
    } else run.addPassthruArgs();
}
