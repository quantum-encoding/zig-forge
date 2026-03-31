//! Startup Code for Bare-Metal Systems
//!
//! This module provides the reset handler and vector table for ARM Cortex-M
//! microcontrollers. When power is applied to the chip:
//!
//! 1. The CPU loads the initial stack pointer from address 0x00000000
//! 2. The CPU loads the reset vector from address 0x00000004
//! 3. Execution begins at the reset handler
//!
//! The reset handler:
//! - Initializes .data section (copies initialized data from flash to RAM)
//! - Zeroes .bss section (uninitialized global variables)
//! - Calls main()

const std = @import("std");
const interrupts = @import("interrupts.zig");

/// Linker-provided symbols
extern const __data_start: u32;
extern const __data_end: u32;
extern const __data_load: u32;
extern const __bss_start: u32;
extern const __bss_end: u32;
extern const __stack_top: u32;

/// User's main function
extern fn main() noreturn;

/// Reset handler - first code to run after power-on
export fn _reset() callconv(.c) noreturn {
    // Initialize .data section (copy from flash to RAM)
    const data_start: [*]u32 = @ptrCast(&__data_start);
    const data_end: [*]u32 = @ptrCast(&__data_end);
    const data_load: [*]const u32 = @ptrCast(&__data_load);

    const data_len = @intFromPtr(data_end) - @intFromPtr(data_start);
    const data_words = data_len / 4;

    for (0..data_words) |i| {
        data_start[i] = data_load[i];
    }

    // Zero .bss section
    const bss_start: [*]u32 = @ptrCast(&__bss_start);
    const bss_end: [*]u32 = @ptrCast(&__bss_end);

    const bss_len = @intFromPtr(bss_end) - @intFromPtr(bss_start);
    const bss_words = bss_len / 4;

    for (0..bss_words) |i| {
        bss_start[i] = 0;
    }

    // Call user's main
    main();
}

/// Vector table for ARM Cortex-M
/// Placed at the start of flash memory (address 0x00000000 or remapped)
pub const VectorTable = extern struct {
    initial_sp: u32,
    reset: interrupts.Handler,
    nmi: interrupts.Handler = interrupts.defaultHandler,
    hard_fault: interrupts.Handler = interrupts.hardFaultHandler,
    mem_manage: interrupts.Handler = interrupts.defaultHandler,
    bus_fault: interrupts.Handler = interrupts.defaultHandler,
    usage_fault: interrupts.Handler = interrupts.defaultHandler,
    reserved1: [4]u32 = .{ 0, 0, 0, 0 },
    sv_call: interrupts.Handler = interrupts.defaultHandler,
    debug_monitor: interrupts.Handler = interrupts.defaultHandler,
    reserved2: u32 = 0,
    pend_sv: interrupts.Handler = interrupts.defaultHandler,
    sys_tick: interrupts.Handler = interrupts.defaultHandler,
    // IRQ handlers follow...
};

/// Default vector table instance
/// Users can create their own with custom handlers
pub const vector_table: VectorTable linksection(".vector_table") = .{
    .initial_sp = @intFromPtr(&__stack_top),
    .reset = _reset,
};

/// Minimal panic handler for bare-metal
pub fn panic(msg: []const u8, stack_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    _ = msg;
    _ = stack_trace;
    _ = ret_addr;

    // Disable interrupts
    interrupts.disable();

    // Infinite loop with breakpoint
    while (true) {
        asm volatile ("bkpt #0");
    }
}

test "startup module compiles" {
    _ = VectorTable;
}
