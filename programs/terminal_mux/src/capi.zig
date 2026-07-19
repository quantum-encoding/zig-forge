//! C ABI for terminal_mux — in-process embedding surface (libterminal_mux).
//!
//! This is the libghostty-style interface: a host application (e.g. a Swift /
//! SwiftUI front-end) links the static library and drives the multiplexer core
//! directly in-process — no socket hop. The PTY + VT100 emulator run inside the
//! caller's address space; the host owns the run loop and the GPU/text render.
//!
//! Threading: the global session registry (create / attach / detach / destroy /
//! list) is mutex-guarded and safe to call from any thread. Per-session calls
//! (pump / drain / feed / send / grid accessors) are NOT internally locked — a
//! single session handle must be driven from one thread at a time, which is the
//! natural model when each session is bound to one UI surface.
//!
//! "Attach / detach" here is in-process session lifecycle: a session created via
//! `tmux_create` is registered under a u64 id and keeps running (its shell stays
//! alive, its grid stays intact) until `tmux_destroy`. `tmux_detach` releases the
//! caller's logical hold without tearing anything down; `tmux_attach` re-acquires
//! the handle by id. This lets a host surface detach and a later surface reattach
//! to the same live session — the embedded analogue of `tmux attach`.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const session = @import("session.zig");
const terminal = @import("terminal.zig");
const config = @import("config.zig");
const url = @import("url.zig");
const gfx = @import("graphics.zig");

/// libc malloc-backed allocator — the standard choice for a C-linked library.
const alloc = std.heap.c_allocator;

/// Zig 0.16-compatible mutex backed by pthread (this toolchain's std has no
/// std.Thread.Mutex; the repo convention is to wrap pthread directly).
const Mutex = struct {
    inner: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,

    pub fn lock(self: *Mutex) void {
        _ = std.c.pthread_mutex_lock(&self.inner);
    }

    pub fn unlock(self: *Mutex) void {
        _ = std.c.pthread_mutex_unlock(&self.inner);
    }
};

const VERSION = "0.2.0";
const DEFAULT_SCROLLBACK: u32 = 10_000;
const READ_CHUNK = 65536;

// =============================================================================
// Handle + global registry
// =============================================================================

/// Opaque session handle exposed to C as `tmux_session*`.
pub const TmuxSession = struct {
    id: u64,
    sess: *session.Session,
    attached: bool,
};

var registry: std.AutoHashMapUnmanaged(u64, *TmuxSession) = .empty;
var registry_mutex: Mutex = .{};
var next_id: u64 = 1;

fn defaultShell() []const u8 {
    if (std.c.getenv("SHELL")) |s| {
        const slice = std.mem.sliceTo(s, 0);
        if (slice.len > 0) return slice;
    }
    // Sensible fallbacks: zsh is the macOS default login shell since 10.15.
    return if (builtin.os.tag.isDarwin()) "/bin/zsh" else "/bin/bash";
}

fn activePane(h: *TmuxSession) *session.Pane {
    return h.sess.getActiveWindow().getActivePane();
}

/// Environment for spawned shells: the host process environment with TERM /
/// COLORTERM forced to advertise this emulator's real capabilities (xterm-
/// compatible, truecolor SGR). A GUI host launched from the Dock has no TERM
/// at all, so without this every program in the PTY detects a dumb terminal
/// and emits zero color. Built once; lives for the process lifetime.
var child_env: ?[*:null]const ?[*:0]const u8 = null;
var child_env_mutex: Mutex = .{};

fn childEnviron() [*:null]const ?[*:0]const u8 {
    child_env_mutex.lock();
    defer child_env_mutex.unlock();
    if (child_env) |e| return e;

    const src = std.c.environ;
    var n: usize = 0;
    while (src[n] != null) : (n += 1) {}

    // Worst case: every host entry kept + 2 forced vars + NULL terminator.
    const buf = alloc.alloc(?[*:0]const u8, n + 3) catch return std.c.environ;
    var i: usize = 0;
    for (0..n) |j| {
        const entry = std.mem.sliceTo(src[j].?, 0);
        if (std.mem.startsWith(u8, entry, "TERM=")) continue;
        if (std.mem.startsWith(u8, entry, "COLORTERM=")) continue;
        buf[i] = src[j];
        i += 1;
    }
    buf[i] = "TERM=xterm-256color";
    buf[i + 1] = "COLORTERM=truecolor";
    buf[i + 2] = null;
    const env: [*:null]const ?[*:0]const u8 = @ptrCast(buf.ptr);
    child_env = env;
    return env;
}

// =============================================================================
// C-visible data layout
// =============================================================================

/// Color encoding for a cell channel. Mirrors `terminal.CellColor`.
pub const ColorKind = enum(u8) {
    default = 0,
    indexed = 1,
    rgb = 2,
};

/// A single terminal cell, flattened for C consumers. Matches `tmux_cell` in
/// include/terminal_mux.h. `attrs` is the bit-for-bit `CellAttrs` byte:
///   bit0 bold, bit1 dim, bit2 italic, bit3 underline,
///   bit4 blink, bit5 inverse, bit6 invisible, bit7 strikethrough.
pub const CCell = extern struct {
    ch: u32, // Unicode codepoint
    fg_kind: u8,
    fg_idx: u8,
    fg_r: u8,
    fg_g: u8,
    fg_b: u8,
    bg_kind: u8,
    bg_idx: u8,
    bg_r: u8,
    bg_g: u8,
    bg_b: u8,
    attrs: u8,
    width: u8, // 1, or 2 for wide (CJK) glyphs
};

fn fillColor(col: terminal.CellColor, kind: *u8, idx: *u8, r: *u8, g: *u8, b: *u8) void {
    switch (col) {
        .default => {
            kind.* = @intFromEnum(ColorKind.default);
            idx.* = 0;
            r.* = 0;
            g.* = 0;
            b.* = 0;
        },
        .indexed => |i| {
            kind.* = @intFromEnum(ColorKind.indexed);
            idx.* = i;
            r.* = 0;
            g.* = 0;
            b.* = 0;
        },
        .rgb => |c| {
            kind.* = @intFromEnum(ColorKind.rgb);
            idx.* = 0;
            r.* = c.r;
            g.* = c.g;
            b.* = c.b;
        },
    }
}

