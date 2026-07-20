const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zvdir",
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

    const run_step = b.step("run", "Run zvdir");
    run_step.dependOn(&run_cmd.step);

    // Tests: externally anchored against the real GNU `vdir` binary.
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gnu_parity_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    const run_tests = b.addRunArtifact(tests);
    // The parity test shells out to the installed zvdir; make sure it exists
    // and tell the test where to find it.
    run_tests.step.dependOn(b.getInstallStep());
    run_tests.setEnvironmentVariable("ZVDIR_BIN", b.getInstallPath(.bin, "zvdir"));

    const test_step = b.step("test", "Run GNU-parity tests");
    test_step.dependOn(&run_tests.step);
}
