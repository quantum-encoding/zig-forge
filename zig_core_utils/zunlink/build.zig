const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zunlink",
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

    const run_step = b.step("run", "Run zunlink");
    run_step.dependOn(&run_cmd.step);

    // --- Tests ---------------------------------------------------------------
    // The parity suite shells out to the built zunlink binary and (when
    // present) the real GNU coreutils `unlink`, so tests depend on the
    // installed artifact. Paths are injected via env vars.
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gnu_parity_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    // Inject the built-binary path and the GNU reference path as compile-time
    // options (env-var reads are awkward under the new Io std).
    const test_opts = b.addOptions();
    test_opts.addOption([]const u8, "zunlink_bin", b.getInstallPath(.bin, "zunlink"));
    test_opts.addOption([]const u8, "gnu_unlink", "/opt/homebrew/opt/coreutils/libexec/gnubin/unlink");
    tests.root_module.addOptions("build_options", test_opts);

    const run_tests = b.addRunArtifact(tests);
    run_tests.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run parity tests against GNU unlink");
    test_step.dependOn(&run_tests.step);
}
