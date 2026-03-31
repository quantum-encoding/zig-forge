//! zig_doom/src/ui/intermission.zig
//!
//! Intermission screen — level stats shown between levels.
//! Translated from: linuxdoom-1.10/wi_stuff.c
//! Original: Copyright (C) 1993-1996 id Software, Inc. GPL-2.0
//!
//! Shows kill/item/secret percentages and time/par counting up with
//! click-sound timing. Simplified version for Phase 5.

const std = @import("std");
const defs = @import("../defs.zig");
const video = @import("../video.zig");
const Wad = @import("../wad.zig").Wad;

const TICRATE = 35;
const SHOWCOUNT = 4; // Tics per percentage increment

pub const IntermissionState = enum {
    stat_count, // Counting up stats
    show_next_loc, // Showing next level location
    no_state, // Done
};

/// Stats passed from the completed level
pub const LevelStats = struct {
    kills: i32 = 0,
    total_kills: i32 = 0,
    items: i32 = 0,
    total_items: i32 = 0,
    secrets: i32 = 0,
    total_secrets: i32 = 0,
    time_tics: i32 = 0, // Level time in tics
    par_tics: i32 = 0, // Par time in tics
    last_level: u8 = 0,
    next_level: u8 = 0,
    episode: u8 = 0,
};

