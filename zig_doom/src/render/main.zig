//! zig_doom/src/render/main.zig
//!
//! Renderer entry point — renders one frame from a player's viewpoint.
//! Translated from: linuxdoom-1.10/r_main.c
//! Original: Copyright (C) 1993-1996 id Software, Inc. GPL-2.0

const std = @import("std");
const fixed = @import("../fixed.zig");
const Fixed = fixed.Fixed;
const Angle = fixed.Angle;
const defs = @import("../defs.zig");
const setup = @import("../play/setup.zig");
const video = @import("../video.zig");
const Wad = @import("../wad.zig").Wad;
const state_mod = @import("state.zig");
const RenderState = state_mod.RenderState;
const bsp = @import("bsp.zig");
const planes = @import("planes.zig");
const things = @import("things.zig");
const sky = @import("sky.zig");
const RenderData = @import("data.zig").RenderData;

pub const SCREENWIDTH = defs.SCREENWIDTH;
pub const SCREENHEIGHT = defs.SCREENHEIGHT;

/// Render a single frame of the given map from the player 1 start position.
/// Returns true on success.
pub fn renderFrame(
    w: *const Wad,
    level: *const setup.Level,
    rdata: *RenderData,
    vid: *video.VideoState,
    alloc: std.mem.Allocator,
) bool {
    _ = alloc;

    // Find player 1 start
    const p1 = level.findPlayer1Start() orelse return false;

    // Convert player position to fixed-point
    const player_x = Fixed.fromInt(@as(i32, p1.x));
    const player_y = Fixed.fromInt(@as(i32, p1.y));
    // Player viewheight is 41 units above floor
    // Find the sector at the player's position to get floor height
    const player_z = getPlayerViewZ(level, player_x, player_y);
    // Player angle: DOOM thing angle is in degrees (0=east, 90=north)
    const player_angle = degreesToAngle(p1.angle);

    // Initialize render state
    var rstate = RenderState.init();
    rstate.setupFrame(player_x, player_y, player_z, player_angle);

    // Initialize plane state
    var pstate = planes.PlaneState.init();
    pstate.clearPlanes();

    // Set sky flat
    sky.initSky(rdata);
    pstate.skyflatnum = sky.getSkyFlatNum(rdata);

    // Resolve texture names
    rdata.resolveNames(level.sides, level.sectors);

    // Clear the framebuffer
    vid.clearScreen(0, 0);

    // Load palette
    if (w.findLump("PLAYPAL")) |pal_lump| {
        vid.loadPalette(w.lumpData(pal_lump));
    }

    // Get screen buffer
    const screen = &vid.screens[0];

    // BSP traversal — renders walls and marks visplanes
    if (level.num_nodes > 0) {
        bsp.renderBSPNode(
            level.num_nodes - 1,
            level,
            &rstate,
            &pstate,
            rdata,
            screen,
        );
    }

    // Draw accumulated floor/ceiling visplanes
    pstate.drawPlanes(rdata, screen, rstate.viewx, rstate.viewy, rstate.viewangle, rstate.viewz);

    // Sprites are not rendered in this minimal version (no mobj_t)
    // but the infrastructure is in place via things.zig

    return true;
}

/// Get player view Z from the subsector's sector floor height + viewheight
fn getPlayerViewZ(level: *const setup.Level, px: Fixed, py: Fixed) Fixed {
    // Walk BSP tree to find subsector at player position
    if (level.num_nodes == 0) {
        // No nodes — single subsector
        if (level.subsectors.len > 0) {
            if (level.subsectors[0].sector) |sec_idx| {
                if (sec_idx < level.sectors.len) {
                    return Fixed.add(level.sectors[sec_idx].floorheight, Fixed.fromInt(41));
                }
            }
        }
        return Fixed.fromInt(41);
    }

    var node_id: u16 = level.num_nodes - 1;
    while (node_id & defs.NF_SUBSECTOR == 0) {
        if (node_id >= level.nodes.len) break;
        const node = &level.nodes[node_id];
        const side = pointOnSide(px, py, node);
        node_id = node.children[side];
    }

    const ssec_idx = node_id & ~defs.NF_SUBSECTOR;
    if (ssec_idx < level.subsectors.len) {
        if (level.subsectors[ssec_idx].sector) |sec_idx| {
            if (sec_idx < level.sectors.len) {
                return Fixed.add(level.sectors[sec_idx].floorheight, Fixed.fromInt(41));
            }
        }
    }

    return Fixed.fromInt(41);
}

fn pointOnSide(x: Fixed, y: Fixed, node: *const setup.Node) usize {
    if (node.dx.raw() == 0) {
        if (x.raw() <= node.x.raw()) {
            return if (node.dy.raw() > 0) @as(usize, 1) else @as(usize, 0);
        }
        return if (node.dy.raw() > 0) @as(usize, 0) else @as(usize, 1);
    }
    if (node.dy.raw() == 0) {
        if (y.raw() <= node.y.raw()) {
            return if (node.dx.raw() < 0) @as(usize, 1) else @as(usize, 0);
        }
        return if (node.dx.raw() < 0) @as(usize, 0) else @as(usize, 1);
    }

    const dx: i64 = x.raw() -% node.x.raw();
    const dy: i64 = y.raw() -% node.y.raw();
    const left: i64 = @as(i64, node.dy.raw()) * dx;
    const right: i64 = dy * @as(i64, node.dx.raw());
    if (right < left) return 0;
    return 1;
}

/// Convert DOOM degrees (0-360, 0=east) to binary angle
fn degreesToAngle(degrees: i16) Angle {
    // DOOM binary angles: 0=east, ANG90=north
    const deg: u32 = @intCast(@mod(@as(i32, degrees), 360));
    return deg *% (0xFFFFFFFF / 360);
}

test "degrees to angle" {
    const a0 = degreesToAngle(0);
    try std.testing.expectEqual(@as(u32, 0), a0);

    const a90 = degreesToAngle(90);
    const diff90 = if (a90 > fixed.ANG90) a90 - fixed.ANG90 else fixed.ANG90 - a90;
    try std.testing.expect(diff90 < 0x1000000); // within ~1.4 degrees

    const a180 = degreesToAngle(180);
    const diff180 = if (a180 > fixed.ANG180) a180 - fixed.ANG180 else fixed.ANG180 - a180;
    try std.testing.expect(diff180 < 0x1000000);
}