// =============================================================================
// Lifecycle
// =============================================================================

/// Library version string ("MAJOR.MINOR.PATCH"), NUL-terminated, static.
pub export fn tmux_version() [*:0]const u8 {
    return VERSION;
}

/// Create a session: allocates a `rows`x`cols` terminal and spawns `shell`
/// (NULL → $SHELL, else /bin/zsh on macOS, /bin/bash elsewhere) in its first
/// pane. The session is registered under a new id (written to `out_id` if
/// non-NULL). Returns the handle, or NULL on failure. rows/cols of 0 default
/// to 24/80.
pub export fn tmux_create(rows: u16, cols: u16, shell: ?[*:0]const u8, out_id: ?*u64) ?*TmuxSession {
    const r: u16 = if (rows == 0) 24 else rows;
    const co: u16 = if (cols == 0) 80 else cols;
    const rect = session.Rect{ .x = 0, .y = 0, .width = co, .height = r };

    const sess = session.Session.init(alloc, "0", rect, DEFAULT_SCROLLBACK) catch return null;

    const pane = sess.getActiveWindow().getActivePane();
    const shell_path: []const u8 = if (shell) |s| std.mem.sliceTo(s, 0) else defaultShell();
    pane.spawn(shell_path, childEnviron()) catch {
        sess.deinit();
        return null;
    };

    const handle = alloc.create(TmuxSession) catch {
        sess.deinit();
        return null;
    };

    registry_mutex.lock();
    defer registry_mutex.unlock();

    const id = next_id;
    handle.* = .{ .id = id, .sess = sess, .attached = true };
    registry.put(alloc, id, handle) catch {
        alloc.destroy(handle);
        sess.deinit();
        return null;
    };
    next_id += 1;
    if (out_id) |o| o.* = id;
    return handle;
}

/// Re-acquire a live session by id. Returns the existing handle (marking it
/// attached) or NULL if no session with that id is registered.
pub export fn tmux_attach(id: u64) ?*TmuxSession {
    registry_mutex.lock();
    defer registry_mutex.unlock();
    const handle = registry.get(id) orelse return null;
    handle.attached = true;
    return handle;
}

/// Release the caller's logical hold on a session without tearing it down: the
/// shell keeps running and the grid is preserved for a later `tmux_attach`.
pub export fn tmux_detach(handle: ?*TmuxSession) void {
    const h = handle orelse return;
    registry_mutex.lock();
    defer registry_mutex.unlock();
    h.attached = false;
}

/// Destroy a session: terminates the shell, frees the terminal, and removes the
/// session from the registry. The handle is invalid after this call.
pub export fn tmux_destroy(handle: ?*TmuxSession) void {
    const h = handle orelse return;
    registry_mutex.lock();
    _ = registry.remove(h.id);
    registry_mutex.unlock();
    h.sess.deinit();
    alloc.destroy(h);
}

/// The session's registry id (0 if handle is NULL).
pub export fn tmux_id(handle: ?*TmuxSession) u64 {
    const h = handle orelse return 0;
    return h.id;
}

/// Whether the session is currently attached (1) or detached (0).
pub export fn tmux_is_attached(handle: ?*TmuxSession) bool {
    const h = handle orelse return false;
    return h.attached;
}

/// Enumerate live session ids. Writes up to `max` ids into `out_ids` (may be
/// NULL to just count) and returns the total number of live sessions (which may
/// exceed `max`).
pub export fn tmux_list(out_ids: ?[*]u64, max: usize) usize {
    registry_mutex.lock();
    defer registry_mutex.unlock();
    var i: usize = 0;
    var it = registry.valueIterator();
    while (it.next()) |hp| {
        if (out_ids) |buf| {
            if (i < max) buf[i] = hp.*.id;
        }
        i += 1;
    }
    return i;
}

// =============================================================================
// I/O
// =============================================================================

/// The PTY master fd of the active pane (-1 if none). The host can register it
/// with a readability source (DispatchSource / kqueue) and call `tmux_drain`
/// when it fires, instead of polling via `tmux_pump`.
pub export fn tmux_pty_fd(handle: ?*TmuxSession) c_int {
    const h = handle orelse return -1;
    const fd = activePane(h).getFd() orelse return -1;
    return @intCast(fd);
}

/// Wait up to `timeout_ms` for PTY output on the active pane, then read one
/// chunk and run it through the VT emulator. Returns bytes processed, 0 on
/// timeout/no-data, or -1 on error (no PTY / read failure / EOF).
pub export fn tmux_pump(handle: ?*TmuxSession, timeout_ms: c_int) c_long {
    const h = handle orelse return -1;
    const pane = activePane(h);
    const fd = pane.getFd() orelse return -1;

    var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
    const n = posix.poll(&fds, timeout_ms) catch return -1;
    if (n == 0 or (fds[0].revents & posix.POLL.IN) == 0) return 0;

    var buf: [READ_CHUNK]u8 = undefined;
    const r = pane.readOutput(&buf) catch return -1;
    if (r == 0) return 0;
    pane.processOutput(buf[0..r]);
    return @intCast(r);
}

/// Drain all currently-available PTY output (non-blocking) from EVERY pane of
/// the active window, feeding each pane's VT emulator. Returns total bytes
/// processed (0 if nothing was ready). Draining only the focused pane would
/// stall background split panes on a full PTY buffer — the multiplexer's one
/// job is that it doesn't.
pub export fn tmux_drain(handle: ?*TmuxSession) c_long {
    const h = handle orelse return -1;
    const w = h.sess.getActiveWindow();

    var total: c_long = 0;
    var buf: [READ_CHUNK]u8 = undefined;
    for (w.panes.items) |pane| {
        const fd = pane.getFd() orelse continue;
        while (true) {
            var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
            const n = posix.poll(&fds, 0) catch break;
            if (n == 0 or (fds[0].revents & posix.POLL.IN) == 0) break;
            const r = pane.readOutput(&buf) catch break;
            if (r == 0) break;
            pane.processOutput(buf[0..r]);
            total += @intCast(r);
        }
    }
    return total;
}

