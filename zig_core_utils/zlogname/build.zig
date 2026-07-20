const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zlogname",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    b.installArtifact(exe);

    // Externally-anchored tests: diff zlogname against the host's real GNU
    // coreutils `logname` (/opt/homebrew/bin/glogname) plus documented GNU
    // getopt behavior. The freshly-built binary path is threaded in via
    // build_options so the test harness can spawn it.
    const test_opts = b.addOptions();
    test_opts.addOptionPath("zlogname_exe", exe.getEmittedBin());

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gnu_parity_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addOptions("build_options", test_opts);

    const run_tests = b.addRunArtifact(tests);
    run_tests.has_side_effects = true; // always re-run: reference glogname output is external

    const test_step = b.step("test", "Run externally-anchored GNU/POSIX parity tests");
    test_step.dependOn(&run_tests.step);
}
