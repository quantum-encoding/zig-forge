//! zig_doom/src/platform/framebuffer.zig
//!
//! Linux framebuffer backend — direct /dev/fb0 writes for bare-metal Linux
//! (e.g., Zigix on Orange Pi, Raspberry Pi, or any Linux without X11/Wayland).
//!
//! Reads keyboard input from /dev/input/event* device files.

const std = @import("std");
const builtin = @import("builtin");
const Platform = @import("interface.zig").Platform;
const event_mod = @import("../event.zig");
const Event = event_mod.Event;
const defs = @import("../defs.zig");

const SCREENWIDTH = defs.SCREENWIDTH;
const SCREENHEIGHT = defs.SCREENHEIGHT;
const SCREENSIZE = defs.SCREENSIZE;

const is_linux = builtin.os.tag == .linux;

const c = if (is_linux) @cImport({
    @cInclude("linux/fb.h");
    @cInclude("linux/input.h");
    @cInclude("sys/mman.h");
    @cInclude("sys/ioctl.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
    @cInclude("time.h");
}) else struct {
    // Stub types for non-Linux platforms so the file compiles
    const fb_var_screeninfo = extern struct { xres: u32 = 0, yres: u32 = 0, bits_per_pixel: u32 = 0 };
    const fb_fix_screeninfo = extern struct { line_length: u32 = 0 };
    const input_event = extern struct { type: u16 = 0, code: u16 = 0, value: i32 = 0 };
    const timespec = extern struct { tv_sec: i64 = 0, tv_nsec: i64 = 0 };
    const FBIOGET_VSCREENINFO: u32 = 0;
    const FBIOGET_FSCREENINFO: u32 = 0;
    const PROT_READ: c_int = 0;
    const PROT_WRITE: c_int = 0;
    const MAP_SHARED: c_int = 0;
    const MAP_FAILED: *anyopaque = @ptrFromInt(std.math.maxInt(usize));
    const O_RDWR: c_int = 0;
    const O_RDONLY: c_int = 0;
    const O_NONBLOCK: c_int = 0;
    const EV_KEY: u16 = 1;
    const CLOCK_MONOTONIC: c_int = 0;
    // Stub key constants
    const KEY_UP: u16 = 103;
    const KEY_DOWN: u16 = 108;
    const KEY_LEFT: u16 = 105;
    const KEY_RIGHT: u16 = 106;
    const KEY_ESC: u16 = 1;
    const KEY_ENTER: u16 = 28;
    const KEY_TAB: u16 = 15;
    const KEY_BACKSPACE: u16 = 14;
    const KEY_SPACE: u16 = 57;
    const KEY_LEFTCTRL: u16 = 29;
    const KEY_RIGHTCTRL: u16 = 97;
    const KEY_LEFTSHIFT: u16 = 42;
    const KEY_RIGHTSHIFT: u16 = 54;
    const KEY_LEFTALT: u16 = 56;
    const KEY_RIGHTALT: u16 = 100;
    const KEY_PAUSE: u16 = 119;
    const KEY_W: u16 = 17;
    const KEY_A: u16 = 30;
    const KEY_S: u16 = 31;
    const KEY_D: u16 = 32;
    const KEY_E: u16 = 18;
    const KEY_F1: u16 = 59;
    const KEY_F2: u16 = 60;
    const KEY_F3: u16 = 61;
    const KEY_F4: u16 = 62;
    const KEY_F5: u16 = 63;
    const KEY_F6: u16 = 64;
    const KEY_F7: u16 = 65;
    const KEY_F8: u16 = 66;
    const KEY_F9: u16 = 67;
    const KEY_F10: u16 = 68;
    const KEY_F11: u16 = 87;
    const KEY_F12: u16 = 88;
    const KEY_1: u16 = 2;
    const KEY_2: u16 = 3;
    const KEY_3: u16 = 4;
    const KEY_4: u16 = 5;
    const KEY_5: u16 = 6;
    const KEY_6: u16 = 7;
    const KEY_7: u16 = 8;
    const KEY_8: u16 = 9;
    const KEY_9: u16 = 10;
    fn open(_: [*:0]const u8, _: c_int) c_int { return -1; }
    fn close(_: c_int) c_int { return 0; }
    fn read(_: c_int, _: *anyopaque, _: usize) isize { return -1; }
    fn ioctl(_: c_int, _: u32, _: *anyopaque) c_int { return -1; }
    fn mmap(_: ?*anyopaque, _: u32, _: c_int, _: c_int, _: c_int, _: i64) *anyopaque { return @ptrFromInt(std.math.maxInt(usize)); }
    fn munmap(_: *anyopaque, _: u32) c_int { return 0; }
    fn clock_gettime(_: c_int, _: *timespec) c_int { return 0; }
    fn nanosleep(_: *const timespec, _: ?*timespec) c_int { return 0; }
};

const FbInfo = struct {
    width: u32,
    height: u32,
    bits_per_pixel: u32,
    bytes_per_pixel: u32,
    line_length: u32,
    fb_size: u32,
};

/// Pre-computed scale lookup tables
const MAX_NATIVE_DIM = 4096;

const FbState = struct {
    allocator: std.mem.Allocator,
    platform: Platform,

    // Framebuffer
    fb_fd: c_int = -1,
    fb_ptr: ?[*]u8 = null,
    fb_info: FbInfo = .{
        .width = 0,
        .height = 0,
        .bits_per_pixel = 0,
        .bytes_per_pixel = 0,
        .line_length = 0,
        .fb_size = 0,
    },

    // Scale lookup tables (pre-computed for fast nearest-neighbor scaling)
    col_lut: [MAX_NATIVE_DIM]u16 = [_]u16{0} ** MAX_NATIVE_DIM,
    row_lut: [MAX_NATIVE_DIM]u16 = [_]u16{0} ** MAX_NATIVE_DIM,

    // Input device
    input_fd: c_int = -1,

    // Timer
    start_time_s: i64 = 0,
    start_time_ns: i64 = 0,

    // State
    quit_requested: bool = false,
    video_init: bool = false,
};

/// Put a single pixel in the framebuffer
fn putPixel(fb: [*]u8, x: u32, y: u32, r: u8, g: u8, b: u8, info: FbInfo) void {
    const offset = y * info.line_length + x * info.bytes_per_pixel;
    if (offset + info.bytes_per_pixel > info.fb_size) return;

    switch (info.bits_per_pixel) {
        16 => {
            // RGB565
            const pixel: u16 = (@as(u16, r >> 3) << 11) | (@as(u16, g >> 2) << 5) | @as(u16, b >> 3);
            const ptr: *align(1) u16 = @ptrCast(fb + offset);
            ptr.* = pixel;
        },
        24 => {
            // BGR888
            fb[offset] = b;
            fb[offset + 1] = g;
            fb[offset + 2] = r;
        },
        32 => {
            // BGRA8888
            fb[offset] = b;
            fb[offset + 1] = g;
            fb[offset + 2] = r;
            fb[offset + 3] = 0xFF;
        },
        else => {},
    }
}

/// Map Linux input KEY_* code to DOOM KEY_* code
fn mapLinuxKey(code: u16) i32 {
    return switch (code) {
        c.KEY_UP => event_mod.KEY_UPARROW,
        c.KEY_DOWN => event_mod.KEY_DOWNARROW,
        c.KEY_LEFT => event_mod.KEY_LEFTARROW,
        c.KEY_RIGHT => event_mod.KEY_RIGHTARROW,
        c.KEY_ESC => event_mod.KEY_ESCAPE,
        c.KEY_ENTER => event_mod.KEY_ENTER,
        c.KEY_TAB => event_mod.KEY_TAB,
        c.KEY_BACKSPACE => event_mod.KEY_BACKSPACE,
        c.KEY_SPACE => event_mod.KEY_USE,
        c.KEY_LEFTCTRL, c.KEY_RIGHTCTRL => event_mod.KEY_FIRE,
        c.KEY_LEFTSHIFT, c.KEY_RIGHTSHIFT => event_mod.KEY_SPEED,
        c.KEY_LEFTALT, c.KEY_RIGHTALT => event_mod.KEY_STRAFE,
        c.KEY_PAUSE => event_mod.KEY_PAUSE,
        // WASD
        c.KEY_W => event_mod.KEY_UPARROW,
        c.KEY_A => event_mod.KEY_LEFTARROW,
        c.KEY_S => event_mod.KEY_DOWNARROW,
        c.KEY_D => event_mod.KEY_RIGHTARROW,
        c.KEY_E => event_mod.KEY_USE,
        // Function keys
        c.KEY_F1 => event_mod.KEY_F1,
        c.KEY_F2 => event_mod.KEY_F2,
        c.KEY_F3 => event_mod.KEY_F3,
        c.KEY_F4 => event_mod.KEY_F4,
        c.KEY_F5 => event_mod.KEY_F5,
        c.KEY_F6 => event_mod.KEY_F6,
        c.KEY_F7 => event_mod.KEY_F7,
        c.KEY_F8 => event_mod.KEY_F8,
        c.KEY_F9 => event_mod.KEY_F9,
        c.KEY_F10 => event_mod.KEY_F10,
        c.KEY_F11 => event_mod.KEY_F11,
        c.KEY_F12 => event_mod.KEY_F12,
        // Number keys
        c.KEY_1 => '1',
        c.KEY_2 => '2',
        c.KEY_3 => '3',
        c.KEY_4 => '4',
        c.KEY_5 => '5',
        c.KEY_6 => '6',
        c.KEY_7 => '7',
        c.KEY_8 => '8',
        c.KEY_9 => '9',
        else => 0,
    };
}

/// Build scale lookup tables for nearest-neighbor scaling
fn buildScaleLuts(state: *FbState) void {
    const native_w = state.fb_info.width;
    const native_h = state.fb_info.height;

    // Maintain DOOM's 4:3 aspect ratio
    const doom_aspect_w: u64 = 4;
    const doom_aspect_h: u64 = 3;
    var draw_w: u32 = native_w;
    var draw_h: u32 = native_h;

    if (@as(u64, native_w) * doom_aspect_h > @as(u64, native_h) * doom_aspect_w) {
        // Pillarbox
        draw_w = @intCast(@as(u64, native_h) * doom_aspect_w / doom_aspect_h);
    } else {
        // Letterbox
        draw_h = @intCast(@as(u64, native_w) * doom_aspect_h / doom_aspect_w);
    }

    const clamp_w = @min(draw_w, MAX_NATIVE_DIM);
    const clamp_h = @min(draw_h, MAX_NATIVE_DIM);

    for (0..clamp_w) |x| {
        state.col_lut[x] = @intCast(@min(x * SCREENWIDTH / draw_w, SCREENWIDTH - 1));
    }
    for (0..clamp_h) |y| {
        state.row_lut[y] = @intCast(@min(y * SCREENHEIGHT / draw_h, SCREENHEIGHT - 1));
    }
}

// ============================================================================
// Platform vtable
// ============================================================================

fn fbInitVideo(ctx: *anyopaque, _: u32, _: u32) bool {
    const state: *FbState = @ptrCast(@alignCast(ctx));

    // Open framebuffer
    state.fb_fd = c.open("/dev/fb0", c.O_RDWR);
    if (state.fb_fd < 0) return false;

    // Get variable screen info
    var vinfo: c.fb_var_screeninfo = undefined;
    if (c.ioctl(state.fb_fd, c.FBIOGET_VSCREENINFO, &vinfo) < 0) {
        _ = c.close(state.fb_fd);
        return false;
    }

    // Get fixed screen info
    var finfo: c.fb_fix_screeninfo = undefined;
    if (c.ioctl(state.fb_fd, c.FBIOGET_FSCREENINFO, &finfo) < 0) {
        _ = c.close(state.fb_fd);
        return false;
    }

    state.fb_info = .{
        .width = vinfo.xres,
        .height = vinfo.yres,
        .bits_per_pixel = vinfo.bits_per_pixel,
        .bytes_per_pixel = (vinfo.bits_per_pixel + 7) / 8,
        .line_length = finfo.line_length,
        .fb_size = finfo.line_length * vinfo.yres,
    };

    // mmap the framebuffer
    const map_result = c.mmap(null, state.fb_info.fb_size, c.PROT_READ | c.PROT_WRITE, c.MAP_SHARED, state.fb_fd, 0);
    if (map_result == c.MAP_FAILED) {
        _ = c.close(state.fb_fd);
        return false;
    }
    state.fb_ptr = @ptrCast(map_result);

    // Build scale LUTs
    buildScaleLuts(state);

    // Try to open keyboard input device
    // Try event0-event9
    const input_paths = [_][*:0]const u8{
        "/dev/input/event0",
        "/dev/input/event1",
        "/dev/input/event2",
        "/dev/input/event3",
    };
    for (input_paths) |path| {
        const fd = c.open(path, c.O_RDONLY | c.O_NONBLOCK);
        if (fd >= 0) {
            state.input_fd = fd;
            break;
        }
    }

    // Initialize timer
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    state.start_time_s = ts.tv_sec;
    state.start_time_ns = ts.tv_nsec;

    state.video_init = true;
    return true;
}

fn fbDeinitVideo(ctx: *anyopaque) void {
    const state: *FbState = @ptrCast(@alignCast(ctx));
    if (!state.video_init) return;

    if (state.fb_ptr) |ptr| {
        _ = c.munmap(ptr, state.fb_info.fb_size);
        state.fb_ptr = null;
    }
    if (state.fb_fd >= 0) {
        _ = c.close(state.fb_fd);
        state.fb_fd = -1;
    }
    if (state.input_fd >= 0) {
        _ = c.close(state.input_fd);
        state.input_fd = -1;
    }
    state.video_init = false;
}

fn fbFinishUpdate(ctx: *anyopaque, screen: *const [SCREENSIZE]u8, palette: *const [768]u8) void {
    const state: *FbState = @ptrCast(@alignCast(ctx));
    const fb = state.fb_ptr orelse return;
    const info = state.fb_info;

    // Nearest-neighbor scale and blit
    for (0..info.height) |y| {
        const src_y: usize = if (y < MAX_NATIVE_DIM) state.row_lut[y] else 0;
        const row_off = src_y * SCREENWIDTH;

        for (0..info.width) |x| {
            const src_x: usize = if (x < MAX_NATIVE_DIM) state.col_lut[x] else 0;
            const pal_idx: usize = screen[row_off + src_x];
            putPixel(
                fb,
                @intCast(x),
                @intCast(y),
                palette[pal_idx * 3 + 0],
                palette[pal_idx * 3 + 1],
                palette[pal_idx * 3 + 2],
                info,
            );
        }
    }
}

fn fbSetPalette(_: *anyopaque, _: *const [768]u8) void {
    // Palette applied per-frame in finishUpdate
}

fn fbGetEvents(ctx: *anyopaque, buffer: []Event) []Event {
    const state: *FbState = @ptrCast(@alignCast(ctx));
    var count: usize = 0;
    const max = buffer.len;

    if (state.input_fd < 0) return buffer[0..0];

    // Read input_event structs
    var ev_buf: [16]c.input_event = undefined;
    const bytes_read = c.read(state.input_fd, &ev_buf, @sizeOf(@TypeOf(ev_buf)));
    if (bytes_read <= 0) return buffer[0..0];

    const num_events: usize = @intCast(@divTrunc(bytes_read, @as(isize, @sizeOf(c.input_event))));

    for (0..num_events) |i| {
        if (count >= max) break;
        const ev = ev_buf[i];

        if (ev.type == c.EV_KEY) {
            const key = mapLinuxKey(ev.code);
            if (key != 0) {
                const event_type: event_mod.EventType = if (ev.value == 1 or ev.value == 2)
                    .key_down
                else
                    .key_up;
                buffer[count] = .{
                    .event_type = event_type,
                    .data1 = key,
                    .data2 = 0,
                    .data3 = 0,
                };
                count += 1;
            }
        }
    }

    return buffer[0..count];
}

fn fbGetTics(ctx: *anyopaque) u32 {
    const state: *FbState = @ptrCast(@alignCast(ctx));
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);

    const elapsed_s: i64 = ts.tv_sec - state.start_time_s;
    const elapsed_ns: i64 = ts.tv_nsec - state.start_time_ns;
    const elapsed_ms: u64 = @intCast(elapsed_s * 1000 + @divTrunc(elapsed_ns, 1_000_000));

    return @intCast(elapsed_ms * 35 / 1000);
}

