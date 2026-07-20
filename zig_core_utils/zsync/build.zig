const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zsync",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    b.installArtifact(exe);

    // ---- Tests: GNU-parity, anchored to the real GNU `sync` binary ----
    // Candidate locations for a GNU coreutils `sync` (Homebrew names it
    // `gsync`). The test resolves the first that exists at runtime; if none
    // do, the parity tests skip themselves.
    const gnu_candidates =
        "/opt/homebrew/opt/coreutils/libexec/gnubin/sync:" ++
        "/opt/homebrew/bin/gsync:" ++
        "/usr/local/opt/coreutils/libexec/gnubin/sync:" ++
        "/usr/local/bin/gsync:" ++
        "/usr/bin/sync"; // Linux: system sync is GNU coreutils

    const test_opts = b.addOptions();
    test_opts.addOption([]const u8, "zsync_path", b.getInstallPath(.bin, "zsync"));
    test_opts.addOption([]const u8, "gnu_sync_candidates", gnu_candidates);

    const parity_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gnu_parity_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    parity_test.root_module.addOptions("build_options", test_opts);

    const run_parity = b.addRunArtifact(parity_test);
    // The tests exec the installed zsync binary, so install must run first.
    run_parity.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run GNU-parity tests");
    test_step.dependOn(&run_parity.step);
}
