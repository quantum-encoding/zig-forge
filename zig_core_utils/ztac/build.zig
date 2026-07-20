const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "ztac",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    b.installArtifact(exe);

    // Externally-anchored parity tests: spawn ztac AND the real GNU tac and
    // diff their output/exit status. The test binary needs the installed ztac,
    // so it depends on the install step and receives the path via ZTAC_BIN.
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    run_tests.setEnvironmentVariable("ZTAC_BIN", b.getInstallPath(.bin, "ztac"));
    run_tests.step.dependOn(b.getInstallStep());
    run_tests.has_side_effects = true;

    const test_step = b.step("test", "Run parity tests against GNU tac");
    test_step.dependOn(&run_tests.step);
}
