const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main zmkdir executable
    const exe = b.addExecutable(.{
        .name = "zmkdir",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    b.installArtifact(exe);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run zmkdir");
    run_step.dependOn(&run_cmd.step);

    // Unit tests
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

    // GNU-parity tests: diff zmkdir's live output against the real GNU
    // coreutils `mkdir` binary. These need the built executable's path,
    // exposed via a build_options module (`zmkdir_bin`). The LazyPath
    // dependency also guarantees the exe is built before the tests run.
    const parity_opts = b.addOptions();
    parity_opts.addOptionPath("zmkdir_bin", exe.getEmittedBin());

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
    test_step.dependOn(&run_parity_tests.step);
}
