const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zchmod",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = if (target.result.abi == .android) false else true,
        }),
    });

    b.installArtifact(exe);

    // Unit tests embedded in main.zig (parser-level assertions).
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = if (target.result.abi == .android) false else true,
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit + GNU-parity tests");
    test_step.dependOn(&run_unit_tests.step);

    // Externally-anchored parity tests: diff zchmod against the real GNU
    // `chmod` binary. Needs the built zchmod on disk, so point the test at
    // its install path and make sure it is installed first.
    const parity_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gnu_parity_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const run_parity_tests = b.addRunArtifact(parity_tests);
    // The binary path reaches the test through build_options (b.getInstallPath is gone in
    // Zig 0.17); ZCHMOD_BIN in the environment still overrides it.
    const parity_opts = b.addOptions();
    parity_opts.addOptionPath("zchmod_bin", exe.getEmittedBin());
    parity_tests.root_module.addOptions("build_options", parity_opts);
    run_parity_tests.step.dependOn(b.getInstallStep());
    test_step.dependOn(&run_parity_tests.step);
}
