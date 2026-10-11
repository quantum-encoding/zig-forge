const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zexpr",
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

    if (@hasDecl(std.Build.Step.Run, "addPassthruArgs")) run_cmd.addPassthruArgs() else if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run zexpr");
    run_step.dependOn(&run_cmd.step);

    // GNU parity tests: shell out to the installed zexpr binary and diff its
    // output against the real GNU `expr`. The test needs the built binary, so it
    // depends on the install step and receives the path via ZEXPR_BIN.
    const parity_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gnu_parity_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true, // for std.c.getenv (reads ZEXPR_BIN)
        }),
    });
    const run_tests = b.addRunArtifact(parity_tests);
    // The binary path reaches the test through build_options (b.getInstallPath is gone in
    // Zig 0.17); ZEXPR_BIN in the environment still overrides it.
    const test_opts = b.addOptions();
    test_opts.addOptionPath("zexpr_bin", exe.getEmittedBin());
    parity_tests.root_module.addOptions("build_options", test_opts);
    run_tests.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run GNU parity tests");
    test_step.dependOn(&run_tests.step);
}
