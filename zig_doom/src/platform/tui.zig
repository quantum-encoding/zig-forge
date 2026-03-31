//! zig_doom/src/platform/tui.zig
//!
//! Terminal (TUI) backend — renders DOOM in the terminal using ANSI escapes
//! and Unicode half-block characters. No external dependencies needed.
//!
//! Each terminal cell represents 2 vertical pixels using the upper-half-block
//! character: the foreground color is the top pixel, background is the bottom.
//! 320x200 framebuffer -> up to 320x100 terminal cells (scaled to fit terminal).

const std = @import("std");
const Platform = @import("interface.zig").Platform;
const event_mod = @import("../event.zig");
const Event = event_mod.Event;
const defs = @import("../defs.zig");

const SCREENWIDTH = defs.SCREENWIDTH;
const SCREENHEIGHT = defs.SCREENHEIGHT;
const SCREENSIZE = defs.SCREENSIZE;

const c = @cImport({
    @cInclude("termios.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("sys/ioctl.h");
    @cInclude("signal.h");
    @cInclude("time.h");
    @cInclude("string.h");
});

/// Maximum output buffer size for one frame.
/// Each cell: ~30 bytes for color escapes + 3 bytes for UTF-8 char. 320*100*33 ~ 1MB.
const MAX_FRAME_BUF = 1200 * 1024;

/// xterm-256 palette cache: maps DOOM palette index -> xterm-256 color index
const PaletteCache = [256]u8;

/// TUI backend state
const TuiState = struct {
    allocator: std.mem.Allocator,
    platform: Platform,

    // Terminal state
    orig_termios: c.termios = undefined,
    raw_mode_active: bool = false,
    stdin_nonblock: bool = false,
    orig_stdin_flags: c_int = 0,

    // Terminal dimensions (in characters)
    term_cols: u32 = 80,
    term_rows: u32 = 24,

    // Rendering dimensions (in terminal cells)
    render_cols: u32 = 80,
    render_rows: u32 = 50, // 100 pixel rows / 2 = 50 cells, but capped to terminal

    // Palette mapping
    palette_cache: PaletteCache = [_]u8{0} ** 256,
    palette_valid: bool = false,

    // Frame output buffer
    frame_buf: []u8 = &[_]u8{},

    // Timer
    start_time_s: i64 = 0,
    start_time_ns: i64 = 0,

    // Debug
    frame_count: u32 = 0,

    // Quit flag
    quit_requested: bool = false,

    // Input escape sequence parsing state
    esc_buf: [8]u8 = undefined,
    esc_len: u8 = 0,

    // Video initialized flag
    video_init: bool = false,
};

// Global pointer for signal handler
var g_tui_state: ?*TuiState = null;

fn sigHandler(_: c_int) callconv(.c) void {
    if (g_tui_state) |state| {
        restoreTerminal(state);
    }
    // Re-raise to get default behavior
    _ = c.signal(c.SIGINT, @as(?*const fn (c_int) callconv(.c) void, null));
    _ = c.raise(c.SIGINT);
}

/// Restore terminal to original state
fn restoreTerminal(state: *TuiState) void {
    if (state.raw_mode_active) {
        // Reset colors, show cursor, leave alternate screen buffer
        const restore_seq = "\x1b[0m\x1b[?25h\x1b[?1049l";
        _ = c.write(1, restore_seq.ptr, restore_seq.len);
        // Restore termios
        _ = c.tcsetattr(0, c.TCSAFLUSH, &state.orig_termios);
        state.raw_mode_active = false;
    }
    if (state.stdin_nonblock) {
        _ = c.fcntl(0, c.F_SETFL, state.orig_stdin_flags);
        state.stdin_nonblock = false;
    }
}

/// Map an RGB color to the nearest xterm-256 color index
fn rgbToXterm256(r_in: u8, g_in: u8, b_in: u8) u8 {
    const r: u32 = r_in;
    const g: u32 = g_in;
    const b: u32 = b_in;

    // Check exact grayscale (r==g==b) for the grayscale ramp
    if (r == g and g == b) {
        if (r < 8) return 16; // black
        if (r > 248) return 231; // white
        const gray_idx: u8 = @intCast(@min((r -| 8) / 10, 23));
        return 232 + gray_idx;
    }

    // Find best match across 6x6x6 color cube AND grayscale ramp
    var best: u8 = 16;
    var best_dist: u32 = std.math.maxInt(u32);

    // Check 6x6x6 color cube (indices 16-231)
    const cube_values = [6]u32{ 0, 95, 135, 175, 215, 255 };
    for (0..6) |ri| {
        for (0..6) |gi| {
            for (0..6) |bi| {
                const cr = cube_values[ri];
                const cg = cube_values[gi];
                const cb = cube_values[bi];
                const dr = if (r >= cr) r - cr else cr - r;
                const dg = if (g >= cg) g - cg else cg - g;
                const db = if (b >= cb) b - cb else cb - b;
                const dist = dr * dr + dg * dg + db * db;
                if (dist < best_dist) {
                    best_dist = dist;
                    best = @intCast(16 + ri * 36 + gi * 6 + bi);
                }
            }
        }
    }

    // Check grayscale ramp (232-255) — only replace if strictly closer
    for (0..24) |gi| {
        const gray: u32 = @as(u32, @intCast(gi)) * 10 + 8;
        const dr2 = if (r >= gray) r - gray else gray - r;
        const dg2 = if (g >= gray) g - gray else gray - g;
        const db2 = if (b >= gray) b - gray else gray - b;
        const dist = dr2 * dr2 + dg2 * dg2 + db2 * db2;
        if (dist < best_dist) {
            best_dist = dist;
            best = @intCast(232 + gi);
        }
    }

    return best;
}

/// Build the palette cache: map each DOOM palette entry -> xterm-256 color
fn buildPaletteCache(cache: *PaletteCache, palette: *const [768]u8) void {
    for (0..256) |i| {
        cache[i] = rgbToXterm256(
            palette[i * 3 + 0],
            palette[i * 3 + 1],
            palette[i * 3 + 2],
        );
    }
}

/// Write a decimal number into a buffer, return number of bytes written
fn writeDecimal(buf: []u8, val: u32) usize {
    if (val == 0) {
        buf[0] = '0';
        return 1;
    }
    var v = val;
    var digits: [10]u8 = undefined;
    var len: usize = 0;
    while (v > 0) : (v /= 10) {
        digits[len] = @intCast('0' + (v % 10));
        len += 1;
    }
    // Reverse
    for (0..len) |i| {
        buf[i] = digits[len - 1 - i];
    }
    return len;
}

// ============================================================================
// Platform vtable implementation
// ============================================================================

fn tuiInitVideo(ctx: *anyopaque, _: u32, _: u32) bool {
    const state: *TuiState = @ptrCast(@alignCast(ctx));

    // Get terminal size (try stdout, then stderr, then stdin)
    var ws: c.winsize = undefined;
    if (c.ioctl(1, c.TIOCGWINSZ, &ws) == 0 and ws.ws_col > 0 and ws.ws_row > 0) {
        state.term_cols = ws.ws_col;
        state.term_rows = ws.ws_row;
    } else if (c.ioctl(2, c.TIOCGWINSZ, &ws) == 0 and ws.ws_col > 0 and ws.ws_row > 0) {
        state.term_cols = ws.ws_col;
        state.term_rows = ws.ws_row;
    } else if (c.ioctl(0, c.TIOCGWINSZ, &ws) == 0 and ws.ws_col > 0 and ws.ws_row > 0) {
        state.term_cols = ws.ws_col;
        state.term_rows = ws.ws_row;
    }

    // Calculate render dimensions to fit terminal
    // Each cell = 1 char wide, 2 pixels tall (half-block)
    const scale_x = if (state.term_cols >= SCREENWIDTH) 1 else (SCREENWIDTH + state.term_cols - 1) / state.term_cols;
    const scale_y = scale_x; // Keep aspect ratio square-ish

    state.render_cols = SCREENWIDTH / scale_x;
    state.render_rows = (SCREENHEIGHT / 2) / scale_y;

    // Clamp to terminal size (leave 2 rows margin to prevent scrolling)
    if (state.render_cols > state.term_cols) state.render_cols = state.term_cols;
    if (state.render_rows > state.term_rows -| 2) state.render_rows = state.term_rows -| 2;

    // Debug: report dimensions to stderr
    {
        var dbg: [128]u8 = undefined;
        var dpos: usize = 0;
        const prefix = "TUI: term=";
        @memcpy(dbg[dpos .. dpos + prefix.len], prefix);
        dpos += prefix.len;
        dpos += writeDecimal(dbg[dpos..], state.term_cols);
        dbg[dpos] = 'x';
        dpos += 1;
        dpos += writeDecimal(dbg[dpos..], state.term_rows);
        const mid = " render=";
        @memcpy(dbg[dpos .. dpos + mid.len], mid);
        dpos += mid.len;
        dpos += writeDecimal(dbg[dpos..], state.render_cols);
        dbg[dpos] = 'x';
        dpos += 1;
        dpos += writeDecimal(dbg[dpos..], state.render_rows);
        dbg[dpos] = '\n';
        dpos += 1;
        _ = c.write(2, &dbg, dpos);
    }

    // Allocate frame buffer
    state.frame_buf = state.allocator.alloc(u8, MAX_FRAME_BUF) catch return false;

    // Save original termios
    _ = c.tcgetattr(0, &state.orig_termios);

    // Enter raw mode
    var raw = state.orig_termios;
    raw.c_iflag &= ~@as(c.tcflag_t, @intCast(c.BRKINT | c.ICRNL | c.INPCK | c.ISTRIP | c.IXON));
    raw.c_oflag &= ~@as(c.tcflag_t, @intCast(c.OPOST));
    raw.c_cflag |= @as(c.tcflag_t, @intCast(c.CS8));
    raw.c_lflag &= ~@as(c.tcflag_t, @intCast(c.ECHO | c.ICANON | c.IEXTEN | c.ISIG));
    raw.c_cc[c.VMIN] = 0;
    raw.c_cc[c.VTIME] = 0;
    _ = c.tcsetattr(0, c.TCSAFLUSH, &raw);
    state.raw_mode_active = true;

    // Set stdin to non-blocking
    state.orig_stdin_flags = c.fcntl(0, c.F_GETFL, @as(c_int, 0));
    _ = c.fcntl(0, c.F_SETFL, state.orig_stdin_flags | c.O_NONBLOCK);
    state.stdin_nonblock = true;

    // Install signal handler for cleanup
    g_tui_state = state;
    _ = c.signal(c.SIGINT, &sigHandler);
    _ = c.signal(c.SIGTERM, &sigHandler);

    // Switch to alternate screen buffer, hide cursor, clear screen
    const init_seq = "\x1b[?1049h\x1b[?25l\x1b[2J\x1b[H";
    _ = c.write(1, init_seq.ptr, init_seq.len);

    // Initialize timer
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    state.start_time_s = ts.tv_sec;
    state.start_time_ns = ts.tv_nsec;

    state.video_init = true;
    return true;
}

fn tuiDeinitVideo(ctx: *anyopaque) void {
    const state: *TuiState = @ptrCast(@alignCast(ctx));
    if (!state.video_init) return;

    restoreTerminal(state);
    g_tui_state = null;

    if (state.frame_buf.len > 0) {
        state.allocator.free(state.frame_buf);
        state.frame_buf = &[_]u8{};
    }
    state.video_init = false;
}

fn tuiFinishUpdate(ctx: *anyopaque, screen: *const [SCREENSIZE]u8, palette: *const [768]u8) void {
    const state: *TuiState = @ptrCast(@alignCast(ctx));

    // Rebuild palette cache if needed
    if (!state.palette_valid) {
        buildPaletteCache(&state.palette_cache, palette);
        state.palette_valid = true;
    }

    var buf = state.frame_buf;
    var pos: usize = 0;

    const cols = state.render_cols;
    const rows = state.render_rows;

    // Scale factors (integer, >= 1)
    const sx = SCREENWIDTH / cols;
    const sy = SCREENHEIGHT / (rows * 2);

    // Debug: write frame stats to /tmp/doom_debug.txt (first 3 frames)
    if (state.frame_count < 3) {
        var nonzero: u32 = 0;
        for (screen) |px| {
            if (px != 0) nonzero += 1;
        }
        var pal_nonzero: u32 = 0;
        for (palette) |b| {
            if (b != 0) pal_nonzero += 1;
        }
        // Also count unique palette indices used in screen
        var idx_used: [256]bool = [_]bool{false} ** 256;
        for (screen) |px| {
            idx_used[px] = true;
        }
        var unique_idx: u32 = 0;
        for (idx_used) |used| {
            if (used) unique_idx += 1;
        }
        var dbg2: [256]u8 = undefined;
        var dp2: usize = 0;
        const pfx_f = "frame=";
        @memcpy(dbg2[dp2 .. dp2 + pfx_f.len], pfx_f);
        dp2 += pfx_f.len;
        dp2 += writeDecimal(dbg2[dp2..], state.frame_count);
        const pfx2 = " pixels=";
        @memcpy(dbg2[dp2 .. dp2 + pfx2.len], pfx2);
        dp2 += pfx2.len;
        dp2 += writeDecimal(dbg2[dp2..], nonzero);
        const pfx3 = "/64000 pal=";
        @memcpy(dbg2[dp2 .. dp2 + pfx3.len], pfx3);
        dp2 += pfx3.len;
        dp2 += writeDecimal(dbg2[dp2..], pal_nonzero);
        const pfx4 = "/768 unique_idx=";
        @memcpy(dbg2[dp2 .. dp2 + pfx4.len], pfx4);
        dp2 += pfx4.len;
        dp2 += writeDecimal(dbg2[dp2..], unique_idx);
        const pfx5 = " cols=";
        @memcpy(dbg2[dp2 .. dp2 + pfx5.len], pfx5);
        dp2 += pfx5.len;
        dp2 += writeDecimal(dbg2[dp2..], cols);
        const pfx6 = " rows=";
        @memcpy(dbg2[dp2 .. dp2 + pfx6.len], pfx6);
        dp2 += pfx6.len;
        dp2 += writeDecimal(dbg2[dp2..], rows);
        const pfx7 = " bufpos=";
        @memcpy(dbg2[dp2 .. dp2 + pfx7.len], pfx7);
        dp2 += pfx7.len;
        // We'll fill this after rendering, use 0 for now
        dp2 += writeDecimal(dbg2[dp2..], 0);
        dbg2[dp2] = '\n';
        dp2 += 1;
        const dbg_path = "/tmp/doom_debug.txt";
        const flags = if (state.frame_count == 0) c.O_WRONLY | c.O_CREAT | c.O_TRUNC else c.O_WRONLY | c.O_CREAT | c.O_APPEND;
        const fd = c.open(dbg_path, flags, @as(c.mode_t, 0o644));
        if (fd >= 0) {
            _ = c.write(fd, &dbg2, dp2);
            _ = c.close(fd);
        }
    }
    state.frame_count +%= 1;

    // Render each row of terminal cells (each cell = 2 pixel rows)
    for (0..rows) |row| {
        // Absolute cursor positioning: \x1b[ROW;1H (1-indexed)
        buf[pos] = 0x1b;
        pos += 1;
        buf[pos] = '[';
        pos += 1;
        pos += writeDecimal(buf[pos..], @as(u16, @intCast(row + 1)));
        buf[pos] = ';';
        pos += 1;
        buf[pos] = '1';
        pos += 1;
        buf[pos] = 'H';
        pos += 1;

        const top_y = row * 2 * sy;
        const bot_y = top_y + sy;

        var prev_fg: u16 = 999;
        var prev_bg: u16 = 999;

        for (0..cols) |col| {
            const src_x = col * sx;

            // Sample top and bottom pixels (center of each scaled cell)
            const top_idx: usize = if (top_y < SCREENHEIGHT and src_x < SCREENWIDTH)
                screen[top_y * SCREENWIDTH + src_x]
            else
                0;
            const bot_idx: usize = if (bot_y < SCREENHEIGHT and src_x < SCREENWIDTH)
                screen[bot_y * SCREENWIDTH + src_x]
            else
                0;

            const fg_color: u16 = state.palette_cache[top_idx];
            const bg_color: u16 = state.palette_cache[bot_idx];

            // Emit color escape sequences (only when colors change)
            if (fg_color != prev_fg or bg_color != prev_bg) {
                // \x1b[38;5;FGm\x1b[48;5;BGm
                buf[pos] = 0x1b;
                pos += 1;
                buf[pos] = '[';
                pos += 1;
                buf[pos] = '3';
                pos += 1;
                buf[pos] = '8';
                pos += 1;
                buf[pos] = ';';
                pos += 1;
                buf[pos] = '5';
                pos += 1;
                buf[pos] = ';';
                pos += 1;
                pos += writeDecimal(buf[pos..], fg_color);
                buf[pos] = 'm';
                pos += 1;
                buf[pos] = 0x1b;
                pos += 1;
                buf[pos] = '[';
                pos += 1;
                buf[pos] = '4';
                pos += 1;
                buf[pos] = '8';
                pos += 1;
                buf[pos] = ';';
                pos += 1;
                buf[pos] = '5';
                pos += 1;
                buf[pos] = ';';
                pos += 1;
                pos += writeDecimal(buf[pos..], bg_color);
                buf[pos] = 'm';
                pos += 1;

                prev_fg = fg_color;
                prev_bg = bg_color;
            }

            // Upper half block: foreground = top pixel, background = bottom pixel
            // UTF-8 for U+2580 (UPPER HALF BLOCK): E2 96 80
            buf[pos] = 0xE2;
            pos += 1;
            buf[pos] = 0x96;
            pos += 1;
            buf[pos] = 0x80;
            pos += 1;

            // Safety check
            if (pos + 64 >= buf.len) break;
        }

        // Reset colors
        buf[pos] = 0x1b;
        pos += 1;
        buf[pos] = '[';
        pos += 1;
        buf[pos] = '0';
        pos += 1;
        buf[pos] = 'm';
        pos += 1;

        // No newline needed — each row uses absolute cursor positioning

        if (pos + 64 >= buf.len) break;
    }

    // Write the entire frame — loop to handle partial writes
    var written: usize = 0;
    while (written < pos) {
        const n = c.write(1, buf.ptr + written, pos - written);
        if (n <= 0) break;
        written += @intCast(n);
    }
}

fn tuiSetPalette(ctx: *anyopaque, _: *const [768]u8) void {
    const state: *TuiState = @ptrCast(@alignCast(ctx));
    // Invalidate cache so finishUpdate rebuilds it
    state.palette_valid = false;
}

fn tuiGetEvents(ctx: *anyopaque, buffer: []Event) []Event {
    const state: *TuiState = @ptrCast(@alignCast(ctx));
    var count: usize = 0;
    const max = buffer.len;

    // Read bytes from stdin (non-blocking)
    var input_buf: [64]u8 = undefined;
    const n = c.read(0, &input_buf, input_buf.len);
    if (n <= 0) return buffer[0..0];

    const bytes: usize = @intCast(n);
    var i: usize = 0;

    while (i < bytes and count < max) {
        const byte = input_buf[i];

        if (byte == 0x1b) {
            // Escape sequence
            if (i + 2 < bytes and input_buf[i + 1] == '[') {
                const code = input_buf[i + 2];
                const key: i32 = switch (code) {
                    'A' => event_mod.KEY_UPARROW,
                    'B' => event_mod.KEY_DOWNARROW,
                    'C' => event_mod.KEY_RIGHTARROW,
                    'D' => event_mod.KEY_LEFTARROW,
                    else => 0,
                };
                if (key != 0) {
                    buffer[count] = .{ .event_type = .key_down, .data1 = key, .data2 = 0, .data3 = 0 };
                    count += 1;
                    if (count < max) {
                        buffer[count] = .{ .event_type = .key_up, .data1 = key, .data2 = 0, .data3 = 0 };
                        count += 1;
                    }
                }
                i += 3;
                continue;
            }
            // Bare escape = ESC key
            buffer[count] = .{ .event_type = .key_down, .data1 = event_mod.KEY_ESCAPE, .data2 = 0, .data3 = 0 };
            count += 1;
            if (count < max) {
                buffer[count] = .{ .event_type = .key_up, .data1 = event_mod.KEY_ESCAPE, .data2 = 0, .data3 = 0 };
                count += 1;
            }
            i += 1;
            continue;
        }

        if (byte == 3) {
            // CTRL+C = quit
            state.quit_requested = true;
            i += 1;
            continue;
        }

        // Map ASCII to DOOM keys
        const key: i32 = switch (byte) {
            '\r', '\n' => event_mod.KEY_ENTER,
            '\t' => event_mod.KEY_TAB,
            127 => event_mod.KEY_BACKSPACE,
            ' ' => event_mod.KEY_USE,
            // WASD movement
            'w', 'W' => event_mod.KEY_UPARROW,
            's', 'S' => event_mod.KEY_DOWNARROW,
            'a', 'A' => event_mod.KEY_LEFTARROW,
            'd', 'D' => event_mod.KEY_RIGHTARROW,
            // Controls
            'e', 'E' => event_mod.KEY_USE, // alternate use key
            'f', 'F' => event_mod.KEY_FIRE,
            'q', 'Q' => event_mod.KEY_ESCAPE,
            // Number keys (weapon select)
            '1', '2', '3', '4', '5', '6', '7', '8', '9' => byte,
            else => if (byte >= 32 and byte < 127) byte else 0,
        };

        if (key != 0) {
            buffer[count] = .{ .event_type = .key_down, .data1 = key, .data2 = 0, .data3 = 0 };
            count += 1;
            if (count < max) {
                buffer[count] = .{ .event_type = .key_up, .data1 = key, .data2 = 0, .data3 = 0 };
                count += 1;
            }
        }

        i += 1;
    }

    return buffer[0..count];
}

fn tuiGetTics(ctx: *anyopaque) u32 {
    const state: *TuiState = @ptrCast(@alignCast(ctx));

    var ts: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);

    const elapsed_s: i64 = ts.tv_sec - state.start_time_s;
    const elapsed_ns: i64 = ts.tv_nsec - state.start_time_ns;
    const elapsed_ms: u64 = @intCast(elapsed_s * 1000 + @divTrunc(elapsed_ns, 1_000_000));

    // Convert to 35 Hz tics
    return @intCast(elapsed_ms * 35 / 1000);
}

