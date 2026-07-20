const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zsort",
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
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run zsort");
    run_step.dependOn(&run_cmd.step);

    // --- Tests ---------------------------------------------------------------
    // Externally-anchored parity tests: the test binary shells out to the just-
    // built zsort AND to the real GNU coreutils `sort` and diffs their output.
    const test_opts = b.addOptions();
    // Pass the built zsort binary path to the test at compile time.
    test_opts.addOptionPath("zsort_exe", exe.getEmittedBin());

    const parity_mod = b.createModule(.{
        .root_source_file = b.path("src/gnu_parity_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    parity_mod.addOptions("build_options", test_opts);

    const parity_tests = b.addTest(.{ .root_module = parity_mod });
    // The test needs the zsort binary to exist on disk before it runs.
    parity_tests.step.dependOn(&exe.step);

    const run_parity = b.addRunArtifact(parity_tests);
    run_parity.has_side_effects = true; // never cache: it observes external state

    const test_step = b.step("test", "Run GNU-parity tests");
    test_step.dependOn(&run_parity.step);
}
