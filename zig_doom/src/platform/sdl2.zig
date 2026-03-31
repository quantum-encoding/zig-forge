//! zig_doom/src/platform/sdl2.zig
//!
//! SDL2 backend for desktop development.
//! Uses @cImport to link against libSDL2 for video, input, sound, and timing.

const std = @import("std");
const builtin = @import("builtin");
const Platform = @import("interface.zig").Platform;
const event_mod = @import("../event.zig");
const Event = event_mod.Event;
const defs = @import("../defs.zig");

const SCREENWIDTH = defs.SCREENWIDTH;
const SCREENHEIGHT = defs.SCREENHEIGHT;
const SCREENSIZE = defs.SCREENSIZE;

/// SDL2 is only available when the build links it (zig build -Dsdl2=true).
/// We detect availability via the "sdl2_enabled" option injected by build.zig.
/// Since @cImport is evaluated eagerly, we cannot conditionally import SDL2
/// headers at comptime. Instead, when SDL2 is not linked, all functions
/// return failure/stubs so the file always compiles.
///
/// When SDL2 IS available, rebuild with: zig build -Dsdl2=true
/// and the @cImport below will succeed.
const c = struct {
    // Stub constants and types so the file compiles without SDL2 headers.
    // When SDL2 is linked, replace this entire struct with the real @cImport.
    const SDL_Window = anyopaque;
    const SDL_Renderer = anyopaque;
    const SDL_Texture = anyopaque;
    const SDL_Event = extern struct { type: u32 = 0, key: extern struct { repeat: u8 = 0, keysym: extern struct { scancode: c_uint = 0 } = .{} } = .{}, motion: extern struct { xrel: i32 = 0, yrel: i32 = 0 } = .{}, button: extern struct { button: u8 = 0 } = .{} };
    const SDL_AudioSpec = extern struct { freq: c_int = 0, format: u16 = 0, channels: u8 = 0, samples: u16 = 0, callback: ?*const fn (?*anyopaque, [*c]u8, c_int) callconv(.c) void = null, userdata: ?*anyopaque = null, padding: [16]u8 = undefined };
    const SDL_AudioDeviceID = u32;
    const SDL_INIT_VIDEO: u32 = 0x20;
    const SDL_INIT_AUDIO: u32 = 0x10;
    const SDL_INIT_TIMER: u32 = 0x01;
    const SDL_WINDOW_SHOWN: u32 = 0x04;
    const SDL_WINDOW_RESIZABLE: u32 = 0x20;
    const SDL_WINDOWPOS_CENTERED: c_int = 0x2FFF0000;
    const SDL_RENDERER_ACCELERATED: u32 = 0x02;
    const SDL_RENDERER_PRESENTVSYNC: u32 = 0x04;
    const SDL_PIXELFORMAT_RGB24: u32 = 0x17101803;
    const SDL_TEXTUREACCESS_STREAMING: c_int = 1;
    const AUDIO_S8: u16 = 0x8008;
    const SDL_QUIT: u32 = 0x100;
    const SDL_KEYDOWN: u32 = 0x300;
    const SDL_KEYUP: u32 = 0x301;
    const SDL_MOUSEMOTION: u32 = 0x400;
    const SDL_MOUSEBUTTONDOWN: u32 = 0x401;
    const SDL_MOUSEBUTTONUP: u32 = 0x402;
    const SDL_BUTTON_LEFT: u8 = 1;
    const SDL_BUTTON_RIGHT: u8 = 3;
    const SDL_BUTTON_MIDDLE: u8 = 2;
    // Scancode constants
    const SDL_SCANCODE_LEFT: c_uint = 80;
    const SDL_SCANCODE_RIGHT: c_uint = 79;
    const SDL_SCANCODE_UP: c_uint = 82;
    const SDL_SCANCODE_DOWN: c_uint = 81;
    const SDL_SCANCODE_ESCAPE: c_uint = 41;
    const SDL_SCANCODE_RETURN: c_uint = 40;
    const SDL_SCANCODE_TAB: c_uint = 43;
    const SDL_SCANCODE_BACKSPACE: c_uint = 42;
    const SDL_SCANCODE_SPACE: c_uint = 44;
    const SDL_SCANCODE_LCTRL: c_uint = 224;
    const SDL_SCANCODE_RCTRL: c_uint = 228;
    const SDL_SCANCODE_LSHIFT: c_uint = 225;
    const SDL_SCANCODE_RSHIFT: c_uint = 229;
    const SDL_SCANCODE_LALT: c_uint = 226;
    const SDL_SCANCODE_RALT: c_uint = 230;
    const SDL_SCANCODE_PAUSE: c_uint = 72;
    const SDL_SCANCODE_W: c_uint = 26;
    const SDL_SCANCODE_A: c_uint = 4;
    const SDL_SCANCODE_S: c_uint = 22;
    const SDL_SCANCODE_D: c_uint = 7;
    const SDL_SCANCODE_E: c_uint = 8;
    const SDL_SCANCODE_F1: c_uint = 58;
    const SDL_SCANCODE_F2: c_uint = 59;
    const SDL_SCANCODE_F3: c_uint = 60;
    const SDL_SCANCODE_F4: c_uint = 61;
    const SDL_SCANCODE_F5: c_uint = 62;
    const SDL_SCANCODE_F6: c_uint = 63;
    const SDL_SCANCODE_F7: c_uint = 64;
    const SDL_SCANCODE_F8: c_uint = 65;
    const SDL_SCANCODE_F9: c_uint = 66;
    const SDL_SCANCODE_F10: c_uint = 67;
    const SDL_SCANCODE_F11: c_uint = 68;
    const SDL_SCANCODE_F12: c_uint = 69;
    const SDL_SCANCODE_1: c_uint = 30;
    const SDL_SCANCODE_2: c_uint = 31;
    const SDL_SCANCODE_3: c_uint = 32;
    const SDL_SCANCODE_4: c_uint = 33;
    const SDL_SCANCODE_5: c_uint = 34;
    const SDL_SCANCODE_6: c_uint = 35;
    const SDL_SCANCODE_7: c_uint = 36;
    const SDL_SCANCODE_8: c_uint = 37;
    const SDL_SCANCODE_9: c_uint = 38;
    fn SDL_Init(_: u32) c_int { return -1; }
    fn SDL_Quit() void {}
    fn SDL_CreateWindow(_: [*:0]const u8, _: c_int, _: c_int, _: c_int, _: c_int, _: u32) ?*SDL_Window { return null; }
    fn SDL_CreateRenderer(_: ?*SDL_Window, _: c_int, _: u32) ?*SDL_Renderer { return null; }
    fn SDL_CreateTexture(_: ?*SDL_Renderer, _: u32, _: c_int, _: c_int, _: c_int) ?*SDL_Texture { return null; }
    fn SDL_DestroyTexture(_: ?*SDL_Texture) void {}
    fn SDL_DestroyRenderer(_: ?*SDL_Renderer) void {}
    fn SDL_DestroyWindow(_: ?*SDL_Window) void {}
    fn SDL_RenderSetLogicalSize(_: ?*SDL_Renderer, _: c_int, _: c_int) c_int { return 0; }
    fn SDL_UpdateTexture(_: ?*SDL_Texture, _: ?*anyopaque, _: *const anyopaque, _: c_int) c_int { return 0; }
    fn SDL_RenderClear(_: ?*SDL_Renderer) c_int { return 0; }
    fn SDL_RenderCopy(_: ?*SDL_Renderer, _: ?*SDL_Texture, _: ?*anyopaque, _: ?*anyopaque) c_int { return 0; }
    fn SDL_RenderPresent(_: ?*SDL_Renderer) void {}
    fn SDL_PollEvent(_: *SDL_Event) c_int { return 0; }
    fn SDL_GetTicks() u32 { return 0; }
    fn SDL_Delay(_: u32) void {}
    fn SDL_OpenAudioDevice(_: ?*anyopaque, _: c_int, _: *const SDL_AudioSpec, _: *SDL_AudioSpec, _: c_int) SDL_AudioDeviceID { return 0; }
    fn SDL_CloseAudioDevice(_: SDL_AudioDeviceID) void {}
    fn SDL_PauseAudioDevice(_: SDL_AudioDeviceID, _: c_int) void {}
};