fn tuiInitSound(_: *anyopaque) bool {
    return false; // TUI has no sound
}

fn tuiDeinitSound(_: *anyopaque) void {}

fn tuiStartSound(_: *anyopaque, _: [*]const u8, _: u32, _: u32, _: u32, _: u32) u32 {
    return 0;
}

fn tuiStopSound(_: *anyopaque, _: u32) void {}

fn tuiIsSoundPlaying(_: *anyopaque, _: u32) bool {
    return false;
}

fn tuiUpdateSound(_: *anyopaque) void {}

fn tuiSleep(_: *anyopaque, ms: u32) void {
    var ts: c.timespec = undefined;
    ts.tv_sec = @intCast(ms / 1000);
    ts.tv_nsec = @intCast(@as(u64, ms % 1000) * 1_000_000);
    _ = c.nanosleep(&ts, null);
}

fn tuiGetTitle(_: *anyopaque) []const u8 {
    return "zig_doom (TUI)";
}

fn tuiIsQuitRequested(ctx: *anyopaque) bool {
    const state: *TuiState = @ptrCast(@alignCast(ctx));
    return state.quit_requested;
}

/// Create a TUI platform backend
pub fn create(allocator: std.mem.Allocator) ?*Platform {
    const state = allocator.create(TuiState) catch return null;
    state.* = .{
        .allocator = allocator,
        .platform = .{
            .initVideo = &tuiInitVideo,
            .deinitVideo = &tuiDeinitVideo,
            .finishUpdate = &tuiFinishUpdate,
            .setPalette = &tuiSetPalette,
            .getEvents = &tuiGetEvents,
            .getTics = &tuiGetTics,
            .initSound = &tuiInitSound,
            .deinitSound = &tuiDeinitSound,
            .startSound = &tuiStartSound,
            .stopSound = &tuiStopSound,
            .isSoundPlaying = &tuiIsSoundPlaying,
            .updateSound = &tuiUpdateSound,
            .sleep = &tuiSleep,
            .getTitle = &tuiGetTitle,
            .isQuitRequested = &tuiIsQuitRequested,
            .impl = undefined, // set below
        },
    };
    state.platform.impl = @ptrCast(state);
    return &state.platform;
}

