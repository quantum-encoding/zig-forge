/*
 * terminal_mux — in-process C ABI (libterminal_mux)
 *
 * libghostty-style embedding surface: link the static library and drive the
 * multiplexer core (PTY + VT100 emulator) directly in-process. No socket hop.
 *
 * Threading: the registry calls (create/attach/detach/destroy/list) are
 * mutex-guarded and thread-safe. Per-session calls (pump/drain/feed/send and the
 * grid accessors) are NOT internally locked — drive a single session handle from
 * one thread at a time (one session per UI surface is the intended model).
 *
 * Generated to match src/capi.zig. Keep the two in sync.
 */
#ifndef TERMINAL_MUX_H
#define TERMINAL_MUX_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque session handle. */
typedef struct TmuxSession tmux_session;

/* Color channel encoding (matches tmux_cell.fg_kind / bg_kind). */
enum {
    TMUX_COLOR_DEFAULT = 0,
    TMUX_COLOR_INDEXED = 1, /* idx holds a 0..255 palette index */
    TMUX_COLOR_RGB     = 2  /* r,g,b hold the 24-bit color      */
};

/* Cell attribute bits (matches tmux_cell.attrs). */
enum {
    TMUX_ATTR_BOLD          = 1 << 0,
    TMUX_ATTR_DIM           = 1 << 1,
    TMUX_ATTR_ITALIC        = 1 << 2,
    TMUX_ATTR_UNDERLINE     = 1 << 3,
    TMUX_ATTR_BLINK         = 1 << 4,
    TMUX_ATTR_INVERSE       = 1 << 5,
    TMUX_ATTR_INVISIBLE     = 1 << 6,
    TMUX_ATTR_STRIKETHROUGH = 1 << 7
};

/*
 * A single terminal cell, flattened for rendering. Layout/size is asserted by
 * a Zig test (sizeof == 16, alignof == 4). `ch` is a Unicode codepoint; `width`
 * is 1, or 2 for wide (CJK) glyphs.
 */
typedef struct {
    uint32_t ch;
    uint8_t  fg_kind;
    uint8_t  fg_idx;
    uint8_t  fg_r;
    uint8_t  fg_g;
    uint8_t  fg_b;
    uint8_t  bg_kind;
    uint8_t  bg_idx;
    uint8_t  bg_r;
    uint8_t  bg_g;
    uint8_t  bg_b;
    uint8_t  attrs;
    uint8_t  width;
} tmux_cell;

/* ---- version ---- */
const char *tmux_version(void);

/* ---- lifecycle ---- */
tmux_session *tmux_create(uint16_t rows, uint16_t cols, const char *shell, uint64_t *out_id);
tmux_session *tmux_attach(uint64_t id);
void          tmux_detach(tmux_session *handle);
void          tmux_destroy(tmux_session *handle);
uint64_t      tmux_id(tmux_session *handle);
bool          tmux_is_attached(tmux_session *handle);
size_t        tmux_list(uint64_t *out_ids, size_t max);

/* ---- I/O ---- */
int      tmux_pty_fd(tmux_session *handle);
long     tmux_pump(tmux_session *handle, int timeout_ms);
long     tmux_drain(tmux_session *handle);
void     tmux_feed(tmux_session *handle, const uint8_t *data, size_t len);
/* Returns bytes ACTUALLY written, or -1. A short return means the child stopped
 * reading and the write hit its ~250ms stall budget — the caller owns the
 * remainder. Keystroke-sized sends never go short. */
long     tmux_send(tmux_session *handle, const uint8_t *data, size_t len);
int      tmux_resize(tmux_session *handle, uint16_t rows, uint16_t cols);
bool     tmux_is_alive(tmux_session *handle);
/* Whether a pane's shell has exited since the last call (read-and-clear).
 * tmux_drain latches this on EOF/POLLHUP once waitpid confirms the child is
 * gone; drain it on every wake. out_code / out_signal (either may be NULL)
 * receive the exit code and the terminating signal (0 = exited normally).
 * A dead pane otherwise looks exactly like an idle one — draw something. */
bool     tmux_take_exit(tmux_session *handle, int *out_code, int *out_signal);

/* ---- grid access ---- */
void     tmux_grid_size(tmux_session *handle, uint16_t *out_rows, uint16_t *out_cols);
size_t   tmux_read_cells(tmux_session *handle, tmux_cell *out, size_t max_cells);
void     tmux_cursor(tmux_session *handle, uint16_t *out_row, uint16_t *out_col, bool *out_visible);

/* ---- modes / cursor style / host effects ----
 * tmux_modes bitmask: 1 app-cursor (DECCKM) · 2 bracketed paste · 4 alt screen ·
 * 8 mouse tracking · 16 SGR mouse · 32 focus events.
 * tmux_mouse forwards press(0)/release(1)/drag-motion(2) of button 0/1/2 with
 * xterm mods (4 shift, 8 alt, 16 ctrl); returns 1 when reported to the app
 * (host must not also act), 0 when the host should handle locally.
 * take_bell / take_clipboard are read-and-clear (clipboard = OSC 52 "Pc;Pd"). */
