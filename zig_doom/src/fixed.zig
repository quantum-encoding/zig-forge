//! zig_doom/src/fixed.zig
//!
//! Fixed-point 16.16 arithmetic.
//! Translated from: linuxdoom-1.10/m_fixed.c, m_fixed.h
//! Original: Copyright (C) 1993-1996 id Software, Inc. GPL-2.0

const std = @import("std");

pub const FRAC_BITS = 16;
pub const FRAC_UNIT: Fixed = @enumFromInt(1 << FRAC_BITS);
pub const FRAC_MASK: i32 = (1 << FRAC_BITS) - 1;

pub const Fixed = enum(i32) {
    _,

    pub fn fromInt(v: i32) Fixed {
        return @enumFromInt(v << FRAC_BITS);
    }

    pub fn toInt(self: Fixed) i32 {
        return @intFromEnum(self) >> FRAC_BITS;
    }

    pub fn raw(self: Fixed) i32 {
        return @intFromEnum(self);
    }

    pub fn fromRaw(v: i32) Fixed {
        return @enumFromInt(v);
    }

    pub fn add(a: Fixed, b: Fixed) Fixed {
        return @enumFromInt(@intFromEnum(a) +% @intFromEnum(b));
    }

    pub fn sub(a: Fixed, b: Fixed) Fixed {
        return @enumFromInt(@intFromEnum(a) -% @intFromEnum(b));
    }

    pub fn mul(a: Fixed, b: Fixed) Fixed {
        const wide: i64 = @as(i64, @intFromEnum(a)) * @intFromEnum(b);
        return @enumFromInt(@as(i32, @truncate(wide >> FRAC_BITS)));
    }

    pub fn div(a: Fixed, b: Fixed) Fixed {
        const bv = @intFromEnum(b);
        if (bv == 0) {
            const av = @intFromEnum(a);
            return if (av >= 0) @enumFromInt(@as(i32, std.math.maxInt(i32))) else @enumFromInt(@as(i32, std.math.minInt(i32)));
        }
        const wide: i64 = @as(i64, @intFromEnum(a)) << FRAC_BITS;
        return @enumFromInt(@as(i32, @truncate(@divTrunc(wide, @as(i64, bv)))));
    }

    pub fn negate(self: Fixed) Fixed {
        return @enumFromInt(-%@intFromEnum(self));
    }

    pub fn abs(self: Fixed) Fixed {
        const v = @intFromEnum(self);
        return @enumFromInt(if (v < 0) -v else v);
    }

    pub fn eql(a: Fixed, b: Fixed) bool {
        return @intFromEnum(a) == @intFromEnum(b);
    }

    pub fn lt(a: Fixed, b: Fixed) bool {
        return @intFromEnum(a) < @intFromEnum(b);
    }

    pub fn gt(a: Fixed, b: Fixed) bool {
        return @intFromEnum(a) > @intFromEnum(b);
    }

    pub fn le(a: Fixed, b: Fixed) bool {
        return @intFromEnum(a) <= @intFromEnum(b);
    }

    pub fn ge(a: Fixed, b: Fixed) bool {
        return @intFromEnum(a) >= @intFromEnum(b);
    }

    pub const ZERO: Fixed = @enumFromInt(0);
    pub const ONE: Fixed = @enumFromInt(1 << FRAC_BITS);
    pub const MAX: Fixed = @enumFromInt(std.math.maxInt(i32));
    pub const MIN: Fixed = @enumFromInt(std.math.minInt(i32));
};

// Angle type — full circle is 0x100000000 (wrapping u32)
pub const Angle = u32;
pub const ANG45: Angle = 0x20000000;
pub const ANG90: Angle = 0x40000000;
pub const ANG180: Angle = 0x80000000;
pub const ANG270: Angle = 0xC0000000;

test "fixed point basic ops" {
    const a = Fixed.fromInt(3); // 3.0
    const b = Fixed.fromInt(2); // 2.0

    try std.testing.expectEqual(@as(i32, 5), Fixed.add(a, b).toInt());
    try std.testing.expectEqual(@as(i32, 1), Fixed.sub(a, b).toInt());
    try std.testing.expectEqual(@as(i32, 6), Fixed.mul(a, b).toInt());
    try std.testing.expectEqual(@as(i32, 1), Fixed.div(a, b).toInt());
}

test "fixed point fractional mul" {
    // 1.5 * 2.0 = 3.0
    const a: Fixed = @enumFromInt((1 << FRAC_BITS) + (1 << (FRAC_BITS - 1))); // 1.5
    const b = Fixed.fromInt(2);
    try std.testing.expectEqual(@as(i32, 3), Fixed.mul(a, b).toInt());
}

test "fixed point div by zero" {
    const a = Fixed.fromInt(5);
    const zero = Fixed.ZERO;
    try std.testing.expectEqual(Fixed.MAX, Fixed.div(a, zero));
    try std.testing.expectEqual(Fixed.MIN, Fixed.div(Fixed.fromInt(-5), zero));
}

test "fixed point wrapping overflow" {
    const big = Fixed.MAX;
    const one = Fixed.ONE;
    // Wrapping add should not panic — MAX (0x7FFFFFFF) + ONE (0x10000) wraps
    const result = Fixed.add(big, one);
    const expected: i32 = @as(i32, std.math.maxInt(i32)) +% (1 << FRAC_BITS);
    try std.testing.expectEqual(@as(Fixed, @enumFromInt(expected)), result);
}
