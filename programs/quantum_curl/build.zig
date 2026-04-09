const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ============================================================
    // CORE DEPENDENCY: http_sentinel
    // quantum_curl is architecturally dependent on http_sentinel
    // for its HttpClient, the apex predator HTTP implementation.
    // ============================================================
    const http_sentinel_dep = b.dependency("http_sentinel", .{
        .target = target,
        .optimize = optimize,
    });
    const http_sentinel_module = http_sentinel_dep.module("http-sentinel");

    // GCP Auth — pure Zig OAuth2 / SA / ADC / metadata token provider.
    // Used by the --gcp-auth flag for long-running batches that outlast the
    // default 1h bearer token lifetime (e.g. hours of embedding inference).
    const gcp_auth_dep = b.dependency("gcp_auth", .{
        .target = target,
        .optimize = optimize,
    });
    const gcp_auth_module = gcp_auth_dep.module("gcp-auth");

    // ============================================================
    // QUANTUM CURL LIBRARY MODULE
    // The Command Protocol Engine - exports core routing capabilities
    // ============================================================
    const quantum_curl_module = b.addModule("quantum-curl", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    quantum_curl_module.addImport("http-sentinel", http_sentinel_module);
    quantum_curl_module.addImport("gcp-auth", gcp_auth_module);

    // ============================================================
    // QUANTUM CURL EXECUTABLE
    // The High-Velocity Command-Driven Router
    // ============================================================
    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_module.addImport("quantum-curl", quantum_curl_module);
    exe_module.addImport("http-sentinel", http_sentinel_module);
    exe_module.addImport("gcp-auth", gcp_auth_module);

    const exe = b.addExecutable(.{
        .name = "quantum-curl",
        .root_module = exe_module,
    });
    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run quantum-curl HTTP engine");
    run_step.dependOn(&run_cmd.step);

    // ============================================================
    // TESTS
    // ============================================================
    const lib_unit_tests = b.addTest(.{
        .root_module = quantum_curl_module,
    });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    const test_step = b.step("test", "Run quantum-curl tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    // ============================================================
    // BENCHMARKS
    // Performance testing infrastructure for CI/CD regression detection
    // ============================================================

    // Echo Server - minimal HTTP server for controlled benchmarking
    const echo_server_module = b.createModule(.{
        .root_source_file = b.path("bench/echo_server.zig"),
        .target = target,
        .optimize = .ReleaseFast, // Always optimize benchmarks
        .link_libc = true,
    });
    const echo_server = b.addExecutable(.{
        .name = "bench-echo-server",
        .root_module = echo_server_module,
    });
    b.installArtifact(echo_server);

    const run_echo = b.addRunArtifact(echo_server);
    if (b.args) |args| {
        run_echo.addArgs(args);
    }
    const echo_step = b.step("echo-server", "Run benchmark echo server");
    echo_step.dependOn(&run_echo.step);

    // Benchmark Runner - statistical analysis and regression detection
    const bench_runner_module = b.createModule(.{
        .root_source_file = b.path("bench/bench_runner.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    const bench_runner = b.addExecutable(.{
        .name = "bench-quantum-curl",
        .root_module = bench_runner_module,
    });
    b.installArtifact(bench_runner);

    const run_bench = b.addRunArtifact(bench_runner);
    if (b.args) |args| {
        run_bench.addArgs(args);
    }
    const bench_step = b.step("bench", "Run performance benchmarks");
    bench_step.dependOn(&run_bench.step);

    // Sustained Benchmark - long-running performance test
    const sustained_bench_module = b.createModule(.{
        .root_source_file = b.path("bench/sustained_bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    const sustained_bench = b.addExecutable(.{
        .name = "sustained-bench",
        .root_module = sustained_bench_module,
    });
    b.installArtifact(sustained_bench);

    const run_sustained = b.addRunArtifact(sustained_bench);
    if (b.args) |args| {
        run_sustained.addArgs(args);
    }
    const sustained_step = b.step("sustained", "Run sustained performance benchmark");
    sustained_step.dependOn(&run_sustained.step);
}
