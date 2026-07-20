const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zsudo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    // Link PAM for authentication
    // macOS has PAM in the system SDK; Linux also needs pam_misc
    exe.root_module.linkSystemLibrary("pam", .{});
    if (exe.rootModuleTarget().os.tag != .macos) {
        exe.root_module.linkSystemLibrary("pam_misc", .{});
    }

    b.installArtifact(exe);

    // ---- Tests ----------------------------------------------------------
    // Externally-anchored parity tests (see src/gnu_parity_test.zig). The test
    // module imports main.zig, so it must link the same system libraries.
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/gnu_parity_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_module.linkSystemLibrary("pam", .{});
    if (exe.rootModuleTarget().os.tag != .macos) {
        test_module.linkSystemLibrary("pam_misc", .{});
    }

    const unit_tests = b.addTest(.{ .root_module = test_module });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run externally-anchored parity tests");
    test_step.dependOn(&run_unit_tests.step);
}
