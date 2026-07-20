const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zxz",
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

    const run_step = b.step("run", "Run zxz");
    run_step.dependOn(&run_cmd.step);

    // GNU-parity tests: drive the installed zxz binary and diff its output /
    // exit codes / on-disk behavior against XZ Utils (embedded GNU-produced
    // fixtures + live GNU xz when available).
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gnu_parity_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    run_tests.step.dependOn(b.getInstallStep()); // ensure zxz is built + installed
    run_tests.setEnvironmentVariable("ZXZ_BIN", b.getInstallPath(.bin, "zxz"));
    // Point at the real GNU xz for the live cross-check; the test skips
    // gracefully if it is absent/non-executable.
    run_tests.setEnvironmentVariable("XZ_BIN", "/opt/homebrew/bin/xz");

    const test_step = b.step("test", "Run GNU-parity tests");
    test_step.dependOn(&run_tests.step);
}
