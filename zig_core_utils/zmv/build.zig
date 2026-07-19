const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zmv",
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

    const run_step = b.step("run", "Run zmv");
    run_step.dependOn(&run_cmd.step);

    // GNU-parity test suite: diffs zmv against the real GNU mv binary
    // (Homebrew coreutils) plus spec-anchored unit tests of the EXDEV
    // copy fallback.
    const test_options = b.addOptions();
    test_options.addOptionPath("zmv_exe", exe.getEmittedBin());

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gnu_parity_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    tests.root_module.addOptions("build_options", test_options);

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run zmv tests (GNU parity + spec-anchored)");
    test_step.dependOn(&run_tests.step);
}
