const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const is_macos = target.result.os.tag == .macos;

    // Build step to compile all components
    const build_all = b.step("all", "Build all cognitive telemetry kit components");

    // Sub-projects
    buildSubProject(b, "chronos-hook", build_all);
    buildSubProject(b, "cognitive-state-server", build_all);
    buildSubProject(b, "cognitive-tools", build_all);
    // libcognitive-capture is macOS-only (uses DYLD interposition)
    if (is_macos) {
        buildSubProject(b, "libcognitive-capture", build_all);
    }
    buildSubProject(b, "get-cognitive-state", build_all);

    // Default install step builds everything
    b.getInstallStep().dependOn(build_all);

    // Test step
    const test_all = b.step("test", "Run all tests");
    testSubProject(b, "chronos-hook", test_all);
    testSubProject(b, "cognitive-state-server", test_all);
    testSubProject(b, "cognitive-tools", test_all);
}

fn buildSubProject(
    b: *std.Build,
    name: []const u8,
    build_all: *std.Build.Step,
) void {
    // Build to monorepo root zig-out (from programs/cognitive_telemetry_kit/<subproject>/)
    // Path: ../../../zig-out goes from subproject -> cognitive_telemetry_kit -> programs -> root
    const build_cmd = b.addSystemCommand(&[_][]const u8{
        "zig",
        "build",
        "--prefix",
        "../../../zig-out",
    });
    build_cmd.setCwd(.{ .cwd_relative = name });
    build_all.dependOn(&build_cmd.step);

    // Create individual build step
    const build_step = b.step(name, b.fmt("Build {s}", .{name}));
    build_step.dependOn(&build_cmd.step);
}

fn testSubProject(
    b: *std.Build,
    name: []const u8,
    test_all: *std.Build.Step,
) void {
    const test_cmd = b.addSystemCommand(&[_][]const u8{
        "zig",
        "build",
        "test",
    });
    test_cmd.setCwd(.{ .cwd_relative = name });
    test_all.dependOn(&test_cmd.step);
}