fn fbInitSound(_: *anyopaque) bool {
    return false; // No sound in framebuffer backend
}

fn fbDeinitSound(_: *anyopaque) void {}
fn fbStartSound(_: *anyopaque, _: [*]const u8, _: u32, _: u32, _: u32, _: u32) u32 { return 0; }
fn fbStopSound(_: *anyopaque, _: u32) void {}
fn fbIsSoundPlaying(_: *anyopaque, _: u32) bool { return false; }
fn fbUpdateSound(_: *anyopaque) void {}

fn fbSleep(_: *anyopaque, ms: u32) void {
    var ts: c.timespec = undefined;
    ts.tv_sec = @intCast(ms / 1000);
    ts.tv_nsec = @intCast(@as(u64, ms % 1000) * 1_000_000);
    _ = c.nanosleep(&ts, null);
}

fn fbGetTitle(_: *anyopaque) []const u8 {
    return "zig_doom (framebuffer)";
}

fn fbIsQuitRequested(ctx: *anyopaque) bool {
    const state: *FbState = @ptrCast(@alignCast(ctx));
    return state.quit_requested;
}

/// Create a framebuffer platform backend
pub fn create(allocator: std.mem.Allocator) ?*Platform {
    const state = allocator.create(FbState) catch return null;
    state.* = .{
        .allocator = allocator,
        .platform = .{
            .initVideo = &fbInitVideo,
            .deinitVideo = &fbDeinitVideo,
            .finishUpdate = &fbFinishUpdate,
            .setPalette = &fbSetPalette,
            .getEvents = &fbGetEvents,
            .getTics = &fbGetTics,
            .initSound = &fbInitSound,
            .deinitSound = &fbDeinitSound,
            .startSound = &fbStartSound,
            .stopSound = &fbStopSound,
            .isSoundPlaying = &fbIsSoundPlaying,
            .updateSound = &fbUpdateSound,
            .sleep = &fbSleep,
            .getTitle = &fbGetTitle,
            .isQuitRequested = &fbIsQuitRequested,
            .impl = undefined,
        },
    };
    state.platform.impl = @ptrCast(state);
    return &state.platform;
}

/// Destroy the framebuffer backend
pub fn destroy(platform: *Platform, allocator: std.mem.Allocator) void {
    const state: *FbState = @ptrCast(@alignCast(platform.impl));
    platform.deinitVideo(platform.impl);
    allocator.destroy(state);
}
