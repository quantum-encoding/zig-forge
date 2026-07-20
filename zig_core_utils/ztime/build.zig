const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "ztime",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.root_module.link_libc = true;

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run ztime");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);

    // Externally-anchored GNU parity tests: these drive the *installed* ztime binary
    // and compare its bytes/exit codes against documented GNU behavior and
    // independently-computed system values (page size, shell exit status).
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "ztime_path", b.getInstallPath(.bin, "ztime"));

    const parity_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gnu_parity_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    parity_tests.root_module.link_libc = true;
    parity_tests.root_module.addOptions("build_options", build_options);

    const run_parity_tests = b.addRunArtifact(parity_tests);
    // The parity tests exec the built binary, so ensure it is installed first.
    run_parity_tests.step.dependOn(b.getInstallStep());
    test_step.dependOn(&run_parity_tests.step);
}
