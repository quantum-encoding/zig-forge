const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create library module
    const lib_module = b.addModule("zig_toml", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Library
    const lib = b.addLibrary(.{
        .name = "zig_toml",
        .root_module = lib_module,
    });
    b.installArtifact(lib);

    // Demo executable module
    const demo_module = b.addModule("zig_toml_demo_module", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    demo_module.addImport("zig_toml", lib_module);

    // Demo executable
    const demo = b.addExecutable(.{
        .name = "zig_toml_demo",
        .root_module = demo_module,
    });
    b.installArtifact(demo);

    const run_demo = b.addRunArtifact(demo);
    if (b.args) |args| {
        run_demo.addArgs(args);
    }

    const demo_step = b.step("demo", "Run the TOML parser demo");
    demo_step.dependOn(&run_demo.step);

    // Benchmarks module
    const bench_module = b.addModule("zig_toml_bench_module", .{
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    bench_module.addImport("zig_toml", lib_module);

    const bench = b.addExecutable(.{
        .name = "zig_toml_bench",
        .root_module = bench_module,
    });
    b.installArtifact(bench);

    const run_bench = b.addRunArtifact(bench);
    const bench_step = b.step("bench", "Run TOML parser benchmarks");
    bench_step.dependOn(&run_bench.step);

    // ============================================================
    // Tests
    //
    // Two test entry points, both gated by `zig build test`:
    //   1. lib.zig         — Tier 2 (failure modes) + Tier 3 (roundtrips)
    //                        discovered via the refAllDecls trampoline in
    //                        lib.zig.
    //   2. tier1_anchors   — externally-anchored toml-test/spec vectors.
    //
    // Per /CLAUDE.md rule #1, removing or weakening tier1_anchors.zig
    // requires a re-audit, not a refactor. The lib.zig tests are gravy.
    // ============================================================
    const test_module = b.addModule("zig_toml_test_module", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const lib_unit_tests = b.addTest(.{ .root_module = test_module });

    const anchors_test_module = b.addModule("zig_toml_anchors_test_module", .{
        .root_source_file = b.path("src/tier1_anchors.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    anchors_test_module.addImport("zig_toml", lib_module);
    const anchor_tests = b.addTest(.{ .root_module = anchors_test_module });

    const test_step = b.step("test", "Run unit tests, tier-2 failure modes, and tier-1 spec anchors");
    test_step.dependOn(&b.addRunArtifact(lib_unit_tests).step);
    test_step.dependOn(&b.addRunArtifact(anchor_tests).step);
}
