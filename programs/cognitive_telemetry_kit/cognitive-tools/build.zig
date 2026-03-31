const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // cognitive-export - CSV export tool
    const export_mod = b.createModule(.{
        .root_source_file = b.path("src/export.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    export_mod.linkSystemLibrary("sqlite3", .{});
    const export_exe = b.addExecutable(.{
        .name = "cognitive-export",
        .root_module = export_mod,
    });
    b.installArtifact(export_exe);

    // cognitive-stats - Analytics tool
    const stats_mod = b.createModule(.{
        .root_source_file = b.path("src/stats.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    stats_mod.linkSystemLibrary("sqlite3", .{});
    const stats_exe = b.addExecutable(.{
        .name = "cognitive-stats",
        .root_module = stats_mod,
    });
    b.installArtifact(stats_exe);

    // cognitive-query - Advanced search tool
    const query_mod = b.createModule(.{
        .root_source_file = b.path("src/query.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    query_mod.linkSystemLibrary("sqlite3", .{});
    const query_exe = b.addExecutable(.{
        .name = "cognitive-query",
        .root_module = query_mod,
    });
    b.installArtifact(query_exe);

    // cognitive-confidence - Code quality confidence analyzer
    const confidence_mod = b.createModule(.{
        .root_source_file = b.path("src/confidence.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    confidence_mod.linkSystemLibrary("sqlite3", .{});
    const confidence_exe = b.addExecutable(.{
        .name = "cognitive-confidence",
        .root_module = confidence_mod,
    });
    b.installArtifact(confidence_exe);
}
