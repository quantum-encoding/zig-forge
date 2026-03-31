//! zig_doom/src/ui/status_bar.zig
//!
//! Status bar — the 32-pixel-high HUD at the bottom of the screen.
//! Translated from: linuxdoom-1.10/st_stuff.c, st_lib.c
//! Original: Copyright (C) 1993-1996 id Software, Inc. GPL-2.0
//!
//! Displays: health, armor, ammo for current weapon, arms (weapon owned),
//! keys, and Doomguy face.

const std = @import("std");
const defs = @import("../defs.zig");
const fixed = @import("../fixed.zig");
const Fixed = fixed.Fixed;
const video = @import("../video.zig");
const Wad = @import("../wad.zig").Wad;
const random = @import("../random.zig");
const user = @import("../play/user.zig");
const Player = user.Player;

// Status bar geometry
const ST_Y = 168; // Top of status bar (SCREENHEIGHT - 32)
const ST_HEIGHT = 32;

// Number drawing positions (x coords on status bar)
const ST_AMMOX = 44; // Ammo count
const ST_AMMOY = 171;
const ST_HEALTHX = 90; // Health
const ST_HEALTHY = 171;
const ST_ARMORX = 221; // Armor
const ST_ARMORY = 171;

// Arms indicator area
const ST_ARMSX = 111;
const ST_ARMSY = 172;
const ST_ARMSXSPACE = 12;
const ST_ARMSYSPACE = 10;

// Key indicator positions
const ST_KEY0X = 239;
const ST_KEY0Y = 171;
const ST_KEY1X = 239;
const ST_KEY1Y = 181;
const ST_KEY2X = 239;
const ST_KEY2Y = 191;

// Face position
const ST_FACEX = 143;
const ST_FACEY = 168;

// Face states: 5 health levels x 3 directions + specials
const ST_NUMPAINFACES = 5;
const ST_NUMSTRAIGHTFACES = 3;
const ST_TURNCOUNT = 2; // Tics to keep damage direction face
const ST_OUCHCOUNT = 1;
const ST_RAMPAGECOUNT = 2;

// Number of face frames total
const ST_FACES_PER_PAIN = 3; // straight, left, right
const ST_TOTAL_FACES = ST_NUMPAINFACES * ST_FACES_PER_PAIN + 5; // + godmode, dead, evil grin, etc.

