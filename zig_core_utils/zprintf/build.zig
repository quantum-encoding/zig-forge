const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zprintf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    b.installArtifact(exe);

    // --- Tests ---------------------------------------------------------------
    // The parity tests shell out to the compiled zprintf binary and diff it
    // against the real GNU coreutils `printf`. Pass the built binary's path in
    // via build options so the test knows what to run.
    const opts = b.addOptions();
    opts.addOptionPath("zprintf_bin", exe.getEmittedBin());

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gnu_parity_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    tests.root_module.addOptions("build_options", opts);

    const run_tests = b.addRunArtifact(tests);
    run_tests.step.dependOn(&exe.step);

    const test_step = b.step("test", "Run GNU-parity tests");
    test_step.dependOn(&run_tests.step);
}
