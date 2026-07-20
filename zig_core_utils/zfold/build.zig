const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zfold",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run zfold");
    run_step.dependOn(&run_cmd.step);

    // ---- Tests ----
    // Externally-anchored GNU-parity tests: they spawn the freshly-built zfold
    // binary and diff its output against the real GNU `fold`. The absolute path
    // of the installed zfold is threaded in as a build option.
    const test_opts = b.addOptions();
    test_opts.addOption([]const u8, "zfold_bin", b.getInstallPath(.bin, "zfold"));

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/gnu_parity_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addOptions("build_options", test_opts);

    const tests = b.addTest(.{ .root_module = test_mod });

    const run_tests = b.addRunArtifact(tests);
    // The tests exec the installed zfold, so build+install it first.
    run_tests.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run GNU-parity tests against the real GNU fold");
    test_step.dependOn(&run_tests.step);
}