/// Number of sound mixing channels
const NUM_SFX_CHANNELS = 8;
const AUDIO_SAMPLE_RATE = 44100;
const AUDIO_BUFFER_SIZE = 1024;

/// A mixing channel for sound effects
const MixChannel = struct {
    data: [*]const u8 = undefined,
    data_len: u32 = 0,
    pos: u32 = 0,
    volume: u32 = 0,
    separation: u32 = 128,
    pitch: u32 = 128,
    active: bool = false,
    handle: u32 = 0,
};

/// SDL2 backend state
const Sdl2State = struct {
    allocator: std.mem.Allocator,
    platform: Platform,

    // Video
    window: ?*c.SDL_Window = null,
    renderer: ?*c.SDL_Renderer = null,
    texture: ?*c.SDL_Texture = null,
    pixel_buf: [SCREENWIDTH * SCREENHEIGHT * 3]u8 = undefined,
    window_width: u32 = 640,
    window_height: u32 = 400,

    // Sound
    audio_device: c.SDL_AudioDeviceID = 0,
    mix_channels: [NUM_SFX_CHANNELS]MixChannel = [_]MixChannel{.{}} ** NUM_SFX_CHANNELS,
    next_handle: u32 = 1,
    sound_init: bool = false,

    // Input
    quit_requested: bool = false,

    // Timer
    base_ticks: u32 = 0,

    // State flags
    video_init: bool = false,
};

