const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zsum",
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

    const run_step = b.step("run", "Run zsum");
    run_step.dependOn(&run_cmd.step);

    // ---- Tests ----
    // Externally-anchored GNU-parity tests: they spawn the freshly-built zsum
    // binary and diff its output against the real GNU `sum` (gsum). The absolute
    // path of the installed zsum is threaded in as a build option.
    const test_opts = b.addOptions();
    test_opts.addOption([]const u8, "zsum_bin", b.getInstallPath(.bin, "zsum"));

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/gnu_parity_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addOptions("build_options", test_opts);

    const tests = b.addTest(.{ .root_module = test_mod });

    const run_tests = b.addRunArtifact(tests);
    // The tests exec the installed zsum, so build+install it first.
    run_tests.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run GNU-parity tests against the real GNU sum");
    test_step.dependOn(&run_tests.step);
}
