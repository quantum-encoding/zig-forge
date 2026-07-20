const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "ztr",
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
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run ztr");
    run_step.dependOn(&run_cmd.step);

    // Externally-anchored GNU-parity tests: diff ztr's output against the real
    // GNU `tr` binary across the translate / delete / squeeze / complement /
    // class / escape / repeat / error matrix (tests/gnu_parity.sh). The just-
    // built binary path is passed as the script's argument.
    const parity = b.addSystemCommand(&.{"bash"});
    parity.addFileArg(b.path("tests/gnu_parity.sh"));
    parity.addArtifactArg(exe);
    // Reruns whenever the binary or the script changes.
    parity.has_side_effects = true;

    const test_step = b.step("test", "Run GNU-parity tests against the real GNU tr");
    test_step.dependOn(&parity.step);
}
