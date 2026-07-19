const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zcp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = if (target.result.abi == .android) false else true,
        }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run zcp");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = if (target.result.abi == .android) false else true,
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    // GNU-anchored black-box tests: run the built zcp against the real GNU
    // cp binary and require identical behavior (skipped if GNU cp absent).
    const test_options = b.addOptions();
    test_options.addOptionPath("zcp_path", exe.getEmittedBin());
    const gnu_tests_module = b.createModule(.{
        .root_source_file = b.path("src/gnu_tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = if (target.result.abi == .android) false else true,
    });
    gnu_tests_module.addOptions("build_options", test_options);
    const gnu_tests = b.addTest(.{ .root_module = gnu_tests_module });
    const run_gnu_tests = b.addRunArtifact(gnu_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_gnu_tests.step);
}
