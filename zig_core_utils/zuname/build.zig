const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zuname",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    b.installArtifact(exe);

    // --- Tests: externally anchored against the real GNU coreutils `uname`. ---
    const gnu_uname = b.option(
        []const u8,
        "gnu-uname",
        "Path to the GNU coreutils uname binary used as the parity anchor",
    ) orelse "/opt/homebrew/opt/coreutils/libexec/gnubin/uname";

    const test_opts = b.addOptions();
    // Path to the freshly-built zuname binary; creates a build dependency so
    // the exe is compiled before the tests run.
    test_opts.addOptionPath("zuname_bin", exe.getEmittedBin());
    test_opts.addOption([]const u8, "gnu_uname", gnu_uname);

    const parity_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gnu_parity_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    parity_tests.root_module.addOptions("build_options", test_opts);

    const run_tests = b.addRunArtifact(parity_tests);
    const test_step = b.step("test", "Run GNU-parity tests");
    test_step.dependOn(&run_tests.step);
}
