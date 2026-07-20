const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zid",
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

    const run_step = b.step("run", "Run zid");
    run_step.dependOn(&run_cmd.step);

    // ---- Tests: externally anchored against GNU coreutils `id` -------------
    const gid_path = b.option(
        []const u8,
        "gid_path",
        "Path to the GNU coreutils id binary used as the test oracle",
    ) orelse "/opt/homebrew/bin/gid";

    const test_opts = b.addOptions();
    // Absolute path of the freshly-installed zid, so the test drives the build
    // it belongs to rather than whatever is on PATH.
    test_opts.addOption([]const u8, "zid_path", b.getInstallPath(.bin, "zid"));
    test_opts.addOption([]const u8, "gid_path", gid_path);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/gnu_parity_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addOptions("build_options", test_opts);

    const parity_tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(parity_tests);
    // The tests exec the installed binary, so install it first.
    run_tests.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run GNU-parity tests");
    test_step.dependOn(&run_tests.step);
}
