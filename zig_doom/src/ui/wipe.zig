//! zig_doom/src/ui/wipe.zig
//!
//! Screen wipe effect — DOOM's iconic "melt" transition.
//! Translated from: linuxdoom-1.10/f_wipe.c
//! Original: Copyright (C) 1993-1996 id Software, Inc. GPL-2.0
//!
//! Algorithm:
//! 1. Capture current screen as start_screen
//! 2. Render new state into end_screen
//! 3. Initialize column y-offsets with random starting positions
//! 4. Each tic: advance columns downward
//! 5. Draw: for each column, show end_screen above offset, start_screen below
//! 6. Complete when all columns have fully scrolled off

const std = @import("std");
const defs = @import("../defs.zig");
const video = @import("../video.zig");
const random = @import("../random.zig");

const SCREENWIDTH = defs.SCREENWIDTH;
const SCREENHEIGHT = defs.SCREENHEIGHT;
const SCREENSIZE = defs.SCREENSIZE;

pub const Wipe = struct {
    active: bool = false,
    y_offsets: [SCREENWIDTH]i32 = [_]i32{0} ** SCREENWIDTH,
    start_screen: [SCREENSIZE]u8 = [_]u8{0} ** SCREENSIZE,
    end_screen: [SCREENSIZE]u8 = [_]u8{0} ** SCREENSIZE,

    /// Capture the current screen as the wipe start, then
    /// the caller should render the new state and call captureEnd().
    pub fn startWipe(self: *Wipe, vid: *const video.VideoState) void {
        // Copy current screen as start
        @memcpy(&self.start_screen, &vid.screens[0]);
        self.active = true;

        // Initialize y_offsets with random column start positions
        // First column: random in -(0..15)
        self.y_offsets[0] = -@as(i32, random.mRandom() & 15);

        for (1..SCREENWIDTH) |i| {
            // Each column varies from previous by ±random(0..2)
            const r: i32 = @as(i32, random.mRandom() % 3) - 1;
            self.y_offsets[i] = self.y_offsets[i - 1] + r;

            // Clamp to valid starting range
            if (self.y_offsets[i] > 0) self.y_offsets[i] = 0;
            if (self.y_offsets[i] < -15) self.y_offsets[i] = -15;
        }
    }

    /// Capture the end (destination) screen after new state has been rendered
    pub fn captureEnd(self: *Wipe, vid: *const video.VideoState) void {
        @memcpy(&self.end_screen, &vid.screens[0]);
    }

    /// Advance the wipe by one tic and draw to screen.
    /// Returns true when the wipe is complete.
    pub fn doWipe(self: *Wipe, vid: *video.VideoState) bool {
        if (!self.active) return true;

        var all_done = true;

        for (0..SCREENWIDTH) |x| {
            if (self.y_offsets[x] < SCREENHEIGHT) {
                all_done = false;

                // Advance this column
                var dy: i32 = if (self.y_offsets[x] < 0) 1 else self.y_offsets[x] + 1;
                if (dy > 8) dy = 8; // Cap speed
                self.y_offsets[x] += dy;
            }
        }

        // Render the wipe to screen[0]
        self.render(vid);

        if (all_done) {
            self.active = false;
        }

        return all_done;
    }

    /// Render the current wipe state to screen buffer
    fn render(self: *const Wipe, vid: *video.VideoState) void {
        const screen = &vid.screens[0];

        for (0..SCREENWIDTH) |x| {
            const y_off = self.y_offsets[x];

            for (0..SCREENHEIGHT) |y| {
                const iy: i32 = @intCast(y);
                const pixel_idx = y * SCREENWIDTH + x;

                if (iy < y_off) {
                    // Above the melt line — show end (new) screen
                    screen[pixel_idx] = self.end_screen[pixel_idx];
                } else {
                    // Below the melt line — show start (old) screen, shifted up
                    const src_y = iy - y_off;
                    if (src_y >= 0 and src_y < SCREENHEIGHT) {
                        const src_idx = @as(usize, @intCast(src_y)) * SCREENWIDTH + x;
                        screen[pixel_idx] = self.start_screen[src_idx];
                    }
                }
            }
        }
    }

    /// Cancel the wipe
    pub fn cancel(self: *Wipe) void {
        self.active = false;
    }
};

test "wipe init" {
    const wipe = Wipe{};
    try std.testing.expect(!wipe.active);
}

test "wipe lifecycle" {
    var wipe = Wipe{};
    var vid = video.VideoState.init();

    // Fill start screen with color 1
    @memset(&vid.screens[0], 1);
    wipe.startWipe(&vid);
    try std.testing.expect(wipe.active);

    // Fill end screen with color 2
    @memset(&vid.screens[0], 2);
    wipe.captureEnd(&vid);

    // Run wipe until complete
    var tics: u32 = 0;
    while (!wipe.doWipe(&vid)) {
        tics += 1;
        if (tics > 500) break; // Safety
    }

    try std.testing.expect(!wipe.active);
    try std.testing.expect(tics > 0);
}
