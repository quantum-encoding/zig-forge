const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "znice",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    b.installArtifact(exe);

    // --- Tests -------------------------------------------------------------
    // Externally-anchored parity tests: they shell out to the just-built znice
    // AND the real GNU `nice` binary and diff. Inject the built binary's path
    // so the test drives exactly what this build produced.
    const test_opts = b.addOptions();
    test_opts.addOptionPath("znice_path", exe.getEmittedBin());

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gnu_parity_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    tests.root_module.addOptions("build_opts", test_opts);
    // The test spawns the znice binary, so it must exist first.
    tests.step.dependOn(&exe.step);

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run GNU-anchored parity tests");
    test_step.dependOn(&run_tests.step);
}
