const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zunexpand",
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

    if (@hasDecl(std.Build.Step.Run, "addPassthruArgs")) run_cmd.addPassthruArgs() else if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run zunexpand");
    run_step.dependOn(&run_cmd.step);

    // --- Tests: GNU-parity vectors that shell out to the built binary and
    //     diff its output against the real GNU `unexpand`. ---
    const build_opts = b.addOptions();
    if (@hasDecl(std.Build, "getInstallPath")) {
        build_opts.addOption([]const u8, "zunexpand_path", b.getInstallPath(.bin, "zunexpand"));
    } else {
        // Zig 0.17: the install prefix is known only at make time, so the path is resolved lazily.
        build_opts.addOptionPathUntracked("zunexpand_path", .{ .relative = .{ .base = .install_bin, .sub_path = "zunexpand" } });
    }

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gnu_parity_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    tests.root_module.addOptions("build_options", build_opts);
    // The tests exec the installed binary, so make sure it is built first.
    tests.step.dependOn(b.getInstallStep());

    const run_tests = b.addRunArtifact(tests);
    run_tests.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run GNU-parity tests");
    test_step.dependOn(&run_tests.step);
}
