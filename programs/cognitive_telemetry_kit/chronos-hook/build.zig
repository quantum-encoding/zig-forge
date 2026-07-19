const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Plane 2 emit-client: the hook builds a ledger event (RFC 8785 canonical)
    // and fires it non-blocking at the sink. It holds NO key and does NOT sign,
    // so it only needs the canonicaliser + the UDS writer — never ml_dsa.
    const canonical = b.createModule(.{
        .root_source_file = b.path("../chronos-ledger/src/canonical.zig"),
        .target = target,
        .optimize = optimize,
    });
    const emit = b.createModule(.{
        .root_source_file = b.path("../chronos-ledger/src/emit_client.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("canonical", canonical);
    exe_mod.addImport("chronos_emit", emit);

    const exe = b.addExecutable(.{
        .name = "chronos-hook",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    // Tests — exercise the pure parsing/attribution helpers (agent misattribution
    // guard, hostile `ps` rows, structured field extraction that ignores keys
    // appearing only inside string values, UTF-8-safe truncation). These are
    // I/O-free, so no libc / canonical / emit wiring is needed here.
    const test_step = b.step("test", "Run chronos-hook tests");
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/parse.zig"),
        .target = target,
        .optimize = optimize,
    });
    const unit_tests = b.addTest(.{ .root_module = test_mod });
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
}
