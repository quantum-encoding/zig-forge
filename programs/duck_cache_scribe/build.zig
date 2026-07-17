const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The default binary (src/main.zig) is implemented with raw std.os.linux
    // syscalls (inotify, linux.read/write/nanosleep). Building it for a non-Linux
    // host produces a binary that issues Linux syscall numbers against the wrong
    // kernel at runtime, so gate it to Linux targets only — mirroring the macOS
    // gate below.
    const is_linux = target.result.os.tag == .linux;
    if (is_linux) {
        const root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        });

        const exe = b.addExecutable(.{
            .name = "duckcache-scribe",
            .root_module = root_module,
        });

        exe.root_module.linkSystemLibrary("c", .{});

        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());

        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const run_step = b.step("run", "Run the DuckCache Scribe daemon");
        run_step.dependOn(&run_cmd.step);
    }

    // macOS version (uses kqueue instead of inotify) - only build on macOS
    const is_macos = target.result.os.tag == .macos;
    if (is_macos) {
        const macos_module = b.createModule(.{
            .root_source_file = b.path("src/main-macos.zig"),
            .target = target,
            .optimize = optimize,
        });
        const macos_exe = b.addExecutable(.{
            .name = "duckcache-scribe-macos",
            .root_module = macos_module,
        });
        macos_exe.root_module.linkSystemLibrary("c", .{});
        b.installArtifact(macos_exe);
    }

    // Unit tests. The monorepo aggregate (zig-forge/build.zig testProgram) runs
    // `zig build test` in this directory; before this step existed that invocation
    // failed because no `test` step was defined.
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const unit_tests = b.addTest(.{ .root_module = test_module });
    unit_tests.root_module.linkSystemLibrary("c", .{});
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