/// Destroy the TUI backend
pub fn destroy(platform: *Platform, allocator: std.mem.Allocator) void {
    const state: *TuiState = @ptrCast(@alignCast(platform.impl));
    platform.deinitVideo(platform.impl);
    allocator.destroy(state);
}

// ============================================================================
// Tests
// ============================================================================

test "rgb to xterm256 black" {
    const result = rgbToXterm256(0, 0, 0);
    try std.testing.expectEqual(@as(u8, 16), result);
}

test "rgb to xterm256 white" {
    const result = rgbToXterm256(255, 255, 255);
    try std.testing.expectEqual(@as(u8, 231), result);
}

test "rgb to xterm256 red" {
    const result = rgbToXterm256(255, 0, 0);
    // Should be in the red area of the cube (index 196 = 16 + 5*36 + 0*6 + 0)
    try std.testing.expectEqual(@as(u8, 196), result);
}

test "palette cache build" {
    var palette: [768]u8 = undefined;
    @memset(&palette, 0);
    // Set entry 1 to pure red
    palette[3] = 255;
    palette[4] = 0;
    palette[5] = 0;

    var cache: PaletteCache = undefined;
    buildPaletteCache(&cache, &palette);

    try std.testing.expectEqual(@as(u8, 16), cache[0]); // black
    try std.testing.expectEqual(@as(u8, 196), cache[1]); // red
}

test "write decimal" {
    var buf: [16]u8 = undefined;
    const len = writeDecimal(&buf, 42);
    try std.testing.expectEqualStrings("42", buf[0..len]);
}

test "write decimal zero" {
    var buf: [16]u8 = undefined;
    const len = writeDecimal(&buf, 0);
    try std.testing.expectEqualStrings("0", buf[0..len]);
}
