const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zchown",
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
    if (@hasDecl(std.Build.Step.Run, "addPassthruArgs")) run_cmd.addPassthruArgs() else if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run zchown");
    run_step.dependOn(&run_cmd.step);

    // Unit tests embedded in main.zig (if any).
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_unit_tests.step);

    // Externally-anchored parity tests: diff zchown against the real GNU
    // `chown` binary. Needs the built zchown on disk, so point the test at its
    // install path and install first.
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
    // Zig 0.17); ZCHOWN_BIN in the environment still overrides it.
    const parity_opts = b.addOptions();
    parity_opts.addOptionPath("zchown_bin", exe.getEmittedBin());
    parity_tests.root_module.addOptions("build_options", parity_opts);
    run_parity_tests.step.dependOn(b.getInstallStep());
    test_step.dependOn(&run_parity_tests.step);
}
