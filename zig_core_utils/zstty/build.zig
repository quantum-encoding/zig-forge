const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zstty",
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

    const run_step = b.step("run", "Run zstty");
    run_step.dependOn(&run_cmd.step);

    // Externally-anchored parity tests: shell out to the built zstty and to the
    // real GNU `gstty`, comparing byte-for-byte over a pseudo-terminal.
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gnu_parity_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    // The tests spawn the installed zstty binary; make sure it exists and tell
    // the tests where to find it.
    run_tests.step.dependOn(b.getInstallStep());
    run_tests.setEnvironmentVariable("ZSTTY_BIN", b.getInstallPath(.bin, "zstty"));

    const test_step = b.step("test", "Run parity tests against GNU stty");
    test_step.dependOn(&run_tests.step);
}
