const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zdate",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = if (target.result.abi == .android) false else true,
        }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run zdate");
    run_step.dependOn(&run_cmd.step);

    // --- Tests ---------------------------------------------------------------
    // Externally-anchored parity tests: they shell out to the compiled zdate
    // binary AND the real GNU date (gdate) and diff the output byte-for-byte.
    // The path to the freshly-built zdate is threaded through build options so
    // the test never depends on an install location.
    const test_opts = b.addOptions();
    test_opts.addOptionPath("zdate_bin", exe.getEmittedBin());

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gnu_parity_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = if (target.result.abi == .android) false else true,
        }),
    });
    tests.root_module.addOptions("build_options", test_opts);

    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run zdate parity tests against GNU date");
    test_step.dependOn(&run_tests.step);
}
