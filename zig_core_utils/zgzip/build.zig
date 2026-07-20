const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // zgzip executable
    const zgzip = b.addExecutable(.{
        .name = "zgzip",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    b.installArtifact(zgzip);

    // zgunzip executable (same source, different name triggers different behavior)
    const zgunzip = b.addExecutable(.{
        .name = "zgunzip",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    b.installArtifact(zgunzip);

    const run_cmd = b.addRunArtifact(zgzip);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run zgzip");
    run_step.dependOn(&run_cmd.step);

    // ---- Tests --------------------------------------------------------------
    // Externally-anchored parity tests. The test binary shells out to the
    // freshly-built zgzip/zgunzip and to the system gzip/gunzip, so it needs
    // their absolute paths, passed in via build options.
    const parity_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gnu_parity_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    const test_opts = b.addOptions();
    test_opts.addOptionPath("zgzip_bin", zgzip.getEmittedBin());
    test_opts.addOptionPath("zgunzip_bin", zgunzip.getEmittedBin());
    parity_tests.root_module.addOptions("build_options", test_opts);

    const run_tests = b.addRunArtifact(parity_tests);
    run_tests.has_side_effects = true; // spawns child processes; never cache-skip

    const test_step = b.step("test", "Run externally-anchored parity tests");
    test_step.dependOn(&run_tests.step);
}
