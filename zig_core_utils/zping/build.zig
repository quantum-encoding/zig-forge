const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zping",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.root_module.link_libc = true;

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run zping");
    run_step.dependOn(&run_cmd.step);

    // ------------------------------------------------------------------
    // Tests: externally-anchored parity/security tests (gnu_parity_test.zig).
    // ------------------------------------------------------------------
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gnu_parity_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    // gnu_parity_test.zig imports main.zig, which @cImports libc.
    tests.root_module.link_libc = true;

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run zping tests");
    test_step.dependOn(&run_tests.step);
}
