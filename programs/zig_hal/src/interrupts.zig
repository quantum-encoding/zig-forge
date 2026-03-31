//! Interrupt Handling
//!
//! Provides utilities for managing hardware interrupts on bare-metal systems.
//! Interrupts are hardware signals that cause the CPU to stop its current
//! execution and jump to a specific handler function.
//!
//! At the transistor level, an interrupt line going high triggers the CPU's
//! interrupt controller to save the current state and load a new program
//! counter from the vector table.

const std = @import("std");

/// Interrupt handler function type
pub const Handler = *const fn () callconv(.c) void;

/// Default handler that loops forever (used for unimplemented interrupts)
pub fn defaultHandler() callconv(.c) void {
    while (true) {
        asm volatile ("nop");
    }
}

/// Hard fault handler - called on unrecoverable errors
pub fn hardFaultHandler() callconv(.c) void {
    while (true) {
        asm volatile ("bkpt #0"); // Trigger debugger breakpoint
    }
}

/// Enable global interrupts
pub inline fn enable() void {
    asm volatile ("cpsie i" ::: "memory");
}

/// Disable global interrupts
pub inline fn disable() void {
    asm volatile ("cpsid i" ::: "memory");
}

/// Check if interrupts are enabled
pub inline fn areEnabled() bool {
    var primask: u32 = undefined;
    asm volatile ("mrs %[primask], primask"
        : [primask] "=r" (primask),
    );
    return primask == 0;
}

/// Critical section guard - disables interrupts and restores on scope exit
pub const CriticalSection = struct {
    saved_state: u32,

    pub fn enter() CriticalSection {
        var primask: u32 = undefined;
        asm volatile ("mrs %[primask], primask"
            : [primask] "=r" (primask),
        );
        disable();
        return .{ .saved_state = primask };
    }

    pub fn leave(self: CriticalSection) void {
        if (self.saved_state == 0) {
            enable();
        }
    }
};

/// Execute a function with interrupts disabled
pub fn withInterruptsDisabled(comptime func: fn () void) void {
    const cs = CriticalSection.enter();
    defer cs.leave();
    func();
}

/// ARM Cortex-M NVIC (Nested Vectored Interrupt Controller) interface
pub const NVIC = struct {
    const NVIC_BASE = 0xE000E100;
    const NVIC_ISER = NVIC_BASE + 0x000; // Interrupt Set Enable
    const NVIC_ICER = NVIC_BASE + 0x080; // Interrupt Clear Enable
    const NVIC_ISPR = NVIC_BASE + 0x100; // Interrupt Set Pending
    const NVIC_ICPR = NVIC_BASE + 0x180; // Interrupt Clear Pending
    const NVIC_IPR = NVIC_BASE + 0x300; // Interrupt Priority

    /// Enable a specific interrupt
    pub fn enableIrq(irq: u8) void {
        const reg_index = irq / 32;
        const bit_index: u5 = @truncate(irq % 32);
        const ptr: *volatile u32 = @ptrFromInt(NVIC_ISER + reg_index * 4);
        ptr.* = @as(u32, 1) << bit_index;
    }

    /// Disable a specific interrupt
    pub fn disableIrq(irq: u8) void {
        const reg_index = irq / 32;
        const bit_index: u5 = @truncate(irq % 32);
        const ptr: *volatile u32 = @ptrFromInt(NVIC_ICER + reg_index * 4);
        ptr.* = @as(u32, 1) << bit_index;
    }

    /// Set interrupt pending
    pub fn setPending(irq: u8) void {
        const reg_index = irq / 32;
        const bit_index: u5 = @truncate(irq % 32);
        const ptr: *volatile u32 = @ptrFromInt(NVIC_ISPR + reg_index * 4);
        ptr.* = @as(u32, 1) << bit_index;
    }

    /// Clear interrupt pending
    pub fn clearPending(irq: u8) void {
        const reg_index = irq / 32;
        const bit_index: u5 = @truncate(irq % 32);
        const ptr: *volatile u32 = @ptrFromInt(NVIC_ICPR + reg_index * 4);
        ptr.* = @as(u32, 1) << bit_index;
    }

    /// Set interrupt priority (0-255, lower = higher priority)
    pub fn setPriority(irq: u8, priority: u8) void {
        const ptr: *volatile u8 = @ptrFromInt(NVIC_IPR + irq);
        ptr.* = priority;
    }
};

/// System Control Block for Cortex-M
pub const SCB = struct {
    const SCB_BASE = 0xE000ED00;

    pub const ICSR = @as(*volatile u32, @ptrFromInt(SCB_BASE + 0x04));
    pub const VTOR = @as(*volatile u32, @ptrFromInt(SCB_BASE + 0x08));
    pub const AIRCR = @as(*volatile u32, @ptrFromInt(SCB_BASE + 0x0C));
    pub const SCR = @as(*volatile u32, @ptrFromInt(SCB_BASE + 0x10));
    pub const CCR = @as(*volatile u32, @ptrFromInt(SCB_BASE + 0x14));

    /// Set the vector table offset
    pub fn setVectorTableOffset(offset: u32) void {
        VTOR.* = offset;
    }

    /// System reset
    pub fn systemReset() noreturn {
        AIRCR.* = 0x05FA0004; // VECTKEY + SYSRESETREQ
        while (true) {}
    }
};

test "interrupt utilities compile" {
    // Compile-time checks only
    _ = CriticalSection;
    _ = NVIC;
    _ = SCB;
}
