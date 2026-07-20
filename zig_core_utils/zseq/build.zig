const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zseq",
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

    const run_step = b.step("run", "Run zseq");
    run_step.dependOn(&run_cmd.step);

    // ----- Tests -----
    // Externally-anchored parity tests diff zseq's output against the real GNU
    // coreutils `seq` binary. The test needs the built zseq path and a GNU
    // reference path; both are injected via a generated options module.
    const options = b.addOptions();
    options.addOption([]const u8, "zseq_path", b.getInstallPath(.bin, "zseq"));
    const gnu_path = b.option([]const u8, "gnu_seq", "Path to a GNU coreutils seq binary for parity tests") orelse "";
    options.addOption([]const u8, "gnu_path", gnu_path);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/gnu_parity_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addOptions("build_options", options);

    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);
    // The parity tests spawn the installed zseq binary, so build+install first.
    run_tests.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run GNU parity tests");
    test_step.dependOn(&run_tests.step);
}
