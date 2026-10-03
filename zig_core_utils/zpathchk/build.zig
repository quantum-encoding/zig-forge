const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zpathchk",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    b.installArtifact(exe);

    // --- tests: externally anchored against GNU coreutils `pathchk` ---
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/gnu_parity_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addSystemCommand(&.{"env"});
    run_tests.addPrefixedFileArg("ZPATHCHK_BIN=", exe.getEmittedBin());
    run_tests.addArtifactArg(tests);

    // The test shells out to the freshly-built zpathchk binary. Install it
    // first and hand the test its absolute path via ZPATHCHK_BIN.
    const install_exe = b.addInstallArtifact(exe, .{});
    run_tests.step.dependOn(&install_exe.step);

    const test_step = b.step("test", "Run GNU-parity tests");
    test_step.dependOn(&run_tests.step);
}
