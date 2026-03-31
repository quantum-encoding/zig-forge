const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Import lockfree_queue from sibling project
    const lockfree_queue_path = b.path("../lockfree_queue/src/main.zig");

    const lockfree_module = b.addModule("lockfree_queue", .{
        .root_source_file = lockfree_queue_path,
        .target = target,
        .optimize = optimize,
    });

    // Protocol module (shared between Queen and Worker)
    const protocol_module = b.addModule("protocol", .{
        .root_source_file = b.path("src/protocol.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Test Interface module (shared types for dlopen loading)
    const test_interface_module = b.addModule("test_interface", .{
        .root_source_file = b.path("src/test_interface.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Variable tester module (for imports)
    const vt_module = b.addModule("variable_tester", .{
        .root_source_file = b.path("src/variable_tester.zig"),
        .target = target,
        .optimize = optimize,
    });
    vt_module.addImport("lockfree_queue", lockfree_module);

    // Test functions module
    const tf_module = b.addModule("test_functions", .{
        .root_source_file = b.path("src/test_functions.zig"),
        .target = target,
        .optimize = optimize,
    });
    tf_module.addImport("variable_tester", vt_module);

    // Queen module
    const queen_module = b.addModule("queen", .{
        .root_source_file = b.path("src/queen.zig"),
        .target = target,
        .optimize = optimize,
    });
    queen_module.addImport("protocol", protocol_module);
    queen_module.addImport("variable_tester", vt_module);

    // Worker module
    const worker_module = b.addModule("worker", .{
        .root_source_file = b.path("src/worker.zig"),
        .target = target,
        .optimize = optimize,
    });
    worker_module.addImport("protocol", protocol_module);
    worker_module.addImport("variable_tester", vt_module);
    worker_module.addImport("test_interface", test_interface_module);

    // ==================== Main executable ====================
    const main_module = b.addModule("main", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    main_module.addImport("lockfree_queue", lockfree_module);
    main_module.addImport("variable_tester", vt_module);
    main_module.addImport("test_functions", tf_module);

    const exe = b.addExecutable(.{
        .name = "variable-tester",
        .root_module = main_module,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the variable tester");
    run_step.dependOn(&run_cmd.step);

    // ==================== Queen executable ====================
    const queen_main_module = b.addModule("queen_main", .{
        .root_source_file = b.path("src/queen_main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    queen_main_module.addImport("queen", queen_module);
    queen_main_module.addImport("protocol", protocol_module);

    const queen_exe = b.addExecutable(.{
        .name = "queen",
        .root_module = queen_main_module,
    });
    b.installArtifact(queen_exe);

    const queen_cmd = b.addRunArtifact(queen_exe);
    queen_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        queen_cmd.addArgs(args);
    }

    const queen_step = b.step("queen", "Run the Queen coordinator");
    queen_step.dependOn(&queen_cmd.step);

    // ==================== Worker executable ====================
    const worker_main_module = b.addModule("worker_main", .{
        .root_source_file = b.path("src/worker_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    worker_main_module.addImport("worker", worker_module);
    worker_main_module.addImport("protocol", protocol_module);
    worker_main_module.addImport("variable_tester", vt_module);
    worker_main_module.addImport("test_interface", test_interface_module);

    const worker_exe = b.addExecutable(.{
        .name = "worker",
        .root_module = worker_main_module,
    });
    worker_exe.root_module.link_libc = true; // Required for dlopen/dlsym
    b.installArtifact(worker_exe);

    const worker_cmd = b.addRunArtifact(worker_exe);
    worker_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        worker_cmd.addArgs(args);
    }

    const worker_step = b.step("worker", "Run a Worker drone");
    worker_step.dependOn(&worker_cmd.step);

    // ==================== Benchmark executable ====================
    const bench_module = b.addModule("bench", .{
        .root_source_file = b.path("benchmarks/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    bench_module.addImport("lockfree_queue", lockfree_module);
    bench_module.addImport("variable_tester", vt_module);
    bench_module.addImport("test_functions", tf_module);

    const bench = b.addExecutable(.{
        .name = "variable-tester-bench",
        .root_module = bench_module,
    });
    b.installArtifact(bench);

    const bench_cmd = b.addRunArtifact(bench);
    bench_cmd.step.dependOn(b.getInstallStep());

    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&bench_cmd.step);

    // ==================== Saturation Benchmark executable ====================
    const sat_module = b.addModule("saturation_bench", .{
        .root_source_file = b.path("src/saturation_bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });

    const sat_exe = b.addExecutable(.{
        .name = "saturation-bench",
        .root_module = sat_module,
    });
    b.installArtifact(sat_exe);

    const sat_cmd = b.addRunArtifact(sat_exe);
    sat_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        sat_cmd.addArgs(args);
    }

    const sat_step = b.step("saturation", "Run saturation benchmark");
    sat_step.dependOn(&sat_cmd.step);

    // ==================== Crypto Benchmark executable ====================
    const crypto_module = b.addModule("crypto_bench", .{
        .root_source_file = b.path("src/crypto_bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });

    const crypto_exe = b.addExecutable(.{
        .name = "crypto-bench",
        .root_module = crypto_module,
    });
    b.installArtifact(crypto_exe);

    const crypto_cmd = b.addRunArtifact(crypto_exe);
    crypto_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        crypto_cmd.addArgs(args);
    }

    const crypto_step = b.step("crypto", "Run crypto brute-force benchmark");
    crypto_step.dependOn(&crypto_cmd.step);

    // ==================== The Forge - Main Variable Tester ====================
    const forge_module = b.addModule("forge", .{
        .root_source_file = b.path("src/forge.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });

    const forge_exe = b.addExecutable(.{
        .name = "forge",
        .root_module = forge_module,
    });
    b.installArtifact(forge_exe);

    const forge_cmd = b.addRunArtifact(forge_exe);
    forge_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        forge_cmd.addArgs(args);
    }

    const forge_step = b.step("forge", "Run The Forge variable tester");
    forge_step.dependOn(&forge_cmd.step);

    // ==================== Compression Benchmark - Real I/O Testing ====================
    const compress_bench_module = b.addModule("compression_bench", .{
        .root_source_file = b.path("src/compression_bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });

    const compress_bench_exe = b.addExecutable(.{
        .name = "compression-bench",
        .root_module = compress_bench_module,
    });
    b.installArtifact(compress_bench_exe);

    const compress_bench_cmd = b.addRunArtifact(compress_bench_exe);
    compress_bench_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        compress_bench_cmd.addArgs(args);
    }

    const compress_bench_step = b.step("compress-bench", "Run compression formula benchmark with real I/O");
    compress_bench_step.dependOn(&compress_bench_cmd.step);

    // ==================== Test Function Shared Libraries ====================
    // These are dynamically loadable test functions for the distributed swarm

    // Compression Test Library (.so)
    const libtest_compression_module = b.addModule("libtest_compression", .{
        .root_source_file = b.path("src/libtest_compression.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });

    const libtest_compression = b.addLibrary(.{
        .name = "test_compression",
        .root_module = libtest_compression_module,
        .linkage = .dynamic,
    });
    libtest_compression.root_module.link_libc = true; // Required for export symbols
    b.installArtifact(libtest_compression);

    const libtest_step = b.step("libtest", "Build test function shared libraries");
    libtest_step.dependOn(&libtest_compression.step);

    // Convenience step to build all swarm components
    const swarm_step = b.step("swarm", "Build all swarm components (queen, worker, test libs)");
    swarm_step.dependOn(&queen_exe.step);
    swarm_step.dependOn(&worker_exe.step);
    swarm_step.dependOn(&libtest_compression.step);
}
