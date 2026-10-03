const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zcomm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = if (target.result.abi == .android) false else true,
        }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    forwardArgs(b, run_cmd);

    const run_step = b.step("run", "Run zcomm");
    run_step.dependOn(&run_cmd.step);

    // Externally-anchored parity tests: diff zcomm against GNU coreutils `comm`
    // (literal 9.10 byte anchors + live-binary diff). The test process locates
    // the built zcomm via ZCOMM_BIN.
    const test_opts = b.addOptions();
    test_opts.addOptionPath("zcomm_bin", exe.getEmittedBin());

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/gnu_parity_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addOptions("build_options", test_opts);

    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);
    run_tests.step.dependOn(b.getInstallStep());
    // The tests shell out to real binaries, so results depend on the filesystem;
    // never let a cached "pass" hide a regression.
    run_tests.has_side_effects = true;

    const test_step = b.step("test", "Run GNU-comm parity tests");
    test_step.dependOn(&run_tests.step);
}

/// Forwards `zig build <step> -- <args>` to a run step: `b.args` on Zig 0.16,
/// passthru args on 0.17+.
fn forwardArgs(b: *std.Build, run: *std.Build.Step.Run) void {
    if (comptime @hasField(std.Build, "args")) {
        if (b.args) |args| run.addArgs(args);
    } else run.addPassthruArgs();
}
