const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zjq",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run zjq");
    run_step.dependOn(&run_cmd.step);

    // --- Tests -------------------------------------------------------------
    // Externally-anchored parity tests: they shell out to the just-built zjq
    // binary and diff its output against the real `jq`. The test binary needs
    // to know where the built zjq lives, so we hand it the install path via a
    // generated build_options module.
    const test_opts = b.addOptions();
    test_opts.addOption([]const u8, "zjq_bin", b.getInstallPath(.bin, "zjq"));

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/gnu_parity_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addOptions("build_options", test_opts);

    const unit_tests = b.addTest(.{ .root_module = test_mod });

    const run_tests = b.addRunArtifact(unit_tests);
    // Ensure the zjq binary is installed before the tests run.
    run_tests.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run externally-anchored jq-parity tests");
    test_step.dependOn(&run_tests.step);
}
