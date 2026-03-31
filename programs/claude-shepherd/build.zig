const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main daemon executable (polling-based)
    const exe = b.addExecutable(.{
        .name = "claude-shepherd",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    b.installArtifact(exe);

    // eBPF-enabled daemon (event-driven, requires root)
    const ebpf_exe = b.addExecutable(.{
        .name = "claude-shepherd-ebpf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_ebpf.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    ebpf_exe.root_module.linkSystemLibrary("bpf", .{});
    ebpf_exe.root_module.linkSystemLibrary("elf", .{});
    ebpf_exe.root_module.linkSystemLibrary("z", .{});
    b.installArtifact(ebpf_exe);

    // CLI tool for interacting with daemon
    const cli = b.addExecutable(.{
        .name = "shepherd",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    b.installArtifact(cli);

    // Compile eBPF program
    const bpf_step = b.step("bpf", "Compile eBPF program");
    const bpf_cmd = b.addSystemCommand(&.{
        "clang",
        "-g",
        "-O2",
        "-target",
        "bpf",
        "-D__TARGET_ARCH_x86",
        "-I",
        "src/ebpf",
        "-c",
        "src/ebpf/shepherd.bpf.c",
        "-o",
    });
    const bpf_output = bpf_cmd.addOutputFileArg("shepherd.bpf.o");
    bpf_step.dependOn(&bpf_cmd.step);

    // Install eBPF object
    const install_bpf = b.addInstallFile(bpf_output, "bin/shepherd.bpf.o");
    bpf_step.dependOn(&install_bpf.step);

    // Make eBPF daemon depend on BPF object
    ebpf_exe.step.dependOn(&install_bpf.step);

    // Run commands
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the daemon (polling mode)");
    run_step.dependOn(&run_cmd.step);

    const run_ebpf_cmd = b.addRunArtifact(ebpf_exe);
    run_ebpf_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_ebpf_cmd.addArgs(args);

    const run_ebpf_step = b.step("run-ebpf", "Run the daemon (eBPF mode, requires root)");
    run_ebpf_step.dependOn(&run_ebpf_cmd.step);

    // Tests
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
