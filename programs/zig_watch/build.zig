const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ============================================================
    // Executable
    // ============================================================
    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_module.link_libc = true;

    const exe = b.addExecutable(.{
        .name = "zig-watch",
        .root_module = exe_module,
    });
    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run zig-watch");
    run_step.dependOn(&run_cmd.step);

    // ============================================================
    // Tests
    // ============================================================
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/watcher.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.link_libc = true;

    const tests = b.addTest(.{
        .root_module = test_module,
    });

    // CLI parsers (parseInterval / parseExtensions / buildCommand / parseArgs)
    // live in main.zig and had no test target at all.
    const cli_test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_test_module.link_libc = true;

    const cli_tests = b.addTest(.{
        .root_module = cli_test_module,
    });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    test_step.dependOn(&b.addRunArtifact(cli_tests).step);
}
