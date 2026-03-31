const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ========================================================================
    // Cross-Platform Target Definitions
    // ========================================================================

    const CrossTarget = struct {
        name: []const u8,
        query: std.Target.Query,
    };

    const cross_targets = [_]CrossTarget{
        // Desktop platforms for Tauri
        .{ .name = "macos-arm64", .query = .{ .cpu_arch = .aarch64, .os_tag = .macos } },
        .{ .name = "macos-x86_64", .query = .{ .cpu_arch = .x86_64, .os_tag = .macos } },
        .{ .name = "windows-x86_64", .query = .{ .cpu_arch = .x86_64, .os_tag = .windows } },
        .{ .name = "linux-x86_64", .query = .{ .cpu_arch = .x86_64, .os_tag = .linux } },
        // Mobile platforms (future)
        .{ .name = "ios-arm64", .query = .{ .cpu_arch = .aarch64, .os_tag = .ios } },
        .{ .name = "android-arm64", .query = .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .android } },
        .{ .name = "android-arm32", .query = .{ .cpu_arch = .arm, .os_tag = .linux, .abi = .android } },
    };

    // ========================================================================
    // Quantum Vault FFI Library (Unified API)
    // ========================================================================

    // FFI static library for native target
    const ffi_lib_mod = b.createModule(.{
        .root_source_file = b.path("src/quantum_vault_ffi.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Link bcrypt on Windows for BCryptGenRandom
    if (target.result.os.tag == .windows) {
        ffi_lib_mod.linkSystemLibrary("bcrypt", .{});
    }

    const ffi_static_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "quantum_vault",
        .root_module = ffi_lib_mod,
    });
    b.installArtifact(ffi_static_lib);

    // FFI shared library for dynamic linking
    const ffi_shared_mod = b.createModule(.{
        .root_source_file = b.path("src/quantum_vault_ffi.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Link bcrypt on Windows for BCryptGenRandom
    if (target.result.os.tag == .windows) {
        ffi_shared_mod.linkSystemLibrary("bcrypt", .{});
    }

    const ffi_shared_lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "quantum_vault_shared",
        .root_module = ffi_shared_mod,
    });
    b.installArtifact(ffi_shared_lib);

    // ========================================================================
    // Legacy ML-KEM Library (for backward compatibility)
    // ========================================================================

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/ml_kem_api.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "quantum-vault-pqc",
        .root_module = lib_mod,
    });
    b.installArtifact(lib);

    // ========================================================================
    // Cross-Compilation Targets
    // ========================================================================

    // Cross-compilation step - now supports all platforms via src/rng.zig
    const cross_step = b.step("cross", "Build for all cross-compilation targets");

    // Build for all defined cross-compilation targets
    inline for (cross_targets) |ct| {
        const cross_target = b.resolveTargetQuery(ct.query);

        // Use ReleaseFast for iOS to avoid dyld debug symbols
        // iOS doesn't support __dyld_get_image_header_containing_address
        const opt_mode: std.builtin.OptimizeMode = if (ct.query.os_tag == .ios)
            .ReleaseFast
        else
            .ReleaseSafe;

        const cross_mod = b.createModule(.{
            .root_source_file = b.path("src/quantum_vault_ffi.zig"),
            .target = cross_target,
            .optimize = opt_mode,
            .link_libc = true,
            // Disable stack traces for iOS (avoids dyld symbols)
            .strip = if (ct.query.os_tag == .ios) true else false,
        });

        // Link bcrypt on Windows for BCryptGenRandom
        if (ct.query.os_tag == .windows) {
            cross_mod.linkSystemLibrary("bcrypt", .{});
        }

        const cross_lib = b.addLibrary(.{
            .linkage = .static,
            .name = "quantum_vault_" ++ ct.name,
            .root_module = cross_mod,
        });

        b.installArtifact(cross_lib);
        cross_step.dependOn(&cross_lib.step);
    }

    // ========================================================================
    // Secrets CLI — Encrypted secret manager
    // ========================================================================

    const secrets_mod = b.createModule(.{
        .root_source_file = b.path("tools/secrets.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const secrets_exe = b.addExecutable(.{
        .name = "secrets",
        .root_module = secrets_mod,
    });
    b.installArtifact(secrets_exe);

    const run_secrets = b.addRunArtifact(secrets_exe);
    if (b.args) |a| run_secrets.addArgs(a);
    const secrets_step = b.step("secrets", "Build and run secrets CLI");
    secrets_step.dependOn(&run_secrets.step);

    // Cross-compile secrets for distribution
    const secrets_cross_step = b.step("secrets-cross", "Cross-compile secrets CLI");
    inline for ([_]CrossTarget{
        .{ .name = "macos-arm64", .query = .{ .cpu_arch = .aarch64, .os_tag = .macos } },
        .{ .name = "macos-x86_64", .query = .{ .cpu_arch = .x86_64, .os_tag = .macos } },
        .{ .name = "linux-x86_64", .query = .{ .cpu_arch = .x86_64, .os_tag = .linux } },
        .{ .name = "linux-arm64", .query = .{ .cpu_arch = .aarch64, .os_tag = .linux } },
    }) |ct| {
        const s_mod = b.createModule(.{
            .root_source_file = b.path("tools/secrets.zig"),
            .target = b.resolveTargetQuery(ct.query),
            .optimize = .ReleaseSafe,
            .link_libc = true,
        });
        const s_exe = b.addExecutable(.{
            .name = "secrets-" ++ ct.name,
            .root_module = s_mod,
        });
        b.installArtifact(s_exe);
        secrets_cross_step.dependOn(&s_exe.step);
    }

    // ========================================================================
    // Header Generation Tool
    // ========================================================================

    const gen_header_step = b.step("gen-header", "Generate C header file");

    // Build a small tool that extracts and writes the header
    const gen_header_mod = b.createModule(.{
        .root_source_file = b.path("tools/gen_header.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "quantum_vault_ffi", .module = b.createModule(.{
                .root_source_file = b.path("src/quantum_vault_ffi.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }) },
        },
    });

    const gen_header_exe = b.addExecutable(.{
        .name = "gen_header",
        .root_module = gen_header_mod,
    });

    const run_gen_header = b.addRunArtifact(gen_header_exe);
    gen_header_step.dependOn(&run_gen_header.step);

    // ========================================================================
    // Test Modules
    // ========================================================================

    // FFI tests
    const ffi_test_mod = b.createModule(.{
        .root_source_file = b.path("src/quantum_vault_ffi.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const ffi_tests = b.addTest(.{
        .root_module = ffi_test_mod,
    });
    const run_ffi_tests = b.addRunArtifact(ffi_tests);

    // Core NTT operations
    const ntt_test_mod = b.createModule(.{
        .root_source_file = b.path("src/ml_kem.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const ntt_tests = b.addTest(.{
        .root_module = ntt_test_mod,
    });
    const run_ntt_tests = b.addRunArtifact(ntt_tests);

    // High-level API
    const api_test_mod = b.createModule(.{
        .root_source_file = b.path("src/ml_kem_api.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const api_tests = b.addTest(.{
        .root_module = api_test_mod,
    });
    const run_api_tests = b.addRunArtifact(api_tests);

    // Hybrid ML-KEM + X25519
    const hybrid_test_mod = b.createModule(.{
        .root_source_file = b.path("src/hybrid.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const hybrid_tests = b.addTest(.{
        .root_module = hybrid_test_mod,
    });
    const run_hybrid_tests = b.addRunArtifact(hybrid_tests);

    // NIST ACVP test vectors
    const nist_test_mod = b.createModule(.{
        .root_source_file = b.path("src/nist_vectors.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const nist_tests = b.addTest(.{
        .root_module = nist_test_mod,
    });
    const run_nist_tests = b.addRunArtifact(nist_tests);

    // ML-DSA-65 signatures
    const dsa_test_mod = b.createModule(.{
        .root_source_file = b.path("src/ml_dsa.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const dsa_tests = b.addTest(.{
        .root_module = dsa_test_mod,
    });
    const run_dsa_tests = b.addRunArtifact(dsa_tests);

    // ML-DSA-65 v2 (complete FIPS 204)
    const dsa_v2_test_mod = b.createModule(.{
        .root_source_file = b.path("src/ml_dsa_v2.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const dsa_v2_tests = b.addTest(.{
        .root_module = dsa_v2_test_mod,
    });
    const run_dsa_v2_tests = b.addRunArtifact(dsa_v2_tests);

    // Test step
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_ffi_tests.step);
    test_step.dependOn(&run_ntt_tests.step);
    test_step.dependOn(&run_api_tests.step);
    test_step.dependOn(&run_hybrid_tests.step);
    test_step.dependOn(&run_nist_tests.step);
    test_step.dependOn(&run_dsa_tests.step);
    test_step.dependOn(&run_dsa_v2_tests.step);

    // ========================================================================
    // Benchmarks
    // ========================================================================

    const bench_mod = b.createModule(.{
        .root_source_file = b.path("bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });

    const bench = b.addExecutable(.{
        .name = "bench",
        .root_module = bench_mod,
    });
    b.installArtifact(bench);

    const run_bench = b.addRunArtifact(bench);
    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&run_bench.step);

    // ========================================================================
    // WASM Build (for Cloudflare Workers / browser)
    // ========================================================================

    const wasm_step = b.step("wasm", "Build WASM module for Cloudflare Workers");

    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    const wasm_mod = b.createModule(.{
        .root_source_file = b.path("src/quantum_vault_ffi.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });

    const wasm_exe = b.addExecutable(.{
        .name = "quantum_vault",
        .root_module = wasm_mod,
    });
    // No entry point — this is a library of exported functions
    wasm_exe.entry = .disabled;
    // Export all FFI symbols to WASM
    wasm_exe.rdynamic = true;

    const wasm_install = b.addInstallArtifact(wasm_exe, .{});
    wasm_step.dependOn(&wasm_install.step);

    // ========================================================================
    // Package for Distribution
    // ========================================================================

    const package_step = b.step("package", "Create distribution package");
    package_step.dependOn(cross_step);
    package_step.dependOn(gen_header_step);
}
