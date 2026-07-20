const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "ztrue",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    // --- Tests: GNU-parity, diffed against the freshly-built binary ---
    const test_opts = b.addOptions();
    test_opts.addOptionPath("ztrue_path", exe.getEmittedBin());

    const parity_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gnu_parity_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    parity_test.root_module.addOptions("build_options", test_opts);

    const run_parity_test = b.addRunArtifact(parity_test);
    // The test spawns the ztrue binary, so it must exist first.
    run_parity_test.step.dependOn(&exe.step);

    const test_step = b.step("test", "Run GNU-parity tests");
    test_step.dependOn(&run_parity_test.step);
}
