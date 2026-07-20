const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zmore",
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

    const run_step = b.step("run", "Run zmore");
    run_step.dependOn(&run_cmd.step);

    // Externally-anchored parity tests. They spawn the installed `zmore`
    // binary as a black box, so the test build depends on the install step and
    // is handed the binary's path via build options.
    const test_opts = b.addOptions();
    test_opts.addOption([]const u8, "zmore_path", b.getInstallPath(.bin, "zmore"));

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
    run_tests.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run parity tests against the built binary");
    test_step.dependOn(&run_tests.step);
}
