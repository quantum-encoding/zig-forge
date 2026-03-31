//! zig_doom/src/ui/hud.zig
//!
//! Heads-up display — message system ("Picked up a shotgun!", etc.).
//! Translated from: linuxdoom-1.10/hu_stuff.c, hu_lib.c
//! Original: Copyright (C) 1993-1996 id Software, Inc. GPL-2.0
//!
//! Messages display at the top of the screen using DOOM's built-in font.
//! Font characters are WAD patches: STCFN033 (!) through STCFN095 (_),
//! covering ASCII 33-95.

const std = @import("std");
const video = @import("../video.zig");
const Wad = @import("../wad.zig").Wad;

const MSG_DISPLAY_TICS = 140; // 4 seconds at 35 fps
const FONT_FIRST_CHAR = 33; // '!'
const FONT_LAST_CHAR = 95; // '_'
const FONT_NUM_CHARS = FONT_LAST_CHAR - FONT_FIRST_CHAR + 1;
const MSG_X = 0;
const MSG_Y = 0;
const CHAR_WIDTH = 8; // Approximate character width

pub const HUD = struct {
    message: ?[]const u8 = null,
    message_tics: i32 = 0,
    message_on: bool = false,

    // Font patches (lump numbers)
    font: [FONT_NUM_CHARS]?usize = [_]?usize{null} ** FONT_NUM_CHARS,

    /// Initialize HUD and cache font patches from WAD
    pub fn init(w: *const Wad) HUD {
        var self = HUD{};

        // Load font patches STCFN033 - STCFN095
        var name_buf: [8]u8 = [_]u8{ 'S', 'T', 'C', 'F', 'N', '0', '0', '0' };
        for (FONT_FIRST_CHAR..FONT_LAST_CHAR + 1) |ch| {
            // Format 3-digit number
            const hundreds: u8 = @intCast(ch / 100);
            const tens: u8 = @intCast((ch / 10) % 10);
            const ones: u8 = @intCast(ch % 10);
            name_buf[5] = '0' + hundreds;
            name_buf[6] = '0' + tens;
            name_buf[7] = '0' + ones;
            self.font[ch - FONT_FIRST_CHAR] = w.findLump(name_buf[0..8]);
        }

        return self;
    }

    /// Set a new message to display
    pub fn setMessage(self: *HUD, msg: []const u8) void {
        self.message = msg;
        self.message_tics = MSG_DISPLAY_TICS;
        self.message_on = true;
    }

    /// Update per tic — decrement message timer
    pub fn ticker(self: *HUD) void {
        if (self.message_on) {
            self.message_tics -= 1;
            if (self.message_tics <= 0) {
                self.message_on = false;
                self.message = null;
            }
        }
    }

    /// Draw HUD message to screen
    pub fn drawer(self: *const HUD, vid: *video.VideoState, w: *const Wad) void {
        if (!self.message_on) return;
        const msg = self.message orelse return;

        var x: i32 = MSG_X;
        const y: i32 = MSG_Y;

        for (msg) |ch| {
            if (ch == ' ') {
                x += 4; // Space width
                continue;
            }

            // Convert to uppercase for font lookup
            const upper: u8 = if (ch >= 'a' and ch <= 'z') ch - 32 else ch;

            if (upper >= FONT_FIRST_CHAR and upper <= FONT_LAST_CHAR) {
                const font_idx = upper - FONT_FIRST_CHAR;
                if (self.font[font_idx]) |lump| {
                    const patch_data = w.lumpData(lump);
                    video.drawPatch(vid, 0, x, y, patch_data);
                    // Advance x by patch width
                    if (patch_data.len >= 2) {
                        const pw: i32 = @as(i32, patch_data[0]) | (@as(i32, patch_data[1]) << 8);
                        x += pw;
                    } else {
                        x += CHAR_WIDTH;
                    }
                } else {
                    x += CHAR_WIDTH;
                }
            } else {
                x += CHAR_WIDTH;
            }

            // Don't draw past screen edge
            if (x >= video.SCREENWIDTH) break;
        }
    }
};

test "hud init" {
    const hud = HUD{};
    try std.testing.expect(!hud.message_on);
    try std.testing.expect(hud.message == null);
}

test "hud set message and tick" {
    var hud = HUD{};
    hud.setMessage("Hello DOOM");
    try std.testing.expect(hud.message_on);
    try std.testing.expectEqual(@as(i32, MSG_DISPLAY_TICS), hud.message_tics);

    // Tick down
    for (0..MSG_DISPLAY_TICS) |_| {
        hud.ticker();
    }
    try std.testing.expect(!hud.message_on);
}
