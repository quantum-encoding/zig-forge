const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zusers",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    b.installArtifact(exe);

    // Externally-anchored GNU parity tests. The freshly-built zusers binary
    // path is threaded in so the harness can spawn it and diff against the real
    // GNU `users` (gusers). The test module links libc so it can synthesize a
    // utmpx fixture via `pututxline` (the exact on-disk format both binaries
    // read).
    const test_opts = b.addOptions();
    test_opts.addOptionPath("zusers_exe", exe.getEmittedBin());

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gnu_parity_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    tests.root_module.addOptions("build_options", test_opts);

    const run_tests = b.addRunArtifact(tests);
    run_tests.has_side_effects = true; // reads live utmpx / external gusers

    const test_step = b.step("test", "Run externally-anchored GNU parity tests");
    test_step.dependOn(&run_tests.step);
}
