const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Library module - exported for dependent packages
    const lib_module = b.addModule("zig-websocket", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_module.link_libc = true;

    // CLI demo executable
    const demo_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    demo_module.addImport("websocket", lib_module);
    demo_module.link_libc = true;

    const demo = b.addExecutable(.{
        .name = "websocket-demo",
        .root_module = demo_module,
    });
    b.installArtifact(demo);

    // Benchmarks
    const bench_module = b.createModule(.{
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_module.addImport("websocket", lib_module);
    bench_module.link_libc = true;

    const bench = b.addExecutable(.{
        .name = "websocket-bench",
        .root_module = bench_module,
    });
    b.installArtifact(bench);

    // Tests
    const test_step = b.step("test", "Run unit tests");

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.link_libc = true;

    const tests = b.addTest(.{
        .root_module = test_module,
    });
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);
}
