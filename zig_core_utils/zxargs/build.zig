const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zxargs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    b.installArtifact(exe);

    // `zig build test` — externally-anchored behavior tests.
    // The harness (test/gnu_parity.sh) diffs zxargs live against the system
    // /usr/bin/xargs binary and checks documented GNU findutils exit-status
    // conventions with literal expected codes. See the script header for the
    // anchor provenance. It receives the freshly-built zxargs as argv[1].
    const parity = b.addSystemCommand(&.{"bash"});
    parity.addFileArg(b.path("test/gnu_parity.sh"));
    parity.addFileArg(exe.getEmittedBin());
    // A nonzero exit from the script must fail the build.
    parity.has_side_effects = true;

    const test_step = b.step("test", "Run externally-anchored parity tests");
    test_step.dependOn(&parity.step);
}
