const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "zig2asm",
        .root_module = exe_module,
    });
    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run zig2asm");
    run_step.dependOn(&run_cmd.step);

    // Test suite
    const test_exe = b.addTest(.{
        .root_module = exe_module,
    });

    const run_test = b.addRunArtifact(test_exe);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_test.step);

    // End-to-end smoke test: run the built zig2asm against a fixture and assert
    // the emitted .s / .ll files appear. Kept OUT of the default `test` step so
    // workspace test aggregation stays hermetic (this one spawns `zig` and
    // writes files). Run explicitly with `zig build test-e2e`.
    const e2e_runner = b.addExecutable(.{
        .name = "zig2asm-e2e",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/e2e_runner.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_e2e = b.addRunArtifact(e2e_runner);
    run_e2e.addArtifactArg(exe); // argv[1]: the zig2asm exe under test
    run_e2e.addFileArg(b.path("test/fixtures/hello.zig")); // argv[2]: fixture
    const out_dir = run_e2e.addOutputDirectoryArg("zig2asm-e2e-out"); // argv[3]: writable outdir
    _ = out_dir;
    const e2e_step = b.step("test-e2e", "Run the end-to-end smoke test (spawns zig)");
    e2e_step.dependOn(&run_e2e.step);
}
