const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zsed",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    b.installArtifact(exe);

    // ------------------------------------------------------------------
    // Tests: externally-anchored parity tests that shell out to the built
    // zsed binary and to the real GNU sed (gsed). See src/gnu_parity_test.zig.
    // ------------------------------------------------------------------
    const parity_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gnu_parity_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    const run_tests = b.addRunArtifact(parity_tests);
    // Point the tests at the freshly-built binary.
    run_tests.setEnvironmentVariable("ZSED_BIN", b.getInstallPath(.bin, "zsed"));
    // The tests spawn the installed zsed binary, so install it first.
    run_tests.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run GNU-sed parity tests (anchored against gsed + documented bytes)");
    test_step.dependOn(&run_tests.step);
}
