const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Compat module for Zig 0.16 time/timer compatibility
    const compat_module = b.createModule(.{
        .root_source_file = b.path("src/compat.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Main library module
    const lib_module = b.addModule("ratelimit", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "compat.zig", .module = compat_module },
        },
    });

    // Demo executable
    const demo_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    demo_module.addImport("ratelimit", lib_module);
    demo_module.addImport("compat.zig", compat_module);

    const demo = b.addExecutable(.{
        .name = "ratelimit-demo",
        .root_module = demo_module,
    });
    b.installArtifact(demo);

    // Benchmarks
    const bench_module = b.createModule(.{
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    bench_module.addImport("ratelimit", lib_module);
    bench_module.addImport("compat.zig", compat_module);

    const bench = b.addExecutable(.{
        .name = "ratelimit-bench",
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
        .link_libc = true,
        .imports = &.{
            .{ .name = "compat.zig", .module = compat_module },
        },
    });

    const lib_tests = b.addTest(.{
        .root_module = test_module,
    });

    const run_tests = b.addRunArtifact(lib_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