/// Feed raw bytes straight into the VT emulator, bypassing the PTY. This drives
/// the emulator core directly — used for deterministic throughput benchmarking
/// and for replaying captured output. No effect if handle/data is NULL.
pub export fn tmux_feed(handle: ?*TmuxSession, data: ?[*]const u8, len: usize) void {
    const h = handle orelse return;
    const d = data orelse return;
    activePane(h).processOutput(d[0..len]);
}

/// Send input (keystrokes) to the active pane's shell. Returns bytes written or
/// -1 on error.
pub export fn tmux_send(handle: ?*TmuxSession, data: ?[*]const u8, len: usize) c_long {
    const h = handle orelse return -1;
    const d = data orelse return -1;
    const pane = activePane(h);
    pane.terminal.scrollback_offset = 0; // typing snaps the view to the live bottom
    pane.sendInput(d[0..len]) catch return -1;
    return @intCast(len);
}

/// Resize the active pane and its PTY to `rows`x`cols` (and notify the shell via
/// SIGWINCH). Returns 0 on success, -1 on error.
pub export fn tmux_resize(handle: ?*TmuxSession, rows: u16, cols: u16) c_int {
    const h = handle orelse return -1;
    const r: u16 = if (rows == 0) 1 else rows;
    const co: u16 = if (cols == 0) 1 else cols;
    h.sess.resize(.{ .x = 0, .y = 0, .width = co, .height = r }) catch return -1;
    return 0;
}

/// Whether the active pane's shell process is still alive.
pub export fn tmux_is_alive(handle: ?*TmuxSession) bool {
    const h = handle orelse return false;
    return activePane(h).isAlive();
}

// =============================================================================
// Grid access (for rendering)
// =============================================================================

/// Report the active pane's grid dimensions.
pub export fn tmux_grid_size(handle: ?*TmuxSession, out_rows: ?*u16, out_cols: ?*u16) void {
    const h = handle orelse return;
    const grid = &activePane(h).terminal.grid;
    if (out_rows) |p| p.* = grid.rows;
    if (out_cols) |p| p.* = grid.cols;
}

/// Shared cell-copy core: a terminal's visible view (scrollback-composed) into
/// a flat CCell buffer, row-major. Returns cells written.
fn readTerminalCells(term: *const terminal.Terminal, buf: [*]CCell, max_cells: usize) usize {
    // term.grid is ALWAYS the displayed grid (swap-based alt screen: alt mode
    // swaps a fresh grid in and stashes the primary in alt_grid).
    const grid = &term.grid;
    const cols: usize = grid.cols;
    const total = @as(usize, grid.rows) * cols;
    const n = @min(total, max_cells);

    // Scrolled-back view: the first `back` rows come from the scrollback ring,
    // the rest from the top of the live grid. Clamped to what history holds —
    // the ring may have evicted lines since the offset was set.
    const back: usize = if (term.modes.alt_screen) 0 else @min(term.scrollback_offset, term.scrollback.len);

    var i: usize = 0;
    while (i < n) : (i += 1) {
        // Map flat index → logical (row,col) so the ring offset is honored.
        const row = i / cols;
        const cell = if (row < back)
            term.scrollback.line(term.scrollback.len - back + row)[i % cols]
        else
            grid.getCellConst(@intCast(row - back), @intCast(i % cols)).*;
        var cc: CCell = undefined;
        cc.ch = cell.char;
        fillColor(cell.fg, &cc.fg_kind, &cc.fg_idx, &cc.fg_r, &cc.fg_g, &cc.fg_b);
        fillColor(cell.bg, &cc.bg_kind, &cc.bg_idx, &cc.bg_r, &cc.bg_g, &cc.bg_b);
        cc.attrs = @as(u8, @bitCast(cell.attrs));
        cc.width = cell.width;
        buf[i] = cc;
    }
    return n;
}

/// Copy the active pane's grid into `out` in row-major order (row*cols+col).
/// Copies at most `max_cells`; returns the number of cells written.
pub export fn tmux_read_cells(handle: ?*TmuxSession, out: ?[*]CCell, max_cells: usize) usize {
    const h = handle orelse return 0;
    const buf = out orelse return 0;
    return readTerminalCells(&activePane(h).terminal, buf, max_cells);
}

/// DEC private modes the host renderer needs, as a bitmask:
/// 1 app-cursor (DECCKM → SS3 arrows) · 2 bracketed paste · 4 alt screen ·
/// 8 mouse tracking on · 16 SGR mouse encoding · 32 focus events wanted.
pub export fn tmux_modes(handle: ?*TmuxSession) u32 {
    const h = handle orelse return 0;
    const m = &activePane(h).terminal.modes;
    var out: u32 = 0;
    if (m.app_cursor) out |= 1;
    if (m.bracketed_paste) out |= 2;
    if (m.alt_screen) out |= 4;
    if (m.mouse_tracking != .none) out |= 8;
    if (m.mouse_sgr) out |= 16;
    if (m.focus_events) out |= 32;
    return out;
}

/// DEC 2026 synchronized output: true while any pane of the active window is
/// mid-sync-block — the host should skip presenting this frame (keep the
/// previous one) and retry; the closing `?2026l` arrives in the same or next
/// drain and repaints the finished frame. Self-healing: a block left open
/// longer than 250ms (app crashed mid-repaint) stops suppressing and clears,
/// so the view can never freeze on a torn writer.
pub export fn tmux_sync_suppressed(handle: ?*TmuxSession) bool {
    const h = handle orelse return false;
    const w = h.sess.getActiveWindow();
    const now = terminal.monotonicMs();
    var suppressed = false;
    for (w.panes.items) |pane| {
        const term = &pane.terminal;
        if (!term.modes.synchronized) continue;
        if (now - term.sync_began_ms < 250) {
            suppressed = true;
        } else {
            term.modes.synchronized = false; // timed out — self-heal
        }
    }
    return suppressed;
}

