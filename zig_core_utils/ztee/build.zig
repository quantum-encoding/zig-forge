const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "ztee",
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

    const run_step = b.step("run", "Run ztee");
    run_step.dependOn(&run_cmd.step);

    // --- Tests: externally anchored against the real GNU `tee` binary --------

    // Absolute path of the ztee binary the tests will exec.
    const ztee_bin = b.getInstallPath(.bin, "ztee");

    // Discover a GNU `tee` on the build host (Homebrew coreutils). If none is
    // found, the differential parity tests skip gracefully.
    const gtee_bin = findGnuTee() orelse "";

    const options = b.addOptions();
    options.addOption([]const u8, "ztee_bin", ztee_bin);
    options.addOption([]const u8, "gtee_bin", gtee_bin);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/gnu_parity_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addOptions("build_options", options);

    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);
    // The tests exec the installed ztee binary, so it must exist first.
    run_tests.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run GNU-parity tests");
    test_step.dependOn(&run_tests.step);
}

fn findGnuTee() ?[]const u8 {
    const candidates = [_][]const u8{
        "/opt/homebrew/opt/coreutils/libexec/gnubin/tee",
        "/opt/homebrew/bin/gtee",
        "/usr/local/opt/coreutils/libexec/gnubin/tee",
        "/usr/local/bin/gtee",
        "/usr/bin/gtee",
    };
    const io = std.Io.Threaded.global_single_threaded.io();
    for (candidates) |c| {
        std.Io.Dir.cwd().access(io, c, .{}) catch continue;
        return c;
    }
    return null;
}
