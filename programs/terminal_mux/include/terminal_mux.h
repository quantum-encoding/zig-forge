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
typedef struct ZtermSession zterm_session;

/* Color channel encoding (matches zterm_cell.fg_kind / bg_kind). */
enum {
    ZTERM_COLOR_DEFAULT = 0,
    ZTERM_COLOR_INDEXED = 1, /* idx holds a 0..255 palette index */
    ZTERM_COLOR_RGB     = 2  /* r,g,b hold the 24-bit color      */
};

/* Cell attribute bits (matches zterm_cell.attrs). */
enum {
    ZTERM_ATTR_BOLD          = 1 << 0,
    ZTERM_ATTR_DIM           = 1 << 1,
    ZTERM_ATTR_ITALIC        = 1 << 2,
    ZTERM_ATTR_UNDERLINE     = 1 << 3,
    ZTERM_ATTR_BLINK         = 1 << 4,
    ZTERM_ATTR_INVERSE       = 1 << 5,
    ZTERM_ATTR_INVISIBLE     = 1 << 6,
    ZTERM_ATTR_STRIKETHROUGH = 1 << 7
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
} zterm_cell;

/* ---- version ---- */
const char *zterm_version(void);

/* ---- lifecycle ---- */
zterm_session *zterm_create(uint16_t rows, uint16_t cols, const char *shell, uint64_t *out_id);
/* The first pane runs argv[0..argc] as its own process: no shell, nothing
 * typed. argv[0] must be an absolute path. NULL on any failure. */
zterm_session *zterm_create_argv(uint16_t rows, uint16_t cols, const char *const *argv, size_t argc, uint64_t *out_id);
zterm_session *zterm_attach(uint64_t id);
void          zterm_detach(zterm_session *handle);
void          zterm_destroy(zterm_session *handle);
uint64_t      zterm_id(zterm_session *handle);
bool          zterm_is_attached(zterm_session *handle);
size_t        zterm_list(uint64_t *out_ids, size_t max);

/* ---- I/O ---- */
int      zterm_pty_fd(zterm_session *handle);
long     zterm_pump(zterm_session *handle, int timeout_ms);
long     zterm_drain(zterm_session *handle);
void     zterm_feed(zterm_session *handle, const uint8_t *data, size_t len);
/* Returns bytes ACTUALLY written, or -1. A short return means the child stopped
 * reading and the write hit its ~250ms stall budget — the caller owns the
 * remainder. Keystroke-sized sends never go short. */
long     zterm_send(zterm_session *handle, const uint8_t *data, size_t len);
int      zterm_resize(zterm_session *handle, uint16_t rows, uint16_t cols);
bool     zterm_is_alive(zterm_session *handle);
/* Whether a pane's shell has exited since the last call (read-and-clear).
 * zterm_drain latches this on EOF/POLLHUP once waitpid confirms the child is
 * gone; drain it on every wake. out_code / out_signal (either may be NULL)
 * receive the exit code and the terminating signal (0 = exited normally).
 * A dead pane otherwise looks exactly like an idle one — draw something. */
bool     zterm_take_exit(zterm_session *handle, int *out_code, int *out_signal);

/* ---- grid access ---- */
void     zterm_grid_size(zterm_session *handle, uint16_t *out_rows, uint16_t *out_cols);
size_t   zterm_read_cells(zterm_session *handle, zterm_cell *out, size_t max_cells);
void     zterm_cursor(zterm_session *handle, uint16_t *out_row, uint16_t *out_col, bool *out_visible);

/* ---- modes / cursor style / host effects ----
 * zterm_modes bitmask: 1 app-cursor (DECCKM) · 2 bracketed paste · 4 alt screen ·
 * 8 mouse tracking · 16 SGR mouse · 32 focus events.
 * zterm_mouse forwards press(0)/release(1)/drag-motion(2) of button 0/1/2 with
 * xterm mods (4 shift, 8 alt, 16 ctrl); returns 1 when reported to the app
 * (host must not also act), 0 when the host should handle locally.
 * take_bell / take_clipboard are read-and-clear (clipboard = OSC 52 "Pc;Pd"). */
