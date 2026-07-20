const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zreadlink",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    b.installArtifact(exe);

    // ---- tests ----
    // Externally-anchored GNU-parity tests. They shell out to the freshly built
    // zreadlink binary (and to the real GNU readlink when installed), so the
    // test module is told where the exe lives via a generated build_options.
    // Absolute install path: the tests change the child's cwd into a temp
    // fixture dir, so a relative exe path would fail to exec.
    const options = b.addOptions();
    options.addOption([]const u8, "zreadlink_path", b.getInstallPath(.bin, "zreadlink"));

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gnu_parity_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    tests.root_module.addOptions("build_options", options);

    const run_tests = b.addRunArtifact(tests);
    run_tests.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run GNU-parity tests");
    test_step.dependOn(&run_tests.step);
}
