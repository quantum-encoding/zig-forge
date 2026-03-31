//! Zig HAL - Hardware Abstraction Layer
//!
//! A bare-metal Zig toolkit for direct hardware register access.
//! Provides type-safe MMIO, packed struct utilities, and target-specific
//! register definitions for popular microcontrollers.
//!
//! Supported Targets:
//!   - STM32F4 (ARM Cortex-M4)
//!   - RP2040 (Raspberry Pi Pico, dual ARM Cortex-M0+)
//!   - ESP32-C3 (RISC-V)
//!
//! Usage:
//!   zig build                     - Build host library and tests
//!   zig build -Dtarget=thumb-freestanding-none  - Build for ARM bare-metal
//!   zig build test                - Run unit tests
//!   zig build example-blink       - Build blink example
//!
//! Integration:
//!   const hal = @import("zig_hal");
//!   const gpio = hal.targets.stm32f4.gpio;
//!   gpio.GPIOA.MODER.modify(.{ .MODER0 = 0b01 });  // Output mode

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ==========================================================================
    // Core HAL Library
    // ==========================================================================
    const hal_module = b.createModule(.{
        .root_source_file = b.path("src/hal.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "zig_hal",
        .root_module = hal_module,
        .linkage = .static,
    });

    b.installArtifact(lib);

    // ==========================================================================
    // ARM Cortex-M4 (STM32F4) Target
    // ==========================================================================
    const stm32f4_target = b.resolveTargetQuery(.{
        .cpu_arch = .thumb,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_m4 },
    });

    const stm32f4_module = b.createModule(.{
        .root_source_file = b.path("src/hal.zig"),
        .target = stm32f4_target,
        .optimize = .ReleaseSmall,
    });

    const stm32f4_lib = b.addLibrary(.{
        .name = "zig_hal",
        .root_module = stm32f4_module,
        .linkage = .static,
    });

    const stm32f4_install = b.addInstallArtifact(stm32f4_lib, .{
        .dest_dir = .{ .override = .{ .custom = "lib/stm32f4" } },
    });

    const stm32f4_step = b.step("stm32f4", "Build for STM32F4 (ARM Cortex-M4)");
    stm32f4_step.dependOn(&stm32f4_install.step);

    // ==========================================================================
    // ARM Cortex-M0+ (RP2040) Target
    // ==========================================================================
    const rp2040_target = b.resolveTargetQuery(.{
        .cpu_arch = .thumb,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_m0plus },
    });

    const rp2040_module = b.createModule(.{
        .root_source_file = b.path("src/hal.zig"),
        .target = rp2040_target,
        .optimize = .ReleaseSmall,
    });

    const rp2040_lib = b.addLibrary(.{
        .name = "zig_hal",
        .root_module = rp2040_module,
        .linkage = .static,
    });

    const rp2040_install = b.addInstallArtifact(rp2040_lib, .{
        .dest_dir = .{ .override = .{ .custom = "lib/rp2040" } },
    });

    const rp2040_step = b.step("rp2040", "Build for RP2040 (Raspberry Pi Pico)");
    rp2040_step.dependOn(&rp2040_install.step);

    // ==========================================================================
    // RISC-V (ESP32-C3) Target
    // ==========================================================================
    const esp32c3_target = b.resolveTargetQuery(.{
        .cpu_arch = .riscv32,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_model = .{ .explicit = &std.Target.riscv.cpu.generic_rv32 },
    });

    const esp32c3_module = b.createModule(.{
        .root_source_file = b.path("src/hal.zig"),
        .target = esp32c3_target,
        .optimize = .ReleaseSmall,
    });

    const esp32c3_lib = b.addLibrary(.{
        .name = "zig_hal",
        .root_module = esp32c3_module,
        .linkage = .static,
    });

    const esp32c3_install = b.addInstallArtifact(esp32c3_lib, .{
        .dest_dir = .{ .override = .{ .custom = "lib/esp32c3" } },
    });

    const esp32c3_step = b.step("esp32c3", "Build for ESP32-C3 (RISC-V)");
    esp32c3_step.dependOn(&esp32c3_install.step);

    // ==========================================================================
    // Examples
    // ==========================================================================

    // Blink example for STM32F4
    const blink_stm32_module = b.createModule(.{
        .root_source_file = b.path("examples/blink_stm32f4.zig"),
        .target = stm32f4_target,
        .optimize = .ReleaseSmall,
    });
    blink_stm32_module.addImport("hal", hal_module);

    const blink_stm32 = b.addExecutable(.{
        .name = "blink_stm32f4",
        .root_module = blink_stm32_module,
    });

    blink_stm32.setLinkerScript(b.path("linker/stm32f4.ld"));

    const blink_stm32_install = b.addInstallArtifact(blink_stm32, .{
        .dest_dir = .{ .override = .{ .custom = "bin/examples" } },
    });

    const blink_step = b.step("example-blink", "Build blink example for STM32F4");
    blink_step.dependOn(&blink_stm32_install.step);

    // ==========================================================================
    // Tests
    // ==========================================================================
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/hal.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run HAL unit tests");
    test_step.dependOn(&run_tests.step);
}
