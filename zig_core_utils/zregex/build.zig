const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zregex",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    b.installArtifact(exe);

    const test_step = b.step("test", "Run unit tests");

    // Engine unit tests (in-source `test` blocks in regex.zig / sparse_set.zig).
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/regex.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);

    // Externally-anchored GNU-parity tests: shell out to the built `zregex`
    // binary and diff its output against the system `grep -E` (a different
    // implementation) plus literal expected bytes taken from POSIX ERE / GNU
    // grep documented behavior. Needs the installed exe path.
    const parity_opts = b.addOptions();
    parity_opts.addOption([]const u8, "zregex_exe", b.getInstallPath(.bin, "zregex"));

    const parity_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gnu_parity_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    parity_tests.root_module.addOptions("build_options", parity_opts);

    const run_parity_tests = b.addRunArtifact(parity_tests);
    // The parity tests execute the installed binary, so it must exist first.
    run_parity_tests.step.dependOn(b.getInstallStep());
    test_step.dependOn(&run_parity_tests.step);
}
