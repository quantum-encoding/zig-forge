const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zecho",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = if (target.result.abi == .android) false else true,
        }),
    });

    b.installArtifact(exe);

    // ----- Tests -----
    // Externally-anchored parity tests diff zecho's output against the real
    // GNU coreutils `echo` binary. The test needs the built zecho path and a
    // GNU reference path; both are injected via a generated options module.
    const options = b.addOptions();
    options.addOption([]const u8, "zecho_path", b.getInstallPath(.bin, "zecho"));
    // Optional override for the GNU reference binary; the test also probes
    // well-known Homebrew locations at runtime.
    const gnu_path = b.option([]const u8, "gnu_echo", "Path to a GNU coreutils echo binary for parity tests") orelse "";
    options.addOption([]const u8, "gnu_path", gnu_path);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/gnu_parity_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = if (target.result.abi == .android) false else true,
    });
    test_mod.addOptions("build_options", options);

    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);
    // The parity tests spawn the installed zecho binary, so ensure it is built
    // and installed first.
    run_tests.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run GNU parity tests");
    test_step.dependOn(&run_tests.step);
}
