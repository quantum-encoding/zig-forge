const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "ztsort",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    b.installArtifact(exe);

    // ---- tests --------------------------------------------------------------
    // Externally-anchored parity tests: they shell out to the just-built ztsort
    // and to the real GNU `tsort` binary and diff. The ztsort binary path is
    // passed via ZTSORT_BIN so the tests run the artifact we just compiled.
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gnu_parity_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true, // std.c.getenv for ZTSORT_BIN
        }),
    });

    const run_tests = b.addRunArtifact(tests);
    // Point the harness at the freshly-installed ztsort binary.
    if (@hasDecl(std.Build, "getInstallPath")) {
        run_tests.setEnvironmentVariable("ZTSORT_BIN", b.getInstallPath(.bin, "ztsort"));
    } else {
        // Zig 0.17: the install prefix is known only at make time and an env var cannot take a
        // lazy path, so the test runs from the install prefix and is given a relative path.
        run_tests.setCwd(.{ .relative = .{ .base = .install_prefix } });
        run_tests.setEnvironmentVariable("ZTSORT_BIN", "bin/ztsort");
    }
    run_tests.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run GNU-parity tests against the built ztsort");
    test_step.dependOn(&run_tests.step);
}