uint32_t zterm_modes(zterm_session *handle);

/* Lines by ABSOLUTE number, stable while output streams and the view scrolls —
 * hold a selection against these, not screen cells. view_top = top visible
 * line, live_top = first line of the live grid, oldest = oldest retained line.
 * 0 on success, -1 for a bad handle or pane. */
int zterm_pane_lines(zterm_session *handle, size_t idx, int64_t *out_view_top,
                    int64_t *out_live_top, int64_t *out_oldest);

/* Copy one absolute line's cells (at most max). Cell count, or -1 when the
 * line is no longer retained or not yet written. */
long zterm_pane_read_line(zterm_session *handle, size_t idx, int64_t line,
                         zterm_cell *out, size_t max);

/* Put absolute `line` at the top of the pane's view (clamped). Returns the
 * resulting scroll offset. */
long zterm_pane_scroll_to(zterm_session *handle, size_t idx, int64_t line);
/* DEC 2026 synchronized output: true while a pane of the active window is
 * mid-sync-block — skip presenting this frame (keep the previous one) and
 * retry; blocks left open >250ms self-heal so the view can never freeze. */
bool     zterm_sync_suppressed(zterm_session *handle);
void     zterm_cursor_style(zterm_session *handle, uint8_t *out_shape, bool *out_blink);
uint32_t zterm_take_bell(zterm_session *handle);
size_t   zterm_take_clipboard(zterm_session *handle, uint8_t *out, size_t max);
/* Device-report replies the emulator owes the app (DA1/DA2, DSR/CPR, OSC 10/11
 * colour queries), read-and-clear. Drain on every wake alongside zterm_drain and
 * write the bytes back with zterm_send: vim/fzf/inner-tmux BLOCK on the answer.
 * Returns bytes copied (0 = none pending). Pass max >= 64 so a reply is never
 * split across two calls. */
size_t   zterm_take_responses(zterm_session *handle, uint8_t *out, size_t max);
size_t   zterm_title(zterm_session *handle, uint8_t *out, size_t max);
int      zterm_mouse(zterm_session *handle, int kind, int button, uint16_t row, uint16_t col, int mods);

/* ---- scrolling ----
 * zterm_scroll routes a wheel scroll of `delta` lines (positive = up / back in
 * time) at cell (row, col): mouse-reporting apps get wheel events (SGR when
 * DEC 1006 is set, X10 bytes otherwise); alt-screen apps without mouse get
 * arrow keys (xterm "alternate scroll"); the primary screen moves the viewport
 * through scrollback — zterm_read_cells then composes history + live grid.
 * Typing or pasting snaps the viewport back to the live bottom. Returns the
 * offset after the call; zterm_scroll_offset reads it without scrolling. */
long     zterm_scroll(zterm_session *handle, int delta, uint16_t row, uint16_t col);
long     zterm_scroll_offset(zterm_session *handle);

/* ---- window / pane control ---- */
int      zterm_split(zterm_session *handle, int horizontal);
int      zterm_new_window(zterm_session *handle);
int      zterm_select_window(zterm_session *handle, uint8_t index);
uint8_t  zterm_window_count(zterm_session *handle);
int      zterm_focus_next_pane(zterm_session *handle);

/* ---- pane-aware surface (composing splits in a host view) ----
 * Pane indices are positions in the active window's pane list at call time;
 * re-enumerate after split/close. Rects are in cells within the window extent
 * (zterm_window_size); split rects reserve a 1-cell gap for the border.
 * zterm_pane_cursor is PANE-LOCAL — the host adds the pane rect offset.
 * zterm_drain drains EVERY pane of the active window (background splits must
 * not stall on a full PTY buffer); zterm_pane_pty_fd gives each pane's fd for
 * per-pane readability sources. zterm_close_pane refuses (-1) the last pane. */
