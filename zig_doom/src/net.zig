//! zig_doom/src/net.zig
//!
//! Network tic synchronization — lockstep model.
//! Translated from: linuxdoom-1.10/d_net.c, d_net.h
//! Original: Copyright (C) 1993-1996 id Software, Inc. GPL-2.0
//!
//! DOOM uses a lockstep networking model where all players exchange TicCmds
//! each tic. For Phase 7, this implements single-player (the common case).

const std = @import("std");
const defs = @import("defs.zig");
const event_mod = @import("event.zig");
const Event = event_mod.Event;
const user = @import("play/user.zig");
const TicCmd = user.TicCmd;
const BT_ATTACK = user.BT_ATTACK;
const BT_USE = user.BT_USE;
const BT_CHANGE = user.BT_CHANGE;
const BT_WEAPONMASK = user.BT_WEAPONMASK;
const BT_WEAPONSHIFT = user.BT_WEAPONSHIFT;

const MAXPLAYERS = defs.MAXPLAYERS;

pub const BACKUPTICS = 12;

// ============================================================================
// Button bit constants (exported for other modules)
// ============================================================================

pub const BT_ATTACK_BIT = BT_ATTACK;
pub const BT_USE_BIT = BT_USE;
pub const BT_CHANGE_BIT = BT_CHANGE;

// ============================================================================
// NetState — network/input state
// ============================================================================

pub const NetState = struct {
    consoleplayer: u8 = 0,
    num_players: u8 = 1,
    netgame: bool = false,
    deathmatch: u8 = 0, // 0=coop, 1=deathmatch, 2=altdeath

    // Tic command ring buffers
    netcmds: [MAXPLAYERS][BACKUPTICS]TicCmd = [_][BACKUPTICS]TicCmd{[_]TicCmd{.{}} ** BACKUPTICS} ** MAXPLAYERS,

    // Input state tracking
    gamekeydown: [256]bool = [_]bool{false} ** 256,
    mousebuttons: [3]bool = [_]bool{false} ** 3,
    mouse_x: i32 = 0,
    joybuttons: [4]bool = [_]bool{false} ** 4,

    // Turn tracking for slow-turn acceleration
    turnheld: i32 = 0,

    // Current tic counter (for ring buffer indexing)
    maketic: u32 = 0,

    /// Initialize a new NetState for single player
    pub fn init() NetState {
        return .{};
    }

    /// Build a TicCmd from current input events for this tic
    pub fn buildTicCmd(self: *NetState, cmd: *TicCmd, events: []const Event) void {
        cmd.* = .{};

        // Process input events to update key state
        for (events) |ev| {
            switch (ev.event_type) {
                .key_down => {
                    const key = clampKey(ev.data1);
                    self.gamekeydown[key] = true;
                },
                .key_up => {
                    const key = clampKey(ev.data1);
                    self.gamekeydown[key] = false;
                },
                .mouse => {
                    self.mousebuttons[0] = (ev.data1 & 1) != 0;
                    self.mousebuttons[1] = (ev.data1 & 2) != 0;
                    self.mousebuttons[2] = (ev.data1 & 4) != 0;
                    self.mouse_x = ev.data2;
                },
                .joystick => {
                    self.joybuttons[0] = (ev.data1 & 1) != 0;
                    self.joybuttons[1] = (ev.data1 & 2) != 0;
                    self.joybuttons[2] = (ev.data1 & 4) != 0;
                    self.joybuttons[3] = (ev.data1 & 8) != 0;
                },
            }
        }

        // Determine run mode
        const running = self.gamekeydown[clampKey(event_mod.KEY_SPEED)];
        const speed: usize = if (running) 1 else 0;

        // Strafe key held?
        const strafe_on = self.gamekeydown[clampKey(event_mod.KEY_STRAFE)];

        // Forward/backward
        if (self.gamekeydown[clampKey(event_mod.KEY_UPARROW)]) {
            cmd.forwardmove +%= forwardmove[speed];
        }
        if (self.gamekeydown[clampKey(event_mod.KEY_DOWNARROW)]) {
            cmd.forwardmove -%= forwardmove[speed];
        }

        // Turning / strafing
        if (self.gamekeydown[clampKey(event_mod.KEY_RIGHTARROW)]) {
            if (strafe_on) {
                cmd.sidemove +%= sidemove[speed];
            } else {
                cmd.angleturn -%= turnAmount(self, speed);
            }
        }
        if (self.gamekeydown[clampKey(event_mod.KEY_LEFTARROW)]) {
            if (strafe_on) {
                cmd.sidemove -%= sidemove[speed];
            } else {
                cmd.angleturn +%= turnAmount(self, speed);
            }
        }

        // Track how long turn key is held (for slow-turn acceleration)
        if (self.gamekeydown[clampKey(event_mod.KEY_RIGHTARROW)] or
            self.gamekeydown[clampKey(event_mod.KEY_LEFTARROW)])
        {
            self.turnheld += 1;
        } else {
            self.turnheld = 0;
        }

        // Fire
        if (self.gamekeydown[clampKey(event_mod.KEY_FIRE)] or self.mousebuttons[0]) {
            cmd.buttons |= BT_ATTACK;
        }

        // Use
        if (self.gamekeydown[clampKey(event_mod.KEY_USE)]) {
            cmd.buttons |= BT_USE;
        }

        // Weapon change: keys '1' through '7'
        inline for (0..7) |w| {
            if (self.gamekeydown['1' + w]) {
                cmd.buttons |= BT_CHANGE;
                cmd.buttons |= @as(u8, @intCast(w)) << BT_WEAPONSHIFT;
            }
        }

        // Mouse turning
        if (self.mouse_x != 0) {
            // Mouse sensitivity: roughly 8 units per pixel
            const mouse_turn: i16 = @intCast(std.math.clamp(self.mouse_x * 8, -1280, 1280));
            cmd.angleturn +%= mouse_turn;
            self.mouse_x = 0;
        }

        // Store the command in the ring buffer
        const buf_idx = self.maketic % BACKUPTICS;
        self.netcmds[self.consoleplayer][buf_idx] = cmd.*;
        self.maketic +%= 1;
    }

    /// Get the ticcmd for a player at a given tic
    pub fn getTicCmd(self: *NetState, player: u8, tic: u32) *TicCmd {
        const buf_idx = tic % BACKUPTICS;
        return &self.netcmds[player][buf_idx];
    }

    /// Network update — for single player, this is a no-op.
    /// For netgame, this would handle packet send/recv.
    pub fn netUpdate(self: *NetState) void {
        _ = self;
        // Single player: nothing to do, commands are already in the buffer.
        // In a network game, this would:
        //   1. Send our maketic's TicCmd to all peers
        //   2. Receive TicCmds from peers
        //   3. Block until all players' cmds for the current tic are available
    }
};

