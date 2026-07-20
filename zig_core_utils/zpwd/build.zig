const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zpwd",
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

    const run_step = b.step("run", "Run zpwd");
    run_step.dependOn(&run_cmd.step);

    // Externally-anchored tests: a harness that diffs zpwd against the real
    // GNU coreutils `pwd` binary across a spread of flags / env / cwd cases
    // (see test/gnu_parity.sh). The GNU binary is the external anchor.
    const parity = b.addSystemCommand(&.{"bash"});
    parity.addFileArg(b.path("test/gnu_parity.sh"));
    // Pass the just-built zpwd binary (LazyPath) as the harness argument.
    parity.addArtifactArg(exe);

    const test_step = b.step("test", "Run GNU-parity tests (diff vs real GNU pwd)");
    test_step.dependOn(&parity.step);
}
