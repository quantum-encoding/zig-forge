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

    if (@hasDecl(std.Build.Step.Run, "addPassthruArgs")) run_cmd.addPassthruArgs() else if (b.args) |args| run_cmd.addArgs(args);

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
    if (@hasDecl(std.Build, "getInstallPath")) {
        run_tests.setEnvironmentVariable("ZXZ_BIN", b.getInstallPath(.bin, "zxz"));
    } else {
        // Zig 0.17: the install prefix is known only at make time and an env var cannot take a
        // lazy path, so the test runs from the install prefix and is given a relative path.
        run_tests.setCwd(.{ .relative = .{ .base = .install_prefix } });
        run_tests.setEnvironmentVariable("ZXZ_BIN", "bin/zxz");
    }
    // Point at the real GNU xz for the live cross-check; the test skips
    // gracefully if it is absent/non-executable.
    run_tests.setEnvironmentVariable("XZ_BIN", "/opt/homebrew/bin/xz");

    const test_step = b.step("test", "Run GNU-parity tests");
    test_step.dependOn(&run_tests.step);
}
