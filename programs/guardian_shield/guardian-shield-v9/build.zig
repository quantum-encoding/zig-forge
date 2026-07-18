const std = @import("std");

// Guardian Shield v9 build.
//
// Steps:
//   1. Generate bpf/vmlinux.h from the running kernel BTF (if bpftool present
//      and the file is missing).
//   2. Compile bpf/guardian_shield.bpf.c -> build/guardian_shield.bpf.o with
//      clang -O2 -g -target bpf against vmlinux.h (CO-RE).
//   3. Build the userspace loader (links libbpf) and the C bypass test harness.
//
// `zig build`            -> everything
// `zig build bpf`        -> just the BPF object
// `zig build loader`     -> just the loader
// `zig build test-harness` -> the external-vector bypass tester
pub fn build(b: *std.Build) void {
    // WORKAROUND: target glibc 2.39 to dodge translate-c bugs with newer glibc
    // fortified headers (same as the main guardian_shield build.zig).
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        .abi = .gnu,
        .glibc_version = .{ .major = 2, .minor = 39, .patch = 0 },
    });
    const optimize = b.standardOptimizeOption(.{});

    // ---------------------------------------------------------------
    // 1 + 2: BPF object (clang), with vmlinux.h auto-generation.
    // ---------------------------------------------------------------
    const gen_vmlinux = b.addSystemCommand(&.{
        "sh", "-c",
        \\set -e
        \\cd "$0"
        \\if [ ! -f bpf/vmlinux.h ]; then
        \\  echo "generating bpf/vmlinux.h from kernel BTF...";
        \\  bpftool btf dump file /sys/kernel/btf/vmlinux format c > bpf/vmlinux.h;
        \\fi
    });
    gen_vmlinux.addArg(b.build_root.path orelse ".");

    const bpf_cc = b.addSystemCommand(&.{
        "clang",
        "-O2",
        "-g",
        "-target",
        "bpf",
        "-mcpu=v3",
        "-D__TARGET_ARCH_x86",
        "-Wall",
        "-Wno-missing-declarations",
        "-Wno-pass-failed",
        "-Ibpf",
        "-c",
    });
    bpf_cc.addFileArg(b.path("bpf/guardian_shield.bpf.c"));
    bpf_cc.addArg("-o");
    const bpf_obj = bpf_cc.addOutputFileArg("guardian_shield.bpf.o");
    bpf_cc.step.dependOn(&gen_vmlinux.step);

    // Install the object next to the loader so runtime path resolution finds it.
    const install_obj = b.addInstallBinFile(bpf_obj, "guardian_shield.bpf.o");

    const bpf_step = b.step("bpf", "Compile the BPF object");
    bpf_step.dependOn(&install_obj.step);

    // ---------------------------------------------------------------
    // 3: userspace loader
    // ---------------------------------------------------------------
    const loader_mod = b.createModule(.{
        .root_source_file = b.path("guardian_shield_loader.zig"),
        .target = target,
        .optimize = optimize,
    });
    const loader = b.addExecutable(.{
        .name = "guardian_shield_loader",
        .root_module = loader_mod,
    });
    loader.root_module.link_libc = true;
    loader.root_module.linkSystemLibrary("bpf", .{});
    loader.root_module.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
    loader.root_module.addIncludePath(.{ .cwd_relative = "/usr/include" });
    // Same fortify workaround as the rest of the tree.
    loader.root_module.addCMacro("_FORTIFY_SOURCE", "0");
    b.installArtifact(loader);

    const loader_step = b.step("loader", "Build the userspace loader");
    loader_step.dependOn(&b.addInstallArtifact(loader, .{}).step);

    // ---------------------------------------------------------------
    // External-vector bypass test harness (C, links liburing).
    // ---------------------------------------------------------------
    const harness_mod = b.createModule(.{ .target = target, .optimize = optimize });
    harness_mod.link_libc = true;
    const harness = b.addExecutable(.{
        .name = "gs_bypass_test",
        .root_module = harness_mod,
    });
    harness.root_module.addCSourceFile(.{
        .file = b.path("tests/gs_bypass_test.c"),
        .flags = &.{ "-Wall", "-Wextra", "-D_GNU_SOURCE" },
    });
    harness.root_module.linkSystemLibrary("uring", .{});
    harness.root_module.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
    harness.root_module.addIncludePath(.{ .cwd_relative = "/usr/include" });
    b.installArtifact(harness);

    const harness_step = b.step("test-harness", "Build the external-vector bypass tester");
    harness_step.dependOn(&b.addInstallArtifact(harness, .{}).step);

    // Default: build everything.
    b.getInstallStep().dependOn(&install_obj.step);
}