void     zterm_window_size(zterm_session *handle, uint16_t *out_rows, uint16_t *out_cols);
size_t   zterm_pane_count(zterm_session *handle);
int      zterm_pane_rect(zterm_session *handle, size_t idx, uint16_t *out_x, uint16_t *out_y, uint16_t *out_w, uint16_t *out_h);
bool     zterm_pane_is_active(zterm_session *handle, size_t idx);
int      zterm_focus_pane(zterm_session *handle, size_t idx);
int      zterm_pane_pty_fd(zterm_session *handle, size_t idx);
void     zterm_pane_cursor(zterm_session *handle, size_t idx, uint16_t *out_row, uint16_t *out_col, bool *out_visible);
size_t   zterm_pane_read_cells(zterm_session *handle, size_t idx, zterm_cell *out, size_t max_cells);
int      zterm_close_pane(zterm_session *handle, size_t idx);
long     zterm_pane_scroll(zterm_session *handle, size_t idx, int delta, uint16_t row, uint16_t col);
int      zterm_resize_split(zterm_session *handle, size_t idx, int dx, int dy);

/* ---- theme (shared color scheme) ----
 * The single source of truth for colors, shared by every renderer. Read your
 * config file yourself and push the bytes via zterm_set_theme_text (the `key =
 * value` format: `preset = <name>` plus background/foreground/cursor/color0..15/
 * url/bold_is_bright/cursor_style overrides), then read the resolved palette back
 * via zterm_get_theme to build your render palette + default fg/bg.
 */
typedef struct { uint8_t r, g, b; } zterm_rgb;

typedef struct {
    zterm_rgb palette[16];   /* ANSI 0-15; 16-255 are the fixed xterm cube */
    zterm_rgb bg;
    zterm_rgb fg;
    zterm_rgb cursor;
    zterm_rgb cursor_text;
    zterm_rgb selection_bg;
    zterm_rgb selection_fg;
    zterm_rgb url;           /* highlight color for detected URLs */
    uint8_t  bold_is_bright;
    uint8_t  cursor_style;  /* 0 block, 1 bar, 2 underline */
} zterm_theme;

void     zterm_set_theme_text(const uint8_t *text, size_t len);
void     zterm_reset_theme(void);
void     zterm_get_theme(zterm_theme *out);

/* ---- URL detection ----
 * Scan the active pane's visible grid for links. Fill `out` with up to `max`
 * ranges (end_col exclusive); returns the count. Paint each range in
 * theme.url + underline, and read the URL text for opening from your own cell
 * buffer (the cells at row/[start_col,end_col)).
 */
/* A detected link. A single-row URL has start_row == end_row; a soft-wrapped one
 * spans rows: row start_row is [start_col, cols), middle rows are full width, and
 * row end_row is [0, end_col). end_col is exclusive. */
typedef struct { uint16_t start_row, start_col, end_row, end_col; } zterm_url_range;
size_t   zterm_find_urls(zterm_session *handle, zterm_url_range *out, size_t max);

/* ---- paste ----
 * zterm_paste sends `data` to the active pane, wrapping it in ESC[200~ … ESC[201~
 * when the app has bracketed paste (DEC 2004) on, so big multi-line pastes go in
 * cleanly. zterm_bracketed_paste reports the current mode if you need it.
 *
 * RETURNS the payload bytes that actually reached the PTY, which may be SHORT
 * of `len`: a child that has stopped reading (Ctrl-Z'd, wedged, dead but not
 * reaped) stalls the write, and rather than block the caller forever the write
 * gives up after ~250ms of no progress. Callers MUST check the return and
 * resend the remainder. -1 on error. Chunk large pastes and keep them off a UI
 * thread — this call is synchronous. */
bool     zterm_bracketed_paste(zterm_session *handle);
long     zterm_paste(zterm_session *handle, const uint8_t *data, size_t len);

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
 *   read zterm_graphics_generation → if it changed, re-read placements + upload
 *   any new image (zterm_image_data → decode → MTLTexture cache keyed by
 *   image_id) → draw a second textured-quad pass → release the textures named
 *   by zterm_take_freed_images.
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
} zterm_placement;

/* Image metadata. format: 0 RGBA, 1 RGB, 2 PNG, 3 iterm-blob. For RGB/RGBA the
 * width/height are pixel dims; for PNG they are the transmitted hint (the host
 * decodes for the true size). */
