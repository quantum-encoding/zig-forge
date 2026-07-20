const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zdircolors",
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

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run zdircolors");
    run_step.dependOn(&run_cmd.step);

    // Externally-anchored GNU-parity tests. They spawn the freshly built
    // zdircolors binary (via libc fork/execve) and compare its behavior against
    // the real GNU `dircolors` and against literal bytes documented by coreutils
    // 9.10. The binary path is threaded in through build options; depending on
    // the emitted binary guarantees it is built before the tests run.
    const test_options = b.addOptions();
    test_options.addOptionPath("zdircolors_bin", exe.getEmittedBin());

    const parity_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gnu_parity_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = if (target.result.abi == .android) false else true,
        }),
    });
    parity_tests.root_module.addOptions("build_options", test_options);

    const test_step = b.step("test", "Run parity tests against GNU dircolors");
    test_step.dependOn(&b.addRunArtifact(parity_tests).step);
}