// ============================================================================
// Video
// ============================================================================

fn sdl2InitVideo(ctx: *anyopaque, width: u32, height: u32) bool {
    const state: *Sdl2State = @ptrCast(@alignCast(ctx));

    if (c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_AUDIO | c.SDL_INIT_TIMER) < 0) {
        return false;
    }

    state.window_width = if (width > 0) width else 640;
    state.window_height = if (height > 0) height else 400;

    state.window = c.SDL_CreateWindow(
        "zig_doom",
        c.SDL_WINDOWPOS_CENTERED,
        c.SDL_WINDOWPOS_CENTERED,
        @intCast(state.window_width),
        @intCast(state.window_height),
        c.SDL_WINDOW_SHOWN | c.SDL_WINDOW_RESIZABLE,
    );
    if (state.window == null) return false;

    state.renderer = c.SDL_CreateRenderer(state.window, -1, c.SDL_RENDERER_ACCELERATED | c.SDL_RENDERER_PRESENTVSYNC);
    if (state.renderer == null) {
        // Try without vsync
        state.renderer = c.SDL_CreateRenderer(state.window, -1, c.SDL_RENDERER_ACCELERATED);
    }
    if (state.renderer == null) return false;

    // Set logical size for aspect ratio
    _ = c.SDL_RenderSetLogicalSize(state.renderer, SCREENWIDTH, SCREENHEIGHT);

    state.texture = c.SDL_CreateTexture(
        state.renderer,
        c.SDL_PIXELFORMAT_RGB24,
        c.SDL_TEXTUREACCESS_STREAMING,
        SCREENWIDTH,
        SCREENHEIGHT,
    );
    if (state.texture == null) return false;

    @memset(&state.pixel_buf, 0);
    state.base_ticks = c.SDL_GetTicks();
    state.video_init = true;
    return true;
}

fn sdl2DeinitVideo(ctx: *anyopaque) void {
    const state: *Sdl2State = @ptrCast(@alignCast(ctx));
    if (!state.video_init) return;

    if (state.texture) |tex| c.SDL_DestroyTexture(tex);
    if (state.renderer) |ren| c.SDL_DestroyRenderer(ren);
    if (state.window) |win| c.SDL_DestroyWindow(win);
    state.texture = null;
    state.renderer = null;
    state.window = null;

    c.SDL_Quit();
    state.video_init = false;
}

fn sdl2FinishUpdate(ctx: *anyopaque, screen: *const [SCREENSIZE]u8, palette: *const [768]u8) void {
    const state: *Sdl2State = @ptrCast(@alignCast(ctx));

    // Convert palette-indexed -> RGB24
    for (0..SCREENSIZE) |i| {
        const pal_idx: usize = screen[i];
        state.pixel_buf[i * 3 + 0] = palette[pal_idx * 3 + 0];
        state.pixel_buf[i * 3 + 1] = palette[pal_idx * 3 + 1];
        state.pixel_buf[i * 3 + 2] = palette[pal_idx * 3 + 2];
    }

    _ = c.SDL_UpdateTexture(state.texture, null, &state.pixel_buf, SCREENWIDTH * 3);
    _ = c.SDL_RenderClear(state.renderer);
    _ = c.SDL_RenderCopy(state.renderer, state.texture, null, null);
    c.SDL_RenderPresent(state.renderer);
}

