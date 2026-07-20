const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zstdbuf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    b.installArtifact(exe);

    // The pre-loaded companion library that actually applies the buffering
    // (read by the child via DYLD_INSERT_LIBRARIES / LD_PRELOAD). Installed
    // next to the binary so zstdbuf can locate it at runtime.
    const libstdbuf = b.addLibrary(.{
        .name = "stdbuf",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/libstdbuf.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    b.installArtifact(libstdbuf);

    // ---- Tests --------------------------------------------------------------
    // Externally-anchored parity tests: they shell out to the real GNU stdbuf
    // (gstdbuf) and diff its behavior against the freshly-built zstdbuf, plus
    // unit-test the size grammar against literal GNU-derived values.
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/gnu_parity_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const unit_tests = b.addTest(.{ .root_module = test_module });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    // The integration tests invoke the installed binary, so build+install first.
    run_unit_tests.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run externally-anchored parity tests");
    test_step.dependOn(&run_unit_tests.step);
}
