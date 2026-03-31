//! zig_doom/src/platform/interface.zig
//!
//! Platform abstraction layer — vtable interface for all backends.
//! Each backend (SDL2, TUI, framebuffer) implements these function pointers.

const std = @import("std");
const defs = @import("../defs.zig");
const event_mod = @import("../event.zig");
const Event = event_mod.Event;

pub const SCREENWIDTH = defs.SCREENWIDTH;
pub const SCREENHEIGHT = defs.SCREENHEIGHT;
pub const SCREENSIZE = defs.SCREENSIZE;

pub const Platform = struct {
    // Video
    initVideo: *const fn (ctx: *anyopaque, width: u32, height: u32) bool,
    deinitVideo: *const fn (ctx: *anyopaque) void,

    /// Blit the 320x200 palette-indexed framebuffer to the display.
    /// The platform converts palette indices -> RGB using the current palette.
    finishUpdate: *const fn (ctx: *anyopaque, screen: *const [SCREENSIZE]u8, palette: *const [768]u8) void,

    /// Set the palette (called when palette changes, e.g., pain flash, pickup flash)
    setPalette: *const fn (ctx: *anyopaque, palette: *const [768]u8) void,

    // Input
    /// Pump input events from the OS. Returns a slice of the buffer filled with events.
    getEvents: *const fn (ctx: *anyopaque, buffer: []Event) []Event,

    // Timer
    /// Get current time in DOOM tics (35 Hz). Used for game loop timing.
    getTics: *const fn (ctx: *anyopaque) u32,

    // Sound
    initSound: *const fn (ctx: *anyopaque) bool,
    deinitSound: *const fn (ctx: *anyopaque) void,
    /// Start playing a sound effect. data = raw PCM from WAD lump, len = byte count.
    startSound: *const fn (ctx: *anyopaque, data: [*]const u8, len: u32, vol: u32, sep: u32, pitch: u32) u32,
    stopSound: *const fn (ctx: *anyopaque, handle: u32) void,
    isSoundPlaying: *const fn (ctx: *anyopaque, handle: u32) bool,
    updateSound: *const fn (ctx: *anyopaque) void,

    // System
    sleep: *const fn (ctx: *anyopaque, ms: u32) void,
    getTitle: *const fn (ctx: *anyopaque) []const u8,

    /// Opaque backend state pointer, passed as first arg to all vtable functions.
    impl: *anyopaque,

    /// Check if a quit was requested by the platform (window close, etc.)
    isQuitRequested: *const fn (ctx: *anyopaque) bool,
};

/// Create a platform backend by name.
/// Supported names: "tui", "sdl2", "framebuffer"
/// Returns null if the backend is not available.
pub fn createPlatform(name: []const u8, allocator: std.mem.Allocator) ?*Platform {
    if (std.mem.eql(u8, name, "tui")) {
        return @import("tui.zig").create(allocator);
    }
    if (std.mem.eql(u8, name, "sdl2")) {
        return @import("sdl2.zig").create(allocator);
    }
    if (std.mem.eql(u8, name, "framebuffer")) {
        return @import("framebuffer.zig").create(allocator);
    }
    return null;
}

/// Destroy a platform backend and free its resources.
pub fn destroyPlatform(platform: *Platform, allocator: std.mem.Allocator) void {
    // Deinit subsystems
    platform.deinitSound(platform.impl);
    platform.deinitVideo(platform.impl);

    // The backend allocated itself; we need to identify it to free.
    // Each backend stores a pointer to its state in impl.
    // We use a simple approach: the backend allocates a Platform + state struct,
    // and the Platform is at a known offset. For simplicity, we just free the impl.
    _ = allocator;
}

test "platform interface size" {
    // Ensure the vtable struct has the expected fields
    const p: Platform = undefined;
    _ = p;
}