fn sdl2SetPalette(_: *anyopaque, _: *const [768]u8) void {
    // Palette is applied each frame in finishUpdate, nothing to cache
}

// ============================================================================
// Input
// ============================================================================

/// Map an SDL scancode to a DOOM key code
fn mapSdlKey(scancode: c_uint) i32 {
    return switch (scancode) {
        c.SDL_SCANCODE_LEFT => event_mod.KEY_LEFTARROW,
        c.SDL_SCANCODE_RIGHT => event_mod.KEY_RIGHTARROW,
        c.SDL_SCANCODE_UP => event_mod.KEY_UPARROW,
        c.SDL_SCANCODE_DOWN => event_mod.KEY_DOWNARROW,
        c.SDL_SCANCODE_ESCAPE => event_mod.KEY_ESCAPE,
        c.SDL_SCANCODE_RETURN => event_mod.KEY_ENTER,
        c.SDL_SCANCODE_TAB => event_mod.KEY_TAB,
        c.SDL_SCANCODE_BACKSPACE => event_mod.KEY_BACKSPACE,
        c.SDL_SCANCODE_SPACE => event_mod.KEY_USE,
        c.SDL_SCANCODE_LCTRL, c.SDL_SCANCODE_RCTRL => event_mod.KEY_FIRE,
        c.SDL_SCANCODE_LSHIFT, c.SDL_SCANCODE_RSHIFT => event_mod.KEY_SPEED,
        c.SDL_SCANCODE_LALT, c.SDL_SCANCODE_RALT => event_mod.KEY_STRAFE,
        c.SDL_SCANCODE_PAUSE => event_mod.KEY_PAUSE,
        // WASD
        c.SDL_SCANCODE_W => event_mod.KEY_UPARROW,
        c.SDL_SCANCODE_A => event_mod.KEY_LEFTARROW,
        c.SDL_SCANCODE_S => event_mod.KEY_DOWNARROW,
        c.SDL_SCANCODE_D => event_mod.KEY_RIGHTARROW,
        c.SDL_SCANCODE_E => event_mod.KEY_USE,
        // Function keys
        c.SDL_SCANCODE_F1 => event_mod.KEY_F1,
        c.SDL_SCANCODE_F2 => event_mod.KEY_F2,
        c.SDL_SCANCODE_F3 => event_mod.KEY_F3,
        c.SDL_SCANCODE_F4 => event_mod.KEY_F4,
        c.SDL_SCANCODE_F5 => event_mod.KEY_F5,
        c.SDL_SCANCODE_F6 => event_mod.KEY_F6,
        c.SDL_SCANCODE_F7 => event_mod.KEY_F7,
        c.SDL_SCANCODE_F8 => event_mod.KEY_F8,
        c.SDL_SCANCODE_F9 => event_mod.KEY_F9,
        c.SDL_SCANCODE_F10 => event_mod.KEY_F10,
        c.SDL_SCANCODE_F11 => event_mod.KEY_F11,
        c.SDL_SCANCODE_F12 => event_mod.KEY_F12,
        // Number keys (weapon select)
        c.SDL_SCANCODE_1 => '1',
        c.SDL_SCANCODE_2 => '2',
        c.SDL_SCANCODE_3 => '3',
        c.SDL_SCANCODE_4 => '4',
        c.SDL_SCANCODE_5 => '5',
        c.SDL_SCANCODE_6 => '6',
        c.SDL_SCANCODE_7 => '7',
        c.SDL_SCANCODE_8 => '8',
        c.SDL_SCANCODE_9 => '9',
        else => 0,
    };
}

