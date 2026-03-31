//! zig_doom/src/play/switch.zig
//!
//! Switch texture swapping — toggle wall textures on activation.
//! Translated from: linuxdoom-1.10/p_switch.c
//! Original: Copyright (C) 1993-1996 id Software, Inc. GPL-2.0

const std = @import("std");
const fixed = @import("../fixed.zig");
const Fixed = fixed.Fixed;
const defs = @import("../defs.zig");
const setup = @import("setup.zig");
const Line = setup.Line;
const Side = setup.Side;
const Level = setup.Level;

// ============================================================================
// Constants
// ============================================================================

pub const BUTTONTIME: i32 = 35; // 1 second
pub const MAXBUTTONS: usize = 16;

// ============================================================================
// Switch texture pair
// ============================================================================

pub const SwitchPair = struct {
    name1: [9]u8,
    name2: [9]u8,
    episode: i16,
};

// Episode 1 (shareware) switch pairs
const alphSwitchList = [_]SwitchPair{
    makePair("SW1BRCOM", "SW2BRCOM", 1),
    makePair("SW1BRN1", "SW2BRN1", 1),
    makePair("SW1BRN2", "SW2BRN2", 1),
    makePair("SW1BRNGN", "SW2BRNGN", 1),
    makePair("SW1BROWN", "SW2BROWN", 1),
    makePair("SW1COMM", "SW2COMM", 1),
    makePair("SW1COMP", "SW2COMP", 1),
    makePair("SW1DIRT", "SW2DIRT", 1),
    makePair("SW1EXIT", "SW2EXIT", 1),
    makePair("SW1GRAY", "SW2GRAY", 1),
    makePair("SW1GRAY1", "SW2GRAY1", 1),
    makePair("SW1METAL", "SW2METAL", 1),
    makePair("SW1PIPE", "SW2PIPE", 1),
    makePair("SW1SLAD", "SW2SLAD", 1),
    makePair("SW1STARG", "SW2STARG", 1),
    makePair("SW1STON1", "SW2STON1", 1),
    makePair("SW1STON2", "SW2STON2", 1),
    makePair("SW1STONE", "SW2STONE", 1),
    makePair("SW1STRTN", "SW2STRTN", 1),
    makePair("SW1BLUE", "SW2BLUE", 2),
    makePair("SW1CMT", "SW2CMT", 2),
    makePair("SW1GARG", "SW2GARG", 2),
    makePair("SW1GSTON", "SW2GSTON", 2),
    makePair("SW1HOT", "SW2HOT", 2),
    makePair("SW1LION", "SW2LION", 2),
    makePair("SW1SATYR", "SW2SATYR", 2),
    makePair("SW1SKIN", "SW2SKIN", 2),
    makePair("SW1VINE", "SW2VINE", 2),
    makePair("SW1WOOD", "SW2WOOD", 2),
};

fn makePair(comptime n1: []const u8, comptime n2: []const u8, episode: i16) SwitchPair {
    var p = SwitchPair{
        .name1 = [_]u8{0} ** 9,
        .name2 = [_]u8{0} ** 9,
        .episode = episode,
    };
    for (n1, 0..) |ch, idx| {
        p.name1[idx] = ch;
    }
    for (n2, 0..) |ch, idx| {
        p.name2[idx] = ch;
    }
    return p;
}

// ============================================================================
// Active switch list (resolved texture indices)
// ============================================================================

const MAX_SWITCH_PAIRS = 50;

var switch_tex1: [MAX_SWITCH_PAIRS]i16 = [_]i16{0} ** MAX_SWITCH_PAIRS;
var switch_tex2: [MAX_SWITCH_PAIRS]i16 = [_]i16{0} ** MAX_SWITCH_PAIRS;
var num_switches: usize = 0;

/// Initialize the switch list from the alphSwitchList table.
/// In full DOOM, this resolves texture names to indices.
/// Here we just copy the count for tracking purposes.
pub fn initSwitchList(episode: i16) void {
    num_switches = 0;
    for (alphSwitchList) |pair| {
        if (pair.episode <= episode) {
            if (num_switches < MAX_SWITCH_PAIRS) {
                // In full implementation, resolve pair.name1/name2 to texture indices
                // For now, store the pair index directly
                switch_tex1[num_switches] = @intCast(num_switches);
                switch_tex2[num_switches] = @intCast(num_switches + MAX_SWITCH_PAIRS);
                num_switches += 1;
            }
        }
    }
}

