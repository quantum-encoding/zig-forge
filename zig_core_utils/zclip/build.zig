const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Shared clipboard module
    const clip_module = b.createModule(.{
        .root_source_file = b.path("src/clipboard.zig"),
        .target = target,
        .optimize = optimize,
            .link_libc = if (target.result.abi == .android) false else true,
    });

    // zcopy executable
    const zcopy_exe = b.addExecutable(.{
        .name = "zcopy",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zcopy.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = if (target.result.abi == .android) false else true,
            .imports = &.{
                .{ .name = "clipboard", .module = clip_module },
            },
        }),
    });
    b.installArtifact(zcopy_exe);

    // zpaste executable
    const zpaste_exe = b.addExecutable(.{
        .name = "zpaste",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zpaste.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = if (target.result.abi == .android) false else true,
            .imports = &.{
                .{ .name = "clipboard", .module = clip_module },
            },
        }),
    });
    b.installArtifact(zpaste_exe);

    // Run commands
    const run_zcopy = b.addRunArtifact(zcopy_exe);
    run_zcopy.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_zcopy.addArgs(args);

    const run_zpaste = b.addRunArtifact(zpaste_exe);
    run_zpaste.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_zpaste.addArgs(args);

    const copy_step = b.step("copy", "Run zcopy");
    copy_step.dependOn(&run_zcopy.step);

    const paste_step = b.step("paste", "Run zpaste");
    paste_step.dependOn(&run_zpaste.step);

    // Tests
    const clip_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/clipboard.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = if (target.result.abi == .android) false else true,
        }),
    });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(clip_tests).step);
}
