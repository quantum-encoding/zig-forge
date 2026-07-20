const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const link_libc = target.result.abi != .android;

    const exe = b.addExecutable(.{
        .name = "zdir",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = link_libc,
        }),
    });

    b.installArtifact(exe);

    // ---- Tests ----
    // Externally-anchored GNU-parity tests: they exec the installed zdir binary
    // and the real GNU `dir`, so the test module needs to know where the
    // installed zdir lives.
    const test_opts = b.addOptions();
    test_opts.addOption([]const u8, "zdir_exe", b.getInstallPath(.bin, "zdir"));

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/gnu_parity_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = link_libc,
    });
    test_mod.addOptions("build_options", test_opts);

    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);
    // The tests exec the installed zdir binary, so install it first.
    run_tests.step.dependOn(b.getInstallStep());
    // Depends on external state (GNU binary, tmp fixtures) — don't cache.
    run_tests.has_side_effects = true;

    const test_step = b.step("test", "Run GNU-parity tests");
    test_step.dependOn(&run_tests.step);
}
