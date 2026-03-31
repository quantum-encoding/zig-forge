//! zig_doom/src/platform/alsa_sound.zig
//!
//! ALSA PCM sound backend for Linux.
//! Stub/placeholder for Phase 6 — the sound engine (sound/sound.zig) handles
//! channel management; this just needs to output mixed PCM data.
//!
//! Full implementation would:
//! - Open ALSA "default" device via snd_pcm_open()
//! - Configure: 11025Hz or 22050Hz, mono, S16_LE
//! - Write mixed PCM frames in a polling loop
//!
//! For now, this is a typed stub that returns false from initSound(),
//! so the engine gracefully falls back to silence.

const std = @import("std");
const Platform = @import("interface.zig").Platform;
const event_mod = @import("../event.zig");
const Event = event_mod.Event;
const defs = @import("../defs.zig");

const SCREENSIZE = defs.SCREENSIZE;

// Uncomment when ALSA headers are available:
// const c = @cImport({
//     @cInclude("alsa/asoundlib.h");
// });

const AlsaState = struct {
    allocator: std.mem.Allocator,
    platform: Platform,
    // pcm_handle: ?*c.snd_pcm_t = null,
    sound_init: bool = false,
};

fn alsaInitVideo(_: *anyopaque, _: u32, _: u32) bool { return false; }
fn alsaDeinitVideo(_: *anyopaque) void {}
fn alsaFinishUpdate(_: *anyopaque, _: *const [SCREENSIZE]u8, _: *const [768]u8) void {}
fn alsaSetPalette(_: *anyopaque, _: *const [768]u8) void {}
fn alsaGetEvents(_: *anyopaque, buffer: []Event) []Event { return buffer[0..0]; }
fn alsaGetTics(_: *anyopaque) u32 { return 0; }

fn alsaInitSound(_: *anyopaque) bool {
    // TODO: Implement ALSA PCM initialization
    // const rc = c.snd_pcm_open(&state.pcm_handle, "default", c.SND_PCM_STREAM_PLAYBACK, 0);
    // if (rc < 0) return false;
    // ... set hw params ...
    return false;
}

fn alsaDeinitSound(_: *anyopaque) void {
    // TODO: snd_pcm_close(state.pcm_handle)
}

fn alsaStartSound(_: *anyopaque, _: [*]const u8, _: u32, _: u32, _: u32, _: u32) u32 {
    return 0;
}

fn alsaStopSound(_: *anyopaque, _: u32) void {}
fn alsaIsSoundPlaying(_: *anyopaque, _: u32) bool { return false; }
fn alsaUpdateSound(_: *anyopaque) void {}
fn alsaSleep(_: *anyopaque, _: u32) void {}
fn alsaGetTitle(_: *anyopaque) []const u8 { return "zig_doom (ALSA)"; }
fn alsaIsQuitRequested(_: *anyopaque) bool { return false; }

/// Create an ALSA sound backend (stub)
pub fn create(allocator: std.mem.Allocator) ?*Platform {
    const state = allocator.create(AlsaState) catch return null;
    state.* = .{
        .allocator = allocator,
        .platform = .{
            .initVideo = &alsaInitVideo,
            .deinitVideo = &alsaDeinitVideo,
            .finishUpdate = &alsaFinishUpdate,
            .setPalette = &alsaSetPalette,
            .getEvents = &alsaGetEvents,
            .getTics = &alsaGetTics,
            .initSound = &alsaInitSound,
            .deinitSound = &alsaDeinitSound,
            .startSound = &alsaStartSound,
            .stopSound = &alsaStopSound,
            .isSoundPlaying = &alsaIsSoundPlaying,
            .updateSound = &alsaUpdateSound,
            .sleep = &alsaSleep,
            .getTitle = &alsaGetTitle,
            .isQuitRequested = &alsaIsQuitRequested,
            .impl = undefined,
        },
    };
    state.platform.impl = @ptrCast(state);
    return &state.platform;
}

/// Destroy the ALSA backend
pub fn destroy(platform: *Platform, allocator: std.mem.Allocator) void {
    const state: *AlsaState = @ptrCast(@alignCast(platform.impl));
    allocator.destroy(state);
}