pub const Intermission = struct {
    state: IntermissionState = .no_state,
    count: i32 = 0, // Tic counter
    accelerate: bool = false, // Player pressed USE to skip

    // Target stats
    kills_percent: i32 = 0,
    items_percent: i32 = 0,
    secrets_percent: i32 = 0,
    time_secs: i32 = 0,
    par_time_secs: i32 = 0,

    // Counting values
    cnt_kills: i32 = 0,
    cnt_items: i32 = 0,
    cnt_secrets: i32 = 0,
    cnt_time: i32 = 0,
    cnt_par: i32 = 0,

    // Level info
    last_level: u8 = 0,
    next_level: u8 = 0,
    episode: u8 = 0,

    // Cached WAD patches
    percent_patch: ?usize = null,
    colon_patch: ?usize = null,
    minus_patch: ?usize = null,
    finished_patch: ?usize = null,
    entering_patch: ?usize = null,
    kills_patch: ?usize = null,
    items_patch: ?usize = null,
    sp_secret_patch: ?usize = null,
    time_patch: ?usize = null,
    par_patch: ?usize = null,
    num_patches: [10]?usize = [_]?usize{null} ** 10,

    /// Initialize and start the intermission with level stats
    pub fn start(self: *Intermission, stats: LevelStats, w: *const Wad) void {
        self.state = .stat_count;
        self.count = 0;
        self.accelerate = false;

        // Calculate percentages
        self.kills_percent = if (stats.total_kills > 0)
            @divTrunc(stats.kills * 100, stats.total_kills)
        else
            100;

        self.items_percent = if (stats.total_items > 0)
            @divTrunc(stats.items * 100, stats.total_items)
        else
            100;

        self.secrets_percent = if (stats.total_secrets > 0)
            @divTrunc(stats.secrets * 100, stats.total_secrets)
        else
            100;

        self.time_secs = @divTrunc(stats.time_tics, TICRATE);
        self.par_time_secs = @divTrunc(stats.par_tics, TICRATE);

        // Reset counters
        self.cnt_kills = 0;
        self.cnt_items = 0;
        self.cnt_secrets = 0;
        self.cnt_time = 0;
        self.cnt_par = 0;

        self.last_level = stats.last_level;
        self.next_level = stats.next_level;
        self.episode = stats.episode;

        // Cache WAD patches
        self.percent_patch = w.findLump("WIPCNT");
        self.colon_patch = w.findLump("WICOLON");
        self.minus_patch = w.findLump("WIMINUS");
        self.finished_patch = w.findLump("WIF");
        self.entering_patch = w.findLump("WIENTER");
        self.kills_patch = w.findLump("WIOSTK");
        self.items_patch = w.findLump("WIOSTI");
        self.sp_secret_patch = w.findLump("WIOSTS");
        self.time_patch = w.findLump("WITIME");
        self.par_patch = w.findLump("WIPAR");

        // Number patches WINUM0-9
        var name_buf: [8]u8 = [_]u8{ 'W', 'I', 'N', 'U', 'M', '0', 0, 0 };
        for (0..10) |i| {
            name_buf[5] = @intCast('0' + i);
            self.num_patches[i] = w.findLump(name_buf[0..6]);
        }
    }

    /// Tick the intermission. Returns true when the intermission is complete.
    pub fn ticker(self: *Intermission) bool {
        self.count += 1;

        switch (self.state) {
            .stat_count => {
                if (self.accelerate) {
                    // Skip to final values
                    self.cnt_kills = self.kills_percent;
                    self.cnt_items = self.items_percent;
                    self.cnt_secrets = self.secrets_percent;
                    self.cnt_time = self.time_secs;
                    self.cnt_par = self.par_time_secs;
                    self.state = .show_next_loc;
                    self.count = 0;
                    return false;
                }

                // Count up kills
                if (self.cnt_kills < self.kills_percent) {
                    self.cnt_kills += 2;
                    if (self.cnt_kills > self.kills_percent) {
                        self.cnt_kills = self.kills_percent;
                    }
                    return false;
                }

                // Count up items
                if (self.cnt_items < self.items_percent) {
                    self.cnt_items += 2;
                    if (self.cnt_items > self.items_percent) {
                        self.cnt_items = self.items_percent;
                    }
                    return false;
                }

                // Count up secrets
                if (self.cnt_secrets < self.secrets_percent) {
                    self.cnt_secrets += 2;
                    if (self.cnt_secrets > self.secrets_percent) {
                        self.cnt_secrets = self.secrets_percent;
                    }
                    return false;
                }

                // Count up time
                if (self.cnt_time < self.time_secs) {
                    self.cnt_time += 3;
                    if (self.cnt_time > self.time_secs) {
                        self.cnt_time = self.time_secs;
                    }
                    return false;
                }

                // Count up par time
                if (self.cnt_par < self.par_time_secs) {
                    self.cnt_par += 3;
                    if (self.cnt_par > self.par_time_secs) {
                        self.cnt_par = self.par_time_secs;
                    }
                    return false;
                }

                // All done counting, move to show next loc
                self.state = .show_next_loc;
                self.count = 0;
            },
            .show_next_loc => {
                // Wait for player input or timeout
                if (self.accelerate or self.count >= TICRATE * 4) {
                    self.state = .no_state;
                    return true;
                }
            },
            .no_state => return true,
        }

        return false;
    }

    /// Draw the intermission screen
    pub fn drawer(self: *const Intermission, vid: *video.VideoState, w: *const Wad) void {
        // Clear screen
        vid.clearScreen(0, 0);

        const x_label: i32 = 50;
        const x_num: i32 = 200;
        var y: i32 = 50;

        // Draw "Finished!" text
        if (self.finished_patch) |lump| {
            video.drawPatch(vid, 0, 80, 10, w.lumpData(lump));
        }

        // Draw kills
        if (self.kills_patch) |lump| {
            video.drawPatch(vid, 0, x_label, y, w.lumpData(lump));
        }
        self.drawIntermissionNum(vid, w, x_num, y, self.cnt_kills);
        if (self.percent_patch) |lump| {
            video.drawPatch(vid, 0, x_num + 42, y, w.lumpData(lump));
        }
        y += 24;

        // Draw items
        if (self.items_patch) |lump| {
            video.drawPatch(vid, 0, x_label, y, w.lumpData(lump));
        }
        self.drawIntermissionNum(vid, w, x_num, y, self.cnt_items);
        if (self.percent_patch) |lump| {
            video.drawPatch(vid, 0, x_num + 42, y, w.lumpData(lump));
        }
        y += 24;

        // Draw secrets
        if (self.sp_secret_patch) |lump| {
            video.drawPatch(vid, 0, x_label, y, w.lumpData(lump));
        }
        self.drawIntermissionNum(vid, w, x_num, y, self.cnt_secrets);
        if (self.percent_patch) |lump| {
            video.drawPatch(vid, 0, x_num + 42, y, w.lumpData(lump));
        }
        y += 36;

        // Draw time
        if (self.time_patch) |lump| {
            video.drawPatch(vid, 0, x_label, y, w.lumpData(lump));
        }
        self.drawTime(vid, w, x_num + 42, y, self.cnt_time);

        // Draw par
        if (self.par_patch) |lump| {
            video.drawPatch(vid, 0, x_label + 160, y, w.lumpData(lump));
        }
        self.drawTime(vid, w, x_num + 160, y, self.cnt_par);

        // Show "Entering" text during show_next_loc
        if (self.state == .show_next_loc) {
            if (self.entering_patch) |lump| {
                video.drawPatch(vid, 0, 80, 160, w.lumpData(lump));
            }
        }
    }

    /// Draw a number using intermission number patches
    fn drawIntermissionNum(self: *const Intermission, vid: *video.VideoState, w: *const Wad, x: i32, y: i32, value: i32) void {
        var num = value;
        if (num < 0) num = 0;
        if (num > 999) num = 999;

        var draw_x = x;
        var digits: [3]u8 = undefined;
        var num_digits: usize = 0;

        if (num == 0) {
            digits[0] = 0;
            num_digits = 1;
        } else {
            var v = num;
            while (v > 0 and num_digits < 3) {
                digits[num_digits] = @intCast(@mod(v, 10));
                v = @divTrunc(v, 10);
                num_digits += 1;
            }
            // Reverse
            if (num_digits > 1) {
                const tmp = digits[0];
                digits[0] = digits[num_digits - 1];
                digits[num_digits - 1] = tmp;
            }
            if (num_digits == 3) {
                // Recompute digits properly
                digits[0] = @intCast(@mod(@divTrunc(num, 100), 10));
                digits[1] = @intCast(@mod(@divTrunc(num, 10), 10));
                digits[2] = @intCast(@mod(num, 10));
            }
        }

        for (0..num_digits) |i| {
            if (self.num_patches[digits[i]]) |lump| {
                video.drawPatch(vid, 0, draw_x, y, w.lumpData(lump));
            }
            draw_x += 14;
        }
    }

    /// Draw a time value as MM:SS
    fn drawTime(self: *const Intermission, vid: *video.VideoState, w: *const Wad, x: i32, y: i32, secs: i32) void {
        const minutes = @divTrunc(secs, 60);
        const seconds = @mod(secs, 60);

        // Draw minutes
        self.drawIntermissionNum(vid, w, x - 56, y, minutes);

        // Draw colon
        if (self.colon_patch) |lump| {
            video.drawPatch(vid, 0, x - 28, y, w.lumpData(lump));
        }

        // Draw seconds (zero-padded would need two digits)
        self.drawIntermissionNum(vid, w, x - 14, y, seconds);
    }

    /// Signal to accelerate (skip counting)
    pub fn accelerateStage(self: *Intermission) void {
        self.accelerate = true;
    }
};

test "intermission state machine" {
    var inter = Intermission{};
    const stats = LevelStats{
        .kills = 10,
        .total_kills = 10,
        .items = 5,
        .total_items = 10,
        .secrets = 0,
        .total_secrets = 1,
        .time_tics = 35 * 60, // 60 seconds
        .par_tics = 35 * 90, // 90 seconds
        .last_level = 0,
        .next_level = 1,
        .episode = 0,
    };

    // Start with a mock WAD - use a zeroed Intermission since we can't init WAD
    _ = stats;
    inter.state = .stat_count;
    inter.kills_percent = 100;
    inter.items_percent = 50;
    inter.secrets_percent = 0;
    inter.time_secs = 60;
    inter.par_time_secs = 90;

    try std.testing.expectEqual(IntermissionState.stat_count, inter.state);

    // Accelerate to skip counting
    inter.accelerateStage();
    _ = inter.ticker();

    try std.testing.expectEqual(IntermissionState.show_next_loc, inter.state);
    try std.testing.expectEqual(@as(i32, 100), inter.cnt_kills);
    try std.testing.expectEqual(@as(i32, 50), inter.cnt_items);
}
