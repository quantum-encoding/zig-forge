//! zig_doom/src/tables.zig
//!
//! Precomputed trigonometric lookup tables.
//! Translated from: linuxdoom-1.10/tables.c, tables.h
//! Original: Copyright (C) 1993-1996 id Software, Inc. GPL-2.0
//!
//! DOOM uses 8192 "fine angles" for a full circle (2*PI).
//! All trig values are in 16.16 fixed-point.
//!
//! The values are the LITERAL vanilla tables (tables_data.zig) — demo sync
//! requires byte-exact values; id generated them with an (i+0.5) phase
//! offset whose rounding a recomputed table cannot reproduce.
//!
//! NOTE finetangent uses VANILLA indexing: finetangent[i] = tan((i-2048+0.5)
//! * pi/4096), i.e. index 0 is just past -90° and 4095 just before +90°.
//! For a signed view-relative angle θ: tan(θ) = finetangent[2048 + (θ>>19)].

const std = @import("std");
const fixed = @import("fixed.zig");
const Fixed = fixed.Fixed;
const data = @import("tables_data.zig");

pub const FINEANGLES = 8192;
pub const FINEMASK = FINEANGLES - 1;
pub const ANGLETOFINESHIFT = 19; // ANG(2^32) >> 19 = 8192

// Sine table: 10240 entries = FINEANGLES + FINEANGLES/4
// Extra quarter allows cosine lookup as finesine[angle + FINEANGLES/4]
pub const finesine: [10240]Fixed = fixedFromData(10240, data.finesine_data);
pub const finecosine: *const [FINEANGLES]Fixed = @ptrCast(&finesine[FINEANGLES / 4]);

// Tangent table: 4096 entries covering -90° to +90° (vanilla indexing)
pub const finetangent: [4096]Fixed = fixedFromData(4096, data.finetangent_data);

// Inverse tangent: maps slope (0..2048) back to angle
pub const tantoangle: [2049]u32 = data.tantoangle_data;

fn fixedFromData(comptime n: usize, comptime src: [n]i32) [n]Fixed {
    @setEvalBranchQuota(60000);
    var table: [n]Fixed = undefined;
    for (0..n) |i| {
        table[i] = @enumFromInt(src[i]);
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
    // VANILLA literals: the table is generated with an (i + 0.5) angle
    // offset, so sin(0) is 25, not 0, and the peak is 65535, not 65536.
    try std.testing.expectEqual(@as(i32, 25), finesine[0].raw());
    try std.testing.expectEqual(@as(i32, 65535), finesine[FINEANGLES / 4].raw());

    // sin(180°) ~= 0 (off by the half-step)
    const sin180 = finesine[FINEANGLES / 2].raw();
    try std.testing.expect(sin180 >= -26 and sin180 <= 26);

    // sin(270°) = -65535 (vanilla literal)
    try std.testing.expectEqual(@as(i32, -65535), finesine[3 * FINEANGLES / 4].raw());
}

test "cosine table sanity" {
    // cos(0) = vanilla 65535 (half-step offset)
    try std.testing.expectEqual(@as(i32, 65535), finecosine[0].raw());

    // cos(90°) ~= 0
    const cos90 = finecosine[FINEANGLES / 4].raw();
    try std.testing.expect(cos90 >= -26 and cos90 <= 26);
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
