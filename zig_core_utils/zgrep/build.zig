const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zgrep",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    b.installArtifact(exe);

    // GNU-parity tests: shell out to the freshly-built zgrep binary and compare
    // its output against documented GNU/POSIX bytes and the independent BSD grep.
    const parity_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gnu_parity_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const run_parity = b.addRunArtifact(parity_tests);
    // The tests spawn the installed binary (zig-out/bin/zgrep) and read fixtures
    // relative to the build root, so ensure it is installed first and pass its
    // resolved path explicitly via ZGREP_BIN.
    run_parity.step.dependOn(b.getInstallStep());
    run_parity.setEnvironmentVariable("ZGREP_BIN", b.getInstallPath(.bin, "zgrep"));

    const test_step = b.step("test", "Run GNU-parity tests");
    test_step.dependOn(&run_parity.step);
}
