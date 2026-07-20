const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main zbench executable
    const exe = b.addExecutable(.{
        .name = "zbench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = if (target.result.abi == .android) false else true,
        }),
    });

    b.installArtifact(exe);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run zbench");
    run_step.dependOn(&run_cmd.step);

    // Unit tests (pure-function tests live in main.zig)
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = if (target.result.abi == .android) false else true,
        }),
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // External-anchor tests (src/gnu_parity_test.zig) shell out to the compiled
    // zbench binary and diff its observable behavior against hyperfine's
    // documented exit-code semantics and RFC 8259 JSON escaping. The binary's
    // install path is injected via a build-options module.
    const parity_options = b.addOptions();
    parity_options.addOption([]const u8, "zbench_exe", b.getInstallPath(.bin, "zbench"));

    const parity_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gnu_parity_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = if (target.result.abi == .android) false else true,
        }),
    });
    parity_tests.root_module.addOptions("build_options", parity_options);

    const run_parity_tests = b.addRunArtifact(parity_tests);
    // The parity tests execute the installed binary, so it must exist first.
    run_parity_tests.step.dependOn(b.getInstallStep());
    test_step.dependOn(&run_parity_tests.step);
}
