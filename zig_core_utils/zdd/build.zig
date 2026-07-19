const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zdd",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = if (target.result.abi == .android) false else true,
        }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run zdd");
    run_step.dependOn(&run_cmd.step);

    // Unit tests (parseSize/parseConv anchors from the GNU dd manual).
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = if (target.result.abi == .android) false else true,
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    // GNU parity tests: run the built zdd against the real GNU dd.
    const parity_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/gnu_parity.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const test_options = b.addOptions();
    test_options.addOptionPath("zdd_path", exe.getEmittedBin());
    parity_tests.root_module.addOptions("build_options", test_options);
    const run_parity_tests = b.addRunArtifact(parity_tests);

    const test_step = b.step("test", "Run unit + GNU parity tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_parity_tests.step);
}
