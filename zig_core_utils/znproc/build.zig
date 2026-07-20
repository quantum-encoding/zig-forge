const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "znproc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    b.installArtifact(exe);

    // --- tests ---------------------------------------------------------------
    // The gnu_parity_test suite shells out to the freshly-built znproc binary
    // and diffs it against the system GNU nproc. Inject the absolute path to the
    // installed binary so the test can exec it.
    const bin_path = b.getInstallPath(.bin, "znproc");

    const test_opts = b.addOptions();
    test_opts.addOption([]const u8, "znproc_bin", bin_path);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    unit_tests.root_module.addOptions("build_options", test_opts);

    const run_tests = b.addRunArtifact(unit_tests);
    // The suite execs the installed binary, so it must be built/installed first.
    run_tests.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run unit + GNU-parity tests");
    test_step.dependOn(&run_tests.step);
}
