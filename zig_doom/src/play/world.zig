//! zig_doom/src/play/world.zig
//!
//! Playsim world context — the globals vanilla DOOM kept in g_game.c /
//! p_setup.c scope. Action functions reach the level geometry, the player
//! list, and the sound engine through here; Game sets everything in
//! doLoadLevel and keeps leveltime in sync each tic.

const std = @import("std");
const fixed = @import("../fixed.zig");
const Fixed = fixed.Fixed;
const setup = @import("setup.zig");
const sound_mod = @import("../sound/sound.zig");
const sound_defs = @import("../sound/defs.zig");

/// Current level geometry (null outside a level)
pub var level: ?*setup.Level = null;

/// The game's player array (MAXPLAYERS entries) and in-game flags.
/// Typed as anyopaque to avoid a user.zig import cycle; cast at use site.
pub var players: ?*anyopaque = null;
pub var player_in_game: ?*const [4]bool = null;

/// Sound engine (null in headless renders/tests — playSound no-ops)
pub var sound: ?*sound_mod.SoundEngine = null;

/// Allocator for runtime spawns (missiles, puffs, blood)
pub var allocator: ?std.mem.Allocator = null;

/// Level time in tics (synced by Game.doTick; used for bobbing/AI cadence)
pub var leveltime: i32 = 0;

/// Current map numbers (for boss specials: E1M8 etc.)
pub var episode: u8 = 1;
pub var map: u8 = 1;

/// Resolved flat number of F_SKY1 (missiles vanish into sky walls)
pub var sky_flatnum: i32 = -1;

/// Exit requests raised by line specials; Game polls + clears these.
pub var exit_level: bool = false;
pub var exit_secret: bool = false;

pub fn reset() void {
    exit_level = false;
    exit_secret = false;
    leveltime = 0;
}

/// Play a sound from the mobjinfo sound tables (i32 index into SfxId).
/// origin is a *MapObject (opaque to avoid the import cycle).
pub fn playSound(origin: ?*anyopaque, sfx_index: i32) void {
    const snd = sound orelse return;
    if (sfx_index <= 0) return;
    const count = @typeInfo(sound_defs.SfxId).@"enum".fields.len;
    if (sfx_index >= count) return;
    snd.startSound(origin, @enumFromInt(@as(u16, @intCast(sfx_index))));
}

/// Play a sound by enum (for weapon/UI code that knows the SfxId directly)
pub fn playSfx(origin: ?*anyopaque, sfx: sound_defs.SfxId) void {
    const snd = sound orelse return;
    snd.startSound(origin, sfx);
}

test "playSound without engine is a no-op" {
    sound = null;
    playSound(null, 1);
    playSfx(null, .pistol);
}
