//! Constructor-argument sanitization shared by every limiter.
//!
//! Constructors in this library are infallible by contract (they return `Self`,
//! not an error union) because in-tree consumers such as `zig_token_service`
//! call them without a `try`. Rather than crash on nonsensical configuration —
//! a `rate` of 0 read from a config file becomes `1e9/0 = inf` and traps in
//! `@intFromFloat` (a safety panic in Debug, illegal behaviour in ReleaseFast)
//! — invalid inputs are clamped to a safe value and documented.
//!
//! Every clamp here is **fail-closed**: a clamped limiter admits *less* traffic,
//! never more. Clamping can only tighten a rate limit, which is the safe
//! failure direction for a security-relevant component.

const std = @import("std");

/// Minimum admissible refill/leak rate (units per second). Non-positive or
/// non-finite rates (0, negative, NaN, +inf) clamp to this so `1e9/rate`
/// (nanoseconds per unit) stays finite and never traps in `@intFromFloat`.
/// ~1 unit per 31.7 years — effectively "no refill", the fail-closed choice.
pub const MIN_RATE: f64 = 1e-9;

/// Maximum admissible capacity (burst size). Keeps token math inside f64's
/// exact-integer range and bounds the nanosecond burst-tolerance so it cannot
/// overflow. +inf / oversized capacities clamp here; NaN / negative capacities
/// clamp to 0 (a bucket that admits nothing).
pub const MAX_CAPACITY: f64 = 1e15;

/// Clamp a rate to a strictly-positive, finite value.
/// Rejects 0, negatives, NaN and +inf (all → `MIN_RATE`).
pub fn sanitizeRate(rate: f64) f64 {
    if (!(rate > 0) or !std.math.isFinite(rate)) return MIN_RATE;
    return rate;
}

/// Clamp a capacity to `[0, MAX_CAPACITY]`. NaN / negative → 0 (fail-closed).
pub fn sanitizeCapacity(capacity: f64) f64 {
    if (std.math.isNan(capacity) or capacity < 0) return 0;
    if (capacity > MAX_CAPACITY) return MAX_CAPACITY;
    return capacity;
}

/// Saturating f64 → i64 conversion.
///
/// `@intFromFloat` is illegal behaviour when the value does not fit the target
/// integer, and clamping the *inputs* is not sufficient on its own: a legal
/// clamped rate of `MIN_RATE` with a large burst still makes
/// `burst * 1e9 / rate` reach ~1e24, far past `maxInt(i64)` (~9.2e18).
/// NaN saturates to maxInt (fail-closed: a bogus arrival time reads as "far
/// future", so the limiter stays shut).
pub fn satToI64(x: f64) i64 {
    if (std.math.isNan(x)) return std.math.maxInt(i64);
    const max_f: f64 = @floatFromInt(std.math.maxInt(i64));
    const min_f: f64 = @floatFromInt(std.math.minInt(i64));
    if (x >= max_f) return std.math.maxInt(i64);
    if (x <= min_f) return std.math.minInt(i64);
    return @intFromFloat(x);
}

/// Saturating i128 → i64 conversion, used to narrow the clock's nanosecond
/// reading. Lossless for every real monotonic value (a CLOCK_MONOTONIC ns count
/// is ~1e15 for a machine up years); saturates rather than trapping if a test
/// clock is advanced past the i64 range. Kept integer-only — routing through
/// f64 would silently round above 2^53.
pub fn satI128ToI64(x: i128) i64 {
    if (x > std.math.maxInt(i64)) return std.math.maxInt(i64);
    if (x < std.math.minInt(i64)) return std.math.minInt(i64);
    return @intCast(x);
}

test "satI128ToI64 saturates at the i64 bounds" {
    try std.testing.expectEqual(@as(i64, 0), satI128ToI64(0));
    try std.testing.expectEqual(@as(i64, 1_700_000_000_000_000_000), satI128ToI64(1_700_000_000_000_000_000));
    try std.testing.expectEqual(std.math.maxInt(i64), satI128ToI64(@as(i128, std.math.maxInt(i64)) + 1));
    try std.testing.expectEqual(std.math.minInt(i64), satI128ToI64(@as(i128, std.math.minInt(i64)) - 1));
}

test "sanitizeRate rejects non-positive and non-finite" {
    try std.testing.expectEqual(MIN_RATE, sanitizeRate(0));
    try std.testing.expectEqual(MIN_RATE, sanitizeRate(-1));
    try std.testing.expectEqual(MIN_RATE, sanitizeRate(std.math.nan(f64)));
    try std.testing.expectEqual(MIN_RATE, sanitizeRate(std.math.inf(f64)));
    try std.testing.expectEqual(MIN_RATE, sanitizeRate(-std.math.inf(f64)));
    try std.testing.expectEqual(@as(f64, 100), sanitizeRate(100));
}

test "sanitizeCapacity clamps to [0, MAX_CAPACITY]" {
    try std.testing.expectEqual(@as(f64, 0), sanitizeCapacity(-5));
    try std.testing.expectEqual(@as(f64, 0), sanitizeCapacity(std.math.nan(f64)));
    try std.testing.expectEqual(MAX_CAPACITY, sanitizeCapacity(std.math.inf(f64)));
    try std.testing.expectEqual(MAX_CAPACITY, sanitizeCapacity(1e30));
    try std.testing.expectEqual(@as(f64, 42), sanitizeCapacity(42));
}

test "satToI64 saturates instead of trapping" {
    try std.testing.expectEqual(std.math.maxInt(i64), satToI64(std.math.inf(f64)));
    try std.testing.expectEqual(std.math.maxInt(i64), satToI64(std.math.nan(f64)));
    try std.testing.expectEqual(std.math.minInt(i64), satToI64(-std.math.inf(f64)));
    // The concrete overflow the input clamps do NOT prevent:
    // burst 100 with the clamped MIN_RATE => 100 * 1e9 / 1e-9 = 1e20.
    try std.testing.expectEqual(std.math.maxInt(i64), satToI64(100.0 * 1_000_000_000.0 / MIN_RATE));
    try std.testing.expectEqual(@as(i64, 1_500), satToI64(1500.7));
}
