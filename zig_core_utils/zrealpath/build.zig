const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zrealpath",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    b.installArtifact(exe);

    // Externally-anchored parity tests: shell out to both zrealpath and the
    // real GNU realpath binary and diff their output. Requires the executable
    // to be installed first (the test invokes zig-out/bin/zrealpath).
    const parity_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gnu_parity_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    const run_parity = b.addRunArtifact(parity_tests);
    run_parity.step.dependOn(b.getInstallStep());
    // Never cache: the tests exercise a live sibling binary + the filesystem.
    run_parity.has_side_effects = true;

    const test_step = b.step("test", "Run GNU realpath parity tests");
    test_step.dependOn(&run_parity.step);
}
