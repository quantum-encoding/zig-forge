const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ==========================================================================
    // UUID Library Module
    // ==========================================================================
    const uuid_module = b.addModule("uuid", .{
        .root_source_file = b.path("src/uuid.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // ==========================================================================
    // Static Library
    // ==========================================================================
    const lib = b.addLibrary(.{
        .name = "zig_uuid",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/uuid.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
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
        .link_libc = true,
    });
    cli_module.addImport("uuid", uuid_module);

    const exe = b.addExecutable(.{
        .name = "zuuid",
        .root_module = cli_module,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    forwardArgs(b, run_cmd);

    const run_step = b.step("run", "Run the UUID CLI tool");
    run_step.dependOn(&run_cmd.step);

    // ==========================================================================
    // Tests
    // ==========================================================================
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/uuid.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
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
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    bench_module.addImport("uuid", uuid_module);

    const bench = b.addExecutable(.{
        .name = "uuid-bench",
        .root_module = bench_module,
    });

    b.installArtifact(bench);

    const bench_cmd = b.addRunArtifact(bench);
    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&bench_cmd.step);
}

/// Forwards `zig build <step> -- <args>` to a run step: `b.args` on Zig 0.16,
/// passthru args on 0.17+.
fn forwardArgs(b: *std.Build, run: *std.Build.Step.Run) void {
    if (comptime @hasField(std.Build, "args")) {
        if (b.args) |args| run.addArgs(args);
    } else run.addPassthruArgs();
}
