const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zwho",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    b.installArtifact(exe);

    // --- Tests ---------------------------------------------------------------
    // Externally-anchored parity tests shell out to the installed zwho binary
    // and the real GNU `who`, so they need the exe's absolute install path.
    const test_opts = b.addOptions();
    test_opts.addOption([]const u8, "zwho_path", b.getInstallPath(.bin, "zwho"));

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gnu_parity_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    tests.root_module.addOptions("build_options", test_opts);

    const run_tests = b.addRunArtifact(tests);
    // The parity tests exec the installed binary, so install must run first.
    run_tests.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run GNU-parity tests against the real gwho");
    test_step.dependOn(&run_tests.step);
}
