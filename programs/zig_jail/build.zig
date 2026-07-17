const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main zig-jail executable
    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "zig-jail",
        .root_module = exe_module,
        // LLVM backend + LLD — see the note on the test target below (host
        // GCC 16 / glibc crt1.o .sframe defeats Zig 0.16's self-hosted linker).
        .use_llvm = true,
    });

    exe.root_module.link_libc = true;
    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run zig-jail");
    run_step.dependOn(&run_cmd.step);

    // Tests
    const tests_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const unit_tests = b.addTest(.{
        .root_module = tests_module,
        // Force the LLVM backend + LLD: this host's GCC 16 / glibc crt1.o ships an
        // .sframe section whose R_X86_64_PC64 relocation Zig 0.16's self-hosted ELF
        // linker cannot handle (fatal linker error). LLD links it fine. Same fix
        // distributed_kv/build.zig uses.
        .use_llvm = true,
    });

    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