typedef struct {
    uint32_t width;
    uint32_t height;
    uint8_t  format;
} zterm_image_info;

/* Number of image placements currently VISIBLE in the active pane. */
size_t   zterm_placement_count(zterm_session *handle);
/* Geometry of the idx-th visible placement (same order as _count). Returns 0 on
 * success, -1 if idx is out of range or on NULL. */
int      zterm_placement_at(zterm_session *handle, size_t idx, zterm_placement *out);
/* Copy image image_id's stored bytes into out (at most max) and fill info.
 * Returns the FULL byte length (may exceed max), 0 if no such image. Call with
 * out=NULL to query length + info, then allocate. */
size_t   zterm_image_data(zterm_session *handle, uint32_t image_id, uint8_t *out, size_t max, zterm_image_info *info);
/* Monotonic counter; bumps when placements/images change (transmit, place,
 * delete, eviction, alt-swap) so the host only re-uploads when something moved. */
uint64_t zterm_graphics_generation(zterm_session *handle);
/* Image ids freed since the last call (a=d, eviction, overwrite, alt-exit),
 * read-and-clear — release the matching textures. Writes up to max ids into
 * out_ids (may be NULL to just drain/count); returns the number freed. */
size_t   zterm_take_freed_images(zterm_session *handle, uint32_t *out_ids, size_t max);

/* ---- deprecated names ----
 * The ABI before it became zterm_*. The library exports every old function
 * symbol as well, so a host built against these names keeps linking for one
 * release; new code uses the zterm_* names above. */
