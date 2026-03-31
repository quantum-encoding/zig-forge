//! zig_doom/src/ui/finale.zig
//!
//! Finale screens — text crawl and art screens at end of episodes.
//! Translated from: linuxdoom-1.10/f_finale.c
//! Original: Copyright (C) 1993-1996 id Software, Inc. GPL-2.0
//!
//! Implements typewriter text reveal and background flat display.
//! Cast sequence (DOOM II) is stubbed out for Phase 5.

const std = @import("std");
const defs = @import("../defs.zig");
const video = @import("../video.zig");
const Wad = @import("../wad.zig").Wad;

const TICRATE = 35;
const TEXT_SPEED = 3; // Tics per character reveal

pub const FinaleStage = enum {
    text, // Typewriter text reveal
    art_screen, // Display art image
    cast, // DOOM II cast sequence (stub)
    done, // Finale complete
};

/// Episode ending texts
const E1_TEXT =
    \\Once you beat the big badasses and
    \\temporary your body, you've earned a
    \\little R&R. You are on to the next
    \\but what the hell is this? It's not
    \\supposed to end this way!
    \\
    \\It stinks like rotten meat, but looks
    \\like the lost Deimos base. Looks like
    \\you're stuck on The Shores of Hell.
    \\The only way out is through.
;

const E2_TEXT =
    \\You've done it! The hideous cyber-
    \\demon lord that ruled the lost Deimos
    \\moon base has been slain and you
    \\are triumphant! But... where are
    \\you? You clamber to the edge of the
    \\moon and look down to see the awful
    \\truth.
    \\
    \\Deimos floats above Hell itself!
    \\You've never heard of anyone escaping
    \\from Hell, but you'll make yourself
    \\the first.
;

const E3_TEXT =
    \\The loathsome spiderdemon that
    \\masterminded the invasion of the moon
    \\bases and caused so much death has had
    \\its ass kicked for all time.
    \\
    \\A hidden doorway opens and you enter.
    \\You've proven too tough for Hell to
    \\contain, and now Hell at last plays
    \\fair -- for you emerge from the door
    \\to see the green fields of Earth!
    \\Home at last.
;

const E4_TEXT =
    \\the spider mastermind must have sent
    \\forth its legions of hellspawn before
    \\your final confrontation with that
    \\terrible beast from hell. but you
    \\stepped forward and brought forth
    \\eternal damnation upon the horde as
    \\a alarm.
;

