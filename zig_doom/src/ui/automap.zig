//! zig_doom/src/ui/automap.zig
//!
//! Automap — overhead view of level geometry.
//! Translated from: linuxdoom-1.10/am_map.c
//! Original: Copyright (C) 1993-1996 id Software, Inc. GPL-2.0
//!
//! Draws linedefs as colored lines, player arrow, and optionally things.

const std = @import("std");
const defs = @import("../defs.zig");
const fixed = @import("../fixed.zig");
const Fixed = fixed.Fixed;
const Angle = fixed.Angle;
const video = @import("../video.zig");
const setup = @import("../play/setup.zig");
const Level = setup.Level;
const user = @import("../play/user.zig");
const Player = user.Player;
const event = @import("../event.zig");
const Event = event.Event;
const tables = @import("../tables.zig");

// Colors (palette indices for DOOM's default palette)
const COLOR_WALL = 176; // Red — one-sided walls
const COLOR_FLOOR_CHANGE = 64; // Brown — two-sided, floor change
const COLOR_CEILING_CHANGE = 231; // Yellow — two-sided, ceiling change
const COLOR_TWO_SIDED = 96; // Dark grey — two-sided, no change
const COLOR_SECRET = 176; // Red — secret (same as wall)
const COLOR_UNMAPPED = 104; // Light grey
const COLOR_PLAYER = 112; // White-green — player arrow
const COLOR_THING = 112; // Green — thing markers
const COLOR_BACKGROUND = 0; // Black

// Zoom limits
const MIN_SCALE_RAW: i32 = 0x800; // Very zoomed out
const MAX_SCALE_RAW: i32 = 0x80000; // Very zoomed in
const ZOOM_STEP_RAW: i32 = 0x200; // Zoom per tic

// Pan speed
const PAN_SPEED = Fixed.fromRaw(4 * 0x10000); // 4.0 map units per tic

pub const Automap = struct {
    active: bool = false,
    follow_player: bool = true,
    show_all_lines: bool = false, // Cheat: show all lines
    show_things: bool = false, // Cheat: show things

    // View center in map coordinates
    center_x: Fixed = Fixed.ZERO,
    center_y: Fixed = Fixed.ZERO,
    scale: Fixed = Fixed.fromRaw(0x8000), // Default zoom

    /// Toggle automap on/off
    pub fn toggle(self: *Automap) void {
        self.active = !self.active;
    }

    /// Handle input events. Returns true if event was consumed.
    pub fn responder(self: *Automap, ev: *const Event) bool {
        if (!self.active) {
            // Only TAB opens automap
            if (ev.event_type == .key_down and ev.data1 == event.KEY_TAB) {
                self.toggle();
                return true;
            }
            return false;
        }

        if (ev.event_type == .key_down) {
            switch (ev.data1) {
                event.KEY_TAB => {
                    self.toggle();
                    return true;
                },
                event.KEY_UPARROW => {
                    if (!self.follow_player) {
                        self.center_y = Fixed.add(self.center_y, PAN_SPEED);
                    }
                    return true;
                },
                event.KEY_DOWNARROW => {
                    if (!self.follow_player) {
                        self.center_y = Fixed.sub(self.center_y, PAN_SPEED);
                    }
                    return true;
                },
                event.KEY_LEFTARROW => {
                    if (!self.follow_player) {
                        self.center_x = Fixed.sub(self.center_x, PAN_SPEED);
                    }
                    return true;
                },
                event.KEY_RIGHTARROW => {
                    if (!self.follow_player) {
                        self.center_x = Fixed.add(self.center_x, PAN_SPEED);
                    }
                    return true;
                },
                '=' => {
                    // Zoom in
                    self.scale = Fixed.fromRaw(@min(MAX_SCALE_RAW, self.scale.raw() + ZOOM_STEP_RAW));
                    return true;
                },
                '-' => {
                    // Zoom out
                    self.scale = Fixed.fromRaw(@max(MIN_SCALE_RAW, self.scale.raw() - ZOOM_STEP_RAW));
                    return true;
                },
                'f' => {
                    // Toggle follow mode
                    self.follow_player = !self.follow_player;
                    return true;
                },
                else => {},
            }
        }

        return false;
    }

    /// Per-tic update
    pub fn ticker(self: *Automap, player: *const Player) void {
        if (!self.active) return;

        // Follow player
        if (self.follow_player) {
            if (player.mobj) |mo| {
                self.center_x = mo.x;
                self.center_y = mo.y;
            }
        }
    }

    /// Draw the automap
    pub fn drawer(self: *const Automap, level: *const Level, player: *const Player, vid: *video.VideoState) void {
        if (!self.active) return;

        // Clear screen to background color
        vid.clearScreen(0, COLOR_BACKGROUND);

        // Draw all linedefs
        for (level.lines) |line| {
            // Skip hidden lines
            if (line.flags & defs.ML_DONTDRAW != 0 and !self.show_all_lines) continue;

            // Skip unmapped lines (unless cheat)
            if (line.flags & defs.ML_MAPPED == 0 and !self.show_all_lines) continue;

            // Determine color
            const color: u8 = blk: {
                // Secret
                if (line.flags & defs.ML_SECRET != 0) break :blk COLOR_SECRET;
                // One-sided
                if (line.sidenum[1] < 0) break :blk COLOR_WALL;
                // Two-sided with floor change
                if (line.frontsector != null and line.backsector != null) {
                    const fs_idx = line.frontsector.?;
                    const bs_idx = line.backsector.?;
                    if (fs_idx < level.sectors.len and bs_idx < level.sectors.len) {
                        if (!level.sectors[fs_idx].floorheight.eql(level.sectors[bs_idx].floorheight)) {
                            break :blk COLOR_FLOOR_CHANGE;
                        }
                        if (!level.sectors[fs_idx].ceilingheight.eql(level.sectors[bs_idx].ceilingheight)) {
                            break :blk COLOR_CEILING_CHANGE;
                        }
                    }
                }
                break :blk COLOR_TWO_SIDED;
            };

            // Get vertex coordinates
            const v1 = level.vertices[line.v1];
            const v2 = level.vertices[line.v2];

            // Transform to screen coords
            const sx1 = self.mapToScreenX(v1.x);
            const sy1 = self.mapToScreenY(v1.y);
            const sx2 = self.mapToScreenX(v2.x);
            const sy2 = self.mapToScreenY(v2.y);

            // Draw line
            drawLine(vid, sx1, sy1, sx2, sy2, color);
        }

        // Draw player arrow
        if (player.mobj) |mo| {
            const px = self.mapToScreenX(mo.x);
            const py = self.mapToScreenY(mo.y);
            drawPlayerArrow(vid, px, py, mo.angle, COLOR_PLAYER);
        }
    }

    /// Transform map X to screen X
    fn mapToScreenX(self: *const Automap, map_x: Fixed) i32 {
        const dx = Fixed.sub(map_x, self.center_x);
        const scaled = Fixed.mul(dx, self.scale);
        return @divTrunc(defs.SCREENWIDTH, 2) + scaled.toInt();
    }

    /// Transform map Y to screen Y (Y is inverted for screen)
    fn mapToScreenY(self: *const Automap, map_y: Fixed) i32 {
        const dy = Fixed.sub(map_y, self.center_y);
        const scaled = Fixed.mul(dy, self.scale);
        return @divTrunc(defs.SCREENHEIGHT, 2) - scaled.toInt();
    }
};

