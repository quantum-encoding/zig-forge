const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zlink",
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

    const run_step = b.step("run", "Run zlink");
    run_step.dependOn(&run_cmd.step);

    // GNU parity tests: shell out to the installed zlink binary and diff
    // its behavior against the real GNU coreutils `link` binary.
    const test_options = b.addOptions();
    test_options.addOption([]const u8, "zlink_bin", b.getInstallPath(.bin, "zlink"));

    const parity_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gnu_parity_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    parity_tests.root_module.addOptions("build_options", test_options);

    const run_parity_tests = b.addRunArtifact(parity_tests);
    run_parity_tests.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run GNU parity tests");
    test_step.dependOn(&run_parity_tests.step);
}
