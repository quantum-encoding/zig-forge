const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build step to compile all programs and collect binaries to root zig-out/
    const build_all = b.step("all", "Build all programs in the monorepo");

    // ── AI and Machine Learning ──────────────────────────────────────
    buildProgram(b, "zig_ai", target, optimize, build_all);
    buildProgram(b, "zig_inference", target, optimize, build_all);
    buildProgram(b, "cognitive_telemetry_kit", target, optimize, build_all);

    // ── Networking and Protocols ─────────────────────────────────────
    buildProgram(b, "http_sentinel", target, optimize, build_all);
    buildProgram(b, "http_sentinel_ffi", target, optimize, build_all);
    buildProgram(b, "quantum_curl", target, optimize, build_all);
    buildProgram(b, "zig_reverse_proxy", target, optimize, build_all);
    buildProgram(b, "zig_dns_server", target, optimize, build_all);
    buildProgram(b, "zig_websocket", target, optimize, build_all);
    buildProgram(b, "warp_gate", target, optimize, build_all);
    buildProgram(b, "zero_copy_net", target, optimize, build_all);
    buildProgram(b, "zig_dpdk", target, optimize, build_all);

    // ── Financial and Trading ────────────────────────────────────────
    buildProgram(b, "financial_engine", target, optimize, build_all);
    buildProgram(b, "market_data_parser", target, optimize, build_all);
    buildProgram(b, "timeseries_db", target, optimize, build_all);
    buildProgram(b, "stratum_engine_claude", target, optimize, build_all);
    buildProgram(b, "stratum_engine_grok", target, optimize, build_all);

    // ── Cryptography and Security ────────────────────────────────────
    buildProgram(b, "simd_crypto_ffi", target, optimize, build_all);
    buildProgram(b, "zig-quantum-encryption", target, optimize, build_all);
    buildProgram(b, "zig_jwt", target, optimize, build_all);
    buildProgram(b, "zig_secret_scanner", target, optimize, build_all);
    buildProgram(b, "guardian_shield", target, optimize, build_all);
    buildProgram(b, "zig_jail", target, optimize, build_all);
    buildProgram(b, "zig_port_scanner", target, optimize, build_all);
    buildProgram(b, "electrum_ffi", target, optimize, build_all);
    buildProgram(b, "mempool_sniffer", target, optimize, build_all);
    buildProgram(b, "quantum_seed_vault", target, optimize, build_all);

    // ── Data Formats and Serialization ───────────────────────────────
    buildProgram(b, "zig_json", target, optimize, build_all);
    buildProgram(b, "zig_toml", target, optimize, build_all);
    buildProgram(b, "zig_msgpack", target, optimize, build_all);
    buildProgram(b, "zig_xlsx", target, optimize, build_all);
    buildProgram(b, "zig_docx", target, optimize, build_all);
    buildProgram(b, "zig_base58", target, optimize, build_all);

    // ── PDF and Document Generation ──────────────────────────────────
    buildProgram(b, "zig_pdf_engine", target, optimize, build_all);
    buildProgram(b, "zig_pdf_generator", target, optimize, build_all);
    buildProgram(b, "zig_charts", target, optimize, build_all);

    // ── Infrastructure and Libraries ─────────────────────────────────
    buildProgram(b, "memory_pool", target, optimize, build_all);
    buildProgram(b, "lockfree_queue", target, optimize, build_all);
    buildProgram(b, "async_scheduler", target, optimize, build_all);
    buildProgram(b, "zig_metrics", target, optimize, build_all);
    buildProgram(b, "zig_ratelimit", target, optimize, build_all);
    buildProgram(b, "zig_bloom", target, optimize, build_all);
    buildProgram(b, "zig_uuid", target, optimize, build_all);
    buildProgram(b, "zig_token_service", target, optimize, build_all);
    buildProgram(b, "zig_humanize", target, optimize, build_all);
    buildProgram(b, "zig_cron", target, optimize, build_all);
    buildProgram(b, "zig_watch", target, optimize, build_all);
    buildProgram(b, "distributed_kv", target, optimize, build_all);
    buildProgram(b, "wasm_runtime", target, optimize, build_all);

    // ── Developer Tools ──────────────────────────────────────────────
    buildProgram(b, "zig_lens", target, optimize, build_all);
    buildProgram(b, "zig_silicon", target, optimize, build_all);
    buildProgram(b, "zig2asm", target, optimize, build_all);
    buildProgram(b, "zig-code-query-native", target, optimize, build_all);
    buildProgram(b, "zig-ingest", target, optimize, build_all);
    buildProgram(b, "zdedupe", target, optimize, build_all);
    buildProgram(b, "register_forge", target, optimize, build_all);
    buildProgram(b, "zigit", target, optimize, build_all);

    // ── Hardware and Embedded ────────────────────────────────────────
    buildProgram(b, "zig_hal", target, optimize, build_all);
    buildProgram(b, "zig_tui", target, optimize, build_all);
    buildProgram(b, "audio_forge", target, optimize, build_all);

    // ── System Administration and Monitoring ─────────────────────────
    buildProgram(b, "chronos_engine", target, optimize, build_all);
    buildProgram(b, "duck_agent_scribe", target, optimize, build_all);
    buildProgram(b, "duck_cache_scribe", target, optimize, build_all);
    buildProgram(b, "claude-shepherd", target, optimize, build_all);
    buildProgram(b, "terminal_mux", target, optimize, build_all);

    // ── Compute and Research ─────────────────────────────────────────
    buildProgram(b, "variable_tester", target, optimize, build_all);
    buildProgram(b, "hydra", target, optimize, build_all);

    // ── Zigix OS Integration ─────────────────────────────────────────
    buildProgram(b, "zigix_desktop", target, optimize, build_all);
    buildProgram(b, "zigix_monitor", target, optimize, build_all);

    // Default install step builds everything
    b.getInstallStep().dependOn(build_all);

    // Test all programs
    const test_all = b.step("test", "Run all tests in the monorepo");
    testProgram(b, "zig_ai", test_all);
    testProgram(b, "http_sentinel", test_all);
    testProgram(b, "http_sentinel_ffi", test_all);
    testProgram(b, "quantum_curl", test_all);
    testProgram(b, "zig_reverse_proxy", test_all);
    testProgram(b, "zig_dns_server", test_all);
    testProgram(b, "zig_websocket", test_all);
    testProgram(b, "warp_gate", test_all);
    testProgram(b, "zero_copy_net", test_all);
    testProgram(b, "zig_dpdk", test_all);
    testProgram(b, "guardian_shield", test_all);
    testProgram(b, "chronos_engine", test_all);
    testProgram(b, "zig_jail", test_all);
    testProgram(b, "zig_port_scanner", test_all);
    testProgram(b, "duck_agent_scribe", test_all);
    testProgram(b, "duck_cache_scribe", test_all);
    testProgram(b, "cognitive_telemetry_kit", test_all);
    testProgram(b, "stratum_engine_claude", test_all);
    testProgram(b, "stratum_engine_grok", test_all);
    testProgram(b, "timeseries_db", test_all);
    testProgram(b, "market_data_parser", test_all);
    testProgram(b, "financial_engine", test_all);
    testProgram(b, "async_scheduler", test_all);
    testProgram(b, "zig_xlsx", test_all);
    testProgram(b, "zig_json", test_all);
    testProgram(b, "zig_toml", test_all);
    testProgram(b, "zig_msgpack", test_all);
    testProgram(b, "zig_docx", test_all);
    testProgram(b, "zig_base58", test_all);
    testProgram(b, "zig_cron", test_all);
    testProgram(b, "zig_watch", test_all);
    testProgram(b, "zig_inference", test_all);
    testProgram(b, "simd_crypto_ffi", test_all);
    testProgram(b, "zig-quantum-encryption", test_all);
    testProgram(b, "zig_jwt", test_all);
    testProgram(b, "zig_secret_scanner", test_all);
    testProgram(b, "electrum_ffi", test_all);
    testProgram(b, "mempool_sniffer", test_all);
    testProgram(b, "quantum_seed_vault", test_all);
    testProgram(b, "zig_pdf_engine", test_all);
    testProgram(b, "zig_pdf_generator", test_all);
    testProgram(b, "zig_charts", test_all);
    testProgram(b, "memory_pool", test_all);
    testProgram(b, "lockfree_queue", test_all);
    testProgram(b, "zig_metrics", test_all);
    testProgram(b, "zig_ratelimit", test_all);
    testProgram(b, "zig_bloom", test_all);
    testProgram(b, "zig_uuid", test_all);
    testProgram(b, "zig_token_service", test_all);
    testProgram(b, "zig_humanize", test_all);
    testProgram(b, "distributed_kv", test_all);
    testProgram(b, "wasm_runtime", test_all);
    testProgram(b, "zig_lens", test_all);
    testProgram(b, "zig_silicon", test_all);
    testProgram(b, "zig2asm", test_all);
    testProgram(b, "zig-code-query-native", test_all);
    testProgram(b, "zig-ingest", test_all);
    testProgram(b, "zdedupe", test_all);
    testProgram(b, "register_forge", test_all);
    testProgram(b, "zig_hal", test_all);
    testProgram(b, "zig_tui", test_all);
    testProgram(b, "audio_forge", test_all);
    testProgram(b, "claude-shepherd", test_all);
    testProgram(b, "terminal_mux", test_all);
    testProgram(b, "variable_tester", test_all);
    testProgram(b, "hydra", test_all);
    testProgram(b, "zigix_desktop", test_all);
    testProgram(b, "zigix_monitor", test_all);

    // Clean step
    const clean_step = b.step("clean", "Remove all build artifacts");
    const clean_cmd = b.addSystemCommand(&[_][]const u8{
        "sh",
        "-c",
        "rm -rf zig-out .zig-cache programs/*/zig-out programs/*/.zig-cache",
    });
    clean_step.dependOn(&clean_cmd.step);
}

fn buildProgram(
    b: *std.Build,
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    build_all: *std.Build.Step,
) void {
    _ = target;
    _ = optimize;

    const program_dir = b.fmt("programs/{s}", .{name});

    // Build the program in its directory
    const build_cmd = b.addSystemCommand(&[_][]const u8{
        "zig",
        "build",
        "--prefix",
        "../../zig-out",
    });
    build_cmd.setCwd(.{ .cwd_relative = program_dir });

    // Add to build_all
    build_all.dependOn(&build_cmd.step);

    // Create individual build step
    const build_step = b.step(name, b.fmt("Build {s} program", .{name}));
    build_step.dependOn(&build_cmd.step);
}

fn testProgram(
    b: *std.Build,
    name: []const u8,
    test_all: *std.Build.Step,
) void {
    const program_dir = b.fmt("programs/{s}", .{name});

    const test_cmd = b.addSystemCommand(&[_][]const u8{
        "zig",
        "build",
        "test",
    });
    test_cmd.setCwd(.{ .cwd_relative = program_dir });

    test_all.dependOn(&test_cmd.step);
}
