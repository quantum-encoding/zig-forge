const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zinstall",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run zinstall");
    run_step.dependOn(&run_cmd.step);

    // --- Tests ---------------------------------------------------------------
    // Externally anchored against the real GNU `install` binary. The test needs
    // to invoke the freshly built zinstall, so it depends on the install step
    // and is told the installed binary path via build options.
    const options = b.addOptions();
    options.addOption([]const u8, "zinstall_path", b.getInstallPath(.bin, "zinstall"));

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/gnu_parity_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addOptions("build_options", options);

    const tests = b.addTest(.{ .root_module = test_mod });

    const run_tests = b.addRunArtifact(tests);
    // Ensure the zinstall binary is installed before the differential tests run.
    run_tests.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run zinstall tests (differential vs GNU install)");
    test_step.dependOn(&run_tests.step);
}