/// DECSCUSR cursor style: shape 0 block / 1 underline / 2 bar, plus blink.
pub export fn tmux_cursor_style(handle: ?*TmuxSession, out_shape: ?*u8, out_blink: ?*bool) void {
    const h = handle orelse return;
    const t = &activePane(h).terminal;
    if (out_shape) |p| p.* = t.cursor_shape;
    if (out_blink) |p| p.* = t.cursor_blink;
}

/// Bell strokes since the last call (read-and-clear).
pub export fn tmux_take_bell(handle: ?*TmuxSession) u32 {
    const h = handle orelse return 0;
    const t = &activePane(h).terminal;
    const n = t.bell_pending;
    t.bell_pending = 0;
    return n;
}

/// The pending OSC 52 clipboard payload ("Pc;Pd", Pd = base64), read-and-clear.
/// Returns the copied length (0 = none pending).
pub export fn tmux_take_clipboard(handle: ?*TmuxSession, out: ?[*]u8, max: usize) usize {
    const h = handle orelse return 0;
    const buf = out orelse return 0;
    const t = &activePane(h).terminal;
    if (t.clipboard_len == 0) return 0;
    const n = @min(t.clipboard_len, max);
    @memcpy(buf[0..n], t.clipboard_pending[0..n]);
    t.clipboard_len = 0;
    return n;
}

/// The window title (OSC 0/2), UTF-8, not NUL-terminated. Returns the length.
pub export fn tmux_title(handle: ?*TmuxSession, out: ?[*]u8, max: usize) usize {
    const h = handle orelse return 0;
    const buf = out orelse return 0;
    const t = &activePane(h).terminal;
    const n = @min(t.title_len, max);
    @memcpy(buf[0..n], t.title[0..n]);
    return n;
}

/// Forward a mouse event to the app when it requested tracking. kind: 0 press,
/// 1 release, 2 drag (button held) / motion. button: 0 left, 1 middle, 2 right.
/// mods bitmask: 4 shift, 8 alt, 16 ctrl (xterm encoding). Returns 1 when the
/// event was reported (host must NOT also act on it), 0 when tracking is off /
/// below the event's level — the host handles it locally (selection etc.).
pub export fn tmux_mouse(handle: ?*TmuxSession, kind: c_int, button: c_int, row: u16, col: u16, mods: c_int) c_int {
    const h = handle orelse return 0;
    const pane = activePane(h);
    const t = &pane.terminal;
    const mode = t.modes.mouse_tracking;
    if (mode == .none) return 0;
    // Level gates: X10 = press only; normal = press/release; button adds
    // held-drag; any adds all motion.
    if (kind == 1 and mode == .x10) return 1; // consumed, nothing sent
    if (kind == 2 and (mode == .x10 or mode == .normal)) return 1;

    var cb: c_int = if (kind == 1 and !t.modes.mouse_sgr) 3 else button;
    if (kind == 2) cb += 32;
    cb += mods;
    if (t.modes.mouse_sgr) {
        var buf: [40]u8 = undefined;
        const fin: u8 = if (kind == 1) 'm' else 'M';
        const seq = std.fmt.bufPrint(&buf, "\x1b[<{d};{d};{d}{c}", .{ cb, col + 1, row + 1, fin }) catch return 1;
        pane.sendInput(seq) catch {};
    } else {
        const bx: u8 = @intCast(@min(@as(usize, col) + 33, 255));
        const by: u8 = @intCast(@min(@as(usize, row) + 33, 255));
        const cbb: u8 = @intCast(@min(@as(c_int, 32) + cb, 255));
        pane.sendInput(&[_]u8{ 0x1b, '[', 'M', cbb, bx, by }) catch {};
    }
    return 1;
}

/// Report the cursor position and visibility of the active pane.
pub export fn tmux_cursor(handle: ?*TmuxSession, out_row: ?*u16, out_col: ?*u16, out_visible: ?*bool) void {
    const h = handle orelse return;
    const term = &activePane(h).terminal;
    if (out_row) |p| p.* = term.cursor.row;
    if (out_col) |p| p.* = term.cursor.col;
    // While scrolled back the cursor's grid position points at content that
    // isn't on screen — hide it until the view snaps back to the live bottom.
    if (out_visible) |p| p.* = term.modes.cursor_visible and
        (term.modes.alt_screen or term.scrollback_offset == 0);
}

/// Route a mouse-wheel scroll of `delta` lines (positive = up / back in time,
/// negative = down) at cell (row, col).
///  - Mouse reporting on (vim, htop, tmux…): forwards wheel events to the
///    app — SGR-encoded when DEC 1006 is set, legacy X10 bytes otherwise.
///  - Alt screen without mouse reporting (less, man): sends arrow keys — the
///    xterm "alternate scroll" convention.
///  - Primary screen otherwise: moves the viewport through the scrollback
///    ring; tmux_read_cells then composes history + live grid.
/// Returns the viewport's scrollback offset after the call (0 = live bottom).
pub export fn tmux_scroll(handle: ?*TmuxSession, delta: c_int, row: u16, col: u16) c_long {
    const h = handle orelse return 0;
    if (delta == 0) return tmux_scroll_offset(handle);
    return scrollPane(activePane(h), delta, row, col);
}

/// Wheel-scroll a SPECIFIC pane (multi-pane hosts route the wheel to the pane
/// under the cursor, not the focused one). `row`/`col` are PANE-LOCAL.
pub export fn tmux_pane_scroll(handle: ?*TmuxSession, idx: usize, delta: c_int, row: u16, col: u16) c_long {
    const h = handle orelse return 0;
    const p = paneAt(h, idx) orelse return 0;
    if (delta == 0) {
        const term = &p.terminal;
        if (term.modes.alt_screen) return 0;
        return @intCast(@min(term.scrollback_offset, term.scrollback.len));
    }
    return scrollPane(p, delta, row, col);
}

