const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zfactor",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    b.installArtifact(exe);

    // --- Tests: externally anchored against the real GNU `factor` binary ---
    const gfactor_path = b.option(
        []const u8,
        "gfactor",
        "Path to the GNU factor binary used as the external test anchor",
    ) orelse "/opt/homebrew/bin/gfactor";

    const opts = b.addOptions();
    opts.addOption([]const u8, "zfactor_path", b.getInstallPath(.bin, "zfactor"));
    opts.addOption([]const u8, "gfactor_path", gfactor_path);

    const test_exe = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gnu_parity_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    test_exe.root_module.addOptions("build_opts", opts);

    const run_test = b.addRunArtifact(test_exe);
    // The tests spawn the installed zfactor binary, so ensure it is built and
    // installed first.
    run_test.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run GNU-parity tests against the real gfactor binary");
    test_step.dependOn(&run_test.step);
}
