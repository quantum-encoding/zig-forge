const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // =============================================================================
    // Static Library (for FFI integration with Rust/C/etc.)
    // =============================================================================

    const ffi_module = b.createModule(.{
        .root_source_file = b.path("src/ffi-grok.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "quantum_crypto",
        .root_module = ffi_module,
        .linkage = .static,
    });

    // Link with libc for C compatibility
    lib.root_module.link_libc = true;

    // Strip debug symbols for production (reduces binary size)
    lib.root_module.strip = optimize != .Debug;

    // zig-out/lib/libquantum_crypto.a is the archive other repos link (libs.toml
    // row `quantum_crypto`), stamped beside it by scripts/build-macos-lib.sh and
    // scripts/build-consumed-libs.sh. Only the `lib` step writes that path, and
    // only in a release mode; build-macos-lib.sh runs `zig build lib`. Every
    // other build — `zig build`, any -Doptimize — installs its archive under
    // zig-out/lib/dev/, so a local build never replaces the stamped release
    // archive.
    const lib_step = b.step("lib", "Build the consumed archive zig-out/lib/libquantum_crypto.a (release modes only; use scripts/build-macos-lib.sh)");
    switch (optimize) {
        .ReleaseSmall, .ReleaseFast => lib_step.dependOn(&b.addInstallArtifact(lib, .{}).step),
        .Debug, .ReleaseSafe => lib_step.dependOn(&b.addFail(b.fmt(
            "zig build lib writes zig-out/lib/libquantum_crypto.a, the archive consumers link; " ++
                "a {t} build keeps Zig's panic machinery and is never that archive. " ++
                "Run scripts/build-macos-lib.sh programs/simd_crypto_ffi from the repo root " ++
                "(ReleaseSmall, repacked, stamped), or plain `zig build` for zig-out/lib/dev/libquantum_crypto.a",
            .{optimize},
        )).step),
    }
    b.getInstallStep().dependOn(&b.addInstallArtifact(lib, .{
        .dest_dir = .{ .override = .{ .custom = "lib/dev" } },
    }).step);

    // =============================================================================
    // Android ARM64 Cross-Compilation Target
    // =============================================================================

    const android_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .linux,
        .abi = .android,
    });

    const android_module = b.createModule(.{
        .root_source_file = b.path("src/ffi-grok.zig"),
        .target = android_target,
        .optimize = .ReleaseFast,
    });

    const android_lib = b.addLibrary(.{
        .name = "quantum_crypto",
        .root_module = android_module,
        .linkage = .static,
    });

    android_lib.root_module.link_libc = true;
    android_lib.root_module.strip = true;

    // Position-independent code is REQUIRED on Android: this static lib is
    // linked into Tauri's `-shared` cdylib. Without PIC, the threadlocal FFI
    // error buffers (last_error_msg / last_error_len in ffi-grok.zig) emit TLS
    // local-exec relocations (R_AARCH64_TLSLE_ADD_TPREL_*) that ld.lld rejects
    // with "cannot be used with -shared". Mirrors the `-fPIC` that the
    // canonical programs/build-android-libs.sh already passes.
    android_lib.root_module.pic = true;

    // Install to zig-out/lib/android-arm64/
    const android_install = b.addInstallArtifact(android_lib, .{
        .dest_dir = .{ .override = .{ .custom = "lib/android-arm64" } },
    });

    const android_step = b.step("android", "Build for Android ARM64 (aarch64-linux-android)");
    android_step.dependOn(&android_install.step);

    // =============================================================================
    // Zig Module (for Zig projects) — consumable via `b.dependency(...).module("simd_crypto")`
    // =============================================================================

    const crypto_module = b.addModule("simd_crypto", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // =============================================================================
    // Tests
    // =============================================================================

    // Test the FFI layer
    const ffi_test_module = b.createModule(.{
        .root_source_file = b.path("src/ffi-grok.zig"),
        .target = target,
        .optimize = optimize,
    });

    const ffi_tests = b.addTest(.{
        .root_module = ffi_test_module,
    });
    ffi_tests.root_module.link_libc = true;

    // Test the Zig module (main.zig + bitcoin/*). Reuses the consumable module
    // declared above so `zig build test` exercises exactly what downstreams import.
    const module_tests = b.addTest(.{
        .root_module = crypto_module,
    });

    const test_step = b.step("test", "Run FFI + Zig-module unit tests and the conformance suite (native and scalar CPU)");
    test_step.dependOn(&b.addRunArtifact(ffi_tests).step);
    test_step.dependOn(&b.addRunArtifact(module_tests).step);

    // Conformance suite (src/conformance.zig): published vectors and the Rust differential
    // corpus, through the quantum_* exports. Built twice: for the target CPU as requested, and
    // for that CPU minus the features std.crypto selects SIMD / crypto-extension code on
    // (ARMv8 SHA-2/SHA-3/AES + NEON; x86 SHA-NI/AES-NI/AVX/AVX2/AVX-512), so the hardware and
    // the portable code paths must both reproduce the same expected bytes. Native targets
    // only: the scalar build has to run on this machine.
    const conformance_step = b.step("conformance", "Run the conformance suite (native and scalar CPU builds)");
    const scalar_sub = switch (target.result.cpu.arch) {
        .aarch64 => std.Target.aarch64.featureSet(&.{ .sha2, .sha3, .aes, .neon, .fp_armv8 }),
        .x86_64 => std.Target.x86.featureSet(&.{ .sha, .aes, .vaes, .pclmul, .vpclmulqdq, .avx, .avx2, .avx512f }),
        else => std.Target.Cpu.Feature.Set.empty,
    };
    var scalar_query = target.query;
    scalar_query.cpu_features_sub = scalar_sub;
    for ([_]struct { name: []const u8, target: std.Build.ResolvedTarget, scalar: bool }{
        .{ .name = "native", .target = target, .scalar = false },
        .{ .name = "scalar", .target = b.resolveTargetQuery(scalar_query), .scalar = true },
    }) |variant| {
        const opts = b.addOptions();
        opts.addOption(bool, "scalar_only", variant.scalar);
        const mod = b.createModule(.{
            .root_source_file = b.path("src/conformance.zig"),
            .target = variant.target,
            // Monte Carlo, PBKDF2 at 80 000 rounds and 2 000 signatures: Debug would take minutes.
            .optimize = if (optimize == .Debug) .ReleaseSafe else optimize,
            .link_libc = true,
        });
        mod.addOptions("build_options", opts);
        for ([_][2][]const u8{
            .{ "SHA256ShortMsg", "testdata/nist/SHA256ShortMsg.rsp" },
            .{ "SHA256LongMsg", "testdata/nist/SHA256LongMsg.rsp" },
            .{ "SHA256Monte", "testdata/nist/SHA256Monte.rsp" },
            .{ "SHA512ShortMsg", "testdata/nist/SHA512ShortMsg.rsp" },
            .{ "SHA512LongMsg", "testdata/nist/SHA512LongMsg.rsp" },
            .{ "SHA512Monte", "testdata/nist/SHA512Monte.rsp" },
            .{ "HMAC", "testdata/nist/HMAC.rsp" },
            .{ "rfc4231_hmac", "testdata/rfc/rfc4231_hmac.txt" },
            .{ "rfc7914_pbkdf2_sha256", "testdata/rfc/rfc7914_pbkdf2_sha256.txt" },
            .{ "rfc8439_chacha20", "testdata/rfc/rfc8439_chacha20.txt" },
            .{ "bip39_vectors", "testdata/bip39/vectors.json" },
            .{ "blake3_vectors", "testdata/blake3/test_vectors.json" },
            .{ "ripemd160_vectors", "testdata/ripemd160/vectors.txt" },
            .{ "bip32_vectors", "testdata/bip32/vectors.txt" },
            .{ "bech32_valid", "testdata/bech32/valid_segwit.txt" },
            .{ "tiny_ecdsa", "testdata/secp256k1/tiny-secp256k1-ecdsa.json" },
            .{ "rust_reference", "testdata/differential/rust_reference.txt" },
        }) |imp| mod.addAnonymousImport(imp[0], .{ .root_source_file = b.path(imp[1]) });
        const t = b.addTest(.{ .name = b.fmt("conformance-{s}", .{variant.name}), .root_module = mod });
        const run = b.addRunArtifact(t);
        test_step.dependOn(&run.step);
        conformance_step.dependOn(&run.step);
    }

    // Keep the standalone module-only test step for convenience.
    const module_test_step = b.step("test-module", "Run Zig module tests only");
    module_test_step.dependOn(&b.addRunArtifact(module_tests).step);
}
