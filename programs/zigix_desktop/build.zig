const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const is_freestanding = target.result.os.tag == .freestanding;

    if (is_freestanding) {
        // ── Zigix freestanding build ─────────────────────────────────────────
        // No libc, no terminal_mux — pure syscall-based desktop.
        // Uses tui_pure.zig instead of zig_tui.
        // Link against Zigix userspace syscall lib.

        const sys_mod = b.createModule(.{
            .root_source_file = b.path("../../zigix/userspace/lib/sys.zig"),
            .target = target,
            .optimize = optimize,
        });

        const exe = b.addExecutable(.{
            .name = "zigix-desktop",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "sys", .module = sys_mod },
                },
            }),
            .use_lld = true,
            .use_llvm = true,
        });

        // Use the RISC-V or architecture-appropriate linker script
        const arch = target.result.cpu.arch;
        if (arch == .riscv64) {
            exe.setLinkerScript(b.path("../../zigix/userspace/lib/linker-riscv64.ld"));
        } else if (arch == .aarch64) {
            exe.setLinkerScript(b.path("../../zigix/userspace/lib/linker-aarch64.ld"));
        }
        // x86_64 uses default linker

        b.installArtifact(exe);
    } else {
        // ── Linux/macOS hosted build ─────────────────────────────────────────
        // Full zig_tui + terminal_mux with libc.

        const tui_mod = b.createModule(.{
            .root_source_file = b.path("../zig_tui/src/lib.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });

        const mux_mod = b.createModule(.{
            .root_source_file = b.path("../terminal_mux/src/lib.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });

        const exe = b.addExecutable(.{
            .name = "zigix-desktop",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        exe.root_module.addImport("zig_tui", tui_mod);
        exe.root_module.addImport("terminal_mux", mux_mod);
        b.installArtifact(exe);

        // Run step
        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
        const run_step = b.step("run", "Run the Zigix TUI desktop environment");
        run_step.dependOn(&run_cmd.step);
    }
}
