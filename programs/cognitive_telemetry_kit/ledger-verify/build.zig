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

    const exe = b.addExecutable(.{ .name = "ledger-verify", .root_module = exe_mod });
    b.installArtifact(exe);
}
