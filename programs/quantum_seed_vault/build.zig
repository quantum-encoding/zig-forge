const std = @import("std");

pub fn build(b: *std.Build) void {
    // Default to native target for development/testing
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main executable
    const exe = b.addExecutable(.{
        .name = "quantum-seed-vault",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    b.installArtifact(exe);

    // Run command for testing on host
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_cmd.step);

    // Cross-compile for Raspberry Pi Zero (ARMv6)
    const pi_target = b.resolveTargetQuery(.{
        .cpu_arch = .arm,
        .os_tag = .linux,
        .abi = .gnueabihf,
        .cpu_model = .{ .explicit = &std.Target.arm.cpu.arm1176jzf_s },
    });

    const pi_exe = b.addExecutable(.{
        .name = "quantum-seed-vault",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = pi_target,
            .optimize = .ReleaseSafe,
            .link_libc = true,
        }),
    });

    const pi_install = b.addInstallArtifact(pi_exe, .{
        .dest_dir = .{ .override = .{ .custom = "arm" } },
    });

    const pi_step = b.step("pi", "Build for Raspberry Pi Zero (ARMv6)");
    pi_step.dependOn(&pi_install.step);

    // Unit tests
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
