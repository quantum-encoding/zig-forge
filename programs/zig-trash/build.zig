const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // macOS: link Objective-C runtime + Foundation for NSFileManager
    if (target.result.os.tag == .macos) {
        mod.linkFramework("Foundation", .{});
        mod.link_libc = true;
    }

    const exe = b.addExecutable(.{
        .name = "trash",
        .root_module = mod,
    });

    b.installArtifact(exe);

    // ── Tests ────────────────────────────────────────────────────────────────
    // Tier-1 anchors: externally-sourced vectors (freedesktop trash spec,
    // gio/trash-cli golden .trashinfo bodies, published Unix epoch values).
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tier1_anchors.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (target.result.os.tag == .macos) {
        test_mod.linkFramework("Foundation", .{});
        test_mod.link_libc = true;
    } else {
        test_mod.link_libc = true;
    }

    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run tier-1 anchor tests");
    test_step.dependOn(&run_unit_tests.step);

    // Behavioural end-to-end tests: drive the real binary against scratch
    // files and assert the file is gone AND recoverable. Kept out of `test`
    // because it touches the caller's real trash (see tests/integration.sh).
    const itest = b.addSystemCommand(&.{"bash"});
    itest.addFileArg(b.path("tests/integration.sh"));
    itest.addArtifactArg(exe);
    itest.has_side_effects = true;

    const itest_step = b.step("itest", "Run end-to-end trash/restore tests (uses the real trash)");
    itest_step.dependOn(&itest.step);
}
