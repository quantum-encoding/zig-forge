const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zcsplit",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = if (target.result.abi == .android) false else true,
        }),
    });

    b.installArtifact(exe);

    // Externally-anchored parity tests: each test shells out to BOTH the freshly
    // built zcsplit and the real GNU csplit (gcsplit) and diffs their output,
    // exit codes, and leftover files. The GNU binary is the external anchor.
    const gnu_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gnu_parity_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    // Hand the test the resolved path of the just-built zcsplit binary.
    const opts = b.addOptions();
    opts.addOptionPath("zcsplit_bin", exe.getEmittedBin());
    gnu_test.root_module.addOptions("build_opts", opts);

    const run_gnu_test = b.addRunArtifact(gnu_test);
    const test_step = b.step("test", "Run GNU csplit parity tests");
    test_step.dependOn(&run_gnu_test.step);
}