fn sdl2GetEvents(ctx: *anyopaque, buffer: []Event) []Event {
    const state: *Sdl2State = @ptrCast(@alignCast(ctx));
    var count: usize = 0;
    const max = buffer.len;

    var sdl_event: c.SDL_Event = undefined;
    while (c.SDL_PollEvent(&sdl_event) != 0 and count < max) {
        switch (sdl_event.type) {
            c.SDL_QUIT => {
                state.quit_requested = true;
            },
            c.SDL_KEYDOWN => {
                if (sdl_event.key.repeat != 0) continue;
                const key = mapSdlKey(sdl_event.key.keysym.scancode);
                if (key != 0) {
                    buffer[count] = .{ .event_type = .key_down, .data1 = key, .data2 = 0, .data3 = 0 };
                    count += 1;
                }
            },
            c.SDL_KEYUP => {
                const key = mapSdlKey(sdl_event.key.keysym.scancode);
                if (key != 0) {
                    buffer[count] = .{ .event_type = .key_up, .data1 = key, .data2 = 0, .data3 = 0 };
                    count += 1;
                }
            },
            c.SDL_MOUSEMOTION => {
                if (count < max) {
                    buffer[count] = .{
                        .event_type = .mouse,
                        .data1 = 0, // buttons handled separately
                        .data2 = sdl_event.motion.xrel,
                        .data3 = -sdl_event.motion.yrel, // DOOM Y is inverted
                    };
                    count += 1;
                }
            },
            c.SDL_MOUSEBUTTONDOWN => {
                // Left click = fire, right click = use
                const key: i32 = switch (sdl_event.button.button) {
                    c.SDL_BUTTON_LEFT => event_mod.KEY_FIRE,
                    c.SDL_BUTTON_RIGHT => event_mod.KEY_USE,
                    c.SDL_BUTTON_MIDDLE => event_mod.KEY_STRAFE,
                    else => 0,
                };
                if (key != 0 and count < max) {
                    buffer[count] = .{ .event_type = .key_down, .data1 = key, .data2 = 0, .data3 = 0 };
                    count += 1;
                }
            },
            c.SDL_MOUSEBUTTONUP => {
                const key: i32 = switch (sdl_event.button.button) {
                    c.SDL_BUTTON_LEFT => event_mod.KEY_FIRE,
                    c.SDL_BUTTON_RIGHT => event_mod.KEY_USE,
                    c.SDL_BUTTON_MIDDLE => event_mod.KEY_STRAFE,
                    else => 0,
                };
                if (key != 0 and count < max) {
                    buffer[count] = .{ .event_type = .key_up, .data1 = key, .data2 = 0, .data3 = 0 };
                    count += 1;
                }
            },
            else => {},
        }
    }

    return buffer[0..count];
}

// ============================================================================
// Timer
// ============================================================================

fn sdl2GetTics(ctx: *anyopaque) u32 {
    const state: *Sdl2State = @ptrCast(@alignCast(ctx));
    const elapsed = c.SDL_GetTicks() - state.base_ticks;
    return elapsed * 35 / 1000;
}

// ============================================================================
// Sound
// ============================================================================

fn audioCallback(userdata: ?*anyopaque, stream: [*c]u8, len_raw: c_int) callconv(.c) void {
    const state: *Sdl2State = @ptrCast(@alignCast(userdata orelse return));
    const stream_len: usize = @intCast(@max(len_raw, 0));

    // Clear the output buffer
    @memset(stream[0..stream_len], 0);

    // Mix all active channels
    for (&state.mix_channels) |*ch| {
        if (!ch.active) continue;

        const samples_to_mix = @min(stream_len, ch.data_len - ch.pos);
        if (samples_to_mix == 0) {
            ch.active = false;
            continue;
        }

        // Simple mixing: DOOM's 8-bit unsigned 11025Hz -> 16-bit signed at output rate
        // For now, just do basic unsigned-to-signed conversion at output rate
        // (proper resampling would be needed for production quality)
        const vol = ch.volume;
        for (0..samples_to_mix) |i| {
            if (i >= stream_len) break;
            // Convert 8-bit unsigned to signed and scale by volume
            const sample_u8 = ch.data[ch.pos + @as(u32, @intCast(i))];
            const sample_i16: i16 = (@as(i16, sample_u8) - 128) * @as(i16, @intCast(@min(vol, 127)));
            // Mix into output (assuming 8-bit output for simplicity)
            const current: i16 = @as(i8, @bitCast(stream[i]));
            const mixed = @as(i16, current) + @divTrunc(sample_i16, 127);
            stream[i] = @bitCast(@as(i8, @intCast(std.math.clamp(mixed, -128, 127))));
        }

        ch.pos += @intCast(samples_to_mix);
        if (ch.pos >= ch.data_len) {
            ch.active = false;
        }
    }
}

