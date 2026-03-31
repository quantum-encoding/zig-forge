const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ========================================================================
    // Core FFI Static Library (ZERO DEPENDENCIES)
    // ========================================================================

    const core_module = b.createModule(.{
        .root_source_file = b.path("src/market_data_core.zig"),
        .target = target,
        .optimize = optimize,
    });

    const core_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "market_data_core",
        .root_module = core_module,
    });

    core_lib.root_module.link_libc = true;
    // NO EXTERNAL DEPS

    b.installArtifact(core_lib);

    const core_step = b.step("core", "Build core FFI static library (zero deps)");
    core_step.dependOn(&b.addInstallArtifact(core_lib, .{}).step);

    // ========================================================================
    // Android ARM64 Cross-Compilation Target
    // ========================================================================

    const android_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .linux,
        .abi = .android,
    });

    const android_module = b.createModule(.{
        .root_source_file = b.path("src/market_data_core.zig"),
        .target = android_target,
        .optimize = .ReleaseFast,
    });

    const android_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "market_data_core",
        .root_module = android_module,
    });

    android_lib.root_module.link_libc = true;
    android_lib.root_module.strip = true;

    const android_install = b.addInstallArtifact(android_lib, .{
        .dest_dir = .{ .override = .{ .custom = "lib/android-arm64" } },
    });

    const android_step = b.step("android", "Build for Android ARM64 (aarch64-linux-android)");
    android_step.dependOn(&android_install.step);

    // ========================================================================
    // Parser library module (used by benchmarks, examples, tests)
    // ========================================================================

    const parser_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Benchmark executable
    const bench_module = b.createModule(.{
        .root_source_file = b.path("src/benchmarks/main_bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_module.addImport("parser", parser_module);
    bench_module.link_libc = true;

    const bench = b.addExecutable(.{
        .name = "bench-parser",
        .root_module = bench_module,
    });

    b.installArtifact(bench);

    const bench_cmd = b.addRunArtifact(bench);
    const bench_step = b.step("bench", "Run parser benchmarks");
    bench_step.dependOn(&bench_cmd.step);

    // Example: Parse Binance stream
    const example_module = b.createModule(.{
        .root_source_file = b.path("examples/binance_parser.zig"),
        .target = target,
        .optimize = optimize,
    });
    example_module.addImport("parser", parser_module);
    example_module.link_libc = true;

    const example_binance = b.addExecutable(.{
        .name = "example-binance",
        .root_module = example_module,
    });

    b.installArtifact(example_binance);

    const run_example = b.addRunArtifact(example_binance);
    const example_step = b.step("example", "Run Binance parser example");
    example_step.dependOn(&run_example.step);

    // Example: Order book demo
    const orderbook_module = b.createModule(.{
        .root_source_file = b.path("examples/orderbook_demo.zig"),
        .target = target,
        .optimize = optimize,
    });
    orderbook_module.addImport("parser", parser_module);
    orderbook_module.link_libc = true;

    const example_orderbook = b.addExecutable(.{
        .name = "example-orderbook",
        .root_module = orderbook_module,
    });

    b.installArtifact(example_orderbook);

    const run_orderbook = b.addRunArtifact(example_orderbook);
    const orderbook_step = b.step("orderbook", "Run order book demo");
    orderbook_step.dependOn(&run_orderbook.step);

    // Tests
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{
        .root_module = test_module,
    });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
