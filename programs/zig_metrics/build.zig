const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main library module (exposed for use as dependency)
    const lib_module = b.addModule("metrics", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Static library
    const lib = b.addLibrary(.{
        .name = "zig_metrics",
        .root_module = lib_module,
    });
    b.installArtifact(lib);

    // Demo executable
    const demo_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    demo_module.addImport("metrics", lib_module);

    const demo = b.addExecutable(.{
        .name = "metrics-demo",
        .root_module = demo_module,
    });
    b.installArtifact(demo);

    // Benchmarks
    const bench_module = b.createModule(.{
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true, // Required for Timer using clock_gettime
    });
    bench_module.addImport("metrics", lib_module);

    const bench = b.addExecutable(.{
        .name = "metrics-bench",
        .root_module = bench_module,
    });
    b.installArtifact(bench);

    // Run demo
    const run_demo = b.addRunArtifact(demo);
    const run_step = b.step("run", "Run the demo");
    run_step.dependOn(&run_demo.step);

    // Run benchmarks
    const run_bench = b.addRunArtifact(bench);
    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&run_bench.step);

    // Tests
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib_tests = b.addTest(.{
        .root_module = test_module,
    });

    const run_tests = b.addRunArtifact(lib_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
