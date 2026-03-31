const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ==================== Core Modules ====================

    // Work unit types and constants
    const work_unit_module = b.addModule("work_unit", .{
        .root_source_file = b.path("src/work_unit.zig"),
        .target = target,
        .optimize = optimize,
    });

    // GPU kernel interface (uses CUDA via dlopen - no linking needed)
    const gpu_kernel_module = b.addModule("gpu_kernel", .{
        .root_source_file = b.path("src/gpu_kernel.zig"),
        .target = target,
        .optimize = optimize,
    });
    gpu_kernel_module.addImport("work_unit", work_unit_module);

    // Queen orchestrator (CPU-side)
    const queen_module = b.addModule("queen", .{
        .root_source_file = b.path("src/queen.zig"),
        .target = target,
        .optimize = optimize,
    });
    queen_module.addImport("work_unit", work_unit_module);
    queen_module.addImport("gpu_kernel", gpu_kernel_module);

    // SIMD batch preparation
    const simd_batch_module = b.addModule("simd_batch", .{
        .root_source_file = b.path("src/simd_batch.zig"),
        .target = target,
        .optimize = optimize,
    });
    simd_batch_module.addImport("work_unit", work_unit_module);

    // Add simd_batch to queen (declared after simd_batch_module exists)
    queen_module.addImport("simd_batch", simd_batch_module);

    // ==================== Main Executable ====================

    const main_module = b.addModule("main", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    main_module.addImport("queen", queen_module);
    main_module.addImport("work_unit", work_unit_module);
    main_module.addImport("gpu_kernel", gpu_kernel_module);
    main_module.addImport("simd_batch", simd_batch_module);

    const hydra_exe = b.addExecutable(.{
        .name = "hydra",
        .root_module = main_module,
    });
    // Link libc for dlopen
    hydra_exe.root_module.link_libc = true;
    b.installArtifact(hydra_exe);

    const run_cmd = b.addRunArtifact(hydra_exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the Hydra GPU variable tester");
    run_step.dependOn(&run_cmd.step);

    // ==================== Benchmark ====================

    const bench_module = b.addModule("bench", .{
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_module.addImport("queen", queen_module);
    bench_module.addImport("work_unit", work_unit_module);
    bench_module.addImport("gpu_kernel", gpu_kernel_module);
    bench_module.addImport("simd_batch", simd_batch_module);

    const bench_exe = b.addExecutable(.{
        .name = "hydra-bench",
        .root_module = bench_module,
    });
    bench_exe.root_module.link_libc = true;
    bench_exe.root_module.linkSystemLibrary("cuda", .{});
    bench_exe.root_module.linkSystemLibrary("cudart", .{});
    bench_exe.root_module.linkSystemLibrary("nvrtc", .{});
    bench_exe.root_module.addIncludePath(.{ .cwd_relative = "/opt/cuda/include" });
    bench_exe.root_module.addLibraryPath(.{ .cwd_relative = "/opt/cuda/lib64" });

    b.installArtifact(bench_exe);

    const bench_cmd = b.addRunArtifact(bench_exe);
    bench_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        bench_cmd.addArgs(args);
    }

    const bench_step = b.step("bench", "Run GPU performance benchmark");
    bench_step.dependOn(&bench_cmd.step);

}
