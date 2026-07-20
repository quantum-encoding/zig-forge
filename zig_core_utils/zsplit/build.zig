const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zsplit",
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

    const run_step = b.step("run", "Run zsplit");
    run_step.dependOn(&run_cmd.step);

    // --- Tests ---------------------------------------------------------------
    const test_step = b.step("test", "Run unit + GNU-parity tests");

    // (a) In-process unit tests for the pure helpers (documented-GNU anchors).
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);

    // (b) External-anchor parity harness: diff zsplit vs the real GNU `gsplit`.
    const parity = b.addSystemCommand(&.{"bash"});
    parity.addFileArg(b.path("src/gnu_parity_test.sh"));
    parity.addArtifactArg(exe); // pass the freshly built zsplit binary path
    parity.has_side_effects = true;
    test_step.dependOn(&parity.step);
}
