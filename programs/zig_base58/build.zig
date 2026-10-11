const std = @import("std");

// Zig 0.17 renamed the optimize tags (Debug/ReleaseSafe/ReleaseFast/ReleaseSmall became
// debug/safe/fast/small) and keeps the old names only as declarations on the enum, which an
// enum literal cannot reach; naming them through the type compiles on 0.16 and 0.17.
const Optimize = std.builtin.OptimizeMode;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ==========================================================================
    // Base58 Library Module
    // ==========================================================================
    const base58_module = b.addModule("base58", .{
        .root_source_file = b.path("src/base58.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ==========================================================================
    // Static Library
    // ==========================================================================
    const lib = b.addLibrary(.{
        .name = "zig_base58",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .linkage = .static,
    });

    b.installArtifact(lib);

    // ==========================================================================
    // CLI Tool
    // ==========================================================================
    const cli_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_module.addImport("base58", base58_module);

    const exe = b.addExecutable(.{
        .name = "zbase58",
        .root_module = cli_module,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    // Zig 0.17 removed `b.args` (configure logic can no longer see run arguments) in
    // favour of `addPassthruArgs`, which 0.16 does not have; the comptime branch keeps
    // both compiling.
    if (@hasDecl(std.Build.Step.Run, "addPassthruArgs")) run_cmd.addPassthruArgs() else if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the Base58 CLI tool");
    run_step.dependOn(&run_cmd.step);

    // ==========================================================================
    // Tests
    // ==========================================================================
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/base58.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // ==========================================================================
    // Benchmarks
    // ==========================================================================
    const bench_module = b.createModule(.{
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = Optimize.ReleaseFast,
        .link_libc = true,
    });
    bench_module.addImport("base58", base58_module);

    const bench = b.addExecutable(.{
        .name = "base58-bench",
        .root_module = bench_module,
    });

    b.installArtifact(bench);

    const bench_cmd = b.addRunArtifact(bench);
    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&bench_cmd.step);
}
