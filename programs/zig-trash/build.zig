const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // macOS: link Objective-C runtime + Foundation for NSFileManager
    if (target.result.os.tag == .macos) {
        mod.linkFramework("Foundation", .{});
        mod.link_libc = true;
    }

    const exe = b.addExecutable(.{
        .name = "trash",
        .root_module = mod,
    });

    b.installArtifact(exe);
}