fn scrollPane(pane: *session.Pane, delta: c_int, row: u16, col: u16) c_long {
    const term = &pane.terminal;
    const up = delta > 0;
    const mag: usize = @intCast(if (up) delta else -delta);

    if (term.modes.mouse_tracking != .none) {
        var i: usize = 0;
        var buf: [32]u8 = undefined;
        while (i < mag) : (i += 1) {
            if (term.modes.mouse_sgr) {
                const btn: u8 = if (up) 64 else 65;
                const seq = std.fmt.bufPrint(&buf, "\x1b[<{d};{d};{d}M", .{ btn, col + 1, row + 1 }) catch break;
                pane.sendInput(seq) catch break;
            } else {
                // Legacy X10 bytes: 32 + button, 32 + 1-based coord (clamped).
                const cb: u8 = if (up) 96 else 97;
                const cx: u8 = @intCast(@min(@as(usize, col) + 33, 255));
                const cy: u8 = @intCast(@min(@as(usize, row) + 33, 255));
                pane.sendInput(&[_]u8{ 0x1b, '[', 'M', cb, cx, cy }) catch break;
            }
        }
        return 0;
    }

    if (term.modes.alt_screen) {
        const seq: []const u8 = if (term.modes.app_cursor)
            (if (up) "\x1bOA" else "\x1bOB")
        else
            (if (up) "\x1b[A" else "\x1b[B");
        var i: usize = 0;
        while (i < mag) : (i += 1) pane.sendInput(seq) catch break;
        return 0;
    }

    const cur = @min(term.scrollback_offset, term.scrollback.len);
    term.scrollback_offset = if (up) @min(cur + mag, term.scrollback.len) else cur -| mag;
    return @intCast(term.scrollback_offset);
}

/// Current viewport scrollback offset in lines (0 = pinned to the live bottom).
pub export fn tmux_scroll_offset(handle: ?*TmuxSession) c_long {
    const h = handle orelse return 0;
    const term = &activePane(h).terminal;
    if (term.modes.alt_screen) return 0;
    return @intCast(@min(term.scrollback_offset, term.scrollback.len));
}

// =============================================================================
// Window / pane control
// =============================================================================

/// Split the active pane and spawn a shell in the new one. `horizontal` != 0
/// splits left/right, else top/bottom. Returns 0 on success, -1 on error.
pub export fn tmux_split(handle: ?*TmuxSession, horizontal: c_int) c_int {
    const h = handle orelse return -1;
    const dir: session.SplitDirection = if (horizontal != 0) .horizontal else .vertical;
    const new_pane = h.sess.getActiveWindow().split(dir, DEFAULT_SCROLLBACK) catch return -1;
    new_pane.spawn(defaultShell(), childEnviron()) catch return -1;
    return 0;
}

/// Create a new window, make it active, and spawn a shell in it. Returns 0 on
/// success, -1 on error.
pub export fn tmux_new_window(handle: ?*TmuxSession) c_int {
    const h = handle orelse return -1;
    _ = h.sess.createWindow() catch return -1;
    h.sess.nextWindow();
    activePane(h).spawn(defaultShell(), childEnviron()) catch return -1;
    return 0;
}

/// Switch the active window by index. Returns 0 on success, -1 if out of range.
pub export fn tmux_select_window(handle: ?*TmuxSession, index: u8) c_int {
    const h = handle orelse return -1;
    return if (h.sess.selectWindow(index)) 0 else -1;
}

/// Number of windows in the session (0 if handle is NULL).
pub export fn tmux_window_count(handle: ?*TmuxSession) u8 {
    const h = handle orelse return 0;
    return @intCast(h.sess.windows.items.len);
}

/// Cycle focus to the next pane in the active window. Returns 0, or -1 if NULL.
pub export fn tmux_focus_next_pane(handle: ?*TmuxSession) c_int {
    const h = handle orelse return -1;
    h.sess.getActiveWindow().focusNext();
    return 0;
}

// =============================================================================
// Pane-aware surface — lets a host view COMPOSE all panes of the active window
// (splits) instead of rendering only the focused pane. Pane indices are
// positions in the active window's pane list at call time; re-enumerate after
// split/close.
// =============================================================================

fn paneAt(h: *TmuxSession, idx: usize) ?*session.Pane {
    const w = h.sess.getActiveWindow();
    if (idx >= w.panes.items.len) return null;
    return w.panes.items[idx];
}

/// The active window's full extent (the rect panes tile), in cells.
pub export fn tmux_window_size(handle: ?*TmuxSession, out_rows: ?*u16, out_cols: ?*u16) void {
    const h = handle orelse return;
    if (out_rows) |p| p.* = h.sess.rect.height;
    if (out_cols) |p| p.* = h.sess.rect.width;
}

/// Number of panes in the active window (0 if handle is NULL).
pub export fn tmux_pane_count(handle: ?*TmuxSession) usize {
    const h = handle orelse return 0;
    return h.sess.getActiveWindow().panes.items.len;
}

/// Pane `idx`'s rect within the window (cells). Returns 0, -1 if out of range.
pub export fn tmux_pane_rect(handle: ?*TmuxSession, idx: usize, out_x: ?*u16, out_y: ?*u16, out_w: ?*u16, out_h: ?*u16) c_int {
    const h = handle orelse return -1;
    const p = paneAt(h, idx) orelse return -1;
    if (out_x) |o| o.* = p.rect.x;
    if (out_y) |o| o.* = p.rect.y;
    if (out_w) |o| o.* = p.rect.width;
    if (out_h) |o| o.* = p.rect.height;
    return 0;
}

/// Whether pane `idx` is the focused pane of the active window.
pub export fn tmux_pane_is_active(handle: ?*TmuxSession, idx: usize) bool {
    const h = handle orelse return false;
    return idx < h.sess.getActiveWindow().panes.items.len and
        idx == h.sess.getActiveWindow().active_pane_idx;
}

/// Focus pane `idx` of the active window. Returns 0, -1 if out of range.
pub export fn tmux_focus_pane(handle: ?*TmuxSession, idx: usize) c_int {
    const h = handle orelse return -1;
    const w = h.sess.getActiveWindow();
    if (idx >= w.panes.items.len) return -1;
    w.panes.items[w.active_pane_idx].active = false;
    w.active_pane_idx = idx;
    w.panes.items[idx].active = true;
    return 0;
}

/// Pane `idx`'s PTY master fd (-1 if none) — one readability source per pane.
pub export fn tmux_pane_pty_fd(handle: ?*TmuxSession, idx: usize) c_int {
    const h = handle orelse return -1;
    const p = paneAt(h, idx) orelse return -1;
    const fd = p.getFd() orelse return -1;
    return @intCast(fd);
}

