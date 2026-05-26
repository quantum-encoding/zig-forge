const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ============================================================
    // Executable: zig-csv2json
    //
    // A one-way text-to-JSON CLI formatter. Reads CSV / TSV /
    // key-value / line-based text on stdin or a file; writes JSON.
    // This is NOT a JSON parser — there is no JSON reading
    // capability anywhere in this directory.
    // ============================================================
    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "zig-csv2json",
        .root_module = exe_module,
    });
    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run zig-csv2json");
    run_step.dependOn(&run_cmd.step);

    // ============================================================
    // Tests
    //
    // parser_tests cover CSV / TSV / KV grammar (parser.zig).
    // writer_tests cover JSON output grammar (json_writer.zig).
    // Both run under `zig build test`.
    // ============================================================
    const parser_test_module = b.createModule(.{
        .root_source_file = b.path("src/parser.zig"),
        .target = target,
        .optimize = optimize,
    });
    const parser_tests = b.addTest(.{ .root_module = parser_test_module });

    const writer_test_module = b.createModule(.{
        .root_source_file = b.path("src/json_writer.zig"),
        .target = target,
        .optimize = optimize,
    });
    const writer_tests = b.addTest(.{ .root_module = writer_test_module });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(parser_tests).step);
    test_step.dependOn(&b.addRunArtifact(writer_tests).step);
}
