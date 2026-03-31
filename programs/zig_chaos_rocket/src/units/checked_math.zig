// checked_math.zig — Overflow-checked arithmetic with error returns
//
// ARIANE 5 FLIGHT 501 — June 4, 1996 — $370M lost
//
// The Ariane 5's inertial reference system (SRI) performed a 64-bit float
// to 16-bit integer conversion on the horizontal bias variable. The value
// (32,768.5) exceeded the 16-bit range (max 32,767). In Ada, this raised
// an Operand_Error exception. The handler shut down the SRI. Both redundant
// SRIs had the same code, both crashed. The rocket lost guidance and
// self-destructed 37 seconds after liftoff.
//
// The protection on this variable had been REMOVED to meet a CPU budget.
// Of 7 variables in the alignment code, 4 were analyzed to be safe and
// had protection removed. The horizontal bias was one of them. The analysis
// was correct for Ariane 4's trajectory, but Ariane 5's trajectory produced
// larger values. The code was reused without re-analysis.
//
// In Zig, every function that can fail returns an error union. You CANNOT
// accidentally discard the error. The compiler forces you to handle it.

const std = @import("std");

/// Safe cast from f64 to i16, returning error instead of undefined behavior.
/// This is the EXACT operation that destroyed Ariane 5.
///
/// Ariane 5 Ada code (simplified):
///   P_M_DERIVE(E_BH) := UC_16S_EN_16NS(TDB.T_ENTIER_16S(...))
///   -- No overflow protection! Value: 32,768.5 → OPERAND ERROR → SRI shutdown
///
/// Zig equivalent:
///   const bh = try floatToI16(horizontal_bias);
///   -- Value: 32,768.5 → error.Overflow → caller handles gracefully
pub fn floatToI16(value: f64) error{Overflow}!i16 {
    if (!std.math.isFinite(value)) return error.Overflow;
    if (value > @as(f64, @floatFromInt(@as(i32, std.math.maxInt(i16)))) or
        value < @as(f64, @floatFromInt(@as(i32, std.math.minInt(i16)))))
    {
        return error.Overflow;
    }
    return @intFromFloat(value);
}

/// Safe cast from f64 to i32.
pub fn floatToI32(value: f64) error{Overflow}!i32 {
    if (!std.math.isFinite(value)) return error.Overflow;
    if (value > @as(f64, @floatFromInt(std.math.maxInt(i32))) or
        value < @as(f64, @floatFromInt(std.math.minInt(i32))))
    {
        return error.Overflow;
    }
    return @intFromFloat(value);
}

/// Safe cast between integer sizes.
/// In C, this is silent truncation. In Zig, it's a checked operation.
pub fn safeCast(comptime T: type, value: anytype) error{Overflow}!T {
    return std.math.cast(T, value) orelse error.Overflow;
}

/// Checked addition that returns error on overflow instead of wrapping.
/// In C, signed integer overflow is undefined behavior.
/// In Zig ReleaseSafe, @addWithOverflow is available but we use std.math.add.
pub fn checkedAdd(comptime T: type, a: T, b: T) error{Overflow}!T {
    const result = @addWithOverflow(a, b);
    if (result[1] != 0) return error.Overflow;
    return result[0];
}

/// Checked subtraction.
pub fn checkedSub(comptime T: type, a: T, b: T) error{Overflow}!T {
    const result = @subWithOverflow(a, b);
    if (result[1] != 0) return error.Overflow;
    return result[0];
}

/// Checked multiplication.
pub fn checkedMul(comptime T: type, a: T, b: T) error{Overflow}!T {
    const result = @mulWithOverflow(a, b);
    if (result[1] != 0) return error.Overflow;
    return result[0];
}

/// Checked division (also catches division by zero).
pub fn checkedDiv(comptime T: type, numerator: T, denominator: T) error{ Overflow, DivisionByZero }!T {
    if (denominator == 0) return error.DivisionByZero;
    if (@typeInfo(T) == .int) {
        const info = @typeInfo(T).int;
        if (info.signedness == .signed) {
            if (numerator == std.math.minInt(T) and denominator == -1) return error.Overflow;
        }
    }
    return @divTrunc(numerator, denominator);
}

/// Safe f64 division with NaN/Inf protection.
pub fn safeDivF64(numerator: f64, denominator: f64) error{DivisionByZero}!f64 {
    if (denominator == 0.0 or !std.math.isFinite(denominator)) return error.DivisionByZero;
    const result = numerator / denominator;
    if (!std.math.isFinite(result)) return error.DivisionByZero;
    return result;
}

/// Clamp a float to a safe integer range before casting.
/// Returns the clamped integer value and a flag indicating whether clamping occurred.
pub fn clampedFloatToI16(value: f64) struct { value: i16, clamped: bool } {
    if (!std.math.isFinite(value)) {
        return .{ .value = 0, .clamped = true };
    }
    const max_f: f64 = @floatFromInt(@as(i32, std.math.maxInt(i16)));
    const min_f: f64 = @floatFromInt(@as(i32, std.math.minInt(i16)));
    if (value > max_f) return .{ .value = std.math.maxInt(i16), .clamped = true };
    if (value < min_f) return .{ .value = std.math.minInt(i16), .clamped = true };
    return .{ .value = @intFromFloat(value), .clamped = false };
}

// ============================================================================
// Tests — including the exact Ariane 5 scenario
// ============================================================================

test "Ariane 5 scenario: float 32768.5 to i16 overflows" {
    // This is the exact value that destroyed Ariane 5 Flight 501.
    // The horizontal bias variable reached 32,768.5 during the first
    // 37 seconds of flight. i16 max is 32,767.
    const horizontal_bias: f64 = 32768.5;
    const result = floatToI16(horizontal_bias);
    try std.testing.expectError(error.Overflow, result);
}

test "Ariane 5 scenario: safe value converts correctly" {
    const safe_bias: f64 = 1000.0;
    const result = try floatToI16(safe_bias);
    try std.testing.expectEqual(@as(i16, 1000), result);
}

test "NaN and Inf are rejected" {
    try std.testing.expectError(error.Overflow, floatToI16(std.math.nan(f64)));
    try std.testing.expectError(error.Overflow, floatToI16(std.math.inf(f64)));
    try std.testing.expectError(error.Overflow, floatToI16(-std.math.inf(f64)));
}

test "integer overflow detection" {
    try std.testing.expectError(error.Overflow, checkedAdd(u8, 255, 1));
    try std.testing.expectError(error.Overflow, checkedMul(i16, 200, 200));

    const sum = try checkedAdd(u8, 100, 50);
    try std.testing.expectEqual(@as(u8, 150), sum);
}

test "division by zero caught" {
    try std.testing.expectError(error.DivisionByZero, checkedDiv(i32, 42, 0));
    try std.testing.expectError(error.DivisionByZero, safeDivF64(1.0, 0.0));
}
