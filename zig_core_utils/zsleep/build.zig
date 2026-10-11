const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zsleep",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    b.installArtifact(exe);

    // ---- tests ----
    const test_step = b.step("test", "Run unit + GNU-parity tests");

    // Unit tests (parseDuration) live in main.zig.
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const run_unit = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit.step);

    // Externally-anchored parity tests shell out to the built binary and to
    // real GNU coreutils `sleep`, so they depend on the install step and are
    // told where the freshly built zsleep lives.
    const parity_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gnu_parity_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const run_parity = b.addRunArtifact(parity_tests);
    if (@hasDecl(std.Build, "getInstallPath")) {
        run_parity.setEnvironmentVariable("ZSLEEP_BIN", b.getInstallPath(.bin, "zsleep"));
    } else {
        // Zig 0.17: the install prefix is known only at make time and an env var cannot take a
        // lazy path, so the test runs from the install prefix and is given a relative path.
        run_parity.setCwd(.{ .relative = .{ .base = .install_prefix } });
        run_parity.setEnvironmentVariable("ZSLEEP_BIN", "bin/zsleep");
    }
    run_parity.step.dependOn(b.getInstallStep());
    test_step.dependOn(&run_parity.step);
}
