const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zbackup",
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
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run zbackup");
    run_step.dependOn(&run_cmd.step);

    // Externally-anchored tests (RFC 8259 JSON, POSIX readlink, documented
    // status legend). See src/gnu_parity_test.zig for the anchor rationale.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/gnu_parity_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = if (target.result.abi == .android) false else true,
    });
    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run zbackup tests");
    test_step.dependOn(&run_unit_tests.step);
}
