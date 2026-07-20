const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zruncon",
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

    const run_step = b.step("run", "Run zruncon");
    run_step.dependOn(&run_cmd.step);

    // --- Tests -------------------------------------------------------------
    // Externally anchored parity tests (see src/gnu_parity_test.zig). The
    // subprocess layer needs the built binary's path, passed in via a build
    // option so the test can spawn it and byte-compare against GNU's contract.
    const test_opts = b.addOptions();
    test_opts.addOptionPath("exe_path", exe.getEmittedBin());

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    tests.root_module.addOptions("build_options", test_opts);

    const run_tests = b.addRunArtifact(tests);
    // The subprocess tests exec the installed binary path, so build it first.
    run_tests.step.dependOn(&exe.step);

    const test_step = b.step("test", "Run parity tests");
    test_step.dependOn(&run_tests.step);
}
