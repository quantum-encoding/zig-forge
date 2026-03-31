//! zig_doom/src/tables.zig
//!
//! Precomputed trigonometric lookup tables.
//! Translated from: linuxdoom-1.10/tables.c, tables.h
//! Original: Copyright (C) 1993-1996 id Software, Inc. GPL-2.0
//!
//! DOOM uses 8192 "fine angles" for a full circle (2*PI).
//! All trig values are in 16.16 fixed-point.
//! Tables generated at comptime to match DOOM's original values.

const std = @import("std");
const fixed = @import("fixed.zig");
const Fixed = fixed.Fixed;

pub const FINEANGLES = 8192;
pub const FINEMASK = FINEANGLES - 1;
pub const ANGLETOFINESHIFT = 19; // ANG(2^32) >> 19 = 8192

// Sine table: 10240 entries = FINEANGLES + FINEANGLES/4
// Extra quarter allows cosine lookup as finesine[angle + FINEANGLES/4]
pub const finesine: [10240]Fixed = generateSineTable();
pub const finecosine: *const [FINEANGLES]Fixed = @ptrCast(&finesine[FINEANGLES / 4]);

// Tangent table: 4096 entries covering -90° to +90°
pub const finetangent: [4096]Fixed = generateTangentTable();

// Inverse tangent: maps slope (0..2048) back to angle
pub const tantoangle: [2049]u32 = generateTanToAngleTable();

fn generateSineTable() [10240]Fixed {
    @setEvalBranchQuota(20000);
    var table: [10240]Fixed = undefined;
    for (0..10240) |i| {
        const angle: f64 = @as(f64, @floatFromInt(i)) * 2.0 * std.math.pi / @as(f64, FINEANGLES);
        const value: f64 = @sin(angle) * 65536.0;
        const rounded: i32 = @intFromFloat(@round(value));
        table[i] = @enumFromInt(rounded);
    }
    return table;
}

fn generateTangentTable() [4096]Fixed {
    @setEvalBranchQuota(200000);
    var table: [4096]Fixed = undefined;
    for (0..4096) |i| {
        // Map index to angle: i=0 is just past +90°, i=2047 is ~0°, i=4095 is just before -90°
        // Original DOOM formula: tan((2048.5 - i) * PI / 4096)
        const angle: f64 = (2048.5 - @as(f64, @floatFromInt(i))) * std.math.pi / 4096.0;
        const value: f64 = @tan(angle) * 65536.0;
        // Clamp to i32 range
        const clamped = std.math.clamp(value, @as(f64, @floatFromInt(std.math.minInt(i32))), @as(f64, @floatFromInt(std.math.maxInt(i32))));
        const rounded: i32 = @intFromFloat(@round(clamped));
        table[i] = @enumFromInt(rounded);
    }
    return table;
}

fn generateTanToAngleTable() [2049]u32 {
    @setEvalBranchQuota(200000);
    var table: [2049]u32 = undefined;
    for (0..2049) |i| {
        // Maps slope i/2048 to binary angle
        const slope: f64 = @as(f64, @floatFromInt(i)) / 2048.0;
        const radians: f64 = std.math.atan(slope);
        // Convert radians to binary angle: full circle = 2^32
        const bam: f64 = radians * (4294967296.0 / (2.0 * std.math.pi));
        table[i] = @intFromFloat(@round(bam));
    }
    return table;
}

/// Look up sine for a binary angle
pub fn sinAngle(angle: u32) Fixed {
    return finesine[angle >> ANGLETOFINESHIFT & FINEMASK];
}

/// Look up cosine for a binary angle
pub fn cosAngle(angle: u32) Fixed {
    return finecosine[angle >> ANGLETOFINESHIFT & FINEMASK];
}

test "sine table sanity" {
    // sin(0) = 0
    try std.testing.expectEqual(@as(i32, 0), finesine[0].raw());

    // sin(90°) = 1.0 = 65536 in fixed point
    // 90° = FINEANGLES/4 = 2048
    try std.testing.expectEqual(@as(i32, 65536), finesine[FINEANGLES / 4].raw());

    // sin(180°) = 0
    const sin180 = finesine[FINEANGLES / 2].raw();
    try std.testing.expect(sin180 >= -1 and sin180 <= 1); // may be ±1 from rounding

    // sin(270°) = -1.0 = -65536
    try std.testing.expectEqual(@as(i32, -65536), finesine[3 * FINEANGLES / 4].raw());
}

test "cosine table sanity" {
    // cos(0) = 1.0 = 65536
    try std.testing.expectEqual(@as(i32, 65536), finecosine[0].raw());

    // cos(90°) ~= 0
    const cos90 = finecosine[FINEANGLES / 4].raw();
    try std.testing.expect(cos90 >= -1 and cos90 <= 1);
}

test "tangent table sanity" {
    // tan at index 2048 should be ~0 (angle ~= 0)
    const tan0 = finetangent[2048].raw();
    try std.testing.expect(tan0 >= -100 and tan0 <= 100);
}

test "tantoangle table sanity" {
    // atan(0) = 0
    try std.testing.expectEqual(@as(u32, 0), tantoangle[0]);
    // atan(1) = 45° = ANG45 = 0x20000000
    const atan1 = tantoangle[2048];
    const diff = if (atan1 > fixed.ANG45) atan1 - fixed.ANG45 else fixed.ANG45 - atan1;
    try std.testing.expect(diff < 0x100000); // within ~0.02°
}
