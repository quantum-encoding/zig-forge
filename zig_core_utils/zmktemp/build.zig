const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zmktemp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    b.installArtifact(exe);

    // ---- Tests -----------------------------------------------------------
    // The parity tests shell out to the installed zmktemp binary and the real
    // GNU mktemp, so they need (a) the installed exe path and (b) the exe to be
    // installed on disk before they run.
    const options = b.addOptions();
    options.addOption([]const u8, "zmktemp_path", b.getInstallPath(.bin, "zmktemp"));

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/gnu_parity_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addOptions("build_options", options);

    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);
    // Ensure the binary the tests exec is present on disk first.
    run_tests.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run externally-anchored GNU-parity tests");
    test_step.dependOn(&run_tests.step);
}
