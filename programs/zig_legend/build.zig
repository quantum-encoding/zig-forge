const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const toml_dep = b.dependency("zig_toml", .{ .target = target, .optimize = optimize });
    const toml_mod = toml_dep.module("zig_toml");

    // Library module, importable as "zig_legend". Pure Zig, no libc.
    const lib_mod = b.addModule("zig_legend", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zig_toml", .module = toml_mod }},
    });

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "zig_legend",
        .root_module = lib_mod,
    });
    b.installArtifact(lib);

    // CLI
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zig_legend", .module = lib_mod }},
    });
    const exe = b.addExecutable(.{ .name = "zig_legend", .root_module = exe_mod });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run the zig_legend CLI").dependOn(&run_cmd.step);

    // Tests: unit tests in the library plus golden renders of the examples.
    // The example files are anonymous imports so the tests can @embedFile them
    // from outside src/.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zig_toml", .module = toml_mod }},
    });
    const example_files = [_][2][]const u8{
        .{ "letter.txt", "examples/letter/letter.txt" },
        .{ "letter.toml", "examples/letter/legend.toml" },
        .{ "letter.approved.txt", "examples/letter/expected/approved.txt" },
        .{ "letter.declined.txt", "examples/letter/expected/declined.txt" },
        .{ "letter.deferred.txt", "examples/letter/expected/deferred.txt" },
        .{ "modguard.txt", "examples/modguard/prompt.txt" },
        .{ "modguard.toml", "examples/modguard/legend.toml" },
        .{ "agent.toml", "examples/agent/legend.toml" },
        .{ "agent.txt", "examples/agent/brief.txt" },
        .{ "agent.goal.json", "examples/agent/goal.json" },
        .{ "agent.role.reviewer.txt", "examples/agent/roles/reviewer.txt" },
        .{ "agent.reviewer.md", "examples/agent/expected/reviewer.md" },
    };
    for (example_files) |pair| {
        test_mod.addAnonymousImport(pair[0], .{ .root_source_file = b.path(pair[1]) });
    }
    const tests = b.addTest(.{ .root_module = test_mod });
    b.step("test", "Run unit tests and example goldens").dependOn(&b.addRunArtifact(tests).step);
}
