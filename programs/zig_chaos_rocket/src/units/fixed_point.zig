// fixed_point.zig — Fixed-point arithmetic for deterministic computation
//
// PATRIOT MISSILE — February 25, 1991 — 28 soldiers killed
//
// The Patriot missile battery in Dhahran tracked time using a 24-bit counter
// incremented every 0.1 seconds. The counter was multiplied by 0.1 (1/10)
// to get seconds — but 1/10 is a repeating binary fraction:
//   0.1 (decimal) = 0.0001100110011... (binary, repeating)
//
// The system truncated to 24 bits, introducing ~0.000000095 sec error per tick.
// After 100 hours of continuous operation: 0.000000095 * 10 * 100 * 3600 = 0.34 sec.
// A Scud missile travels 1,676 m in 0.34 seconds. The tracking gate was off
// by half a kilometer. The Patriot didn't fire.
//
// Lesson: Never accumulate time with floating-point arithmetic.
// Use integer tick counters for all time-critical operations.

const std = @import("std");
const checked_math = @import("checked_math.zig");

/// Fixed-point number with configurable fractional bits.
/// All arithmetic is exact (no floating-point rounding).
pub fn FixedPoint(comptime frac_bits: u8) type {
    return struct {
        raw: i64, // Scaled integer representation

        const Self = @This();
        const SCALE: i64 = @as(i64, 1) << frac_bits;
        const SCALE_F: f64 = @floatFromInt(SCALE);

        pub fn fromInt(val: i64) Self {
            return .{ .raw = val << frac_bits };
        }

        pub fn fromFloat(val: f64) Self {
            return .{ .raw = @intFromFloat(val * SCALE_F) };
        }

        pub fn toFloat(self: Self) f64 {
            return @as(f64, @floatFromInt(self.raw)) / SCALE_F;
        }

        pub fn toInt(self: Self) i64 {
            return self.raw >> frac_bits;
        }

        pub fn add(a: Self, b: Self) error{Overflow}!Self {
            const raw = try checked_math.checkedAdd(i64, a.raw, b.raw);
            return .{ .raw = raw };
        }

        pub fn sub(a: Self, b: Self) error{Overflow}!Self {
            const raw = try checked_math.checkedSub(i64, a.raw, b.raw);
            return .{ .raw = raw };
        }

        pub fn mul(a: Self, b: Self) error{Overflow}!Self {
            // Multiply then shift back to maintain scale
            const wide_a: i128 = a.raw;
            const wide_b: i128 = b.raw;
            const product = wide_a * wide_b;
            const shifted = product >> frac_bits;
            if (shifted > std.math.maxInt(i64) or shifted < std.math.minInt(i64)) {
                return error.Overflow;
            }
            return .{ .raw = @intCast(shifted) };
        }

        pub fn div(a: Self, b: Self) error{ Overflow, DivisionByZero }!Self {
            if (b.raw == 0) return error.DivisionByZero;
            const wide_a: i128 = @as(i128, a.raw) << frac_bits;
            const result = @divTrunc(wide_a, @as(i128, b.raw));
            if (result > std.math.maxInt(i64) or result < std.math.minInt(i64)) {
                return error.Overflow;
            }
            return .{ .raw = @intCast(result) };
        }

        pub fn lessThan(a: Self, b: Self) bool {
            return a.raw < b.raw;
        }

        pub fn greaterThan(a: Self, b: Self) bool {
            return a.raw > b.raw;
        }

        pub fn eql(a: Self, b: Self) bool {
            return a.raw == b.raw;
        }
    };
}

/// Mission Elapsed Time — integer tick counter, NEVER floating point.
///
/// This is the Patriot lesson. We count ticks. Period.
/// The conversion to seconds is ONLY for display, NEVER for computation.
pub const MissionElapsedTime = struct {
    ticks: u64 = 0,
    ticks_per_second: u64,

    pub fn init(tps: u64) MissionElapsedTime {
        return .{ .ticks = 0, .ticks_per_second = tps };
    }

    pub fn advance(self: *MissionElapsedTime, delta_ticks: u64) error{Overflow}!void {
        self.ticks = try checked_math.checkedAdd(u64, self.ticks, delta_ticks);
    }

    /// For display ONLY. Never use this value for control logic.
    pub fn toSecondsDisplay(self: MissionElapsedTime) f64 {
        return @as(f64, @floatFromInt(self.ticks)) / @as(f64, @floatFromInt(self.ticks_per_second));
    }

    /// Integer seconds (truncated) — safe for comparison
    pub fn wholeSeconds(self: MissionElapsedTime) u64 {
        return self.ticks / self.ticks_per_second;
    }

    /// Format as MM:SS.mmm
    pub fn format(self: MissionElapsedTime, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        const total_ms = (self.ticks * 1000) / self.ticks_per_second;
        const secs = total_ms / 1000;
        const ms = total_ms % 1000;
        const mins = secs / 60;
        const s = secs % 60;
        try writer.print("{d:0>2}:{d:0>2}.{d:0>3}", .{ mins, s, ms });
    }
};

// Fixed16 = 16 fractional bits (Q47.16), about 0.0000153 resolution
pub const Fixed16 = FixedPoint(16);
// Fixed32 = 32 fractional bits (Q31.32), about 2.33e-10 resolution
pub const Fixed32 = FixedPoint(32);

test "fixed point basic arithmetic" {
    const a = Fixed16.fromFloat(3.14);
    const b = Fixed16.fromFloat(2.0);
    const sum = try a.add(b);
    try std.testing.expectApproxEqAbs(5.14, sum.toFloat(), 0.001);
}

test "fixed point multiplication" {
    const a = Fixed16.fromFloat(3.0);
    const b = Fixed16.fromFloat(4.0);
    const product = try a.mul(b);
    try std.testing.expectApproxEqAbs(12.0, product.toFloat(), 0.001);
}

test "fixed point division by zero" {
    const a = Fixed16.fromFloat(1.0);
    const b = Fixed16.fromInt(0);
    try std.testing.expectError(error.DivisionByZero, a.div(b));
}

test "mission elapsed time - Patriot scenario" {
    // Simulate the Patriot's 100-hour uptime
    var met = MissionElapsedTime.init(10); // 10 ticks per second (simplified)

    // Advance 100 hours worth of ticks
    const ticks_100hrs = 100 * 3600 * 10;
    try met.advance(ticks_100hrs);

    // Integer time: exact. No drift. Period.
    try std.testing.expectEqual(@as(u64, 3600000), met.ticks);
    try std.testing.expectEqual(@as(u64, 360000), met.wholeSeconds());

    // The float display has rounding, but it's NEVER used for control
    const display_secs = met.toSecondsDisplay();
    try std.testing.expectApproxEqAbs(360000.0, display_secs, 0.001);
}
