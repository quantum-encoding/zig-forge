const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zln",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run zln");
    run_step.dependOn(&run_cmd.step);

    // GNU-parity tests: diff zln against the real GNU coreutils `ln` binary.
    const parity_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/gnu_parity.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const test_options = b.addOptions();
    test_options.addOptionPath("zln_exe", exe.getEmittedBin());
    parity_tests.root_module.addOptions("build_options", test_options);

    const run_parity_tests = b.addRunArtifact(parity_tests);
    const test_step = b.step("test", "Run GNU-parity tests (requires GNU coreutils ln)");
    test_step.dependOn(&run_parity_tests.step);
}
