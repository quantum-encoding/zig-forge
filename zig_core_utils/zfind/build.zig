const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zfind",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    b.installArtifact(exe);

    // Tests. The integration suite (src/gnu_parity_test.zig) shells out to the
    // installed zfind binary and diffs it against the system `find`, so the
    // test run must depend on the install step and know where the binary is.
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    run_tests.setEnvironmentVariable("ZFIND_BIN", b.getInstallPath(.bin, "zfind"));
    run_tests.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run unit + GNU-parity integration tests");
    test_step.dependOn(&run_tests.step);
}