pub const StatusBar = struct {
    // Cached lump numbers for WAD patches
    big_nums: [10]?usize = [_]?usize{null} ** 10, // STTNUM0-9
    small_nums: [10]?usize = [_]?usize{null} ** 10, // STGNUM0-9
    bar_bg: ?usize = null, // STBAR
    arms_bg: ?usize = null, // STARMS
    key_patches: [6]?usize = [_]?usize{null} ** 6, // STKEYS0-5
    face_patches: [ST_TOTAL_FACES]?usize = [_]?usize{null} ** ST_TOTAL_FACES,
    face_bg: ?usize = null, // STFB0
    percent_patch: ?usize = null, // STTPRCNT
    minus_patch: ?usize = null, // STTMINUS

    // State
    old_health: i32 = -1,
    face_index: u8 = 0,
    face_count: i32 = 0,
    last_attack_down: bool = false,
    priority: i32 = 0, // Face priority (higher = more important)
    random_number: u8 = 0,

    /// Initialize status bar by caching lump numbers from WAD
    pub fn init(w: *const Wad) StatusBar {
        var self = StatusBar{};

        // Big numbers (STTNUM0 - STTNUM9)
        var name_buf: [8]u8 = undefined;
        for (0..10) |i| {
            @memcpy(name_buf[0..6], "STTNUM");
            name_buf[6] = @intCast('0' + i);
            name_buf[7] = 0;
            self.big_nums[i] = w.findLump(name_buf[0..7]);
        }

        // Small numbers (STGNUM0 - STGNUM9)
        for (0..10) |i| {
            @memcpy(name_buf[0..6], "STGNUM");
            name_buf[6] = @intCast('0' + i);
            name_buf[7] = 0;
            self.small_nums[i] = w.findLump(name_buf[0..7]);
        }

        // Status bar background
        self.bar_bg = w.findLump("STBAR");
        self.arms_bg = w.findLump("STARMS");
        self.percent_patch = w.findLump("STTPRCNT");
        self.minus_patch = w.findLump("STTMINUS");

        // Keys (STKEYS0 - STKEYS5)
        for (0..6) |i| {
            @memcpy(name_buf[0..6], "STKEYS");
            name_buf[6] = @intCast('0' + i);
            name_buf[7] = 0;
            self.key_patches[i] = w.findLump(name_buf[0..7]);
        }

        // Face patches: STFST00 through STFST42, then specials
        // Pattern: STFST[pain_level][direction] where pain 0-4, dir 0-2
        var face_idx: usize = 0;
        for (0..ST_NUMPAINFACES) |pain| {
            for (0..ST_FACES_PER_PAIN) |dir| {
                name_buf[0] = 'S';
                name_buf[1] = 'T';
                name_buf[2] = 'F';
                name_buf[3] = 'S';
                name_buf[4] = 'T';
                name_buf[5] = @intCast('0' + pain);
                name_buf[6] = @intCast('0' + dir);
                name_buf[7] = 0;
                self.face_patches[face_idx] = w.findLump(name_buf[0..7]);
                face_idx += 1;
            }
        }

        // Special faces: god mode (STFGOD0), dead (STFDEAD0), evil grin (STFEVL0),
        // ouch (STFOUCH0), kill (STFKILL0)
        self.face_patches[face_idx] = w.findLump("STFGOD0");
        face_idx += 1;
        self.face_patches[face_idx] = w.findLump("STFDEAD0");
        face_idx += 1;
        self.face_patches[face_idx] = w.findLump("STFEVL0");
        face_idx += 1;
        self.face_patches[face_idx] = w.findLump("STFOUCH0");
        face_idx += 1;
        self.face_patches[face_idx] = w.findLump("STFKILL0");

        // Face background
        self.face_bg = w.findLump("STFB0");

        return self;
    }

    /// Update status bar state (face animation, change detection)
    pub fn ticker(self: *StatusBar, player: *const Player) void {
        // Update face
        self.face_count -= 1;
        if (self.face_count <= 0) {
            self.updateFace(player);
            self.face_count = 15 + @as(i32, random.mRandom() & 15); // Random duration
        }
    }

    /// Draw the status bar to screen
    pub fn drawer(self: *const StatusBar, player: *const Player, vid: *video.VideoState, w: *const Wad) void {
        // Draw status bar background
        if (self.bar_bg) |lump| {
            video.drawPatch(vid, 0, 0, ST_Y, w.lumpData(lump));
        }

        // Draw arms background (if not commercial)
        if (self.arms_bg) |lump| {
            video.drawPatch(vid, 0, ST_ARMSX, ST_ARMSY, w.lumpData(lump));
        }

        // Draw face background
        if (self.face_bg) |lump| {
            video.drawPatch(vid, 0, ST_FACEX, ST_FACEY, w.lumpData(lump));
        }

        // Draw Doomguy face
        if (self.face_index < ST_TOTAL_FACES) {
            if (self.face_patches[self.face_index]) |lump| {
                video.drawPatch(vid, 0, ST_FACEX, ST_FACEY, w.lumpData(lump));
            }
        }

        // Draw ammo count for current weapon
        const ammo_type = weaponAmmoType(player.ready_weapon);
        if (ammo_type < defs.NUMAMMO) {
            self.drawBigNumber(vid, w, player.ammo[ammo_type], ST_AMMOX, ST_AMMOY, 3);
        }

        // Draw health with percent sign
        self.drawBigNumber(vid, w, player.health, ST_HEALTHX, ST_HEALTHY, 3);
        if (self.percent_patch) |lump| {
            video.drawPatch(vid, 0, ST_HEALTHX + 42, ST_HEALTHY, w.lumpData(lump));
        }

        // Draw armor with percent sign
        self.drawBigNumber(vid, w, player.armor_points, ST_ARMORX, ST_ARMORY, 3);
        if (self.percent_patch) |lump| {
            video.drawPatch(vid, 0, ST_ARMORX + 42, ST_ARMORY, w.lumpData(lump));
        }

        // Draw arms indicators (weapons 2-7)
        for (0..6) |i| {
            const weapon_idx = i + 2; // weapons 2-7
            if (weapon_idx < defs.NUMWEAPONS) {
                const owned = player.weapon_owned[weapon_idx];
                const col: usize = i % 3;
                const row: usize = i / 3;
                const x = ST_ARMSX + @as(i32, @intCast(col)) * ST_ARMSXSPACE;
                const y = ST_ARMSY + @as(i32, @intCast(row)) * ST_ARMSYSPACE;
                // Draw digit in yellow (owned) or grey (not owned)
                const digit: usize = weapon_idx;
                if (digit < 10) {
                    const nums = if (owned) self.big_nums else self.small_nums;
                    if (nums[digit]) |lump| {
                        video.drawPatch(vid, 0, x, y, w.lumpData(lump));
                    }
                }
            }
        }

        // Draw key indicators
        for (0..3) |i| {
            const key_x = [3]i32{ ST_KEY0X, ST_KEY1X, ST_KEY2X };
            const key_y = [3]i32{ ST_KEY0Y, ST_KEY1Y, ST_KEY2Y };

            // Check card and skull for this color
            if (player.cards[i]) {
                if (self.key_patches[i]) |lump| {
                    video.drawPatch(vid, 0, key_x[i], key_y[i], w.lumpData(lump));
                }
            }
            if (player.cards[i + 3]) {
                if (self.key_patches[i + 3]) |lump| {
                    video.drawPatch(vid, 0, key_x[i], key_y[i], w.lumpData(lump));
                }
            }
        }
    }

    /// Draw a multi-digit number using big number patches
    fn drawBigNumber(self: *const StatusBar, vid: *video.VideoState, w: *const Wad, value: i32, x: i32, y: i32, max_digits: i32) void {
        var num = value;

        // Handle negative
        if (num < 0) {
            if (self.minus_patch) |lump| {
                video.drawPatch(vid, 0, x - 14 * max_digits, y, w.lumpData(lump));
            }
            num = -num;
        }

        // Clamp to max displayable
        if (num > 999) num = 999;

        // Draw right to left
        var draw_x = x + (max_digits - 1) * 14;
        var digits_drawn: i32 = 0;
        if (num == 0) {
            if (self.big_nums[0]) |lump| {
                video.drawPatch(vid, 0, draw_x, y, w.lumpData(lump));
            }
            return;
        }

        while (num > 0 and digits_drawn < max_digits) {
            const digit: usize = @intCast(@mod(num, 10));
            if (self.big_nums[digit]) |lump| {
                video.drawPatch(vid, 0, draw_x, y, w.lumpData(lump));
            }
            num = @divTrunc(num, 10);
            draw_x -= 14;
            digits_drawn += 1;
        }
    }

    /// Update Doomguy face based on player state
    fn updateFace(self: *StatusBar, player: *const Player) void {
        // Check for god mode
        if (player.cheats & 1 != 0) { // CF_GODMODE
            self.face_index = ST_NUMPAINFACES * ST_FACES_PER_PAIN; // God face
            return;
        }

        // Check for dead
        if (player.player_state == .dead) {
            self.face_index = @intCast(ST_NUMPAINFACES * ST_FACES_PER_PAIN + 1); // Dead face
            return;
        }

        // Determine health level (0 = near death, 4 = healthy)
        const health = @max(0, player.health);
        const pain_level: usize = blk: {
            if (health >= 80) break :blk 4;
            if (health >= 60) break :blk 3;
            if (health >= 40) break :blk 2;
            if (health >= 20) break :blk 1;
            break :blk 0;
        };

        // Invert: DOOM stores most damaged first
        const pain_idx = 4 - pain_level;

        // Damage direction face (straight face for now, simplified)
        const direction: usize = 0; // straight

        self.face_index = @intCast(pain_idx * ST_FACES_PER_PAIN + direction);
    }
};

/// Get ammo type for a weapon
fn weaponAmmoType(weapon: defs.WeaponType) usize {
    return switch (weapon) {
        .fist, .chainsaw => @intFromEnum(defs.AmmoType.no_ammo),
        .pistol, .chaingun => @intFromEnum(defs.AmmoType.clip),
        .shotgun, .super_shotgun => @intFromEnum(defs.AmmoType.shell),
        .missile => @intFromEnum(defs.AmmoType.missile),
        .plasma, .bfg => @intFromEnum(defs.AmmoType.cell),
    };
}

test "status bar init" {
    // Can't test with real WAD, just verify struct initializes
    const sb = StatusBar{};
    try std.testing.expectEqual(@as(u8, 0), sb.face_index);
    try std.testing.expectEqual(@as(i32, -1), sb.old_health);
}

test "weapon ammo type" {
    try std.testing.expectEqual(@as(usize, 0), weaponAmmoType(.pistol));
    try std.testing.expectEqual(@as(usize, 1), weaponAmmoType(.shotgun));
    try std.testing.expectEqual(@as(usize, 4), weaponAmmoType(.fist));
}