/// Pane `idx`'s cursor in PANE-LOCAL cells (host adds the pane rect offset).
pub export fn tmux_pane_cursor(handle: ?*TmuxSession, idx: usize, out_row: ?*u16, out_col: ?*u16, out_visible: ?*bool) void {
    const h = handle orelse return;
    const p = paneAt(h, idx) orelse return;
    const term = &p.terminal;
    if (out_row) |o| o.* = term.cursor.row;
    if (out_col) |o| o.* = term.cursor.col;
    if (out_visible) |o| o.* = term.modes.cursor_visible and
        (term.modes.alt_screen or term.scrollback_offset == 0);
}

/// Copy pane `idx`'s visible grid (scrollback-composed) into `out`, row-major
/// at the PANE's width. Returns cells written (0 on bad idx/NULL).
pub export fn tmux_pane_read_cells(handle: ?*TmuxSession, idx: usize, out: ?[*]CCell, max_cells: usize) usize {
    const h = handle orelse return 0;
    const buf = out orelse return 0;
    const p = paneAt(h, idx) orelse return 0;
    return readTerminalCells(&p.terminal, buf, max_cells);
}

/// Close pane `idx`: kills its shell and re-tiles the survivors. Refused (-1)
/// for the last pane of the window — destroy the session instead.
pub export fn tmux_close_pane(handle: ?*TmuxSession, idx: usize) c_int {
    const h = handle orelse return -1;
    const w = h.sess.getActiveWindow();
    const p = paneAt(h, idx) orelse return -1;
    if (w.panes.items.len <= 1) return -1;
    _ = w.removePaneReflow(p.id);
    return 0;
}

/// Move the border between pane `idx` and its right (dx) / bottom (dy)
/// neighbor by that many cells (positive grows pane `idx`). The neighbor must
/// span the same cross-axis extent (clean tiling). Returns 0 when anything
/// moved, -1 otherwise. Deltas clamp so both panes keep >= 2 cells.
pub export fn tmux_resize_split(handle: ?*TmuxSession, idx: usize, dx: c_int, dy: c_int) c_int {
    const h = handle orelse return -1;
    const w = h.sess.getActiveWindow();
    const p = paneAt(h, idx) orelse return -1;
    var changed = false;

    if (dx != 0) {
        for (w.panes.items) |q| {
            if (q == p) continue;
            if (q.rect.y == p.rect.y and q.rect.height == p.rect.height and
                q.rect.x == p.rect.x + p.rect.width + 1)
            {
                const pw: i32 = p.rect.width;
                const qw: i32 = q.rect.width;
                var d: i32 = dx;
                if (pw + d < 2) d = 2 - pw;
                if (qw - d < 2) d = qw - 2;
                if (d != 0) {
                    p.resize(.{ .x = p.rect.x, .y = p.rect.y, .width = @intCast(pw + d), .height = p.rect.height }) catch {};
                    q.resize(.{ .x = @intCast(@as(i32, q.rect.x) + d), .y = q.rect.y, .width = @intCast(qw - d), .height = q.rect.height }) catch {};
                    changed = true;
                }
                break;
            }
        }
    }
    if (dy != 0) {
        for (w.panes.items) |q| {
            if (q == p) continue;
            if (q.rect.x == p.rect.x and q.rect.width == p.rect.width and
                q.rect.y == p.rect.y + p.rect.height + 1)
            {
                const ph: i32 = p.rect.height;
                const qh: i32 = q.rect.height;
                var d: i32 = dy;
                if (ph + d < 2) d = 2 - ph;
                if (qh - d < 2) d = qh - 2;
                if (d != 0) {
                    p.resize(.{ .x = p.rect.x, .y = p.rect.y, .width = p.rect.width, .height = @intCast(ph + d) }) catch {};
                    q.resize(.{ .x = q.rect.x, .y = @intCast(@as(i32, q.rect.y) + d), .width = q.rect.width, .height = @intCast(qh - d) }) catch {};
                    changed = true;
                }
                break;
            }
        }
    }
    return if (changed) 0 else -1;
}

// =============================================================================
// Theme — the shared color scheme. Consumers (CosmicDuck's Metal view, a future
// standalone GUI) read the file themselves and push the bytes via
// tmux_set_theme_text, then read back the resolved palette via tmux_get_theme.
// Parsing lives once in Zig (config.Theme.parse); this just exposes it over C.
// =============================================================================

/// One RGB color in the C ABI.
pub const CRgb = extern struct { r: u8, g: u8, b: u8 };

/// The resolved theme, flat for the C/Swift side.
pub const CTheme = extern struct {
    palette: [16]CRgb, // ANSI 0-15
    bg: CRgb,
    fg: CRgb,
    cursor: CRgb,
    cursor_text: CRgb,
    selection_bg: CRgb,
    selection_fg: CRgb,
    url: CRgb,
    bold_is_bright: u8,
    cursor_style: u8, // 0 block, 1 bar, 2 underline
};

fn toCRgb(c: config.Color) CRgb {
    return .{ .r = c.r, .g = c.g, .b = c.b };
}

/// Parse theme config text (the `key = value` format) and make it the active theme.
pub export fn tmux_set_theme_text(text: ?[*]const u8, len: usize) void {
    const t = text orelse return;
    config.active_theme = config.Theme.parse(t[0..len]);
}

/// Reset to the built-in default theme.
pub export fn tmux_reset_theme() void {
    config.active_theme = .{};
}

/// Copy the active theme (resolved ANSI-16 palette + named colors) into `out`.
pub export fn tmux_get_theme(out: ?*CTheme) void {
    const o = out orelse return;
    const th = &config.active_theme;
    var i: usize = 0;
    while (i < 16) : (i += 1) o.palette[i] = toCRgb(th.palette[i]);
    o.bg = toCRgb(th.bg);
    o.fg = toCRgb(th.fg);
    o.cursor = toCRgb(th.cursor);
    o.cursor_text = toCRgb(th.cursor_text);
    o.selection_bg = toCRgb(th.selection_bg);
    o.selection_fg = toCRgb(th.selection_fg);
    o.url = toCRgb(th.url);
    o.bold_is_bright = @intFromBool(th.bold_is_bright);
    o.cursor_style = @intFromEnum(th.cursor_style);
}

