const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zpr",
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

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run zpr");
    run_step.dependOn(&run_cmd.step);

    // --- Tests: externally-anchored GNU `pr` parity harness ---------------
    // The test shells out to the freshly-built zpr binary and (when present)
    // the real GNU coreutils `pr`, so it needs the exe installed first and its
    // path passed in via a build option.
    const test_opts = b.addOptions();
    test_opts.addOption([]const u8, "zpr_exe_path", b.getInstallPath(.bin, "zpr"));

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gnu_parity_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    tests.root_module.addOptions("build_options", test_opts);

    const run_tests = b.addRunArtifact(tests);
    // The parity tests exec the installed binary, so build+install it first.
    run_tests.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run GNU-parity tests");
    test_step.dependOn(&run_tests.step);
}
