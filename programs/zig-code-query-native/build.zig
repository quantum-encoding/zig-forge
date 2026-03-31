const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const build_lib = b.option(bool, "lib", "Build as shared/static library instead of executable") orelse false;
    const build_static = b.option(bool, "static", "Build static library (use with -Dlib)") orelse false;

    if (build_lib) {
        // Library build
        const linkage: std.builtin.LinkMode = if (build_static) .static else .dynamic;
        const lib_artifact = b.addLibrary(.{
            .linkage = linkage,
            .name = "zig_code_query",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/lib.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        b.installArtifact(lib_artifact);

        // Install C header
        b.installFile("include/zig_code_query.h", "include/zig_code_query.h");
    } else {
        // Executable build (default)
        const exe = b.addExecutable(.{
            .name = "zig-code-query",
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

        const run_step = b.step("run", "Run zig-code-query");
        run_step.dependOn(&run_cmd.step);
    }

    // Tests
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
