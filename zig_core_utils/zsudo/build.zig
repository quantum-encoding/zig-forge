const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zsudo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    // Link PAM for authentication
    // macOS has PAM in the system SDK; Linux also needs pam_misc
    exe.root_module.linkSystemLibrary("pam", .{});
    if (exe.rootModuleTarget().os.tag != .macos) {
        exe.root_module.linkSystemLibrary("pam_misc", .{});
    }

    b.installArtifact(exe);
}
