const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "duckcache-scribe",
        .root_module = root_module,
    });

    exe.root_module.linkSystemLibrary("c", .{});

    b.installArtifact(exe);

    // macOS version (uses kqueue instead of inotify) - only build on macOS
    const is_macos = target.result.os.tag == .macos;
    if (is_macos) {
        const macos_module = b.createModule(.{
            .root_source_file = b.path("src/main-macos.zig"),
            .target = target,
            .optimize = optimize,
        });
        const macos_exe = b.addExecutable(.{
            .name = "duckcache-scribe-macos",
            .root_module = macos_module,
        });
        macos_exe.root_module.linkSystemLibrary("c", .{});
        b.installArtifact(macos_exe);
    }

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the DuckCache Scribe daemon");
    run_step.dependOn(&run_cmd.step);
}
