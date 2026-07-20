const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zrm",
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

    const run_step = b.step("run", "Run zrm");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Externally-anchored GNU-parity tests: shell out to the just-built `zrm` and
    // to the real GNU `rm` (grm) and diff their behavior. The built binary path is
    // threaded in via a build option so the tests exercise the actual executable.
    // Use the ABSOLUTE installed path: the parity tests spawn `zrm` from scratch
    // working directories, so a build-root-relative path would not resolve.
    const parity_opts = b.addOptions();
    parity_opts.addOption([]const u8, "zrm_exe", b.getInstallPath(.bin, "zrm"));

    const parity_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gnu_parity_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    parity_tests.root_module.addImport("build_options", parity_opts.createModule());

    const run_parity_tests = b.addRunArtifact(parity_tests);
    run_parity_tests.step.dependOn(b.getInstallStep()); // ensure zrm is installed first
    test_step.dependOn(&run_parity_tests.step);
}
