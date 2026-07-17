const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_module = b.addModule("zigit", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
    });

    const cli_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
    });
    cli_module.addImport("zigit", lib_module);

    const exe = b.addExecutable(.{
        .name = "zigit",
        .root_module = cli_module,
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    const run_step = b.step("run", "Run zigit");
    run_step.dependOn(&run.step);

    const lib_tests = b.addTest(.{ .root_module = lib_module });
    const run_lib_tests = b.addRunArtifact(lib_tests);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_lib_tests.step);

    // Parity harness: runs tests/parity.sh, which shells out to the real
    // `git` binary and diffs its output byte-for-byte against the freshly
    // built `zigit`. It needs the installed executable on disk (the script
    // resolves $ZIGIT_BIN to zig-out/bin/zigit), so depend on the install
    // step. Kept OUT of `zig build test` because it requires a system `git`
    // (and, for the clone/push sections, network + git-http-backend) that a
    // hermetic unit-test run can't assume — invoke it explicitly with
    // `zig build parity`.
    const parity = b.addSystemCommand(&.{"bash"});
    parity.addFileArg(b.path("tests/parity.sh"));
    parity.setEnvironmentVariable(
        "ZIGIT_BIN",
        b.getInstallPath(.bin, exe.out_filename),
    );
    parity.step.dependOn(b.getInstallStep());
    const parity_step = b.step("parity", "Run the git-parity harness (requires system git)");
    parity_step.dependOn(&parity.step);
}
