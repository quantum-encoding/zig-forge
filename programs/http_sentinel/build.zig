const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Core HTTP Sentinel library module
    const http_sentinel_module = b.addModule("http-sentinel", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
    });

    // Tests
    const lib_unit_tests = b.addTest(.{
        .root_module = http_sentinel_module,
    });

    // Manifest tests — engine/manifest.zig isn't pulled into lib.zig's
    // public surface (the engine module is consumed by quantum_curl as
    // a binary, not re-exported as a library), so its hostile-input
    // tests need their own test target to participate in `zig build test`.
    const manifest_test_module = b.createModule(.{
        .root_source_file = b.path("src/engine/manifest.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
    });
    const manifest_unit_tests = b.addTest(.{
        .root_module = manifest_test_module,
    });

    // Externally-anchored SSRF regression tests (src/security_test.zig).
    // Rooted directly on the http_client source so it can call the internal
    // `isPrivateRedirect` guard that engine/core.zig's block_private_urls
    // flag delegates to.
    const security_test_module = b.createModule(.{
        .root_source_file = b.path("src/security_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
    });
    const security_unit_tests = b.addTest(.{
        .root_module = security_test_module,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    const run_manifest_unit_tests = b.addRunArtifact(manifest_unit_tests);
    const run_security_unit_tests = b.addRunArtifact(security_unit_tests);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_manifest_unit_tests.step);
    test_step.dependOn(&run_security_unit_tests.step);

    // Helper function to create executable with http-sentinel import
    const addExample = struct {
        fn call(
            builder: *std.Build,
            name: []const u8,
            src: []const u8,
            tgt: std.Build.ResolvedTarget,
            opt: std.builtin.OptimizeMode,
            module: *std.Build.Module,
        ) *std.Build.Step.Compile {
            const exe_module = builder.createModule(.{
                .root_source_file = builder.path(src),
                .target = tgt,
                .optimize = opt,
                .link_libc = false,
            });
            exe_module.addImport("http-sentinel", module);

            const exe = builder.addExecutable(.{
                .name = name,
                .root_module = exe_module,
            });
            builder.installArtifact(exe);
            return exe;
        }
    }.call;

    // CLI Tool
    const cli = addExample(b, "zig-ai", "src/main.zig", target, optimize, http_sentinel_module);

    // Install CLI to system (built-in 'install' step will handle this automatically)
    b.installArtifact(cli);

    // Run CLI
    const run_cli = b.addRunArtifact(cli);
    if (b.args) |args| {
        run_cli.addArgs(args);
    }
    const cli_step = b.step("cli", "Run AI Providers CLI");
    cli_step.dependOn(&run_cli.step);

    // Security attack test suite
    const attack = addExample(b, "attack-tests", "tests/attack.zig", target, optimize, http_sentinel_module);
    b.installArtifact(attack);

    const run_attack = b.addRunArtifact(attack);
    if (b.args) |args| {
        run_attack.addArgs(args);
    }
    const attack_step = b.step("attack", "Run security attack test suite");
    attack_step.dependOn(&run_attack.step);

    // Wire the security attack suite into `zig build test` so the SSRF/CRLF/
    // redirect-limit/path-traversal regressions run in CI, not just as a
    // standalone `zig build attack` binary that nobody invokes.
    test_step.dependOn(&run_attack.step);

    // Benchmark suite
    const bench = addExample(b, "http-bench", "tests/bench.zig", target, optimize, http_sentinel_module);
    b.installArtifact(bench);

    const run_bench = b.addRunArtifact(bench);
    if (b.args) |args| {
        run_bench.addArgs(args);
    }
    const bench_step = b.step("bench", "Run HTTP benchmark suite");
    bench_step.dependOn(&run_bench.step);

    // Quantum Curl - Universal HTTP Engine
    const quantum_curl = addExample(b, "quantum-curl", "src/quantum_curl.zig", target, optimize, http_sentinel_module);
    b.installArtifact(quantum_curl);

    const run_quantum = b.addRunArtifact(quantum_curl);
    if (b.args) |args| {
        run_quantum.addArgs(args);
    }
    const quantum_step = b.step("quantum", "Run Quantum Curl HTTP Engine");
    quantum_step.dependOn(&run_quantum.step);

    // ------------------------------------------------------------------
    // Recon target — Zigix-style build to map the std.os.linux blast radius.
    //
    //   os_tag = .linux, abi = .none, link_libc = false
    //
    // Cross-compile only — the binary is not meant to run on the host.
    // We just want the compiler/linker to surface every std.os.linux.*
    // symbol that std.http.Client + std.crypto.tls + std.Io.Threaded pull
    // in, so we know what the freestanding Zigix Io vtable must cover.
    // ------------------------------------------------------------------
    const recon_arch = b.option(
        std.Target.Cpu.Arch,
        "recon-arch",
        "Recon target architecture (x86_64 or aarch64)",
    ) orelse .aarch64;

    const recon_target = b.resolveTargetQuery(.{
        .cpu_arch = recon_arch,
        .os_tag = .linux,
        .abi = .none,
    });

    const recon_optimize = b.option(
        std.builtin.OptimizeMode,
        "recon-optimize",
        "Recon optimize mode (default ReleaseSmall for max dead-code-elim)",
    ) orelse .ReleaseSmall;

    const recon_module = b.addModule("http-sentinel-recon", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = recon_target,
        .optimize = recon_optimize,
        .link_libc = false,
    });

    const recon_exe_module = b.createModule(.{
        .root_source_file = b.path("tests/recon.zig"),
        .target = recon_target,
        .optimize = recon_optimize,
        .link_libc = false,
    });
    recon_exe_module.addImport("http-sentinel", recon_module);

    const recon_exe = b.addExecutable(.{
        .name = "http-sentinel-recon",
        .root_module = recon_exe_module,
    });
    b.installArtifact(recon_exe);

    const recon_step = b.step("recon", "Build recon target (.linux/.none, no libc) — maps std.os.linux surface");
    recon_step.dependOn(&recon_exe.step);

    // ------------------------------------------------------------------
    // Zigix target — a runnable userspace ELF for the Zigix OS.
    //
    //   os_tag = .linux, abi = .none, link_libc = false
    //
    // Zigix speaks the Linux syscall ABI (the `syscall` instruction that
    // std.os.linux emits), so a stock std.http.Client runs on it with no
    // custom std.Io vtable. This target builds `src/zigix_demo.zig` — the
    // minimal single-GET bring-up program — as an installable binary to
    // copy onto a Zigix ext image. See ZIGIX_INTEGRATION.md for the kernel
    // gaps (RTC, CSPRNG, poll readiness) that gate HTTPS.
    // ------------------------------------------------------------------
    const zigix_arch = b.option(
        std.Target.Cpu.Arch,
        "zigix-arch",
        "Zigix target architecture (x86_64 or aarch64)",
    ) orelse .x86_64;

    const zigix_optimize = b.option(
        std.builtin.OptimizeMode,
        "zigix-optimize",
        "Zigix optimize mode (default ReleaseSmall)",
    ) orelse .ReleaseSmall;

    const zigix_url = b.option(
        []const u8,
        "zigix-url",
        "URL the Zigix demo fetches (default plaintext http:// — milestone 1)",
    ) orelse "http://example.com/";

    // Default cert-validation epoch: 2025-01-01T00:00:00Z in nanoseconds.
    // Used only on the https:// path, to stand in for Zigix's not-yet-real
    // wall clock. Override with -Dzigix-cert-epoch-ns once an RTC lands.
    const zigix_cert_epoch_ns = b.option(
        i64,
        "zigix-cert-epoch-ns",
        "TLS cert-validation timestamp in ns since Unix epoch (https:// only)",
    ) orelse 1_735_689_600_000_000_000;

    const zigix_opts = b.addOptions();
    zigix_opts.addOption([]const u8, "zigix_url", zigix_url);
    zigix_opts.addOption(i96, "zigix_cert_epoch_ns", zigix_cert_epoch_ns);

    const zigix_target = b.resolveTargetQuery(.{
        .cpu_arch = zigix_arch,
        .os_tag = .linux,
        .abi = .none,
    });

    const zigix_lib_module = b.addModule("http-sentinel-zigix", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = zigix_target,
        .optimize = zigix_optimize,
        .link_libc = false,
    });

    const zigix_exe_module = b.createModule(.{
        .root_source_file = b.path("src/zigix_demo.zig"),
        .target = zigix_target,
        .optimize = zigix_optimize,
        .link_libc = false,
    });
    zigix_exe_module.addImport("http-sentinel", zigix_lib_module);
    zigix_exe_module.addOptions("build_options", zigix_opts);

    const zigix_exe = b.addExecutable(.{
        .name = "zigix-sentinel-demo",
        .root_module = zigix_exe_module,
    });
    const zigix_step = b.step("zigix", "Build the Zigix userspace HTTP demo (.linux/.none, no libc)");
    zigix_step.dependOn(&b.addInstallArtifact(zigix_exe, .{}).step);
}
