const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zshuf",
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

    forwardArgs(b, run_cmd);

    const run_step = b.step("run", "Run zshuf");
    run_step.dependOn(&run_cmd.step);

    // Externally-anchored parity tests: shell out to zshuf and the real GNU
    // `shuf` (gshuf) and compare. See src/gnu_parity_test.zig.
    const parity_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gnu_parity_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    // Tests invoke the built zshuf binary via ZSHUF_BIN, set by `env`.
    const run_parity = b.addSystemCommand(&.{"env"});
    run_parity.addPrefixedFileArg("ZSHUF_BIN=", exe.getEmittedBin());
    run_parity.addArtifactArg(parity_tests);
    run_parity.step.dependOn(b.getInstallStep());
    run_parity.setEnvironmentVariable("GSHUF_BIN", "/opt/homebrew/bin/gshuf");

    const test_step = b.step("test", "Run GNU-parity tests against gshuf");
    test_step.dependOn(&run_parity.step);
}

/// Forwards `zig build <step> -- <args>` to a run step: `b.args` on Zig 0.16,
/// passthru args on 0.17+.
fn forwardArgs(b: *std.Build, run: *std.Build.Step.Run) void {
    if (comptime @hasField(std.Build, "args")) {
        if (b.args) |args| run.addArgs(args);
    } else run.addPassthruArgs();
}
