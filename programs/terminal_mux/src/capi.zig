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
    pane.spawn(shell_path, std.c.environ) catch {
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

/// Drain all currently-available PTY output (non-blocking), feeding the VT
/// emulator. Returns total bytes processed (0 if nothing was ready).
pub export fn tmux_drain(handle: ?*TmuxSession) c_long {
    const h = handle orelse return -1;
    const pane = activePane(h);
    const fd = pane.getFd() orelse return -1;

    var total: c_long = 0;
    var buf: [READ_CHUNK]u8 = undefined;
    while (true) {
        var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
        const n = posix.poll(&fds, 0) catch break;
        if (n == 0 or (fds[0].revents & posix.POLL.IN) == 0) break;
        const r = pane.readOutput(&buf) catch break;
        if (r == 0) break;
        pane.processOutput(buf[0..r]);
        total += @intCast(r);
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
    activePane(h).sendInput(d[0..len]) catch return -1;
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

/// Copy the active pane's grid into `out` in row-major order (row*cols+col).
/// Copies at most `max_cells`; returns the number of cells written.
pub export fn tmux_read_cells(handle: ?*TmuxSession, out: ?[*]CCell, max_cells: usize) usize {
    const h = handle orelse return 0;
    const buf = out orelse return 0;
    const grid = &activePane(h).terminal.grid;
    const cols: usize = grid.cols;
    const total = @as(usize, grid.rows) * cols;
    const n = @min(total, max_cells);

    var i: usize = 0;
    while (i < n) : (i += 1) {
        // Map flat index → logical (row,col) so the ring offset is honored.
        const cell = grid.getCellConst(@intCast(i / cols), @intCast(i % cols)).*;
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

/// Report the cursor position and visibility of the active pane.
pub export fn tmux_cursor(handle: ?*TmuxSession, out_row: ?*u16, out_col: ?*u16, out_visible: ?*bool) void {
    const h = handle orelse return;
    const term = &activePane(h).terminal;
    if (out_row) |p| p.* = term.cursor.row;
    if (out_col) |p| p.* = term.cursor.col;
    if (out_visible) |p| p.* = term.modes.cursor_visible;
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
    new_pane.spawn(defaultShell(), std.c.environ) catch return -1;
    return 0;
}

/// Create a new window, make it active, and spawn a shell in it. Returns 0 on
/// success, -1 on error.
pub export fn tmux_new_window(handle: ?*TmuxSession) c_int {
    const h = handle orelse return -1;
    _ = h.sess.createWindow() catch return -1;
    h.sess.nextWindow();
    activePane(h).spawn(defaultShell(), std.c.environ) catch return -1;
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

test "version string is well formed" {
    const v = std.mem.sliceTo(tmux_version(), 0);
    try std.testing.expect(v.len >= 5);
}
