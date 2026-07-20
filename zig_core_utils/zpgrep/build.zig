const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zpgrep",
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

    const run_step = b.step("run", "Run zpgrep");
    run_step.dependOn(&run_cmd.step);

    // --- tests (externally anchored: POSIX ERE + procps-ng documented CLI) ---
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/gnu_parity_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // Absolute path to the installed binary, so the CLI shell-out tests can
    // exec the real zpgrep regardless of cwd.
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "zpgrep_path", b.getInstallPath(.bin, "zpgrep"));
    test_mod.addOptions("build_options", build_options);

    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(unit_tests);
    // Ensure the binary is built+installed before the shell-out tests run.
    run_tests.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run zpgrep parity tests");
    test_step.dependOn(&run_tests.step);
}
