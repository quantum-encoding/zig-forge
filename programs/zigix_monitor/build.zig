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

    // Test step — required by the repo-root `test-all` aggregate, which runs
    // `zig build test` in this directory. Compiles main.zig (which pulls in the
    // parser/formatter modules) as a test root so their `test` blocks run.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addImport("zig_tui", tui_mod);
    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
