const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zbasenc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = if (target.result.abi == .android) false else true,
        }),
    });

    b.installArtifact(exe);

    // ---- tests ----
    // Externally-anchored GNU-parity tests. They shell out to the freshly built
    // zbasenc binary (and to the real GNU basenc when installed), so the test
    // module is told where the exe lives via a generated build_options module.
    const options = b.addOptions();
    options.addOptionPath("zbasenc_path", exe.getEmittedBin());

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gnu_parity_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = if (target.result.abi == .android) false else true,
        }),
    });
    tests.root_module.addOptions("build_options", options);

    const run_tests = b.addRunArtifact(tests);
    // Ensure the exe is built (and its path resolved) before tests run.
    run_tests.step.dependOn(&exe.step);

    const test_step = b.step("test", "Run GNU-parity tests");
    test_step.dependOn(&run_tests.step);
}
