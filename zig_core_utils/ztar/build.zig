const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "ztar",
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

    const run_step = b.step("run", "Run ztar");
    run_step.dependOn(&run_cmd.step);

    // Tests: (1) pure-Zig unit tests in main.zig anchored to the POSIX ustar
    // header spec, and (2) a cross-implementation parity harness that diffs
    // ztar against the system tar (GNU tar / bsdtar). Both run under
    // `zig build test`.
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const parity = b.addSystemCommand(&.{"bash"});
    parity.addFileArg(b.path("tests/parity_test.sh"));
    parity.addFileArg(exe.getEmittedBin()); // $1 = freshly-built ztar binary
    // Always re-run the harness (it touches the filesystem / external tar).
    parity.has_side_effects = true;

    const test_step = b.step("test", "Run unit tests and the GNU/bsdtar parity harness");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&parity.step);
}
