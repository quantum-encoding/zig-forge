//! Zig HAL - Hardware Abstraction Layer
//!
//! Provides type-safe access to hardware registers through:
//! - Memory-Mapped I/O (MMIO) utilities
//! - Packed struct definitions for bit-level control
//! - Target-specific register definitions
//!
//! Example:
//! ```zig
//! const hal = @import("hal");
//! const gpio = hal.stm32f4.gpio;
//!
//! // Set PA5 as output (LED on Nucleo board)
//! gpio.GPIOA.MODER.modify(.{ .MODER5 = 0b01 });
//! gpio.GPIOA.ODR.modify(.{ .ODR5 = 1 });
//! ```

pub const mmio = @import("mmio.zig");
pub const bitfield = @import("bitfield.zig");
pub const interrupts = @import("interrupts.zig");
pub const startup = @import("startup.zig");

// Target-specific HAL implementations
pub const stm32f4 = @import("targets/stm32f4.zig");
pub const rp2040 = @import("targets/rp2040.zig");
pub const esp32c3 = @import("targets/esp32c3.zig");

/// Volatile write to a memory-mapped register
pub inline fn write(comptime T: type, addr: usize, value: T) void {
    mmio.write(T, addr, value);
}

/// Volatile read from a memory-mapped register
pub inline fn read(comptime T: type, addr: usize) T {
    return mmio.read(T, addr);
}

/// Modify specific bits in a register using a packed struct
pub inline fn modify(comptime T: type, addr: usize, fields: anytype) void {
    mmio.modify(T, addr, fields);
}

/// Busy-wait delay (cycle-approximate)
pub fn delay(cycles: u32) void {
    var i: u32 = 0;
    while (i < cycles) : (i += 1) {
        asm volatile ("nop");
    }
}

/// Millisecond delay (assumes 16MHz clock by default)
pub fn delayMs(ms: u32) void {
    delay(ms * 16000);
}

test "hal module compiles" {
    _ = mmio;
    _ = bitfield;
}

// Import comprehensive test module
test {
    _ = @import("tests.zig");
    _ = @import("bench.zig");
}
