//! Bitfield Utilities
//!
//! Helpers for creating and manipulating packed structs that map directly
//! to hardware register layouts. In Zig, a `packed struct` guarantees
//! exact bit-level memory layout, making it perfect for hardware registers.
//!
//! When you modify a field in a packed struct that's mapped to a hardware
//! address, you're physically changing the voltage state of transistor gates.

const std = @import("std");

/// Create a register type from a packed struct
/// This adds read/write methods and ensures volatile access
pub fn Register(comptime T: type, comptime addr: usize) type {
    comptime {
        if (@typeInfo(T) != .@"struct") {
            @compileError("Register type must be a struct");
        }
        if (!@typeInfo(T).@"struct".layout == .@"packed") {
            @compileError("Register type must be a packed struct");
        }
    }

    return struct {
        const Self = @This();
        const ptr: *volatile T = @ptrFromInt(addr);

        pub inline fn read() T {
            return ptr.*;
        }

        pub inline fn write(value: T) void {
            ptr.* = value;
        }

        pub inline fn modify(fields: anytype) void {
            var value = ptr.*;
            inline for (@typeInfo(@TypeOf(fields)).@"struct".fields) |field| {
                @field(value, field.name) = @field(fields, field.name);
            }
            ptr.* = value;
        }

        pub inline fn rawAddress() usize {
            return addr;
        }

        pub inline fn rawPtr() *volatile T {
            return ptr;
        }
    };
}

/// Reserved bits placeholder - ensures correct struct size
pub fn Reserved(comptime n: comptime_int) type {
    return std.meta.Int(.unsigned, n);
}

/// Create a bit mask for a range of bits
pub inline fn bitMask(comptime start: u5, comptime end: u5) u32 {
    const width = end - start + 1;
    return ((1 << width) - 1) << start;
}

/// Extract bits from a value
pub inline fn extractBits(value: u32, comptime start: u5, comptime end: u5) u32 {
    return (value >> start) & ((1 << (end - start + 1)) - 1);
}

/// Insert bits into a value
pub inline fn insertBits(value: u32, bits: u32, comptime start: u5, comptime end: u5) u32 {
    const mask = bitMask(start, end);
    return (value & ~mask) | ((bits << start) & mask);
}

/// Commonly used register field types
pub const FieldTypes = struct {
    /// Single bit flag
    pub const Flag = bool;

    /// 2-bit mode selector (common for GPIO)
    pub const Mode2 = u2;

    /// 4-bit nibble
    pub const Nibble = u4;

    /// 8-bit byte field
    pub const Byte = u8;
};

/// GPIO Mode constants (common across ARM chips)
pub const GpioMode = struct {
    pub const Input: u2 = 0b00;
    pub const Output: u2 = 0b01;
    pub const AlternateFunction: u2 = 0b10;
    pub const Analog: u2 = 0b11;
};

/// GPIO Output Type constants
pub const GpioOutputType = struct {
    pub const PushPull: u1 = 0;
    pub const OpenDrain: u1 = 1;
};

/// GPIO Speed constants
pub const GpioSpeed = struct {
    pub const Low: u2 = 0b00;
    pub const Medium: u2 = 0b01;
    pub const High: u2 = 0b10;
    pub const VeryHigh: u2 = 0b11;
};

/// GPIO Pull-up/Pull-down constants
pub const GpioPull = struct {
    pub const None: u2 = 0b00;
    pub const PullUp: u2 = 0b01;
    pub const PullDown: u2 = 0b10;
};

test "bit operations" {
    try std.testing.expectEqual(bitMask(0, 3), 0xF);
    try std.testing.expectEqual(bitMask(4, 7), 0xF0);
    try std.testing.expectEqual(extractBits(0xABCD, 4, 7), 0xC);
    try std.testing.expectEqual(insertBits(0x0000, 0xF, 4, 7), 0xF0);
}
