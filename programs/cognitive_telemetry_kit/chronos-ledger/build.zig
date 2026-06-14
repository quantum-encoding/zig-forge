const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The audited ML-DSA-65 implementation lives in the sibling program. We pull
    // ml_dsa.zig in as a module; it only @imports std + rng.zig (resolved relative
    // to its own directory), so no extra wiring is needed beyond libc.
    const ml_dsa = b.createModule(.{
        .root_source_file = b.path("../../zig-quantum-encryption/src/ml_dsa.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // ── Consumable Zig module: `@import("chronos_ledger")` ──────────────────
    const mod = b.addModule("chronos_ledger", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("ml_dsa", ml_dsa);

    // ── C-ABI static library (for the Go proxy + Swift app) ─────────────────
    const c_mod = b.createModule(.{
        .root_source_file = b.path("src/c_api.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    c_mod.addImport("ml_dsa", ml_dsa);
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "chronos_ledger",
        .root_module = c_mod,
    });
    lib.installHeadersDirectory(b.path("include"), "", .{});
    b.installArtifact(lib);

    // ── Tests: `zig build test` runs canonical + ledger + c_api suites ──────
    const test_step = b.step("test", "Run chronos-ledger tests");
    for ([_][]const u8{ "src/canonical.zig", "src/ledger.zig", "src/c_api.zig" }) |src| {
        const t_mod = b.createModule(.{
            .root_source_file = b.path(src),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        t_mod.addImport("ml_dsa", ml_dsa);
        const t = b.addTest(.{ .root_module = t_mod });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}
