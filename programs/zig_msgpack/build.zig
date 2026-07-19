const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main library module
    const lib_module = b.addModule("msgpack", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Static library
    const lib = b.addLibrary(.{
        .name = "zig_msgpack",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .linkage = .static,
    });
    b.installArtifact(lib);

    // Demo executable
    const demo_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    demo_module.addImport("msgpack", lib_module);

    const demo = b.addExecutable(.{
        .name = "msgpack-demo",
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
    bench_module.addImport("msgpack", lib_module);

    const bench = b.addExecutable(.{
        .name = "msgpack-bench",
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
    //
    // Three test entry points, all gated by `zig build test`:
    //   1. lib.zig            — encoder + decoder unit tests (via refAllDecls)
    //   2. comprehensive_test — end-to-end encode→decode coverage for every type
    //   3. tier1_anchors      — externally-anchored spec byte vectors
    //
    // Each test module imports `msgpack` so the `@import("lib.zig")` /
    // `@import("msgpack")` paths used inside test files both work.
    const lib_test_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    const lib_tests = b.addTest(.{ .root_module = lib_test_module });

    const comprehensive_test_module = b.createModule(.{
        .root_source_file = b.path("src/comprehensive_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    comprehensive_test_module.addImport("msgpack", lib_module);
    const comprehensive_tests = b.addTest(.{ .root_module = comprehensive_test_module });

    const anchors_test_module = b.createModule(.{
        .root_source_file = b.path("src/tier1_anchors.zig"),
        .target = target,
        .optimize = optimize,
    });
    anchors_test_module.addImport("msgpack", lib_module);
    const anchor_tests = b.addTest(.{ .root_module = anchors_test_module });

    // Fuzz harness (untrusted-bytes → Decoder) for `skip()` and `read()`.
    // `zig build fuzz --fuzz` runs the coverage-guided fuzzer; the same target
    // is folded into `zig build test`, where std.testing.fuzz executes a
    // single deterministic iteration so the harness stays green in CI.
    const fuzz_test_module = b.createModule(.{
        .root_source_file = b.path("src/fuzz.zig"),
        .target = target,
        .optimize = optimize,
    });
    fuzz_test_module.addImport("msgpack", lib_module);
    const fuzz_tests = b.addTest(.{ .root_module = fuzz_test_module });

    const fuzz_step = b.step("fuzz", "Fuzz the decoder against arbitrary bytes");
    fuzz_step.dependOn(&b.addRunArtifact(fuzz_tests).step);

    const test_step = b.step("test", "Run unit tests, end-to-end tests, and spec anchors");
    test_step.dependOn(&b.addRunArtifact(lib_tests).step);
    test_step.dependOn(&b.addRunArtifact(comprehensive_tests).step);
    test_step.dependOn(&b.addRunArtifact(anchor_tests).step);
    test_step.dependOn(&b.addRunArtifact(fuzz_tests).step);
}
