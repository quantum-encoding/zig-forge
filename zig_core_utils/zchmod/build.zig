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
    run_parity_tests.setEnvironmentVariable("ZCHMOD_BIN", b.getInstallPath(.bin, "zchmod"));
    run_parity_tests.step.dependOn(b.getInstallStep());
    test_step.dependOn(&run_parity_tests.step);
}