// ============================================================================
// Movement speed tables (matching original DOOM exactly)
// ============================================================================

const forwardmove = [2]i8{ 25, 50 }; // walk, run
const sidemove = [2]i8{ 24, 40 }; // strafe walk, strafe run
const angleturn = [3]i16{ 640, 1280, 320 }; // normal, fast, slow-start

/// Calculate turn amount based on speed and turn-hold duration
fn turnAmount(self: *const NetState, speed: usize) i16 {
    if (self.turnheld < 6) {
        // Slow turning for first 6 tics
        return angleturn[2];
    }
    return angleturn[speed];
}

/// Clamp key code to valid array index
fn clampKey(key: i32) u8 {
    if (key < 0 or key > 255) return 0;
    return @intCast(key);
}

// ============================================================================
// Tests
// ============================================================================

test "net state init" {
    const net = NetState.init();
    try std.testing.expectEqual(@as(u8, 0), net.consoleplayer);
    try std.testing.expectEqual(@as(u8, 1), net.num_players);
    try std.testing.expect(!net.netgame);
}

test "build ticcmd forward" {
    var net = NetState.init();
    var cmd = TicCmd{};

    // Simulate pressing up arrow
    const events = [_]Event{
        .{ .event_type = .key_down, .data1 = event_mod.KEY_UPARROW, .data2 = 0, .data3 = 0 },
    };

    net.buildTicCmd(&cmd, &events);
    try std.testing.expectEqual(@as(i8, 25), cmd.forwardmove); // Walk speed
}

