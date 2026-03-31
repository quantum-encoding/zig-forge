const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main executable
    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "stratum-engine",
        .root_module = exe_module,
    });

    // Enable AVX2/AVX-512 for SIMD optimization
    // User can override with -Dcpu=native for best performance
    if (optimize == .ReleaseFast or optimize == .ReleaseSafe) {
        exe.root_module.addCMacro("ENABLE_SIMD", "1");
    }

    // Link mbedTLS for TLS support (execution engine)
    exe.root_module.linkSystemLibrary("mbedtls", .{});
    exe.root_module.linkSystemLibrary("mbedx509", .{});
    exe.root_module.linkSystemLibrary("mbedcrypto", .{});
    exe.root_module.link_libc = true;

    b.installArtifact(exe);

    // Dashboard executable (mining + mempool)
    const dash_module = b.createModule(.{
        .root_source_file = b.path("src/main_dashboard.zig"),
        .target = target,
        .optimize = optimize,
    });

    const dash_exe = b.addExecutable(.{
        .name = "stratum-engine-dashboard",
        .root_module = dash_module,
    });

    if (optimize == .ReleaseFast or optimize == .ReleaseSafe) {
        dash_exe.root_module.addCMacro("ENABLE_SIMD", "1");
    }

    // Link libc for DNS resolution (getaddrinfo)
    dash_exe.root_module.link_libc = true;

    b.installArtifact(dash_exe);

    // Run commands
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the Stratum mining engine");
    run_step.dependOn(&run_cmd.step);

    const dash_cmd = b.addRunArtifact(dash_exe);
    dash_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        dash_cmd.addArgs(args);
    }

    const dash_step = b.step("dashboard", "Run the mining + mempool dashboard");
    dash_step.dependOn(&dash_cmd.step);

    // Benchmarks
    const bench_module = b.createModule(.{
        .root_source_file = b.path("benchmarks/sha256_bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_module.addImport("crypto/sha256d.zig", b.createModule(.{
        .root_source_file = b.path("src/crypto/sha256d.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    }));
    bench_module.link_libc = true;

    const bench = b.addExecutable(.{
        .name = "bench-sha256",
        .root_module = bench_module,
    });
    b.installArtifact(bench);

    const bench_cmd = b.addRunArtifact(bench);
    const bench_step = b.step("bench", "Run SHA256 benchmarks");
    bench_step.dependOn(&bench_cmd.step);

    // Mempool test executable
    const test_mempool_module = b.createModule(.{
        .root_source_file = b.path("src/test_mempool.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_mempool_exe = b.addExecutable(.{
        .name = "test-mempool",
        .root_module = test_mempool_module,
    });
    test_mempool_exe.root_module.link_libc = true;

    b.installArtifact(test_mempool_exe);

    const test_mempool_cmd = b.addRunArtifact(test_mempool_exe);
    test_mempool_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        test_mempool_cmd.addArgs(args);
    }

    const test_mempool_step = b.step("test-mempool", "Test Bitcoin P2P mempool connection");
    test_mempool_step.dependOn(&test_mempool_cmd.step);

    // Execution engine test executable
    const test_exec_module = b.createModule(.{
        .root_source_file = b.path("src/test_execution_engine.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_exec_exe = b.addExecutable(.{
        .name = "test-execution-engine",
        .root_module = test_exec_module,
    });

    // Link mbedTLS for TLS support
    test_exec_exe.root_module.linkSystemLibrary("mbedtls", .{});
    test_exec_exe.root_module.linkSystemLibrary("mbedx509", .{});
    test_exec_exe.root_module.linkSystemLibrary("mbedcrypto", .{});
    test_exec_exe.root_module.link_libc = true;

    b.installArtifact(test_exec_exe);

    const test_exec_cmd = b.addRunArtifact(test_exec_exe);
    test_exec_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        test_exec_cmd.addArgs(args);
    }

    const test_exec_step = b.step("test-exec", "Test high-frequency execution engine");
    test_exec_step.dependOn(&test_exec_cmd.step);

    // TLS connection test executable
    const test_tls_module = b.createModule(.{
        .root_source_file = b.path("src/test_tls_connection.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_tls_exe = b.addExecutable(.{
        .name = "test-tls",
        .root_module = test_tls_module,
    });

    // Link mbedTLS for TLS support
    test_tls_exe.root_module.linkSystemLibrary("mbedtls", .{});
    test_tls_exe.root_module.linkSystemLibrary("mbedx509", .{});
    test_tls_exe.root_module.linkSystemLibrary("mbedcrypto", .{});
    test_tls_exe.root_module.link_libc = true;

    b.installArtifact(test_tls_exe);

    const test_tls_cmd = b.addRunArtifact(test_tls_exe);
    test_tls_cmd.step.dependOn(b.getInstallStep());

    const test_tls_step = b.step("test-tls", "Test TLS connection to exchange");
    test_tls_step.dependOn(&test_tls_cmd.step);

    // Exchange client WebSocket test executable
    const test_exchange_module = b.createModule(.{
        .root_source_file = b.path("src/test_exchange_client.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_exchange_exe = b.addExecutable(.{
        .name = "test-exchange-client",
        .root_module = test_exchange_module,
    });

    // Link mbedTLS for TLS support
    test_exchange_exe.root_module.linkSystemLibrary("mbedtls", .{});
    test_exchange_exe.root_module.linkSystemLibrary("mbedx509", .{});
    test_exchange_exe.root_module.linkSystemLibrary("mbedcrypto", .{});
    test_exchange_exe.root_module.link_libc = true;

    b.installArtifact(test_exchange_exe);

    const test_exchange_cmd = b.addRunArtifact(test_exchange_exe);
    test_exchange_cmd.step.dependOn(b.getInstallStep());

    const test_exchange_step = b.step("test-exchange", "Test WebSocket-over-TLS exchange connection");
    test_exchange_step.dependOn(&test_exchange_cmd.step);

    // ASIC Proxy executable (SentientTrader backend)
    const proxy_module = b.createModule(.{
        .root_source_file = b.path("src/main_proxy.zig"),
        .target = target,
        .optimize = optimize,
    });

    const proxy_exe = b.addExecutable(.{
        .name = "stratum-proxy",
        .root_module = proxy_module,
    });

    if (optimize == .ReleaseFast or optimize == .ReleaseSafe) {
        proxy_exe.root_module.addCMacro("ENABLE_SIMD", "1");
    }

    // Link SQLite3 for persistence
    proxy_exe.root_module.linkSystemLibrary("sqlite3", .{});
    // Link mbedTLS for TLS pool connections
    proxy_exe.root_module.linkSystemLibrary("mbedtls", .{});
    proxy_exe.root_module.linkSystemLibrary("mbedx509", .{});
    proxy_exe.root_module.linkSystemLibrary("mbedcrypto", .{});
    proxy_exe.root_module.link_libc = true;

    b.installArtifact(proxy_exe);

    const proxy_cmd = b.addRunArtifact(proxy_exe);
    proxy_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        proxy_cmd.addArgs(args);
    }

    const proxy_step = b.step("proxy", "Run the ASIC Stratum proxy server");
    proxy_step.dependOn(&proxy_cmd.step);

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
