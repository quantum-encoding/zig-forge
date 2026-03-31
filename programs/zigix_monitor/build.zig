const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Reference the zig_tui library from sibling directory
    const tui_mod = b.createModule(.{
        .root_source_file = b.path("../zig_tui/src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Zigix system monitor executable
    const exe = b.addExecutable(.{
        .name = "zigix-monitor",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    exe.root_module.addImport("zig_tui", tui_mod);
    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the Zigix system monitor");
    run_step.dependOn(&run_cmd.step);
}
