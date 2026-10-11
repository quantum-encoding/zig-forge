const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "ztouch",
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

    const run_step = b.step("run", "Run ztouch");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Externally-anchored parity tests: diff ztouch against the real GNU
    // `touch` binary. Needs the built ztouch on disk, so point the test at
    // its install path and make sure it is installed first.
    const parity_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gnu_parity_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const run_parity_tests = b.addRunArtifact(parity_tests);
    if (@hasDecl(std.Build, "getInstallPath")) {
        run_parity_tests.setEnvironmentVariable("ZTOUCH_BIN", b.getInstallPath(.bin, "ztouch"));
    } else {
        // Zig 0.17: the install prefix is known only at make time and an env var cannot take a
        // lazy path, so the test runs from the install prefix and is given a relative path.
        run_parity_tests.setCwd(.{ .relative = .{ .base = .install_prefix } });
        run_parity_tests.setEnvironmentVariable("ZTOUCH_BIN", "bin/ztouch");
    }
    run_parity_tests.step.dependOn(b.getInstallStep());
    test_step.dependOn(&run_parity_tests.step);
}
