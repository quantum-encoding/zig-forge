const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zuniq",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    b.installArtifact(exe);

    // --- Tests -------------------------------------------------------------
    // Externally-anchored parity tests: they shell out to the just-built zuniq
    // binary and diff its output against the real GNU `uniq`. The test binary
    // needs to know where the built zuniq lives, so we hand it the artifact's
    // output path via the ZUNIQ_BIN env var.
    const test_opts = b.addOptions();
    test_opts.addOption([]const u8, "zuniq_bin", b.getInstallPath(.bin, "zuniq"));

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/gnu_parity_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addOptions("build_options", test_opts);

    const unit_tests = b.addTest(.{ .root_module = test_mod });

    const run_tests = b.addRunArtifact(unit_tests);
    // Ensure the zuniq binary is installed before the tests run.
    run_tests.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run externally-anchored GNU-parity tests");
    test_step.dependOn(&run_tests.step);
}