pub const Finale = struct {
    text: []const u8 = "",
    text_count: i32 = 0, // Characters revealed so far
    text_speed: i32 = TEXT_SPEED,
    stage: FinaleStage = .done,
    count: i32 = 0, // Global tic counter
    episode: u8 = 0,
    flat_lump: ?usize = null, // Background flat

    /// Start the finale for an episode
    pub fn start(self: *Finale, episode: u8, w: *const Wad) void {
        self.episode = episode;
        self.stage = .text;
        self.text_count = 0;
        self.count = 0;

        // Select text and background flat for episode
        switch (episode) {
            1 => {
                self.text = E1_TEXT;
                self.flat_lump = w.findLump("FLOOR4_8");
            },
            2 => {
                self.text = E2_TEXT;
                self.flat_lump = w.findLump("SFLR6_1");
            },
            3 => {
                self.text = E3_TEXT;
                self.flat_lump = w.findLump("MFLR8_4");
            },
            4 => {
                self.text = E4_TEXT;
                self.flat_lump = w.findLump("MFLR8_3");
            },
            else => {
                self.text = E1_TEXT;
                self.flat_lump = null;
            },
        }
    }

    /// Tick the finale. Returns true when complete.
    pub fn ticker(self: *Finale) bool {
        self.count += 1;

        switch (self.stage) {
            .text => {
                // Reveal one character every TEXT_SPEED tics
                if (@mod(self.count, self.text_speed) == 0) {
                    self.text_count += 1;
                }

                // Check if all text is revealed
                if (self.text_count >= @as(i32, @intCast(self.text.len))) {
                    // Wait a bit then move to art screen
                    if (self.count > @as(i32, @intCast(self.text.len)) * self.text_speed + TICRATE * 3) {
                        self.stage = .art_screen;
                        self.count = 0;
                    }
                }
            },
            .art_screen => {
                // Show art screen for a few seconds then finish
                if (self.count >= TICRATE * 5) {
                    self.stage = .done;
                    return true;
                }
            },
            .cast => {
                // DOOM II cast sequence — stub
                self.stage = .done;
                return true;
            },
            .done => return true,
        }

        return false;
    }

    /// Accelerate (skip) the finale
    pub fn accelerate(self: *Finale) void {
        switch (self.stage) {
            .text => {
                // Skip to all text revealed
                self.text_count = @intCast(self.text.len);
                self.stage = .art_screen;
                self.count = 0;
            },
            .art_screen => {
                self.stage = .done;
            },
            .cast, .done => {},
        }
    }

    /// Draw the finale screen
    pub fn drawer(self: *const Finale, vid: *video.VideoState, w: *const Wad) void {
        switch (self.stage) {
            .text => {
                // Draw background flat (tiled)
                self.drawBackgroundFlat(vid, w);

                // Draw revealed text
                self.drawText(vid);
            },
            .art_screen => {
                // Draw victory art or background
                self.drawBackgroundFlat(vid, w);
            },
            .cast, .done => {},
        }
    }

    /// Draw a flat tiled across the entire screen as background
    fn drawBackgroundFlat(self: *const Finale, vid: *video.VideoState, w: *const Wad) void {
        const flat_data = if (self.flat_lump) |lump|
            w.lumpData(lump)
        else
            return;

        if (flat_data.len < 4096) return;

        // Tile 64x64 flat across 320x200 screen
        const screen = &vid.screens[0];
        for (0..defs.SCREENHEIGHT) |y| {
            const flat_row: usize = y & 63; // Wrap at 64
            for (0..defs.SCREENWIDTH) |x| {
                const flat_col: usize = x & 63;
                screen[y * defs.SCREENWIDTH + x] = flat_data[flat_row * 64 + flat_col];
            }
        }
    }

    /// Draw typewriter text on screen
    fn drawText(self: *const Finale, vid: *video.VideoState) void {
        const chars_to_show: usize = @intCast(@max(0, self.text_count));
        if (chars_to_show == 0) return;

        const text = self.text;
        const show_len = @min(chars_to_show, text.len);

        // Simple text rendering using direct pixel writes
        // Each character is 8x8 pixels (simplified — real DOOM uses font patches)
        var cx: i32 = 10; // Start x
        var cy: i32 = 10; // Start y

        for (text[0..show_len]) |ch| {
            if (ch == '\n') {
                cx = 10;
                cy += 11;
                if (cy >= defs.SCREENHEIGHT - 10) break;
                continue;
            }

            // Draw a simple 8x8 placeholder for each character
            // In Phase 6, this would use the font patches from the HUD
            if (cx >= 0 and cx < defs.SCREENWIDTH - 8 and cy >= 0 and cy < defs.SCREENHEIGHT - 8) {
                // Draw character as a small bright block (simplified)
                drawSimpleChar(vid, cx, cy, ch);
            }

            cx += 8;
            if (cx >= defs.SCREENWIDTH - 10) {
                cx = 10;
                cy += 11;
                if (cy >= defs.SCREENHEIGHT - 10) break;
            }
        }
    }
};

/// Draw a simplified character (5x7 dot in a bright color)
fn drawSimpleChar(vid: *video.VideoState, x: i32, y: i32, ch: u8) void {
    if (ch == ' ') return;

    // Use a bright palette index for text
    const color: u8 = 4; // Red-ish in DOOM palette

    // Draw a simple 6x7 filled rect as character placeholder
    const screen = &vid.screens[0];
    var row: i32 = 0;
    while (row < 7) : (row += 1) {
        const py = y + row;
        if (py < 0 or py >= defs.SCREENHEIGHT) continue;
        var col: i32 = 0;
        while (col < 6) : (col += 1) {
            const px = x + col;
            if (px < 0 or px >= defs.SCREENWIDTH) continue;
            screen[@as(usize, @intCast(py)) * defs.SCREENWIDTH + @as(usize, @intCast(px))] = color;
        }
    }
}

test "finale start and tick" {
    var finale = Finale{};
    // Can't use real WAD, just test state machine
    finale.stage = .text;
    finale.text = "Hello";
    finale.text_count = 0;
    finale.text_speed = 1;

    // Tick to reveal characters
    for (0..10) |_| {
        _ = finale.ticker();
    }

    try std.testing.expect(finale.text_count >= 5);
}

test "finale accelerate" {
    var finale = Finale{};
    finale.stage = .text;
    finale.text = "Test text";
    finale.text_count = 2;

    finale.accelerate();
    try std.testing.expectEqual(FinaleStage.art_screen, finale.stage);
}
