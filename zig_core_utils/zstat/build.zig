const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zstat",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    b.installArtifact(exe);

    // Externally-anchored parity tests: diff zstat against the real GNU stat
    // binary (and a few documented, TZ-independent literals). See
    // src/gnu_parity_test.zig.
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gnu_parity_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    // The tests exec the freshly built binary at zig-out/bin/zstat, so install
    // it first and run from the project root.
    run_tests.step.dependOn(b.getInstallStep());
    run_tests.setCwd(b.path("."));
    // Never cache a green result: the anchor must actually re-run.
    run_tests.has_side_effects = true;

    const test_step = b.step("test", "Run GNU-parity tests");
    test_step.dependOn(&run_tests.step);
}
