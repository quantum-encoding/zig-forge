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
/// Truecolor cells cost ~38 bytes (two `\x1b[38;2;r;g;bm`-style escapes) + the
/// 3-byte half-block glyph. A full-detail frame (~320x200 cells) needs headroom.
const MAX_FRAME_BUF = 4 * 1024 * 1024;

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

    // 24-bit truecolor output (exact DOOM palette) vs xterm-256 quantization.
    truecolor: bool = false,

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

    // Synthetic key-hold tracking. A terminal only delivers key *presses*
    // (auto-repeated bytes while held), never releases. We treat a key as held
    // while its bytes keep arriving and release it after KEY_HOLD_MS of silence.
    key_down: [256]bool = [_]bool{false} ** 256,
    key_seen_ms: [256]i64 = [_]i64{0} ** 256,

    // Video initialized flag
    video_init: bool = false,
};

/// How long (ms) a key stays "held" after its last byte. Must exceed the
/// terminal's auto-repeat interval so a held key doesn't flicker, but be short
/// enough that a release stops movement promptly.
const KEY_HOLD_MS: i64 = 140;

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

/// Average the RGB of a rectangular block of the 320x200 framebuffer and map
/// the mean color to the nearest xterm-256 index.
///
/// This is an area (box) filter. Point-sampling (picking one pixel per cell)
/// aliases badly when downscaling 320x200 to ~106x66 terminal sub-pixels: a
/// fixed stride keeps landing on the same phase, so thin features collapse —
/// the wood-grain pillar turns into a solid black bar, status-bar digits drop
/// out. Averaging every source pixel the cell covers keeps those features.
fn avgBlockRgb(
    screen: *const [SCREENSIZE]u8,
    palette: *const [768]u8,
    x0: usize,
    x1: usize,
    y0: usize,
    y1: usize,
) [3]u8 {
    var rs: u32 = 0;
    var gs: u32 = 0;
    var bs: u32 = 0;
    var n: u32 = 0;
    var y = y0;
    while (y < y1) : (y += 1) {
        const rowbase = y * SCREENWIDTH;
        var x = x0;
        while (x < x1) : (x += 1) {
            const idx: usize = screen[rowbase + x];
            rs += palette[idx * 3 + 0];
            gs += palette[idx * 3 + 1];
            bs += palette[idx * 3 + 2];
            n += 1;
        }
    }
    if (n == 0) return .{ 0, 0, 0 };
    return .{ @intCast(rs / n), @intCast(gs / n), @intCast(bs / n) };
}

fn avgBlockXterm(
    screen: *const [SCREENSIZE]u8,
    palette: *const [768]u8,
    x0: usize,
    x1: usize,
    y0: usize,
    y1: usize,
) u8 {
    const rgb = avgBlockRgb(screen, palette, x0, x1, y0, y1);
    return rgbToXterm256(rgb[0], rgb[1], rgb[2]);
}

/// Write a `\x1b[38;2;R;G;Bm` (fg) or `\x1b[48;2;R;G;Bm` (bg) truecolor escape.
fn writeSetColorTrue(buf: []u8, is_bg: bool, rgb: [3]u8) usize {
    var p: usize = 0;
    buf[p] = 0x1b;
    p += 1;
    buf[p] = '[';
    p += 1;
    buf[p] = if (is_bg) '4' else '3';
    p += 1;
    buf[p] = '8';
    p += 1;
    buf[p] = ';';
    p += 1;
    buf[p] = '2';
    p += 1;
    buf[p] = ';';
    p += 1;
    p += writeDecimal(buf[p..], rgb[0]);
    buf[p] = ';';
    p += 1;
    p += writeDecimal(buf[p..], rgb[1]);
    buf[p] = ';';
    p += 1;
    p += writeDecimal(buf[p..], rgb[2]);
    buf[p] = 'm';
    p += 1;
    return p;
}

/// Write a `\x1b[38;5;Nm` (fg) or `\x1b[48;5;Nm` (bg) 256-color escape.
fn writeSetColor256(buf: []u8, is_bg: bool, idx: u8) usize {
    var p: usize = 0;
    buf[p] = 0x1b;
    p += 1;
    buf[p] = '[';
    p += 1;
    buf[p] = if (is_bg) '4' else '3';
    p += 1;
    buf[p] = '8';
    p += 1;
    buf[p] = ';';
    p += 1;
    buf[p] = '5';
    p += 1;
    buf[p] = ';';
    p += 1;
    p += writeDecimal(buf[p..], idx);
    buf[p] = 'm';
    p += 1;
    return p;
}

