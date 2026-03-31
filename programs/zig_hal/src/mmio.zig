//! Memory-Mapped I/O Utilities
//!
//! Provides type-safe volatile access to hardware registers.
//! All operations use volatile semantics to prevent compiler optimization
//! that could remove or reorder hardware register accesses.
//!
//! The key insight: when you write to a memory address that maps to a hardware
//! register, you're actually sending electrical signals that flip transistor
//! gates in the peripheral circuitry.

const std = @import("std");

/// Register access wrapper that provides type-safe MMIO operations
pub fn Mmio(comptime T: type, comptime addr: usize) type {
    return struct {
        const Self = @This();
        const ptr: *volatile T = @ptrFromInt(addr);

        /// Read the entire register
        pub inline fn read() T {
            return ptr.*;
        }

        /// Write the entire register
        pub inline fn write(value: T) void {
            ptr.* = value;
        }

        /// Read-modify-write: update specific fields while preserving others
        pub inline fn modify(fields: anytype) void {
            var value = ptr.*;
            inline for (@typeInfo(@TypeOf(fields)).@"struct".fields) |field| {
                @field(value, field.name) = @field(fields, field.name);
            }
            ptr.* = value;
        }

        /// Set bits (OR operation)
        pub inline fn setBits(mask: T) void {
            ptr.* = ptr.* | mask;
        }

        /// Clear bits (AND NOT operation)
        pub inline fn clearBits(mask: T) void {
            ptr.* = ptr.* & ~mask;
        }

        /// Toggle bits (XOR operation)
        pub inline fn toggleBits(mask: T) void {
            ptr.* = ptr.* ^ mask;
        }

        /// Get the raw address
        pub inline fn address() usize {
            return addr;
        }
    };
}

/// Register cluster for a peripheral with multiple registers at sequential addresses
pub fn MmioArray(comptime T: type, comptime base: usize, comptime count: usize) type {
    return struct {
        const Self = @This();

        pub inline fn get(index: usize) *volatile T {
            if (index >= count) @panic("MMIO array index out of bounds");
            return @ptrFromInt(base + index * @sizeOf(T));
        }

        pub inline fn read(index: usize) T {
            return get(index).*;
        }

        pub inline fn write(index: usize, value: T) void {
            get(index).* = value;
        }
    };
}

/// Direct volatile write to an address
pub inline fn write(comptime T: type, addr: usize, value: T) void {
    const ptr: *volatile T = @ptrFromInt(addr);
    ptr.* = value;
}

/// Direct volatile read from an address
pub inline fn read(comptime T: type, addr: usize) T {
    const ptr: *volatile T = @ptrFromInt(addr);
    return ptr.*;
}

/// Read-modify-write with field updates
pub inline fn modify(comptime T: type, addr: usize, fields: anytype) void {
    const ptr: *volatile T = @ptrFromInt(addr);
    var value = ptr.*;
    inline for (@typeInfo(@TypeOf(fields)).@"struct".fields) |field| {
        @field(value, field.name) = @field(fields, field.name);
    }
    ptr.* = value;
}

/// Set specific bits at an address
pub inline fn setBits(comptime T: type, addr: usize, mask: T) void {
    const ptr: *volatile T = @ptrFromInt(addr);
    ptr.* = ptr.* | mask;
}

/// Clear specific bits at an address
pub inline fn clearBits(comptime T: type, addr: usize, mask: T) void {
    const ptr: *volatile T = @ptrFromInt(addr);
    ptr.* = ptr.* & ~mask;
}

/// Memory barrier - ensure all previous memory operations complete
pub inline fn memoryBarrier() void {
    asm volatile ("" ::: "memory");
}

/// Data synchronization barrier (ARM)
pub inline fn dsb() void {
    asm volatile ("dsb" ::: "memory");
}

/// Instruction synchronization barrier (ARM)
pub inline fn isb() void {
    asm volatile ("isb" ::: "memory");
}

/// Data memory barrier (ARM)
pub inline fn dmb() void {
    asm volatile ("dmb" ::: "memory");
}

test "Mmio basic operations" {
    // Test compilation - actual hardware tests require real hardware
    const TestReg = packed struct {
        enable: bool,
        mode: u2,
        reserved: u5,
    };

    // Verify type sizes
    try std.testing.expectEqual(@sizeOf(TestReg), 1);
}
