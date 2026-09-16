const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Library module, importable as "darwin_kit" by dependants.
    const mod = b.addModule("darwin_kit", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "darwin_kit",
        .root_module = mod,
    });
    b.installArtifact(lib);

    // Tests link libbsm only to anchor the audit-token field indices against
    // Apple's implementation; the library itself has no such dependency.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.linkSystemLibrary("bsm", .{});
    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests (macOS only)");
    test_step.dependOn(&run_tests.step);
}