// ============================================================================
// Button state — tracks switches that need to revert
// ============================================================================

pub const ButtonPosition = enum {
    top,
    middle,
    bottom,
};

pub const Button = struct {
    line_idx: ?usize = null,
    position: ButtonPosition = .middle,
    timer: i32 = 0,
};

var buttons: [MAXBUTTONS]Button = [_]Button{.{}} ** MAXBUTTONS;

/// Change a switch texture (swap to partner)
pub fn changeSwitchTexture(line_idx: usize, use_again: bool, level: *Level) void {
    if (line_idx >= level.lines.len) return;
    const line = &level.lines[line_idx];

    if (line.sidenum[0] < 0) return;
    const side_idx: usize = @intCast(line.sidenum[0]);
    if (side_idx >= level.sides.len) return;
    const side = &level.sides[side_idx];

    // Try to find and swap the texture
    // Check top, middle, bottom textures against switch list
    var found = false;
    var position: ButtonPosition = .middle;

    // Check mid texture
    if (findAndSwapTexture(&side.midtexture)) {
        found = true;
        position = .middle;
    } else if (findAndSwapTexture(&side.toptexture)) {
        found = true;
        position = .top;
    } else if (findAndSwapTexture(&side.bottomtexture)) {
        found = true;
        position = .bottom;
    }

    if (!found) return;

    // If repeatable, start a button timer to swap back
    if (use_again) {
        for (&buttons) |*button| {
            if (button.line_idx == null) {
                button.* = .{
                    .line_idx = line_idx,
                    .position = position,
                    .timer = BUTTONTIME,
                };
                return;
            }
        }
    }
}

/// Try to swap a texture with its switch pair. Returns true if swapped.
fn findAndSwapTexture(tex: *i16) bool {
    for (0..num_switches) |i| {
        if (tex.* == switch_tex1[i]) {
            tex.* = switch_tex2[i];
            return true;
        }
        if (tex.* == switch_tex2[i]) {
            tex.* = switch_tex1[i];
            return true;
        }
    }
    return false;
}

/// Per-tic: check button timers and swap textures back when expired
pub fn checkButtons(level: *Level) void {
    for (&buttons) |*button| {
        if (button.line_idx) |line_idx| {
            button.timer -= 1;
            if (button.timer <= 0) {
                // Swap texture back
                if (line_idx < level.lines.len) {
                    const line = &level.lines[line_idx];
                    if (line.sidenum[0] >= 0) {
                        const side_idx: usize = @intCast(line.sidenum[0]);
                        if (side_idx < level.sides.len) {
                            const side = &level.sides[side_idx];
                            switch (button.position) {
                                .top => _ = findAndSwapTexture(&side.toptexture),
                                .middle => _ = findAndSwapTexture(&side.midtexture),
                                .bottom => _ = findAndSwapTexture(&side.bottomtexture),
                            }
                        }
                    }
                }
                button.line_idx = null;
                button.timer = 0;
            }
        }
    }
}

/// Clear all active buttons (for level init)
pub fn clearButtons() void {
    for (&buttons) |*button| {
        button.* = .{};
    }
}

// ============================================================================
// Tests
// ============================================================================

test "makePair comptime" {
    const pair = makePair("SW1BRCOM", "SW2BRCOM", 1);
    try std.testing.expect(std.mem.eql(u8, "SW1BRCOM\x00", &pair.name1));
    try std.testing.expect(std.mem.eql(u8, "SW2BRCOM\x00", &pair.name2));
    try std.testing.expectEqual(@as(i16, 1), pair.episode);
}

test "initSwitchList episode 1" {
    initSwitchList(1);
    // Episode 1 has 19 pairs
    try std.testing.expectEqual(@as(usize, 19), num_switches);
}

test "initSwitchList episode 2" {
    initSwitchList(2);
    // Episode 1 (19) + Episode 2 (10) = 29 pairs
    try std.testing.expectEqual(@as(usize, 29), num_switches);
}

test "clearButtons" {
    buttons[0] = .{ .line_idx = 5, .position = .top, .timer = 10 };
    clearButtons();
    try std.testing.expectEqual(@as(?usize, null), buttons[0].line_idx);
}

test "button time constant" {
    try std.testing.expectEqual(@as(i32, 35), BUTTONTIME);
}
