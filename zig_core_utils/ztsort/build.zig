const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "ztsort",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    b.installArtifact(exe);

    // ---- tests --------------------------------------------------------------
    // Externally-anchored parity tests: they shell out to the just-built ztsort
    // and to the real GNU `tsort` binary and diff. The ztsort binary path is
    // passed via ZTSORT_BIN so the tests run the artifact we just compiled.
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gnu_parity_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true, // std.c.getenv for ZTSORT_BIN
        }),
    });

    const run_tests = b.addSystemCommand(&.{"env"});
    run_tests.addPrefixedFileArg("ZTSORT_BIN=", exe.getEmittedBin());
    run_tests.addArtifactArg(tests);
    // Point the harness at the freshly-installed ztsort binary.
    run_tests.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run GNU-parity tests against the built ztsort");
    test_step.dependOn(&run_tests.step);
}
