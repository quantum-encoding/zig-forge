const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "znl",
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

    const run_step = b.step("run", "Run znl");
    run_step.dependOn(&run_cmd.step);

    // --- Tests: externally anchored GNU-parity vectors ---
    // Pass the compiled znl binary path to the test so it exercises the real
    // executable (the tests shell out and diff against literal GNU `nl` output).
    const test_opts = b.addOptions();
    test_opts.addOptionPath("znl_bin", exe.getEmittedBin());

    const test_exe = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gnu_parity_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_exe.root_module.addOptions("build_options", test_opts);
    // The tests run the built binary, so ensure it exists first.
    const run_tests = b.addRunArtifact(test_exe);
    run_tests.step.dependOn(&exe.step);

    const test_step = b.step("test", "Run GNU-parity tests");
    test_step.dependOn(&run_tests.step);
}
