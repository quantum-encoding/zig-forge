const std = @import("std");

pub fn build(b: *std.Build) void {
    const wasm_step = b.step("wasm", "Build WebAssembly module for Cloudflare Workers");

    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    const wasm_module = b.createModule(.{
        .root_source_file = b.path("src/wasm_ffi.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });

    const wasm_lib = b.addExecutable(.{
        .name = "voidnote_keys",
        .root_module = wasm_module,
    });

    // Required for Cloudflare Workers WASM interop
    wasm_lib.export_memory = true;
    wasm_lib.entry = .disabled;
    wasm_lib.rdynamic = true;

    const wasm_install = b.addInstallArtifact(wasm_lib, .{
        .dest_dir = .{ .override = .{ .custom = "wasm" } },
    });
    wasm_step.dependOn(&wasm_install.step);

    // ==========================================================================
    // Tests — externally-anchored crypto vectors (native target)
    //
    // src/tier1_anchors.zig pins the module's SHA-256 / HMAC-SHA256 output to
    // NIST CAVP + RFC 4231 vectors. It imports src/wasm_ffi.zig, which compiles
    // for the host: the js_get_random_bytes import is gated behind a comptime
    // wasm32 check so native builds link cleanly (std.crypto.random fallback).
    //
    // Per /CLAUDE.md rule #1, weakening tier1_anchors.zig requires a re-audit.
    // ==========================================================================
    const test_step = b.step("test", "Run tier-1 external-anchor crypto tests (NIST SHA-256 + RFC 4231 HMAC)");

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/tier1_anchors.zig"),
        .target = b.graph.host,
        .optimize = b.standardOptimizeOption(.{}),
    });

    const tests = b.addTest(.{ .root_module = test_module });
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