typedef zterm_cell tmux_cell __attribute__((deprecated("use zterm_cell")));
typedef zterm_image_info tmux_image_info __attribute__((deprecated("use zterm_image_info")));
typedef zterm_placement tmux_placement __attribute__((deprecated("use zterm_placement")));
typedef zterm_rgb tmux_rgb __attribute__((deprecated("use zterm_rgb")));
typedef zterm_session tmux_session __attribute__((deprecated("use zterm_session")));
typedef zterm_theme tmux_theme __attribute__((deprecated("use zterm_theme")));
typedef zterm_url_range tmux_url_range __attribute__((deprecated("use zterm_url_range")));
enum {
    TMUX_COLOR_DEFAULT __attribute__((deprecated("use ZTERM_COLOR_DEFAULT"))) = ZTERM_COLOR_DEFAULT,
    TMUX_COLOR_INDEXED __attribute__((deprecated("use ZTERM_COLOR_INDEXED"))) = ZTERM_COLOR_INDEXED,
    TMUX_COLOR_RGB __attribute__((deprecated("use ZTERM_COLOR_RGB"))) = ZTERM_COLOR_RGB,
    TMUX_ATTR_BOLD __attribute__((deprecated("use ZTERM_ATTR_BOLD"))) = ZTERM_ATTR_BOLD,
    TMUX_ATTR_DIM __attribute__((deprecated("use ZTERM_ATTR_DIM"))) = ZTERM_ATTR_DIM,
    TMUX_ATTR_ITALIC __attribute__((deprecated("use ZTERM_ATTR_ITALIC"))) = ZTERM_ATTR_ITALIC,
    TMUX_ATTR_UNDERLINE __attribute__((deprecated("use ZTERM_ATTR_UNDERLINE"))) = ZTERM_ATTR_UNDERLINE,
    TMUX_ATTR_BLINK __attribute__((deprecated("use ZTERM_ATTR_BLINK"))) = ZTERM_ATTR_BLINK,
    TMUX_ATTR_INVERSE __attribute__((deprecated("use ZTERM_ATTR_INVERSE"))) = ZTERM_ATTR_INVERSE,
    TMUX_ATTR_INVISIBLE __attribute__((deprecated("use ZTERM_ATTR_INVISIBLE"))) = ZTERM_ATTR_INVISIBLE,
    TMUX_ATTR_STRIKETHROUGH __attribute__((deprecated("use ZTERM_ATTR_STRIKETHROUGH"))) = ZTERM_ATTR_STRIKETHROUGH
};
const char *tmux_version(void) __attribute__((deprecated("use zterm_version")));
zterm_session *tmux_create(uint16_t rows, uint16_t cols, const char *shell, uint64_t *out_id) __attribute__((deprecated("use zterm_create")));
zterm_session *tmux_attach(uint64_t id) __attribute__((deprecated("use zterm_attach")));
void tmux_detach(zterm_session *handle) __attribute__((deprecated("use zterm_detach")));
void tmux_destroy(zterm_session *handle) __attribute__((deprecated("use zterm_destroy")));
uint64_t tmux_id(zterm_session *handle) __attribute__((deprecated("use zterm_id")));
bool tmux_is_attached(zterm_session *handle) __attribute__((deprecated("use zterm_is_attached")));
size_t tmux_list(uint64_t *out_ids, size_t max) __attribute__((deprecated("use zterm_list")));
int tmux_pty_fd(zterm_session *handle) __attribute__((deprecated("use zterm_pty_fd")));
long tmux_pump(zterm_session *handle, int timeout_ms) __attribute__((deprecated("use zterm_pump")));
long tmux_drain(zterm_session *handle) __attribute__((deprecated("use zterm_drain")));
void tmux_feed(zterm_session *handle, const uint8_t *data, size_t len) __attribute__((deprecated("use zterm_feed")));
long tmux_send(zterm_session *handle, const uint8_t *data, size_t len) __attribute__((deprecated("use zterm_send")));
int tmux_resize(zterm_session *handle, uint16_t rows, uint16_t cols) __attribute__((deprecated("use zterm_resize")));
bool tmux_is_alive(zterm_session *handle) __attribute__((deprecated("use zterm_is_alive")));
bool tmux_take_exit(zterm_session *handle, int *out_code, int *out_signal) __attribute__((deprecated("use zterm_take_exit")));
void tmux_grid_size(zterm_session *handle, uint16_t *out_rows, uint16_t *out_cols) __attribute__((deprecated("use zterm_grid_size")));
size_t tmux_read_cells(zterm_session *handle, zterm_cell *out, size_t max_cells) __attribute__((deprecated("use zterm_read_cells")));
void tmux_cursor(zterm_session *handle, uint16_t *out_row, uint16_t *out_col, bool *out_visible) __attribute__((deprecated("use zterm_cursor")));
uint32_t tmux_modes(zterm_session *handle) __attribute__((deprecated("use zterm_modes")));
int tmux_pane_lines(zterm_session *handle, size_t idx, int64_t *out_view_top, int64_t *out_live_top, int64_t *out_oldest) __attribute__((deprecated("use zterm_pane_lines")));
long tmux_pane_read_line(zterm_session *handle, size_t idx, int64_t line, zterm_cell *out, size_t max) __attribute__((deprecated("use zterm_pane_read_line")));
long tmux_pane_scroll_to(zterm_session *handle, size_t idx, int64_t line) __attribute__((deprecated("use zterm_pane_scroll_to")));
bool tmux_sync_suppressed(zterm_session *handle) __attribute__((deprecated("use zterm_sync_suppressed")));
void tmux_cursor_style(zterm_session *handle, uint8_t *out_shape, bool *out_blink) __attribute__((deprecated("use zterm_cursor_style")));
uint32_t tmux_take_bell(zterm_session *handle) __attribute__((deprecated("use zterm_take_bell")));
size_t tmux_take_clipboard(zterm_session *handle, uint8_t *out, size_t max) __attribute__((deprecated("use zterm_take_clipboard")));
size_t tmux_take_responses(zterm_session *handle, uint8_t *out, size_t max) __attribute__((deprecated("use zterm_take_responses")));
size_t tmux_title(zterm_session *handle, uint8_t *out, size_t max) __attribute__((deprecated("use zterm_title")));
int tmux_mouse(zterm_session *handle, int kind, int button, uint16_t row, uint16_t col, int mods) __attribute__((deprecated("use zterm_mouse")));
long tmux_scroll(zterm_session *handle, int delta, uint16_t row, uint16_t col) __attribute__((deprecated("use zterm_scroll")));
long tmux_scroll_offset(zterm_session *handle) __attribute__((deprecated("use zterm_scroll_offset")));
int tmux_split(zterm_session *handle, int horizontal) __attribute__((deprecated("use zterm_split")));
int tmux_new_window(zterm_session *handle) __attribute__((deprecated("use zterm_new_window")));
int tmux_select_window(zterm_session *handle, uint8_t index) __attribute__((deprecated("use zterm_select_window")));
uint8_t tmux_window_count(zterm_session *handle) __attribute__((deprecated("use zterm_window_count")));
int tmux_focus_next_pane(zterm_session *handle) __attribute__((deprecated("use zterm_focus_next_pane")));
void tmux_window_size(zterm_session *handle, uint16_t *out_rows, uint16_t *out_cols) __attribute__((deprecated("use zterm_window_size")));
size_t tmux_pane_count(zterm_session *handle) __attribute__((deprecated("use zterm_pane_count")));
int tmux_pane_rect(zterm_session *handle, size_t idx, uint16_t *out_x, uint16_t *out_y, uint16_t *out_w, uint16_t *out_h) __attribute__((deprecated("use zterm_pane_rect")));
bool tmux_pane_is_active(zterm_session *handle, size_t idx) __attribute__((deprecated("use zterm_pane_is_active")));
int tmux_focus_pane(zterm_session *handle, size_t idx) __attribute__((deprecated("use zterm_focus_pane")));
int tmux_pane_pty_fd(zterm_session *handle, size_t idx) __attribute__((deprecated("use zterm_pane_pty_fd")));
void tmux_pane_cursor(zterm_session *handle, size_t idx, uint16_t *out_row, uint16_t *out_col, bool *out_visible) __attribute__((deprecated("use zterm_pane_cursor")));
size_t tmux_pane_read_cells(zterm_session *handle, size_t idx, zterm_cell *out, size_t max_cells) __attribute__((deprecated("use zterm_pane_read_cells")));
int tmux_close_pane(zterm_session *handle, size_t idx) __attribute__((deprecated("use zterm_close_pane")));
long tmux_pane_scroll(zterm_session *handle, size_t idx, int delta, uint16_t row, uint16_t col) __attribute__((deprecated("use zterm_pane_scroll")));
int tmux_resize_split(zterm_session *handle, size_t idx, int dx, int dy) __attribute__((deprecated("use zterm_resize_split")));
void tmux_set_theme_text(const uint8_t *text, size_t len) __attribute__((deprecated("use zterm_set_theme_text")));
void tmux_reset_theme(void) __attribute__((deprecated("use zterm_reset_theme")));
void tmux_get_theme(zterm_theme *out) __attribute__((deprecated("use zterm_get_theme")));
size_t tmux_find_urls(zterm_session *handle, zterm_url_range *out, size_t max) __attribute__((deprecated("use zterm_find_urls")));
bool tmux_bracketed_paste(zterm_session *handle) __attribute__((deprecated("use zterm_bracketed_paste")));
long tmux_paste(zterm_session *handle, const uint8_t *data, size_t len) __attribute__((deprecated("use zterm_paste")));
size_t tmux_placement_count(zterm_session *handle) __attribute__((deprecated("use zterm_placement_count")));
int tmux_placement_at(zterm_session *handle, size_t idx, zterm_placement *out) __attribute__((deprecated("use zterm_placement_at")));
size_t tmux_image_data(zterm_session *handle, uint32_t image_id, uint8_t *out, size_t max, zterm_image_info *info) __attribute__((deprecated("use zterm_image_data")));
uint64_t tmux_graphics_generation(zterm_session *handle) __attribute__((deprecated("use zterm_graphics_generation")));
size_t tmux_take_freed_images(zterm_session *handle, uint32_t *out_ids, size_t max) __attribute__((deprecated("use zterm_take_freed_images")));

#ifdef __cplusplus
}
#endif

#endif /* TERMINAL_MUX_H */
