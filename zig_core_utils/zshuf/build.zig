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

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

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

    const run_parity = b.addRunArtifact(parity_tests);
    // Tests invoke the freshly-installed zshuf binary via ZSHUF_BIN.
    run_parity.step.dependOn(b.getInstallStep());
    run_parity.setEnvironmentVariable("ZSHUF_BIN", b.pathJoin(&.{ b.install_path, "bin", "zshuf" }));
    run_parity.setEnvironmentVariable("GSHUF_BIN", "/opt/homebrew/bin/gshuf");

    const test_step = b.step("test", "Run GNU-parity tests against gshuf");
    test_step.dependOn(&run_parity.step);
}
