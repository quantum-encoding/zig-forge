const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zhostid",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    b.installArtifact(exe);

    // --- Externally-anchored parity tests ---------------------------------
    // The GNU `hostid` binary is the external anchor. Override its location
    // with -Dgnu-hostid=/path if needed; when absent the tests fall back to
    // documented literal bytes / skip the cross-checks.
    const default_gnu = "/opt/homebrew/opt/coreutils/libexec/gnubin/hostid";
    const gnu_hostid = b.option([]const u8, "gnu-hostid", "Path to the real GNU hostid binary (external test anchor)") orelse default_gnu;

    const test_opts = b.addOptions();
    // Emit the just-built zhostid binary path; also makes the test depend on it.
    test_opts.addOptionPath("zhostid_bin", exe.getEmittedBin());
    test_opts.addOption([]const u8, "gnu_hostid", gnu_hostid);

    const parity_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gnu_parity_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    parity_tests.root_module.addImport("build_options", test_opts.createModule());

    const run_tests = b.addRunArtifact(parity_tests);
    // Spawns real child processes and inspects host state; never cache-hit.
    run_tests.has_side_effects = true;

    const test_step = b.step("test", "Run externally-anchored GNU parity tests");
    test_step.dependOn(&run_tests.step);
}