uint32_t tmux_modes(tmux_session *handle);
/* DEC 2026 synchronized output: true while a pane of the active window is
 * mid-sync-block — skip presenting this frame (keep the previous one) and
 * retry; blocks left open >250ms self-heal so the view can never freeze. */
bool     tmux_sync_suppressed(tmux_session *handle);
void     tmux_cursor_style(tmux_session *handle, uint8_t *out_shape, bool *out_blink);
uint32_t tmux_take_bell(tmux_session *handle);
size_t   tmux_take_clipboard(tmux_session *handle, uint8_t *out, size_t max);
/* Device-report replies the emulator owes the app (DA1/DA2, DSR/CPR, OSC 10/11
 * colour queries), read-and-clear. Drain on every wake alongside tmux_drain and
 * write the bytes back with tmux_send: vim/fzf/inner-tmux BLOCK on the answer.
 * Returns bytes copied (0 = none pending). Pass max >= 64 so a reply is never
 * split across two calls. */
size_t   tmux_take_responses(tmux_session *handle, uint8_t *out, size_t max);
size_t   tmux_title(tmux_session *handle, uint8_t *out, size_t max);
int      tmux_mouse(tmux_session *handle, int kind, int button, uint16_t row, uint16_t col, int mods);

/* ---- scrolling ----
 * tmux_scroll routes a wheel scroll of `delta` lines (positive = up / back in
 * time) at cell (row, col): mouse-reporting apps get wheel events (SGR when
 * DEC 1006 is set, X10 bytes otherwise); alt-screen apps without mouse get
 * arrow keys (xterm "alternate scroll"); the primary screen moves the viewport
 * through scrollback — tmux_read_cells then composes history + live grid.
 * Typing or pasting snaps the viewport back to the live bottom. Returns the
 * offset after the call; tmux_scroll_offset reads it without scrolling. */
long     tmux_scroll(tmux_session *handle, int delta, uint16_t row, uint16_t col);
long     tmux_scroll_offset(tmux_session *handle);

/* ---- window / pane control ---- */
int      tmux_split(tmux_session *handle, int horizontal);
int      tmux_new_window(tmux_session *handle);
int      tmux_select_window(tmux_session *handle, uint8_t index);
uint8_t  tmux_window_count(tmux_session *handle);
int      tmux_focus_next_pane(tmux_session *handle);

/* ---- pane-aware surface (composing splits in a host view) ----
 * Pane indices are positions in the active window's pane list at call time;
 * re-enumerate after split/close. Rects are in cells within the window extent
 * (tmux_window_size); split rects reserve a 1-cell gap for the border.
 * tmux_pane_cursor is PANE-LOCAL — the host adds the pane rect offset.
 * tmux_drain drains EVERY pane of the active window (background splits must
 * not stall on a full PTY buffer); tmux_pane_pty_fd gives each pane's fd for
 * per-pane readability sources. tmux_close_pane refuses (-1) the last pane. */
void     tmux_window_size(tmux_session *handle, uint16_t *out_rows, uint16_t *out_cols);
size_t   tmux_pane_count(tmux_session *handle);
int      tmux_pane_rect(tmux_session *handle, size_t idx, uint16_t *out_x, uint16_t *out_y, uint16_t *out_w, uint16_t *out_h);
bool     tmux_pane_is_active(tmux_session *handle, size_t idx);
int      tmux_focus_pane(tmux_session *handle, size_t idx);
int      tmux_pane_pty_fd(tmux_session *handle, size_t idx);
void     tmux_pane_cursor(tmux_session *handle, size_t idx, uint16_t *out_row, uint16_t *out_col, bool *out_visible);
size_t   tmux_pane_read_cells(tmux_session *handle, size_t idx, tmux_cell *out, size_t max_cells);
int      tmux_close_pane(tmux_session *handle, size_t idx);
long     tmux_pane_scroll(tmux_session *handle, size_t idx, int delta, uint16_t row, uint16_t col);
int      tmux_resize_split(tmux_session *handle, size_t idx, int dx, int dy);

/* ---- theme (shared color scheme) ----
 * The single source of truth for colors, shared by every renderer. Read your
 * config file yourself and push the bytes via tmux_set_theme_text (the `key =
 * value` format: `preset = <name>` plus background/foreground/cursor/color0..15/
 * url/bold_is_bright/cursor_style overrides), then read the resolved palette back
 * via tmux_get_theme to build your render palette + default fg/bg.
 */
typedef struct { uint8_t r, g, b; } tmux_rgb;

typedef struct {
    tmux_rgb palette[16];   /* ANSI 0-15; 16-255 are the fixed xterm cube */
    tmux_rgb bg;
    tmux_rgb fg;
    tmux_rgb cursor;
    tmux_rgb cursor_text;
    tmux_rgb selection_bg;
    tmux_rgb selection_fg;
    tmux_rgb url;           /* highlight color for detected URLs */
    uint8_t  bold_is_bright;
    uint8_t  cursor_style;  /* 0 block, 1 bar, 2 underline */
} tmux_theme;

