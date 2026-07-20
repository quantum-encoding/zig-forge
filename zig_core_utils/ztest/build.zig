const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "ztest",
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
    const run_step = b.step("run", "Run ztest");
    run_step.dependOn(&run_cmd.step);

    // GNU parity tests: shell out to the installed ztest binary and diff its
    // exit codes against the real GNU coreutils `test`. The test needs the built
    // binary, so it depends on the install step and receives the path via
    // ZTEST_BIN.
    const parity_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gnu_parity_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true, // std.c.getenv / access / symlink / utimensat
        }),
    });
    const run_tests = b.addRunArtifact(parity_tests);
    run_tests.setEnvironmentVariable("ZTEST_BIN", b.getInstallPath(.bin, "ztest"));
    run_tests.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run GNU parity tests");
    test_step.dependOn(&run_tests.step);
}
