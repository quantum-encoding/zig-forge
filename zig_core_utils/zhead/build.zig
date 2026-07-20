const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zhead",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    b.installArtifact(exe);

    // ---- Tests -----------------------------------------------------------
    // The parity suite shells out to the built `zhead` and diffs its output
    // against the real GNU `head`. Thread the emitted binary's absolute path
    // into the test via a build option (this also makes the test depend on the
    // exe being built first).
    const test_opts = b.addOptions();
    test_opts.addOptionPath("zhead_bin", exe.getEmittedBin());

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gnu_parity_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    tests.root_module.addOptions("build_options", test_opts);

    const run_tests = b.addRunArtifact(tests);
    run_tests.has_side_effects = true; // always re-run (spawns child processes)

    const test_step = b.step("test", "Run GNU-parity tests against the built zhead");
    test_step.dependOn(&run_tests.step);
}