void     tmux_set_theme_text(const uint8_t *text, size_t len);
void     tmux_reset_theme(void);
void     tmux_get_theme(tmux_theme *out);

/* ---- URL detection ----
 * Scan the active pane's visible grid for links. Fill `out` with up to `max`
 * ranges (end_col exclusive); returns the count. Paint each range in
 * theme.url + underline, and read the URL text for opening from your own cell
 * buffer (the cells at row/[start_col,end_col)).
 */
/* A detected link. A single-row URL has start_row == end_row; a soft-wrapped one
 * spans rows: row start_row is [start_col, cols), middle rows are full width, and
 * row end_row is [0, end_col). end_col is exclusive. */
typedef struct { uint16_t start_row, start_col, end_row, end_col; } tmux_url_range;
size_t   tmux_find_urls(tmux_session *handle, tmux_url_range *out, size_t max);

/* ---- paste ----
 * tmux_paste sends `data` to the active pane, wrapping it in ESC[200~ … ESC[201~
 * when the app has bracketed paste (DEC 2004) on, so big multi-line pastes go in
 * cleanly. tmux_bracketed_paste reports the current mode if you need it.
 *
 * RETURNS the payload bytes that actually reached the PTY, which may be SHORT
 * of `len`: a child that has stopped reading (Ctrl-Z'd, wedged, dead but not
 * reaped) stalls the write, and rather than block the caller forever the write
 * gives up after ~250ms of no progress. Callers MUST check the return and
 * resend the remainder. -1 on error. Chunk large pastes and keep them off a UI
 * thread — this call is synchronous. */
bool     tmux_bracketed_paste(tmux_session *handle);
long     tmux_paste(tmux_session *handle, const uint8_t *data, size_t len);

/* ---- inline graphics (Kitty protocol, Phase 1) — ADDITIVE ----
 * The emulator is a byte-pipe + geometry tracker: it captures transmitted image
 * bytes (RGB/RGBA/PNG) verbatim and tracks placements. It does NOT decode — the
 * host decodes (CGImageSource on Apple). Placements are anchored to an absolute
 * line index, so scroll is O(1); the ABI reports each visible placement's
 * CLIPPED on-screen cell rect plus the source pixel crop to sample.
 *
 * A consumer that ignores these calls renders exactly as before.
 *
 * Steady-state VRAM loop (the DOOM demo transmits+deletes one image per frame):
 *   read tmux_graphics_generation → if it changed, re-read placements + upload
 *   any new image (tmux_image_data → decode → MTLTexture cache keyed by
 *   image_id) → draw a second textured-quad pass → release the textures named
 *   by tmux_take_freed_images.
 */

/* A visible placement: the clipped on-screen CELL rect plus the SOURCE pixel
 * crop the host samples from the image. cell_* are grid-local; src_* are in
 * image-pixel space. z<0 draws below glyphs, z>=0 above. */
typedef struct {
    uint32_t image_id;
    uint16_t cell_x;
    uint16_t cell_y;
    uint16_t cell_w;
    uint16_t cell_h;
    uint32_t src_x;
    uint32_t src_y;
    uint32_t src_w;
    uint32_t src_h;
    int32_t  z;
} tmux_placement;

/* Image metadata. format: 0 RGBA, 1 RGB, 2 PNG, 3 iterm-blob. For RGB/RGBA the
 * width/height are pixel dims; for PNG they are the transmitted hint (the host
 * decodes for the true size). */
typedef struct {
    uint32_t width;
    uint32_t height;
    uint8_t  format;
} tmux_image_info;

/* Number of image placements currently VISIBLE in the active pane. */
size_t   tmux_placement_count(tmux_session *handle);
/* Geometry of the idx-th visible placement (same order as _count). Returns 0 on
 * success, -1 if idx is out of range or on NULL. */
int      tmux_placement_at(tmux_session *handle, size_t idx, tmux_placement *out);
/* Copy image image_id's stored bytes into out (at most max) and fill info.
 * Returns the FULL byte length (may exceed max), 0 if no such image. Call with
 * out=NULL to query length + info, then allocate. */
size_t   tmux_image_data(tmux_session *handle, uint32_t image_id, uint8_t *out, size_t max, tmux_image_info *info);
/* Monotonic counter; bumps when placements/images change (transmit, place,
 * delete, eviction, alt-swap) so the host only re-uploads when something moved. */
uint64_t tmux_graphics_generation(tmux_session *handle);
/* Image ids freed since the last call (a=d, eviction, overwrite, alt-exit),
 * read-and-clear — release the matching textures. Writes up to max ids into
 * out_ids (may be NULL to just drain/count); returns the number freed. */
size_t   tmux_take_freed_images(tmux_session *handle, uint32_t *out_ids, size_t max);

#ifdef __cplusplus
}
#endif

#endif /* TERMINAL_MUX_H */
