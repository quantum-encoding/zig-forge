const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zsha1sum",
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
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run zsha1sum");
    run_step.dependOn(&run_cmd.step);

    // Externally-anchored GNU-parity tests: they exec the *installed* zsha1sum
    // binary and diff its output against the real GNU `sha1sum`/`gsha1sum` (when
    // present) plus published SHA-1 vectors. Inject the absolute install path so
    // the test is cwd-independent, and make the test depend on the install.
    const test_opts = b.addOptions();
    test_opts.addOption([]const u8, "zsha1sum_path", b.getInstallPath(.bin, "zsha1sum"));

    const parity_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gnu_parity_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    parity_tests.root_module.addOptions("build_options", test_opts);

    const run_parity_tests = b.addRunArtifact(parity_tests);
    run_parity_tests.has_side_effects = true; // reference GNU output is external
    run_parity_tests.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run externally-anchored GNU-parity tests");
    test_step.dependOn(&run_parity_tests.step);
}
