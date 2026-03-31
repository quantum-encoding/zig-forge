const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Library module (exposed for use as dependency)
    // link_libc required for clock_gettime used in timestamp functions
    const lib_module = b.addModule("jwt", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Static library
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "jwt",
        .root_module = lib_module,
    });
    b.installArtifact(lib);

    // CLI demo executable
    // link_libc required for clock_gettime used in timestamp functions
    const demo_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    demo_module.addImport("jwt", lib_module);

    const demo = b.addExecutable(.{
        .name = "jwt-demo",
        .root_module = demo_module,
    });
    b.installArtifact(demo);

    // Benchmarks
    // link_libc required for clock_gettime used in Timer implementation
    const bench_module = b.createModule(.{
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    bench_module.addImport("jwt", lib_module);

    const bench = b.addExecutable(.{
        .name = "jwt-bench",
        .root_module = bench_module,
    });
    b.installArtifact(bench);

    // Tests
    const test_step = b.step("test", "Run unit tests");
    const tests = b.addTest(.{
        .root_module = lib_module,
    });
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);
}
