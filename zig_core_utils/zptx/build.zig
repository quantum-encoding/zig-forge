const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zptx",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    b.installArtifact(exe);

    // ---- Externally-anchored tests (diff against the real GNU `ptx`) ----
    // The test binary needs the path to the freshly-built zptx so it can run it
    // as a child process; pass it through build_options.
    const test_opts = b.addOptions();
    test_opts.addOptionPath("zptx_path", exe.getEmittedBin());

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
    // Ensure zptx is actually built before the tests try to execute it.
    run_tests.step.dependOn(&exe.step);

    const test_step = b.step("test", "Run externally-anchored GNU-parity tests");
    test_step.dependOn(&run_tests.step);
}
