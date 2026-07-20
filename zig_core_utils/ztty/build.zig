const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "ztty",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    b.installArtifact(exe);

    // ---- Tests --------------------------------------------------------------
    // GNU-parity tests shell out to both the freshly-built ztty and the real
    // GNU coreutils `tty`, then compare exit codes / stdout routing. The paths
    // are injected via build options so the test binary knows where to find
    // both executables.
    const test_options = b.addOptions();
    test_options.addOptionPath("ztty_bin", exe.getEmittedBin());
    // GNU coreutils `tty` (Homebrew). Overridable with -Dgnu-tty=/path.
    const gnu_tty = b.option(
        []const u8,
        "gnu-tty",
        "Path to the GNU coreutils `tty` binary for parity tests",
    ) orelse "/opt/homebrew/opt/coreutils/libexec/gnubin/tty";
    test_options.addOption([]const u8, "gnu_tty", gnu_tty);

    const parity_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gnu_parity_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    parity_tests.root_module.addOptions("build_options", test_options);

    const run_tests = b.addRunArtifact(parity_tests);
    const test_step = b.step("test", "Run GNU-parity tests");
    test_step.dependOn(&run_tests.step);
}