// =============================================================================
// URL detection — scan the active pane's visible grid for links. The renderer
// paints each range in theme.url + underline and reads the URL text for opening
// straight from its own cell buffer. A range is {start_row, start_col,
// end_row, end_col-exclusive} — multi-row when the URL soft-wrapped.
// =============================================================================

pub const CUrlRange = url.UrlRange; // extern struct {start_row, start_col, end_row, end_col: u16}

pub export fn tmux_find_urls(handle: ?*TmuxSession, out: ?[*]CUrlRange, max: usize) usize {
    const h = handle orelse return 0;
    const buf = out orelse return 0;
    const grid = &activePane(h).terminal.grid;
    return url.findUrls(grid, buf[0..max]);
}

// =============================================================================
// Paste — bracketed-paste-aware. If the app enabled DEC mode 2004, wrap the data
// in ESC[200~ … ESC[201~ so multi-line pastes don't trigger auto-indent / run
// line-by-line. The write loop (pty.write) handles arbitrarily large pastes.
// =============================================================================

/// True if the active pane's app turned on bracketed paste (DEC 2004).
pub export fn tmux_bracketed_paste(handle: ?*TmuxSession) bool {
    const h = handle orelse return false;
    return activePane(h).terminal.modes.bracketed_paste;
}

/// Paste `data` into the active pane, bracketing it when DEC 2004 is on.
pub export fn tmux_paste(handle: ?*TmuxSession, data: ?[*]const u8, len: usize) c_long {
    const h = handle orelse return -1;
    const d = data orelse return -1;
    const pane = activePane(h);
    pane.terminal.scrollback_offset = 0; // pasting snaps the view to the live bottom
    if (pane.terminal.modes.bracketed_paste) {
        pane.sendInput("\x1b[200~") catch return -1;
        pane.sendInput(d[0..len]) catch return -1;
        pane.sendInput("\x1b[201~") catch return -1;
    } else {
        pane.sendInput(d[0..len]) catch return -1;
    }
    return @intCast(len);
}

// =============================================================================
// Inline graphics (Kitty protocol, Phase 1) — additive ABI. A consumer that
// ignores these calls renders exactly as before.
//
// The emulator is a byte-pipe + geometry tracker: it hands over the ORIGINAL
// transmitted bytes + a format tag; the host decodes (CGImageSource on Apple).
// Placements are line-anchored, so scroll is O(1); the ABI reports each
// placement's CLIPPED on-screen cell rect plus the source pixel crop to sample.
// =============================================================================

/// A visible placement: the clipped on-screen cell rect + the source pixel crop
/// the host should sample from the image texture. Additive extern struct.
pub const CPlacement = extern struct {
    image_id: u32,
    cell_x: u16, // grid-local cell column of the rect's top-left
    cell_y: u16, // grid-local cell row
    cell_w: u16, // width in cells (clipped to the viewport)
    cell_h: u16, // height in cells (clipped)
    src_x: u32, // source crop in image-pixel space
    src_y: u32,
    src_w: u32,
    src_h: u32,
    z: i32, // z-order relative to text (z<0 below glyphs, z>=0 above)
};

/// Image metadata returned alongside the bytes. `format`: 0 RGBA, 1 RGB, 2 PNG,
/// 3 iterm-blob. For RGB/RGBA `width`/`height` are the pixel dimensions; for PNG
/// they are the transmitted hint (the host decodes for the true size).
pub const CImageInfo = extern struct {
    width: u32,
    height: u32,
    format: u8,
};

/// The idx-th VISIBLE placement in the active pane, or null if idx is past the
/// visible count. Iterates placements in insertion order, skipping off-screen
/// ones, so `_at` matches `_count`.
fn nthVisiblePlacement(term: *const terminal.Terminal, idx: usize, out: *CPlacement) bool {
    const rows = term.grid.rows;
    const cols = term.grid.cols;
    const top_abs = term.graphicsViewportTopAbs();
    var seen: usize = 0;
    for (term.graphics.placements.items) |p| {
        const img = term.graphics.findImage(p.image_id) orelse continue;
        const vr = gfx.clip(p, img, top_abs, rows, cols) orelse continue;
        if (seen == idx) {
            out.* = .{
                .image_id = p.image_id,
                .cell_x = vr.cell_x,
                .cell_y = vr.cell_y,
                .cell_w = vr.cell_w,
                .cell_h = vr.cell_h,
                .src_x = vr.src_x,
                .src_y = vr.src_y,
                .src_w = vr.src_w,
                .src_h = vr.src_h,
                .z = p.z,
            };
            return true;
        }
        seen += 1;
    }
    return false;
}

/// Number of image placements currently VISIBLE in the active pane.
pub export fn tmux_placement_count(handle: ?*TmuxSession) usize {
    const h = handle orelse return 0;
    const term = &activePane(h).terminal;
    const rows = term.grid.rows;
    const cols = term.grid.cols;
    const top_abs = term.graphicsViewportTopAbs();
    var n: usize = 0;
    for (term.graphics.placements.items) |p| {
        const img = term.graphics.findImage(p.image_id) orelse continue;
        if (gfx.clip(p, img, top_abs, rows, cols) != null) n += 1;
    }
    return n;
}

/// Fill `out` with the geometry of the idx-th visible placement. Returns 0 on
/// success, -1 if idx is out of range or on NULL.
pub export fn tmux_placement_at(handle: ?*TmuxSession, idx: usize, out: ?*CPlacement) c_int {
    const h = handle orelse return -1;
    const o = out orelse return -1;
    const term = &activePane(h).terminal;
    return if (nthVisiblePlacement(term, idx, o)) 0 else -1;
}