/// Pack an RGB triple into a u32 for cheap change-detection.
fn packRgb(rgb: [3]u8) u32 {
    return (@as(u32, rgb[0]) << 16) | (@as(u32, rgb[1]) << 8) | rgb[2];
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

    // Calculate render dimensions, aspect-corrected.
    //
    // The 320x200 framebuffer was designed to fill a 4:3 display, so its pixels
    // are NOT square — they're stretched 1.2x vertically (200 logical rows shown
    // as if 240). We render with the upper-half-block glyph, so each terminal
    // cell stacks 2 sub-pixels vertically; a monospace cell is ~2x taller than
    // wide, which makes those sub-pixels roughly square.
    //
    // For the picture to look like real DOOM (4:3) with square sub-pixels:
    //     render_cols : (render_rows * 2)  ==  4 : 3
    // i.e. render_rows = render_cols * 3 / 8.
    //
    // The previous code used render_rows = render_cols * 100/320 = *0.3125,
    // which drops the 1.2x correction and squashes everything vertically.
    const max_rows = state.term_rows -| 2; // leave a margin to avoid scrolling

    var cols: u32 = state.term_cols;
    if (cols > SCREENWIDTH) cols = SCREENWIDTH; // no benefit oversampling width
    var rows: u32 = (cols * 3) / 8;

    // If height-limited, cap rows and re-derive width to preserve 4:3.
    if (rows > max_rows) {
        rows = max_rows;
        cols = (rows * 8) / 3;
        if (cols > state.term_cols) cols = state.term_cols;
        if (cols > SCREENWIDTH) cols = SCREENWIDTH;
    }
    if (cols == 0) cols = 1;
    if (rows == 0) rows = 1;

    state.render_cols = cols;
    state.render_rows = rows;

    // Detect 24-bit truecolor support. Terminals that support it set COLORTERM
    // to "truecolor" or "24bit"; if so we emit exact DOOM palette RGB instead of
    // quantizing to the xterm-256 cube (which washes dark/desaturated DOOM
    // browns to gray).
    state.truecolor = false;
    if (std.c.getenv("COLORTERM")) |ct| {
        const s = std.mem.span(ct);
        if (std.mem.eql(u8, s, "truecolor") or std.mem.eql(u8, s, "24bit")) {
            state.truecolor = true;
        }
    }

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

    // NOTE: We deliberately do NOT set O_NONBLOCK on stdin here.
    //
    // On a real terminal, stdin/stdout/stderr (fds 0/1/2) all refer to the
    // *same* open file description for the tty. Setting O_NONBLOCK on fd 0
    // therefore also makes fd 1 (stdout) non-blocking. A full frame can be
    // ~100KB+ of ANSI; when it doesn't fit the tty output buffer in one go,
    // write() returns EAGAIN and the frame-write loop below would abandon the
    // rest of the frame — leaving only the top one or two rows on screen.
    //
    // Non-blocking *input* is already provided by the raw-mode termios above
    // (VMIN=0, VTIME=0): read() returns immediately with 0 bytes when there is
    // no pending input. So O_NONBLOCK on stdin is both redundant and harmful.
    state.orig_stdin_flags = c.fcntl(0, c.F_GETFL, @as(c_int, 0));
    state.stdin_nonblock = false;

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

        // Vertical extent of this cell's two stacked sub-pixels. Each terminal
        // row is 2 sub-pixels tall; there are rows*2 sub-pixels over 200 source
        // rows. Compute exact boundaries so the whole framebuffer is covered.
        const total_sub = rows * 2;
        const yt0 = (row * 2) * SCREENHEIGHT / total_sub;
        const yt1 = (row * 2 + 1) * SCREENHEIGHT / total_sub;
        const yb1 = (row * 2 + 2) * SCREENHEIGHT / total_sub;

        // Sentinel that never equals a real packed color (0xRRGGBB <= 0xFFFFFF).
        var prev_fg: u32 = 0xFFFF_FFFF;
        var prev_bg: u32 = 0xFFFF_FFFF;

        for (0..cols) |col| {
            // Horizontal extent of this cell over the 320-wide framebuffer.
            const x0 = col * SCREENWIDTH / cols;
            var x1 = (col + 1) * SCREENWIDTH / cols;
            if (x1 <= x0) x1 = x0 + 1;

            // Upper half-block: foreground = top sub-pixel, background = bottom.
            // Each is the area-average of the source pixels it covers.
            const fg_rgb = avgBlockRgb(screen, palette, x0, x1, yt0, yt1);
            const bg_rgb = avgBlockRgb(screen, palette, x0, x1, yt1, yb1);

            // Emit color escapes only when the cell colors change from the
            // previous cell (run-length compression of identical spans).
            if (state.truecolor) {
                const fk = packRgb(fg_rgb);
                const bk = packRgb(bg_rgb);
                if (fk != prev_fg or bk != prev_bg) {
                    pos += writeSetColorTrue(buf[pos..], false, fg_rgb);
                    pos += writeSetColorTrue(buf[pos..], true, bg_rgb);
                    prev_fg = fk;
                    prev_bg = bk;
                }
            } else {
                const fk: u32 = rgbToXterm256(fg_rgb[0], fg_rgb[1], fg_rgb[2]);
                const bk: u32 = rgbToXterm256(bg_rgb[0], bg_rgb[1], bg_rgb[2]);
                if (fk != prev_fg or bk != prev_bg) {
                    pos += writeSetColor256(buf[pos..], false, @intCast(fk));
                    pos += writeSetColor256(buf[pos..], true, @intCast(bk));
                    prev_fg = fk;
                    prev_bg = bk;
                }
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

    // Write the entire frame — loop to handle partial writes.
    // Retry on EINTR/EAGAIN rather than dropping the rest of the frame; a
    // half-written frame leaves stale rows on screen (the original "only the
    // top two rows render" bug). errno 0 means a clean partial write.
    var written: usize = 0;
    while (written < pos) {
        const n = c.write(1, buf.ptr + written, pos - written);
        if (n > 0) {
            written += @intCast(n);
            continue;
        }
        const err = std.posix.errno(@as(isize, n));
        if (err == .INTR or err == .AGAIN) continue;
        break;
    }
}

fn tuiSetPalette(ctx: *anyopaque, _: *const [768]u8) void {
    const state: *TuiState = @ptrCast(@alignCast(ctx));
    // Invalidate cache so finishUpdate rebuilds it
    state.palette_valid = false;
}

/// Monotonic milliseconds since video init.
fn nowMs(state: *const TuiState) i64 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    const s: i64 = @as(i64, ts.tv_sec) - state.start_time_s;
    const ns: i64 = @as(i64, ts.tv_nsec) - state.start_time_ns;
    return s * 1000 + @divTrunc(ns, 1_000_000);
}

fn tuiGetEvents(ctx: *anyopaque, buffer: []Event) []Event {
    const state: *TuiState = @ptrCast(@alignCast(ctx));
    var count: usize = 0;
    const max = buffer.len;
    const now = nowMs(state);

    // Mark a key as pressed this poll. Emits a key_down only on the rising edge
    // (first byte after release); subsequent auto-repeat bytes just refresh the
    // "last seen" time so the key stays held.
    const Mark = struct {
        fn press(st: *TuiState, buf: []Event, cnt: *usize, key: i32, t: i64) void {
            if (key <= 0 or key > 255) return;
            const k: usize = @intCast(key);
            st.key_seen_ms[k] = t;
            if (!st.key_down[k]) {
                st.key_down[k] = true;
                if (cnt.* < buf.len) {
                    buf[cnt.*] = .{ .event_type = .key_down, .data1 = key, .data2 = 0, .data3 = 0 };
                    cnt.* += 1;
                }
            }
        }
    };

    // Read available bytes (raw-mode VMIN=0/VTIME=0 makes this return at once).
    var input_buf: [64]u8 = undefined;
    const n = c.read(0, &input_buf, input_buf.len);
    const bytes: usize = if (n > 0) @intCast(n) else 0;

    var i: usize = 0;
    while (i < bytes) {
        const byte = input_buf[i];

        if (byte == 0x1b) {
            // Arrow-key escape sequence: ESC [ A/B/C/D
            if (i + 2 < bytes and input_buf[i + 1] == '[') {
                const key: i32 = switch (input_buf[i + 2]) {
                    'A' => event_mod.KEY_UPARROW,
                    'B' => event_mod.KEY_DOWNARROW,
                    'C' => event_mod.KEY_RIGHTARROW,
                    'D' => event_mod.KEY_LEFTARROW,
                    else => 0,
                };
                if (key != 0) Mark.press(state, buffer, &count, key, now);
                i += 3;
                continue;
            }
            // Bare ESC
            Mark.press(state, buffer, &count, event_mod.KEY_ESCAPE, now);
            i += 1;
            continue;
        }

        if (byte == 3) {
            // CTRL+C = quit
            state.quit_requested = true;
            i += 1;
            continue;
        }

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
        if (key != 0) Mark.press(state, buffer, &count, key, now);
        i += 1;
    }

    // Release keys that haven't been seen within the hold window.
    var k: usize = 0;
    while (k < 256) : (k += 1) {
        if (state.key_down[k] and (now - state.key_seen_ms[k]) > KEY_HOLD_MS) {
            state.key_down[k] = false;
            if (count < max) {
                buffer[count] = .{ .event_type = .key_up, .data1 = @intCast(k), .data2 = 0, .data3 = 0 };
                count += 1;
            }
        }
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