/// Draw a line using Bresenham's algorithm
fn drawLine(vid: *video.VideoState, x0: i32, y0: i32, x1: i32, y1: i32, color: u8) void {
    var dx = if (x1 > x0) x1 - x0 else x0 - x1;
    var dy = if (y1 > y0) y1 - y0 else y0 - y1;
    const sx: i32 = if (x0 < x1) 1 else -1;
    const sy: i32 = if (y0 < y1) 1 else -1;
    _ = &dx;
    _ = &dy;
    var err = dx - dy;

    var cx = x0;
    var cy = y0;

    const max_steps: i32 = @intCast(defs.SCREENWIDTH + defs.SCREENHEIGHT); // Safety limit
    var steps: i32 = 0;

    while (steps < max_steps) : (steps += 1) {
        // Plot pixel if on screen
        if (cx >= 0 and cx < defs.SCREENWIDTH and cy >= 0 and cy < defs.SCREENHEIGHT) {
            vid.screens[0][@as(usize, @intCast(cy)) * defs.SCREENWIDTH + @as(usize, @intCast(cx))] = color;
        }

        if (cx == x1 and cy == y1) break;

        const e2 = err * 2;
        if (e2 > -dy) {
            err -= dy;
            cx += sx;
        }
        if (e2 < dx) {
            err += dx;
            cy += sy;
        }
    }
}

/// Draw a simple player arrow (triangle) at screen position
fn drawPlayerArrow(vid: *video.VideoState, px: i32, py: i32, angle: Angle, color: u8) void {
    // Arrow points in the direction the player is facing
    const fine = angle >> tables.ANGLETOFINESHIFT;
    const cos_val = tables.finecosine[fine & tables.FINEMASK].raw();
    const sin_val = tables.finesine[fine & tables.FINEMASK].raw();

    // Arrow tip (8 pixels in facing direction)
    const tip_x = px + @as(i32, @intCast(@divTrunc(@as(i64, cos_val) * 8, 65536)));
    const tip_y = py - @as(i32, @intCast(@divTrunc(@as(i64, sin_val) * 8, 65536)));

    // Arrow tail center
    const tail_x = px - @as(i32, @intCast(@divTrunc(@as(i64, cos_val) * 4, 65536)));
    const tail_y = py + @as(i32, @intCast(@divTrunc(@as(i64, sin_val) * 4, 65536)));

    // Draw line from tail to tip
    drawLine(vid, tail_x, tail_y, tip_x, tip_y, color);

    // Draw short perpendicular lines at tail for arrowhead
    const perp_x = @as(i32, @intCast(@divTrunc(@as(i64, sin_val) * 3, 65536)));
    const perp_y = @as(i32, @intCast(@divTrunc(@as(i64, cos_val) * 3, 65536)));

    drawLine(vid, tail_x - perp_x, tail_y - perp_y, tail_x + perp_x, tail_y + perp_y, color);
}

test "automap toggle" {
    var am = Automap{};
    try std.testing.expect(!am.active);
    am.toggle();
    try std.testing.expect(am.active);
    am.toggle();
    try std.testing.expect(!am.active);
}

test "automap coordinate transform" {
    var am = Automap{};
    am.center_x = Fixed.ZERO;
    am.center_y = Fixed.ZERO;
    am.scale = Fixed.ONE;

    // Center of map should be center of screen
    const cx = am.mapToScreenX(Fixed.ZERO);
    const cy = am.mapToScreenY(Fixed.ZERO);
    try std.testing.expectEqual(@as(i32, 160), cx);
    try std.testing.expectEqual(@as(i32, 100), cy);
}