/// Copy image `image_id`'s stored bytes into `out` (at most `max`) and fill
/// `info`. Returns the FULL byte length (which may exceed `max`), or 0 if no
/// such image. Call with out=NULL to query the length + info, then allocate.
pub export fn tmux_image_data(handle: ?*TmuxSession, image_id: u32, out: ?[*]u8, max: usize, info: ?*CImageInfo) usize {
    const h = handle orelse return 0;
    const term = &activePane(h).terminal;
    const img = term.graphics.findImage(image_id) orelse return 0;
    if (info) |p| p.* = .{ .width = img.width, .height = img.height, .format = @intFromEnum(img.format) };
    if (out) |buf| {
        const n = @min(img.bytes.len, max);
        @memcpy(buf[0..n], img.bytes[0..n]);
    }
    return img.bytes.len;
}

/// Monotonic graphics generation for the active pane. Bumps whenever
/// placements/images change (transmit, place, delete, eviction, alt-swap), so
/// the host only re-reads/re-uploads when something actually moved.
pub export fn tmux_graphics_generation(handle: ?*TmuxSession) u64 {
    const h = handle orelse return 0;
    return activePane(h).terminal.graphics_gen;
}

/// Image ids freed since the last call (a=d, eviction, overwrite, alt-exit),
/// read-and-clear — the host releases the matching MTLTextures. Writes up to
/// `max` ids into `out_ids` (may be NULL to just drain/count) and returns the
/// number freed.
pub export fn tmux_take_freed_images(handle: ?*TmuxSession, out_ids: ?[*]u32, max: usize) usize {
    const h = handle orelse return 0;
    const term = &activePane(h).terminal;
    const items = term.graphics_freed.items;
    const n = items.len;
    if (out_ids) |buf| {
        const m = @min(n, max);
        var i: usize = 0;
        while (i < m) : (i += 1) buf[i] = items[i];
    }
    term.graphics_freed.clearRetainingCapacity();
    return n;
}

// =============================================================================
// Tests
// =============================================================================

test "feed maps bytes into the grid" {
    const rect = session.Rect{ .x = 0, .y = 0, .width = 20, .height = 5 };
    const sess = try session.Session.init(std.testing.allocator, "t", rect, 100);
    defer sess.deinit();

    const pane = sess.getActiveWindow().getActivePane();
    pane.processOutput("Hi");

    const grid = &pane.terminal.grid;
    try std.testing.expectEqual(@as(u21, 'H'), grid.getCellConst(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'i'), grid.getCellConst(0, 1).char);
}

test "CCell layout is stable for the C header" {
    // The Swift/C side hard-codes this layout; lock it down.
    try std.testing.expectEqual(@as(usize, 4), @alignOf(CCell));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(CCell));
}

test "graphics ABI struct layouts are stable for the C header" {
    // tmux_placement: u32 + 4×u16 + 4×u32 + i32 = 32 bytes, align 4.
    try std.testing.expectEqual(@as(usize, 4), @alignOf(CPlacement));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(CPlacement));
    // tmux_image_info: u32 + u32 + u8 → 12 bytes (align 4), matches C padding.
    try std.testing.expectEqual(@as(usize, 4), @alignOf(CImageInfo));
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(CImageInfo));
}

test "pane-aware surface: split, rects tile with a border gap, focus, close" {
    var id: u64 = 0;
    // /bin/cat as the "shell": no rc files, no prompt noise, sits on the pty.
    const h = tmux_create(24, 80, "/bin/cat", &id) orelse return error.CreateFailed;
    defer tmux_destroy(h);

    try std.testing.expectEqual(@as(usize, 1), tmux_pane_count(h));
    var rows: u16 = 0;
    var cols: u16 = 0;
    tmux_window_size(h, &rows, &cols);
    try std.testing.expectEqual(@as(u16, 24), rows);
    try std.testing.expectEqual(@as(u16, 80), cols);

    try std.testing.expectEqual(@as(c_int, 0), tmux_split(h, 1));
    try std.testing.expectEqual(@as(usize, 2), tmux_pane_count(h));

    var ax: u16 = 0;
    var aw: u16 = 0;
    var bx: u16 = 0;
    var bw: u16 = 0;
    try std.testing.expectEqual(@as(c_int, 0), tmux_pane_rect(h, 0, &ax, null, &aw, null));
    try std.testing.expectEqual(@as(c_int, 0), tmux_pane_rect(h, 1, &bx, null, &bw, null));
    try std.testing.expectEqual(@as(u16, 0), ax);
    try std.testing.expectEqual(ax + aw + 1, bx); // 1-cell border gap between panes
    try std.testing.expectEqual(@as(u16, 80), bx + bw);

    try std.testing.expectEqual(@as(c_int, 0), tmux_focus_pane(h, 1));
    try std.testing.expect(tmux_pane_is_active(h, 1));
    try std.testing.expect(!tmux_pane_is_active(h, 0));
    try std.testing.expect(tmux_pane_pty_fd(h, 1) >= 0);

    try std.testing.expectEqual(@as(c_int, 0), tmux_close_pane(h, 1));
    try std.testing.expectEqual(@as(usize, 1), tmux_pane_count(h));
    try std.testing.expectEqual(@as(c_int, -1), tmux_close_pane(h, 0)); // last pane refused
}

test "version string is well formed" {
    const v = std.mem.sliceTo(tmux_version(), 0);
    try std.testing.expect(v.len >= 5);
}

test "theme C-ABI roundtrip + layout" {
    const txt = "preset = matrix\nbackground = #010203\n";
    tmux_set_theme_text(txt.ptr, txt.len);
    var ct: CTheme = undefined;
    tmux_get_theme(&ct);
    try std.testing.expectEqual(@as(u8, 0x01), ct.bg.r); // override applied
    try std.testing.expectEqual(@as(u8, 0x00), ct.fg.r); // matrix green
    try std.testing.expectEqual(@as(u8, 0xFF), ct.fg.g);
    try std.testing.expectEqual(@as(u8, 1), ct.bold_is_bright);
    tmux_reset_theme();
    tmux_get_theme(&ct);
    try std.testing.expectEqual(@as(u8, 0xD9), ct.fg.r); // default fg restored
    // CRgb is tightly packed so [16]CRgb maps cleanly to the Swift side
    try std.testing.expectEqual(@as(usize, 3), @sizeOf(CRgb));
}