fn sdl2InitSound(ctx: *anyopaque) bool {
    const state: *Sdl2State = @ptrCast(@alignCast(ctx));

    var desired: c.SDL_AudioSpec = undefined;
    @memset(@as([*]u8, @ptrCast(&desired))[0..@sizeOf(c.SDL_AudioSpec)], 0);
    desired.freq = AUDIO_SAMPLE_RATE;
    desired.format = c.AUDIO_S8;
    desired.channels = 1;
    desired.samples = AUDIO_BUFFER_SIZE;
    desired.callback = &audioCallback;
    desired.userdata = ctx;

    var obtained: c.SDL_AudioSpec = undefined;
    state.audio_device = c.SDL_OpenAudioDevice(null, 0, &desired, &obtained, 0);
    if (state.audio_device == 0) return false;

    c.SDL_PauseAudioDevice(state.audio_device, 0); // unpause
    state.sound_init = true;
    return true;
}

fn sdl2DeinitSound(ctx: *anyopaque) void {
    const state: *Sdl2State = @ptrCast(@alignCast(ctx));
    if (state.sound_init) {
        c.SDL_CloseAudioDevice(state.audio_device);
        state.sound_init = false;
    }
}

fn sdl2StartSound(ctx: *anyopaque, data: [*]const u8, len: u32, vol: u32, sep: u32, pitch: u32) u32 {
    const state: *Sdl2State = @ptrCast(@alignCast(ctx));

    // Find a free channel
    var best: ?usize = null;
    for (&state.mix_channels, 0..) |*ch, i| {
        if (!ch.active) {
            best = i;
            break;
        }
    }
    if (best == null) best = 0; // Steal first channel

    const handle = state.next_handle;
    state.next_handle +%= 1;
    if (state.next_handle == 0) state.next_handle = 1;

    state.mix_channels[best.?] = .{
        .data = data,
        .data_len = len,
        .pos = 0,
        .volume = vol,
        .separation = sep,
        .pitch = pitch,
        .active = true,
        .handle = handle,
    };

    return handle;
}

fn sdl2StopSound(ctx: *anyopaque, handle: u32) void {
    const state: *Sdl2State = @ptrCast(@alignCast(ctx));
    for (&state.mix_channels) |*ch| {
        if (ch.active and ch.handle == handle) {
            ch.active = false;
        }
    }
}

fn sdl2IsSoundPlaying(ctx: *anyopaque, handle: u32) bool {
    const state: *Sdl2State = @ptrCast(@alignCast(ctx));
    for (state.mix_channels) |ch| {
        if (ch.active and ch.handle == handle) return true;
    }
    return false;
}

fn sdl2UpdateSound(_: *anyopaque) void {
    // Audio callback handles mixing; nothing to do here
}

// ============================================================================
// System
// ============================================================================

fn sdl2Sleep(_: *anyopaque, ms: u32) void {
    c.SDL_Delay(ms);
}

fn sdl2GetTitle(_: *anyopaque) []const u8 {
    return "zig_doom (SDL2)";
}

fn sdl2IsQuitRequested(ctx: *anyopaque) bool {
    const state: *Sdl2State = @ptrCast(@alignCast(ctx));
    return state.quit_requested;
}

// ============================================================================
// Create / Destroy
// ============================================================================

/// Create an SDL2 platform backend
pub fn create(allocator: std.mem.Allocator) ?*Platform {
    const state = allocator.create(Sdl2State) catch return null;
    state.* = .{
        .allocator = allocator,
        .platform = .{
            .initVideo = &sdl2InitVideo,
            .deinitVideo = &sdl2DeinitVideo,
            .finishUpdate = &sdl2FinishUpdate,
            .setPalette = &sdl2SetPalette,
            .getEvents = &sdl2GetEvents,
            .getTics = &sdl2GetTics,
            .initSound = &sdl2InitSound,
            .deinitSound = &sdl2DeinitSound,
            .startSound = &sdl2StartSound,
            .stopSound = &sdl2StopSound,
            .isSoundPlaying = &sdl2IsSoundPlaying,
            .updateSound = &sdl2UpdateSound,
            .sleep = &sdl2Sleep,
            .getTitle = &sdl2GetTitle,
            .isQuitRequested = &sdl2IsQuitRequested,
            .impl = undefined,
        },
    };
    state.platform.impl = @ptrCast(state);
    return &state.platform;
}

/// Destroy the SDL2 backend
pub fn destroy(platform: *Platform, allocator: std.mem.Allocator) void {
    const state: *Sdl2State = @ptrCast(@alignCast(platform.impl));
    platform.deinitSound(platform.impl);
    platform.deinitVideo(platform.impl);
    allocator.destroy(state);
}
