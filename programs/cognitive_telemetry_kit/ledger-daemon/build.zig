const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ml_dsa = b.createModule(.{
        .root_source_file = b.path("../../zig-quantum-encryption/src/ml_dsa.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const chronos_ledger = b.createModule(.{
        .root_source_file = b.path("../chronos-ledger/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    chronos_ledger.addImport("ml_dsa", ml_dsa);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addImport("chronos_ledger", chronos_ledger);

    const exe = b.addExecutable(.{ .name = "ledger-daemon", .root_module = exe_mod });
    b.installArtifact(exe);

    // Tests cover the Sink core (the security logic); the socket/file loop in
    // main.zig is the thin shell, exercised by the end-to-end smoke check.
    const test_step = b.step("test", "Run ledger-daemon Sink tests");
    const t_mod = b.createModule(.{
        .root_source_file = b.path("src/sink.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    t_mod.addImport("chronos_ledger", chronos_ledger);
    const t = b.addTest(.{ .root_module = t_mod });
    test_step.dependOn(&b.addRunArtifact(t).step);
}
