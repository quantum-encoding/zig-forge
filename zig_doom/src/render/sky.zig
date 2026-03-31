//! zig_doom/src/render/sky.zig
//!
//! Sky rendering.
//! Translated from: linuxdoom-1.10/r_sky.c, r_sky.h
//! Original: Copyright (C) 1993-1996 id Software, Inc. GPL-2.0
//!
//! The sky is a special texture that wraps around 360 degrees based on viewangle.
//! It is rendered as part of visplane drawing when picnum matches skyflatnum.

const std = @import("std");
const fixed = @import("../fixed.zig");
const Fixed = fixed.Fixed;
const Angle = fixed.Angle;
const defs = @import("../defs.zig");
const RenderData = @import("data.zig").RenderData;

pub const SKYFLATNAME = "F_SKY1\x00\x00";
pub const SKY_TEX_NAME = "SKY1\x00\x00\x00\x00";

/// Sky texture number (in the texture list)
pub var skytexture: i16 = -1;

/// Column offset for sky rendering (changes with viewangle)
pub var skycolumnoffset: i32 = 0;

/// Initialize sky — find the sky texture and flat
pub fn initSky(rdata: *RenderData) void {
    skytexture = rdata.textureNumForName(SKY_TEX_NAME.*);
}

/// Get the sky flat number (used to identify ceiling visplanes as sky)
pub fn getSkyFlatNum(rdata: *const RenderData) i32 {
    return rdata.flatNumForName(SKYFLATNAME.*);
}

/// Calculate sky column from viewangle and screen x position
pub fn skyColumnForX(viewangle: Angle, x: i32) i32 {
    // Sky texture is 256 pixels wide, wraps around full 360
    // viewangle maps to the center of the screen
    // Each screen pixel corresponds to (ANG90/160) angle
    const angle_per_pixel: u32 = fixed.ANG90 / 160;
    const offset: i32 = x - defs.SCREENWIDTH / 2;
    // Use wrapping arithmetic — negative offsets wrap around in u32 angle space
    const col_angle = viewangle +% @as(u32, @bitCast(offset)) *% angle_per_pixel;
    // Map the full 32-bit angle to 0..255 texture column
    return @intCast((col_angle >> 22) & 0xFF);
}

test "sky column wraps" {
    // Opposite sides of the screen should produce different columns
    const left = skyColumnForX(0, 0);
    const right = skyColumnForX(0, defs.SCREENWIDTH - 1);
    try std.testing.expect(left != right);
}

test "sky column at center" {
    // At viewangle 0 and screen center, should be column 0
    const center = skyColumnForX(0, defs.SCREENWIDTH / 2);
    try std.testing.expectEqual(@as(i32, 0), center);
}
