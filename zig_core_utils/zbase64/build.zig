const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zbase64",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            // main.zig routes all I/O through libc (write/read/open/close), so
            // libc is required on every target, android included.
            .link_libc = true,
        }),
    });

    b.installArtifact(exe);

    // GNU-parity differential tests: shell out to the built zbase64 binary and
    // to the real GNU base64, comparing byte-for-byte. The zbase64 binary path
    // is injected as a build option (resolves to the compiled artifact), which
    // also makes the parity test depend on the exe being built.
    const parity_opts = b.addOptions();
    parity_opts.addOptionPath("zbase64_exe", exe.getEmittedBin());

    const parity_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gnu_parity_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    parity_tests.root_module.addOptions("build_options", parity_opts);

    const run_parity_tests = b.addRunArtifact(parity_tests);
    const test_step = b.step("test", "Run GNU-parity tests");
    test_step.dependOn(&run_parity_tests.step);
}
