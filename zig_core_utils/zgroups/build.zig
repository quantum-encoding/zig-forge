const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zgroups",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    b.installArtifact(exe);

    // --- Tests: GNU-parity, anchored to the real ggroups binary --------------
    const gnu = "/opt/homebrew/bin/ggroups";
    const test_opts = b.addOptions();
    test_opts.addOption([]const u8, "zgroups_exe", b.getInstallPath(.bin, "zgroups"));
    test_opts.addOption([]const u8, "ggroups_exe", gnu);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/gnu_parity_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addOptions("build_opts", test_opts);

    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);
    // The tests spawn the installed zgroups binary, so it must exist first.
    run_tests.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run GNU-parity tests");
    test_step.dependOn(&run_tests.step);
}
