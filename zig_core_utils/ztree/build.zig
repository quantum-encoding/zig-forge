const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "ztree",
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

    forwardArgs(b, run_cmd);

    const run_step = b.step("run", "Run ztree");
    run_step.dependOn(&run_cmd.step);

    // ---- Tests: externally anchored against the real GNU `tree` binary ----
    const gnu_tree_path = b.option(
        []const u8,
        "gnu-tree",
        "Path to the GNU tree binary used as the parity anchor",
    ) orelse "/opt/homebrew/bin/tree";

    const test_opts = b.addOptions();
    // Absolute path to the freshly-installed ztree binary under test.
    test_opts.addOptionPath("ztree_exe", exe.getEmittedBin());
    test_opts.addOption([]const u8, "gnu_tree", gnu_tree_path);

    const test_exe = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gnu_parity_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    test_exe.root_module.addOptions("build_options", test_opts);

    const run_tests = b.addRunArtifact(test_exe);
    // The parity tests shell out to the installed ztree binary, so it must be
    // built and installed first.
    run_tests.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run GNU-parity tests");
    test_step.dependOn(&run_tests.step);
}

/// Forwards `zig build <step> -- <args>` to a run step: `b.args` on Zig 0.16,
/// passthru args on 0.17+.
fn forwardArgs(b: *std.Build, run: *std.Build.Step.Run) void {
    if (comptime @hasField(std.Build, "args")) {
        if (b.args) |args| run.addArgs(args);
    } else run.addPassthruArgs();
}
