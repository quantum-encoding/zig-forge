const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // CLI executable
    const exe = b.addExecutable(.{
        .name = "zig-infer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.link_libc = true;
    exe.root_module.linkSystemLibrary("espeak-ng", .{});
    exe.root_module.addCSourceFile(.{ .file = b.path("stb/stb_impl.c"), .flags = &.{} });
    exe.root_module.addIncludePath(b.path("stb"));
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run zig-infer");
    run_step.dependOn(&run_cmd.step);

    // Shared library for FFI
    const shared = b.addLibrary(.{
        .name = "ziginfer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ffi.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
        .linkage = .dynamic,
    });
    shared.root_module.link_libc = true;
    shared.root_module.linkSystemLibrary("espeak-ng", .{});
    shared.root_module.addCSourceFile(.{ .file = b.path("stb/stb_impl.c"), .flags = &.{} });
    shared.root_module.addIncludePath(b.path("stb"));

    const install_shared = b.addInstallArtifact(shared, .{
        .dest_dir = .{ .override = .{ .custom = "lib" } },
    });
    const shared_step = b.step("shared", "Build shared library (libziginfer.so) for FFI");
    shared_step.dependOn(&install_shared.step);

    // Static library
    const static_lib = b.addLibrary(.{
        .name = "ziginfer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ffi.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
        .linkage = .static,
    });
    static_lib.root_module.link_libc = true;
    static_lib.root_module.linkSystemLibrary("espeak-ng", .{});
    static_lib.root_module.addCSourceFile(.{ .file = b.path("stb/stb_impl.c"), .flags = &.{} });
    static_lib.root_module.addIncludePath(b.path("stb"));

    const install_static = b.addInstallArtifact(static_lib, .{
        .dest_dir = .{ .override = .{ .custom = "lib" } },
    });
    const static_step = b.step("static", "Build static library (libziginfer.a)");
    static_step.dependOn(&install_static.step);

    // Tests
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.link_libc = true;
    tests.root_module.linkSystemLibrary("espeak-ng", .{});
    tests.root_module.addCSourceFile(.{ .file = b.path("stb/stb_impl.c"), .flags = &.{} });
    tests.root_module.addIncludePath(b.path("stb"));

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
