//! zig_doom/src/sound/sound.zig
//!
//! Sound engine — channel management and prioritization.
//! Translated from: linuxdoom-1.10/s_sound.c
//! Original: Copyright (C) 1993-1996 id Software, Inc. GPL-2.0
//!
//! Manages logical sound channels. Does NOT produce actual audio output
//! (that requires Phase 6 platform backends). This is the channel assignment,
//! priority, and distance attenuation logic.

const std = @import("std");
const fixed = @import("../fixed.zig");
const Fixed = fixed.Fixed;
const Angle = fixed.Angle;
const tables = @import("../tables.zig");
const sound_defs = @import("defs.zig");
const SfxId = sound_defs.SfxId;

pub const NUM_CHANNELS = 8;
pub const MAX_DIST: i32 = 1600; // Map units for full attenuation
pub const MAX_VOLUME: i32 = 127;

pub const SoundChannel = struct {
    sfx_id: SfxId = .none,
    origin: ?*anyopaque = null, // Thing that made the sound (for positional audio)
    volume: i32 = 0,
    priority: i32 = 0,
    active: bool = false,
};

pub const SoundEngine = struct {
    channels: [NUM_CHANNELS]SoundChannel = [_]SoundChannel{.{}} ** NUM_CHANNELS,

    // Listener position/angle (player)
    listener_x: Fixed = Fixed.ZERO,
    listener_y: Fixed = Fixed.ZERO,
    listener_angle: Angle = 0,

    /// Initialize the sound engine
    pub fn init() SoundEngine {
        return .{};
    }

    /// Start a sound effect. Finds a free or lowest-priority channel.
    pub fn startSound(self: *SoundEngine, origin: ?*anyopaque, sfx_id: SfxId) void {
        if (sfx_id == .none) return;

        // If origin already has a sound playing, stop it
        if (origin != null) {
            self.stopSound(origin);
        }

        // Find a free channel or the lowest priority one
        var best_idx: usize = 0;
        var best_priority: i32 = std.math.maxInt(i32);

        for (&self.channels, 0..) |*ch, i| {
            if (!ch.active) {
                best_idx = i;
                break;
            }
            if (ch.priority < best_priority) {
                best_priority = ch.priority;
                best_idx = i;
            }
        }

        // Assign channel
        self.channels[best_idx] = .{
            .sfx_id = sfx_id,
            .origin = origin,
            .volume = MAX_VOLUME,
            .priority = @intFromEnum(sfx_id), // Simple priority based on sfx id
            .active = true,
        };
    }

    /// Stop all sounds from a given origin
    pub fn stopSound(self: *SoundEngine, origin: ?*anyopaque) void {
        if (origin == null) return;
        for (&self.channels) |*ch| {
            if (ch.active and ch.origin == origin) {
                ch.active = false;
                ch.sfx_id = .none;
                ch.origin = null;
            }
        }
    }

    /// Update channel volumes and panning based on listener position.
    /// Called once per tic.
    pub fn update(self: *SoundEngine) void {
        for (&self.channels) |*ch| {
            if (!ch.active) continue;

            // If origin exists, compute distance attenuation
            if (ch.origin != null) {
                // In a full implementation, we'd dereference the origin
                // to get x,y position and compute distance/angle.
                // For now, just keep at current volume.
            }
        }
    }

    /// Set listener position for distance/panning calculations
    pub fn setListener(self: *SoundEngine, x: Fixed, y: Fixed, angle: Angle) void {
        self.listener_x = x;
        self.listener_y = y;
        self.listener_angle = angle;
    }

    /// Count active channels (for testing/debug)
    pub fn activeChannels(self: *const SoundEngine) usize {
        var count: usize = 0;
        for (self.channels) |ch| {
            if (ch.active) count += 1;
        }
        return count;
    }
};

/// Compute volume attenuation based on distance
pub fn distanceVolume(base_volume: i32, dist: i32) i32 {
    if (dist >= MAX_DIST) return 0;
    if (dist <= 0) return base_volume;
    return @divTrunc(base_volume * (MAX_DIST - dist), MAX_DIST);
}

/// Compute stereo panning (0=left, 128=center, 255=right) based on angle
pub fn anglePan(listener_angle: Angle, sound_angle: Angle) i32 {
    const diff = sound_angle -% listener_angle;
    // Map angle difference to panning
    // 0 = directly ahead (center), ANG90 = right, ANG270 = left
    const fine = diff >> tables.ANGLETOFINESHIFT;
    const sin_val = tables.finesine[fine & tables.FINEMASK].raw();
    // Scale to 0-255 range, centered at 128
    return 128 + @as(i32, @intCast(@divTrunc(@as(i64, sin_val) * 127, 65536)));
}

test "sound engine init" {
    const engine = SoundEngine.init();
    try std.testing.expectEqual(@as(usize, 0), engine.activeChannels());
}

test "start and stop sound" {
    var engine = SoundEngine.init();

    // Use a simple address as origin
    var dummy: u32 = 42;
    const origin: *anyopaque = @ptrCast(&dummy);

    engine.startSound(origin, .pistol);
    try std.testing.expectEqual(@as(usize, 1), engine.activeChannels());

    engine.stopSound(origin);
    try std.testing.expectEqual(@as(usize, 0), engine.activeChannels());
}

test "start multiple sounds" {
    var engine = SoundEngine.init();

    engine.startSound(null, .pistol);
    engine.startSound(null, .shotgn);
    engine.startSound(null, .plasma);
    try std.testing.expectEqual(@as(usize, 3), engine.activeChannels());
}

test "distance volume" {
    try std.testing.expectEqual(@as(i32, 127), distanceVolume(127, 0));
    try std.testing.expectEqual(@as(i32, 0), distanceVolume(127, 1600));
    // Half distance should give roughly half volume
    const half = distanceVolume(127, 800);
    try std.testing.expect(half > 50 and half < 70);
}
