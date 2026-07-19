const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Consumable library module for in-tree @import("zig_humanize") consumers.
    const humanize_module = b.addModule("zig_humanize", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Create modules for main and bench
    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const bench_module = b.createModule(.{
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Make the library module importable as @import("zig_humanize") from the
    // in-tree executables as well (they also reference src/humanize.zig directly).
    exe_module.addImport("zig_humanize", humanize_module);
    bench_module.addImport("zig_humanize", humanize_module);

    // CLI executable
    const exe = b.addExecutable(.{
        .name = "zig_humanize",
        .root_module = exe_module,
    });
    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Tests
    const lib_test_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib_tests = b.addTest(.{
        .root_module = lib_test_module,
    });
    const run_lib_tests = b.addRunArtifact(lib_tests);

    // Tier-1 externally-anchored vectors (go-humanize / python humanize).
    // Separate module so it exercises the public @import("zig_humanize")
    // surface exactly as an in-tree consumer would.
    const anchors_test_module = b.createModule(.{
        .root_source_file = b.path("src/tier1_anchors.zig"),
        .target = target,
        .optimize = optimize,
    });
    anchors_test_module.addImport("zig_humanize", humanize_module);
    const anchor_tests = b.addTest(.{ .root_module = anchors_test_module });
    const run_anchor_tests = b.addRunArtifact(anchor_tests);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&run_anchor_tests.step);

    // Benchmark
    const bench = b.addExecutable(.{
        .name = "bench",
        .root_module = bench_module,
    });
    b.installArtifact(bench);

    const bench_cmd = b.addRunArtifact(bench);
    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&bench_cmd.step);
}
