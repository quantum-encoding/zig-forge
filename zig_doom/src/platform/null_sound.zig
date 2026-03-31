//! zig_doom/src/platform/null_sound.zig
//!
//! No-op sound backend for platforms without sound support or
//! when sound is explicitly disabled via CLI.

const std = @import("std");
const Platform = @import("interface.zig").Platform;
const event_mod = @import("../event.zig");
const Event = event_mod.Event;
const defs = @import("../defs.zig");

const SCREENSIZE = defs.SCREENSIZE;

const NullSoundState = struct {
    allocator: std.mem.Allocator,
    platform: Platform,
};

fn nullInitVideo(_: *anyopaque, _: u32, _: u32) bool { return false; }
fn nullDeinitVideo(_: *anyopaque) void {}
fn nullFinishUpdate(_: *anyopaque, _: *const [SCREENSIZE]u8, _: *const [768]u8) void {}
fn nullSetPalette(_: *anyopaque, _: *const [768]u8) void {}
fn nullGetEvents(_: *anyopaque, buffer: []Event) []Event { return buffer[0..0]; }
fn nullGetTics(_: *anyopaque) u32 { return 0; }
fn nullInitSound(_: *anyopaque) bool { return true; }
fn nullDeinitSound(_: *anyopaque) void {}
fn nullStartSound(_: *anyopaque, _: [*]const u8, _: u32, _: u32, _: u32, _: u32) u32 { return 0; }
fn nullStopSound(_: *anyopaque, _: u32) void {}
fn nullIsSoundPlaying(_: *anyopaque, _: u32) bool { return false; }
fn nullUpdateSound(_: *anyopaque) void {}
fn nullSleep(_: *anyopaque, _: u32) void {}
fn nullGetTitle(_: *anyopaque) []const u8 { return "zig_doom (no sound)"; }
fn nullIsQuitRequested(_: *anyopaque) bool { return false; }

/// Create a no-op sound-only platform (all functions are no-ops)
pub fn create(allocator: std.mem.Allocator) ?*Platform {
    const state = allocator.create(NullSoundState) catch return null;
    state.* = .{
        .allocator = allocator,
        .platform = .{
            .initVideo = &nullInitVideo,
            .deinitVideo = &nullDeinitVideo,
            .finishUpdate = &nullFinishUpdate,
            .setPalette = &nullSetPalette,
            .getEvents = &nullGetEvents,
            .getTics = &nullGetTics,
            .initSound = &nullInitSound,
            .deinitSound = &nullDeinitSound,
            .startSound = &nullStartSound,
            .stopSound = &nullStopSound,
            .isSoundPlaying = &nullIsSoundPlaying,
            .updateSound = &nullUpdateSound,
            .sleep = &nullSleep,
            .getTitle = &nullGetTitle,
            .isQuitRequested = &nullIsQuitRequested,
            .impl = undefined,
        },
    };
    state.platform.impl = @ptrCast(state);
    return &state.platform;
}

/// Destroy the null sound backend
pub fn destroy(platform: *Platform, allocator: std.mem.Allocator) void {
    const state: *NullSoundState = @ptrCast(@alignCast(platform.impl));
    allocator.destroy(state);
}

test "null sound creates successfully" {
    const alloc = std.testing.allocator;
    const platform = create(alloc) orelse unreachable;
    defer destroy(platform, alloc);

    try std.testing.expect(platform.initSound(platform.impl));
    try std.testing.expect(!platform.isSoundPlaying(platform.impl, 0));
    try std.testing.expectEqual(@as(u32, 0), platform.startSound(platform.impl, undefined, 0, 0, 0, 0));
    try std.testing.expectEqualStrings("zig_doom (no sound)", platform.getTitle(platform.impl));
}
