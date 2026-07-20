const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zsha256sum",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    b.installArtifact(exe);

    // GNU-parity tests: shell out to the installed zsha256sum and to the real
    // GNU sha256sum binary and diff their behavior. The absolute path to our
    // freshly-installed binary is handed to the test via ZSHA_BIN.
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gnu_parity_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const options = b.addOptions();
    options.addOption([]const u8, "zsha_bin", b.getInstallPath(.bin, "zsha256sum"));
    options.addOption([]const u8, "gnu_bin", "/opt/homebrew/bin/gsha256sum");
    tests.root_module.addImport("build_options", options.createModule());

    const run_tests = b.addRunArtifact(tests);
    run_tests.step.dependOn(b.getInstallStep()); // ensure the binary exists first
    run_tests.has_side_effects = true; // always re-run

    const test_step = b.step("test", "Run GNU-parity tests");
    test_step.dependOn(&run_tests.step);
}
