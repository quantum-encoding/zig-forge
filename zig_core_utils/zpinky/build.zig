const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zpinky",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    b.installArtifact(exe);

    // ---- tests ----------------------------------------------------------
    // 1. Zig unit tests for the pure formatting/parsing helpers (anchored to
    //    documented GNU pinky behavior and the passwd(5) format).
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gnu_parity_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    // 2. End-to-end byte-for-byte diff of the built binary against the real
    //    GNU coreutils `pinky` (the strong external anchor). Skips cleanly if
    //    no GNU pinky is installed.
    const gnu_diff = b.addSystemCommand(&.{"bash"});
    gnu_diff.addFileArg(b.path("test/gnu_diff.sh"));
    gnu_diff.addArtifactArg(exe);
    // Never let cached success hide a regression: always re-run the harness.
    gnu_diff.has_side_effects = true;

    const test_step = b.step("test", "Run unit tests and the GNU-parity diff");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&gnu_diff.step);
}
