const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zmd5sum",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    b.installArtifact(exe);

    // --- Tests: externally-anchored GNU parity + RFC 1321 spec vectors. ---
    // Inject the built binary's path so the tests can exec it and diff its
    // output against the real GNU md5sum.
    const test_opts = b.addOptions();
    test_opts.addOptionPath("zmd5sum_bin", exe.getEmittedBin());

    const parity_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gnu_parity_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    parity_tests.root_module.addOptions("build_options", test_opts);

    const run_parity_tests = b.addRunArtifact(parity_tests);
    // The tests exec the freshly-built binary, so make them depend on it.
    run_parity_tests.step.dependOn(&exe.step);

    const test_step = b.step("test", "Run GNU-parity and spec-vector tests");
    test_step.dependOn(&run_parity_tests.step);
}
