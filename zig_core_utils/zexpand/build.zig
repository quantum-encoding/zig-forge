const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zexpand",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = if (target.result.abi == .android) false else true,
        }),
    });

    b.installArtifact(exe);

    // --- Externally-anchored GNU-parity tests -------------------------------
    // The tests exec the installed zexpand and compare its output against the
    // real GNU `expand` (resolved at runtime inside the test; SkipZigTest if
    // absent). Only the installed-binary path is injected here.
    const opts = b.addOptions();
    // getInstallPath returns a configure-time string path to the installed exe.
    opts.addOption([]const u8, "zexpand_bin", b.getInstallPath(.bin, "zexpand"));

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
    // The tests exec the *installed* zexpand binary, so build+install it first.
    run_tests.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run GNU-parity tests against the real GNU expand");
    test_step.dependOn(&run_tests.step);
}
