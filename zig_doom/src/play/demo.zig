//! zig_doom/src/play/demo.zig
//!
//! Demo recording and playback — replays of TicCmds.
//! Translated from: linuxdoom-1.10/g_game.c (demo sections)
//! Original: Copyright (C) 1993-1996 id Software, Inc. GPL-2.0
//!
//! DOOM demos (.lmp) are recordings of player input that can be replayed
//! deterministically. The shareware WAD contains DEMO1, DEMO2, DEMO3.

const std = @import("std");
const defs = @import("../defs.zig");
const user = @import("user.zig");
const TicCmd = user.TicCmd;

const c = @cImport({
    @cInclude("stdio.h");
});

const MAXPLAYERS = defs.MAXPLAYERS;
const DEMO_VERSION: u8 = 109; // DOOM 1.9
const DEMO_END_MARKER: u8 = 0x80;

// ============================================================================
// DemoState
// ============================================================================

pub const DemoState = struct {
    playing: bool = false,
    recording: bool = false,

    // Playback state
    data: []const u8 = &.{},
    pos: usize = 0,

    // Header info (parsed on playback start)
    version: u8 = DEMO_VERSION,
    skill: u8 = 2,
    episode: u8 = 1,
    map: u8 = 1,
    deathmatch: bool = false,
    respawn: bool = false,
    fast: bool = false,
    nomonsters: bool = false,
    consoleplayer: u8 = 0,
    player_in_game: [MAXPLAYERS]bool = [_]bool{false} ** MAXPLAYERS,

    // Recording buffer
    rec_buffer: ?RecBuffer = null,

    const RecBuffer = struct {
        data: std.ArrayList(u8),
    };

    /// Start playback from a lump's raw data.
    /// Returns true if the header was parsed successfully.
    /// After calling, the caller should use skill/episode/map to start the level.
    pub fn startPlayback(self: *DemoState, lump_data: []const u8) bool {
        if (lump_data.len < 13) return false;

        self.data = lump_data;
        self.pos = 0;

        // Parse header
        self.version = lump_data[0];
        self.skill = lump_data[1];
        self.episode = lump_data[2];
        self.map = lump_data[3];
        self.deathmatch = lump_data[4] != 0;
        self.respawn = lump_data[5] != 0;
        self.fast = lump_data[6] != 0;
        self.nomonsters = lump_data[7] != 0;
        self.consoleplayer = lump_data[8];

        // Players present (bytes 9-12)
        for (0..MAXPLAYERS) |i| {
            self.player_in_game[i] = lump_data[9 + i] != 0;
        }

        self.pos = 13; // Start of tic data
        self.playing = true;
        self.recording = false;

        return true;
    }

    /// Read the next tic's command for the consoleplayer.
    /// Returns false if the demo has ended (0x80 marker or data exhausted).
    pub fn readTicCmd(self: *DemoState, cmd: *TicCmd) bool {
        if (!self.playing) return false;
        if (self.pos >= self.data.len) {
            self.playing = false;
            return false;
        }

        // Read commands for each active player, but only fill cmd for consoleplayer
        for (0..MAXPLAYERS) |i| {
            if (!self.player_in_game[i]) continue;

            if (self.pos >= self.data.len) {
                self.playing = false;
                return false;
            }

            // Check for end marker
            if (self.data[self.pos] == DEMO_END_MARKER) {
                self.playing = false;
                return false;
            }

            // Need 4 bytes per player per tic
            if (self.pos + 4 > self.data.len) {
                self.playing = false;
                return false;
            }

            if (i == self.consoleplayer) {
                cmd.forwardmove = @bitCast(self.data[self.pos]);
                cmd.sidemove = @bitCast(self.data[self.pos + 1]);
                // angleturn: stored as u8, represents the high byte of the 16-bit turn
                cmd.angleturn = @as(i16, @as(i8, @bitCast(self.data[self.pos + 2]))) << 8;
                cmd.buttons = self.data[self.pos + 3];
            }

            self.pos += 4;
        }

        return true;
    }

    /// Start recording a demo. Writes the header bytes.
    pub fn startRecording(self: *DemoState, allocator: std.mem.Allocator, skill: u8, episode: u8, map: u8, player_in_game: [MAXPLAYERS]bool) void {
        var buf = std.ArrayList(u8){};

        // Write header
        buf.append(allocator, DEMO_VERSION) catch return;
        buf.append(allocator, skill) catch return;
        buf.append(allocator, episode) catch return;
        buf.append(allocator, map) catch return;
        buf.append(allocator, 0) catch return; // deathmatch
        buf.append(allocator, 0) catch return; // respawn
        buf.append(allocator, 0) catch return; // fast
        buf.append(allocator, 0) catch return; // nomonsters
        buf.append(allocator, 0) catch return; // consoleplayer

        for (0..MAXPLAYERS) |i| {
            buf.append(allocator, if (player_in_game[i]) @as(u8, 1) else @as(u8, 0)) catch return;
        }

        self.rec_buffer = .{ .data = buf };
        self.recording = true;
        self.playing = false;
        self.skill = skill;
        self.episode = episode;
        self.map = map;
        self.player_in_game = player_in_game;
    }

    /// Write a TicCmd to the recording buffer
    pub fn writeTicCmd(self: *DemoState, cmd: *const TicCmd, allocator: std.mem.Allocator) void {
        if (!self.recording) return;
        if (self.rec_buffer) |*buf| {
            buf.data.append(allocator, @bitCast(cmd.forwardmove)) catch return;
            buf.data.append(allocator, @bitCast(cmd.sidemove)) catch return;
            // Store high byte of angleturn
            const turn_byte: u8 = @bitCast(@as(i8, @intCast(cmd.angleturn >> 8)));
            buf.data.append(allocator, turn_byte) catch return;
            buf.data.append(allocator, cmd.buttons) catch return;
        }
    }

    /// Stop recording and write the demo file. Returns true on success.
    pub fn stopRecording(self: *DemoState, path: []const u8) bool {
        if (!self.recording) return false;
        self.recording = false;

        if (self.rec_buffer) |*buf| {
            // Append end marker
            // Need a temporary allocator — use the ArrayList's internal one
            // Since we can't easily get it, just use C file I/O
            const f = c.fopen(path.ptr, "wb");
            if (f == null) return false;
            defer _ = c.fclose(f);

            const items = buf.data.items;
            if (items.len > 0) {
                _ = c.fwrite(items.ptr, 1, items.len, f);
            }
            // Write end marker
            const marker = [1]u8{DEMO_END_MARKER};
            _ = c.fwrite(&marker, 1, 1, f);

            return true;
        }

        return false;
    }

    /// Stop playback
    pub fn stopPlayback(self: *DemoState) void {
        self.playing = false;
    }

    /// Free recording buffer
    pub fn deinit(self: *DemoState, allocator: std.mem.Allocator) void {
        if (self.rec_buffer) |*buf| {
            buf.data.deinit(allocator);
            self.rec_buffer = null;
        }
    }

    /// Count the number of active players
    pub fn numPlayers(self: *const DemoState) u8 {
        var count: u8 = 0;
        for (self.player_in_game) |present| {
            if (present) count += 1;
        }
        return count;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "demo header parse" {
    // Build a minimal demo buffer
    var demo_data = [_]u8{
        109, // version
        2, // skill (HMP)
        1, // episode
        1, // map
        0, // deathmatch
        0, // respawn
        0, // fast
        0, // nomonsters
        0, // consoleplayer
        1, 0, 0, 0, // player 1 present, others not
        // One tic of data
        25, 0, 0, 0, // forward=25, side=0, turn=0, buttons=0
        DEMO_END_MARKER,
    };

    var state = DemoState{};
    const ok = state.startPlayback(&demo_data);
    try std.testing.expect(ok);
    try std.testing.expectEqual(@as(u8, 109), state.version);
    try std.testing.expectEqual(@as(u8, 2), state.skill);
    try std.testing.expectEqual(@as(u8, 1), state.episode);
    try std.testing.expectEqual(@as(u8, 1), state.map);
    try std.testing.expect(state.player_in_game[0]);
    try std.testing.expect(!state.player_in_game[1]);
    try std.testing.expect(state.playing);
}

test "demo read ticcmd" {
    var demo_data = [_]u8{
        109, 2, 1, 1, 0, 0, 0, 0, 0, // header
        1, 0, 0, 0, // player present flags
        25, 10, 0, 1, // tic 1: forward=25, side=10, turn=0, buttons=BT_ATTACK
        0, 0, 5, 2, // tic 2: forward=0, side=0, turn=5<<8, buttons=BT_USE
        DEMO_END_MARKER,
    };

    var state = DemoState{};
    _ = state.startPlayback(&demo_data);

    var cmd = TicCmd{};

    // Read tic 1
    const ok1 = state.readTicCmd(&cmd);
    try std.testing.expect(ok1);
    try std.testing.expectEqual(@as(i8, 25), cmd.forwardmove);
    try std.testing.expectEqual(@as(i8, 10), cmd.sidemove);
    try std.testing.expectEqual(@as(u8, 1), cmd.buttons);

    // Read tic 2
    const ok2 = state.readTicCmd(&cmd);
    try std.testing.expect(ok2);
    try std.testing.expectEqual(@as(i8, 0), cmd.forwardmove);
    try std.testing.expectEqual(@as(i16, 5 << 8), cmd.angleturn);
    try std.testing.expectEqual(@as(u8, 2), cmd.buttons);

    // Read end marker — should return false
    const ok3 = state.readTicCmd(&cmd);
    try std.testing.expect(!ok3);
    try std.testing.expect(!state.playing);
}

test "demo too short" {
    var short_data = [_]u8{ 109, 2 };
    var state = DemoState{};
    const ok = state.startPlayback(&short_data);
    try std.testing.expect(!ok);
}

test "demo write and format" {
    const allocator = std.testing.allocator;

    var state = DemoState{};
    const pig = [MAXPLAYERS]bool{ true, false, false, false };
    state.startRecording(allocator, 2, 1, 1, pig);
    defer state.deinit(allocator);

    try std.testing.expect(state.recording);

    // Write a ticcmd
    const cmd = TicCmd{
        .forwardmove = 25,
        .sidemove = -10,
        .angleturn = 640,
        .buttons = 1,
    };
    state.writeTicCmd(&cmd, allocator);

    // Verify the buffer has header (13 bytes) + 1 tic (4 bytes) = 17 bytes
    if (state.rec_buffer) |buf| {
        try std.testing.expectEqual(@as(usize, 17), buf.data.items.len);
        // Header check
        try std.testing.expectEqual(@as(u8, 109), buf.data.items[0]); // version
        try std.testing.expectEqual(@as(u8, 2), buf.data.items[1]); // skill
        try std.testing.expectEqual(@as(u8, 1), buf.data.items[9]); // player 1 present
    } else {
        try std.testing.expect(false); // Should have a buffer
    }
}

test "demo num players" {
    var state = DemoState{};
    state.player_in_game = .{ true, true, false, false };
    try std.testing.expectEqual(@as(u8, 2), state.numPlayers());
}

test "demo stop playback" {
    var demo_data = [_]u8{
        109, 2, 1, 1, 0, 0, 0, 0, 0,
        1, 0, 0, 0,
        25, 0, 0, 0,
        DEMO_END_MARKER,
    };

    var state = DemoState{};
    _ = state.startPlayback(&demo_data);
    try std.testing.expect(state.playing);

    state.stopPlayback();
    try std.testing.expect(!state.playing);
}
