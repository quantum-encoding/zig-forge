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
long     tmux_send(tmux_session *handle, const uint8_t *data, size_t len);
int      tmux_resize(tmux_session *handle, uint16_t rows, uint16_t cols);
bool     tmux_is_alive(tmux_session *handle);

/* ---- grid access ---- */
void     tmux_grid_size(tmux_session *handle, uint16_t *out_rows, uint16_t *out_cols);
size_t   tmux_read_cells(tmux_session *handle, tmux_cell *out, size_t max_cells);
void     tmux_cursor(tmux_session *handle, uint16_t *out_row, uint16_t *out_col, bool *out_visible);

/* ---- window / pane control ---- */
int      tmux_split(tmux_session *handle, int horizontal);
int      tmux_new_window(tmux_session *handle);
int      tmux_select_window(tmux_session *handle, uint8_t index);
uint8_t  tmux_window_count(tmux_session *handle);
int      tmux_focus_next_pane(tmux_session *handle);

#ifdef __cplusplus
}
#endif

#endif /* TERMINAL_MUX_H */
