const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zbasename",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = if (target.result.abi == .android) false else true,
        }),
    });

    b.installArtifact(exe);

    // --- Tests: GNU-parity, diffed against the freshly-built binary ---
    const test_opts = b.addOptions();
    test_opts.addOptionPath("zbasename_path", exe.getEmittedBin());

    const parity_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gnu_parity_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = if (target.result.abi == .android) false else true,
        }),
    });
    parity_test.root_module.addOptions("build_options", test_opts);

    const run_parity_test = b.addRunArtifact(parity_test);
    // The test spawns the zbasename binary, so it must exist first.
    run_parity_test.step.dependOn(&exe.step);

    const test_step = b.step("test", "Run GNU-parity tests");
    test_step.dependOn(&run_parity_test.step);
}