test "build ticcmd forward run" {
    var net = NetState.init();
    var cmd = TicCmd{};

    // Press shift (run) + up arrow
    const events = [_]Event{
        .{ .event_type = .key_down, .data1 = event_mod.KEY_SPEED, .data2 = 0, .data3 = 0 },
        .{ .event_type = .key_down, .data1 = event_mod.KEY_UPARROW, .data2 = 0, .data3 = 0 },
    };

    net.buildTicCmd(&cmd, &events);
    try std.testing.expectEqual(@as(i8, 50), cmd.forwardmove); // Run speed
}

test "build ticcmd turn" {
    var net = NetState.init();
    var cmd = TicCmd{};

    // Press left arrow (should turn left = positive angleturn)
    const events = [_]Event{
        .{ .event_type = .key_down, .data1 = event_mod.KEY_LEFTARROW, .data2 = 0, .data3 = 0 },
    };

    net.buildTicCmd(&cmd, &events);
    // First 6 tics use slow turn (320)
    try std.testing.expectEqual(@as(i16, 320), cmd.angleturn);
}

test "build ticcmd fire" {
    var net = NetState.init();
    var cmd = TicCmd{};

    const events = [_]Event{
        .{ .event_type = .key_down, .data1 = event_mod.KEY_FIRE, .data2 = 0, .data3 = 0 },
    };

    net.buildTicCmd(&cmd, &events);
    try std.testing.expect(cmd.buttons & BT_ATTACK != 0);
}

test "build ticcmd use" {
    var net = NetState.init();
    var cmd = TicCmd{};

    const events = [_]Event{
        .{ .event_type = .key_down, .data1 = event_mod.KEY_USE, .data2 = 0, .data3 = 0 },
    };

    net.buildTicCmd(&cmd, &events);
    try std.testing.expect(cmd.buttons & BT_USE != 0);
}

test "build ticcmd weapon change" {
    var net = NetState.init();
    var cmd = TicCmd{};

    // Press '3' for shotgun
    const events = [_]Event{
        .{ .event_type = .key_down, .data1 = '3', .data2 = 0, .data3 = 0 },
    };

    net.buildTicCmd(&cmd, &events);
    try std.testing.expect(cmd.buttons & BT_CHANGE != 0);
    const weapon = (cmd.buttons & BT_WEAPONMASK) >> BT_WEAPONSHIFT;
    try std.testing.expectEqual(@as(u8, 2), weapon); // '3' - '1' = 2 (shotgun index)
}

test "build ticcmd strafe" {
    var net = NetState.init();
    var cmd = TicCmd{};

    // Hold strafe + right arrow = strafe right
    const events = [_]Event{
        .{ .event_type = .key_down, .data1 = event_mod.KEY_STRAFE, .data2 = 0, .data3 = 0 },
        .{ .event_type = .key_down, .data1 = event_mod.KEY_RIGHTARROW, .data2 = 0, .data3 = 0 },
    };

    net.buildTicCmd(&cmd, &events);
    try std.testing.expectEqual(@as(i8, 24), cmd.sidemove); // Walk strafe speed
    try std.testing.expectEqual(@as(i16, 0), cmd.angleturn); // No turning
}

test "get ticcmd roundtrip" {
    var net = NetState.init();
    var cmd = TicCmd{};

    const events = [_]Event{
        .{ .event_type = .key_down, .data1 = event_mod.KEY_UPARROW, .data2 = 0, .data3 = 0 },
    };

    net.buildTicCmd(&cmd, &events);

    // The command should be stored and retrievable
    const stored = net.getTicCmd(0, 0);
    try std.testing.expectEqual(@as(i8, 25), stored.forwardmove);
}

test "key up clears state" {
    var net = NetState.init();
    var cmd = TicCmd{};

    // Press up arrow
    const ev_down = [_]Event{
        .{ .event_type = .key_down, .data1 = event_mod.KEY_UPARROW, .data2 = 0, .data3 = 0 },
    };
    net.buildTicCmd(&cmd, &ev_down);
    try std.testing.expectEqual(@as(i8, 25), cmd.forwardmove);

    // Release up arrow
    const ev_up = [_]Event{
        .{ .event_type = .key_up, .data1 = event_mod.KEY_UPARROW, .data2 = 0, .data3 = 0 },
    };
    net.buildTicCmd(&cmd, &ev_up);
    try std.testing.expectEqual(@as(i8, 0), cmd.forwardmove);
}
