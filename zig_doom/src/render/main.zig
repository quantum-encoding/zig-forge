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
const tick = @import("../play/tick.zig");
const mobj_mod = @import("../play/mobj.zig");
const user = @import("../play/user.zig");
const info = @import("../info.zig");

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

    // Static one-shot render: derive the viewpoint from the player-1 start.
    const p1 = level.findPlayer1Start() orelse return false;
    const player_x = Fixed.fromInt(@as(i32, p1.x));
    const player_y = Fixed.fromInt(@as(i32, p1.y));
    const player_z = getPlayerViewZ(level, player_x, player_y);
    const player_angle = degreesToAngle(p1.angle);
    return renderView(w, level, rdata, vid, player_x, player_y, player_z, player_angle, null);
}

/// Render one frame from an explicit viewpoint. The live game calls this every
/// tic with the player mobj's current position/angle, so moving and turning
/// actually change the view. (Previously the live path re-derived a fixed
/// player-1-start viewpoint every frame, freezing the camera at spawn.)
pub fn renderView(
    w: *const Wad,
    level: *const setup.Level,
    rdata: *RenderData,
    vid: *video.VideoState,
    viewx: Fixed,
    viewy: Fixed,
    viewz: Fixed,
    viewangle: Angle,
    player: ?*const user.Player, // for the weapon sprite; null in static renders
) bool {
    // Initialize render state
    var rstate = RenderState.init();
    rstate.setupFrame(viewx, viewy, viewz, viewangle);

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

    // ------------------------------------------------------------------
    // Masked pass: things (sprites), masked mid textures, weapon sprite
    // ------------------------------------------------------------------
    var tstate = things.ThingState.init();

    // Project every live mobj (walk the global thinker list)
    const cap = tick.getThinkerCap();
    var current = cap.next;
    while (current != null and current != cap) {
        const thinker = current.?;
        current = thinker.next;
        if (thinker.function) |func| {
            if (func == @as(tick.ThinkFn, @ptrCast(&mobj_mod.mobjThinker))) {
                const mo: *const mobj_mod.MapObject = @fieldParentPtr("thinker", thinker);
                if (mo.flags & info.MF_NOSECTOR != 0) continue; // not rendered
                const light = sectorLightAt(level, mo.x, mo.y);
                tstate.projectSprite(mo.x, mo.y, mo.z, mo.angle, mo.sprite, mo.frame, mo.flags, light, &rstate, rdata);
            }
        }
    }

    // Draw sprites (clipped against the recorded drawsegs) + masked walls
    tstate.drawMasked(level, &rstate, rdata, screen);

    // Player weapon sprite on top
    if (player) |p| {
        const light = sectorLightAt(level, rstate.viewx, rstate.viewy);
        things.drawPlayerSprites(p, light, &rstate, rdata, screen);
    }

    return true;
}

/// Light level of the sector containing a point (BSP point-location).
fn sectorLightAt(level: *const setup.Level, x: Fixed, y: Fixed) i16 {
    if (level.num_nodes == 0) {
        if (level.subsectors.len > 0) {
            if (level.subsectors[0].sector) |si| {
                if (si < level.sectors.len) return level.sectors[si].lightlevel;
            }
        }
        return 255;
    }
    var node_id: u16 = level.num_nodes - 1;
    while (node_id & defs.NF_SUBSECTOR == 0) {
        if (node_id >= level.nodes.len) return 255;
        const node = &level.nodes[node_id];
        const side = pointOnSide(x, y, node);
        node_id = node.children[side];
    }
    const ssec_idx = node_id & ~defs.NF_SUBSECTOR;
    if (ssec_idx < level.subsectors.len) {
        if (level.subsectors[ssec_idx].sector) |si| {
            if (si < level.sectors.len) return level.sectors[si].lightlevel;
        }
    }
    return 255;
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
