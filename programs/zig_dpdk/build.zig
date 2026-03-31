const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main executable
    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const exe = b.addExecutable(.{
        .name = "zig-dpdk",
        .root_module = exe_module,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run zig-dpdk");
    run_step.dependOn(&run_cmd.step);

    // Unit tests (root module imports all sub-modules, so all inline tests are discovered)
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const tests = b.addTest(.{
        .root_module = test_module,
    });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // Hardware integration test (standalone executable, not part of `zig build test`).
    // Lives in src/ so relative @imports resolve to the same module tree as main.zig.
    const hw_test_module = b.createModule(.{
        .root_source_file = b.path("src/hw_test_main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const hw_test_exe = b.addExecutable(.{
        .name = "zig-dpdk-hw-test",
        .root_module = hw_test_module,
    });

    b.installArtifact(hw_test_exe);

    const hw_step = b.step("hw-test", "Build VFIO hardware integration test");
    hw_step.dependOn(&b.addInstallArtifact(hw_test_exe, .{}).step);
}
