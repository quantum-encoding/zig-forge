const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zb2sum",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = if (target.result.abi == .android) false else true,
        }),
    });

    b.installArtifact(exe);

    // Externally-anchored parity tests (spec vectors + live GNU b2sum diff).
    // The test binary shells out to the installed zb2sum, so it needs the path.
    const test_opts = b.addOptions();
    test_opts.addOption([]const u8, "zb_exe", b.getInstallPath(.bin, "zb2sum"));

    const parity_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gnu_parity_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = if (target.result.abi == .android) false else true,
        }),
    });
    parity_tests.root_module.addOptions("build_options", test_opts);

    const run_parity_tests = b.addRunArtifact(parity_tests);
    // Ensure the zb2sum binary is installed before the tests run it.
    run_parity_tests.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run externally-anchored parity tests");
    test_step.dependOn(&run_parity_tests.step);
}
