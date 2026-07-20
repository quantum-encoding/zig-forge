const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zfmt",
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
    const run_step = b.step("run", "Run zfmt");
    run_step.dependOn(&run_cmd.step);

    // GNU-parity tests: shell out to the built zfmt and (when installed) the
    // real GNU coreutils fmt, byte-comparing stdout + exit codes.
    const test_options = b.addOptions();
    test_options.addOptionPath("zfmt_exe", exe.getEmittedBin());

    const parity_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gnu_parity_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    parity_tests.root_module.addOptions("build_options", test_options);

    const run_parity_tests = b.addRunArtifact(parity_tests);
    const test_step = b.step("test", "Run GNU-parity tests");
    test_step.dependOn(&run_parity_tests.step);
}
