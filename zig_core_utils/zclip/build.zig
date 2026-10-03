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
    forwardArgs(b, run_zcopy);

    const run_zpaste = b.addRunArtifact(zpaste_exe);
    run_zpaste.step.dependOn(b.getInstallStep());
    forwardArgs(b, run_zpaste);

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

    // Externally-anchored parity tests. They shell out to the built zcopy/zpaste
    // binaries, so expose each binary's built path.
    const test_options = b.addOptions();
    test_options.addOptionPath("zcopy_bin", zcopy_exe.getEmittedBin());
    test_options.addOptionPath("zpaste_bin", zpaste_exe.getEmittedBin());

    const parity_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gnu_parity_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = if (target.result.abi == .android) false else true,
            .imports = &.{
                .{ .name = "clipboard", .module = clip_module },
                .{ .name = "build_options", .module = test_options.createModule() },
            },
        }),
    });
    const run_parity = b.addRunArtifact(parity_tests);
    run_parity.step.dependOn(b.getInstallStep()); // binaries must exist first

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(clip_tests).step);
    test_step.dependOn(&run_parity.step);
}

/// Forwards `zig build <step> -- <args>` to a run step: `b.args` on Zig 0.16,
/// passthru args on 0.17+.
fn forwardArgs(b: *std.Build, run: *std.Build.Step.Run) void {
    if (comptime @hasField(std.Build, "args")) {
        if (b.args) |args| run.addArgs(args);
    } else run.addPassthruArgs();
}
