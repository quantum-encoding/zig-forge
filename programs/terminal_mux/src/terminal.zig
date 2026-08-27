//! Terminal Emulator
//!
//! Virtual terminal implementation supporting VT100/ANSI escape sequences.
//! Each pane contains one of these to track terminal state.

const std = @import("std");
const config = @import("config.zig");
const Color = config.Color;
const gfx = @import("graphics.zig");

/// Cell attributes (packed for memory efficiency)
pub const CellAttrs = packed struct {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    blink: bool = false,
    inverse: bool = false,
    invisible: bool = false,
    strikethrough: bool = false,

    pub const default: CellAttrs = .{};

    pub fn eql(self: CellAttrs, other: CellAttrs) bool {
        return @as(u8, @bitCast(self)) == @as(u8, @bitCast(other));
    }
};

/// Terminal cell
pub const Cell = struct {
    /// Unicode codepoint (21 bits, max 0x10FFFF)
    char: u21 = ' ',

    /// Foreground color (indexed or RGB)
    fg: CellColor = .{ .default = {} },

    /// Background color (indexed or RGB)
    bg: CellColor = .{ .default = {} },

    /// Text attributes
    attrs: CellAttrs = .{},

    /// Width (1 or 2 for wide characters)
    width: u2 = 1,

    pub const default: Cell = .{};

    pub fn eql(self: *const Cell, other: *const Cell) bool {
        return self.char == other.char and
            self.fg.eql(other.fg) and
            self.bg.eql(other.bg) and
            self.attrs.eql(other.attrs) and
            self.width == other.width;
    }
};

/// Cell color (can be default, indexed 256, or RGB)
pub const CellColor = union(enum) {
    default: void,
    indexed: u8,
    rgb: Color,

    pub fn eql(self: CellColor, other: CellColor) bool {
        return switch (self) {
            .default => other == .default,
            .indexed => |i| switch (other) {
                .indexed => |j| i == j,
                else => false,
            },
            .rgb => |c| switch (other) {
                .rgb => |d| c.r == d.r and c.g == d.g and c.b == d.b,
                else => false,
            },
        };
    }

    pub fn toColor(self: CellColor, default_color: Color) Color {
        return switch (self) {
            .default => default_color,
            .indexed => |i| Color.from256(i),
            .rgb => |c| c,
        };
    }
};

/// Cursor state
pub const Cursor = struct {
    row: u16 = 0,
    col: u16 = 0,
    visible: bool = true,
    style: Style = .block,

    pub const Style = enum {
        block,
        underline,
        bar,
    };
};

/// Reply-queue capacity. A CPR is ~10 bytes and a DA ~9, so 64 holds a burst
/// of several queries between host drains without ever reallocating.
pub const RESP_CAPACITY = 64;

/// Saved cursor state (for ESC 7 / ESC 8)
pub const SavedCursor = struct {
    row: u16,
    col: u16,
    attrs: CellAttrs,
    fg: CellColor,
    bg: CellColor,
    origin_mode: bool,
    autowrap: bool,
    /// DECSC saves the deferred-wrap state too (xterm: DECRC restores it).
    pending_wrap: bool = false,
};

/// Scroll region
pub const ScrollRegion = struct {
    top: u16,
    bottom: u16,
};

/// Monotonic milliseconds (std.time.milliTimestamp is gone in Zig 0.16; this
/// matches the clock_gettime pattern used across the repo). Monotonic on
/// purpose: the 2026 sync timeout must not jump with wall-clock changes.
pub fn monotonicMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @intCast(@as(i128, ts.sec) * 1000 + @divTrunc(ts.nsec, 1_000_000));
}

/// Terminal modes
pub const Modes = struct {
    /// Application cursor keys (DECCKM)
    app_cursor: bool = false,
    /// Application keypad (DECKPAM/DECKPNM)
    app_keypad: bool = false,
    /// Origin mode (DECOM)
    origin: bool = false,
    /// Auto wrap mode (DECAWM)
    autowrap: bool = true,
    /// Cursor visible (DECTCEM)
    cursor_visible: bool = true,
    /// Alternate screen buffer
    alt_screen: bool = false,
    /// Bracketed paste mode
    bracketed_paste: bool = false,
    /// Mouse tracking modes
    mouse_tracking: MouseMode = .none,
    /// SGR extended mouse encoding (DEC 1006) — how wheel/button events are
    /// serialized when mouse_tracking is on.
    mouse_sgr: bool = false,
    /// Focus events
    focus_events: bool = false,
    /// Synchronized output (DEC 2026): the app is mid-repaint and the host
    /// must not present the grid until the closing `?2026l` (or a timeout —
    /// see tmux_sync_suppressed). Claude Code wraps EVERY frame in a 2026
    /// pair; painting between them shows half-erased rows and duplicated
    /// composer blocks (goal 556D61CB defects #4/#5).
    synchronized: bool = false,

    pub const MouseMode = enum {
        none,
        x10, // Button press only
        normal, // Button press and release
        button, // Button events + motion while pressed
        any, // All motion events
    };
};

/// Character set designations
pub const CharsetSlot = enum(u2) {
    g0 = 0,
    g1 = 1,
    g2 = 2,
    g3 = 3,
};

pub const Charset = enum {
    ascii,
    dec_special, // DEC Special Graphics (line drawing)
    uk,
};

/// Ring buffer for scrollback
pub fn RingBuffer(comptime T: type) type {
    return struct {
        items: []T,
        head: usize,
        len: usize,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            return Self{
                .items = try allocator.alloc(T, capacity),
                .head = 0,
                .len = 0,
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.items);
        }

        pub fn push(self: *Self, item: T) void {
            const idx = (self.head + self.len) % self.items.len;
            self.items[idx] = item;
            if (self.len < self.items.len) {
                self.len += 1;
            } else {
                self.head = (self.head + 1) % self.items.len;
            }
        }

        pub fn get(self: *const Self, index: usize) ?*const T {
            if (index >= self.len) return null;
            const actual_idx = (self.head + index) % self.items.len;
            return &self.items[actual_idx];
        }

        pub fn clear(self: *Self) void {
            self.head = 0;
            self.len = 0;
        }
    };
}

/// Terminal grid.
///
/// Rows are stored in a circular buffer: logical row `r` lives at physical row
/// `(row_offset + r) mod rows`. Full-screen scrolling is then an O(1) offset
/// bump (rotate) instead of an O(rows*cols) memcpy. `cells` is still a single
/// flat allocation of `rows*cols`; each *physical* row is contiguous, so writes
/// within one logical row remain a contiguous span (the SIMD bulk path relies
/// on this).
pub const Grid = struct {
    allocator: std.mem.Allocator,
    cells: []Cell,
    /// Per-*physical*-row soft-wrap flag: `wrapped[physRow(r)]` is true when
    /// logical row `r` was continued onto row r+1 by DECAWM autowrap (a printable
    /// overflowed the last column), i.e. there was NO explicit CR/LF between them.
    /// Indexed by physRow (mirrors `cells`) so it rides the ring rotation on
    /// scroll exactly like the cells do. INTERNAL only — never exported over the
    /// C ABI (tmux_cell stays 16 bytes; this is Grid-level metadata, not per-cell).
    /// Renderers/URL detection use it to distinguish a real soft-wrap from a
    /// hard-terminated line that merely happens to fill the full width.
    wrapped: []bool,
    rows: u16,
    cols: u16,
    /// Physical index of logical row 0. Advanced on scroll; never memcpy.
    row_offset: usize = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, rows: u16, cols: u16) !Self {
        const size = @as(usize, rows) * @as(usize, cols);
        const cells = try allocator.alloc(Cell, size);
        errdefer allocator.free(cells);
        @memset(cells, Cell.default);

        const wrapped = try allocator.alloc(bool, rows);
        @memset(wrapped, false);

        return Self{
            .allocator = allocator,
            .cells = cells,
            .wrapped = wrapped,
            .rows = rows,
            .cols = cols,
            .row_offset = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.cells);
        self.allocator.free(self.wrapped);
    }

    /// Whether logical row `row` was soft-wrapped (autowrap continuation follows).
    pub inline fn isRowWrapped(self: *const Self, row: u16) bool {
        if (row >= self.rows) return false;
        return self.wrapped[self.physRow(row)];
    }

    /// Record (or clear) the soft-wrap flag for logical row `row`.
    pub inline fn setRowWrapped(self: *Self, row: u16, value: bool) void {
        if (row >= self.rows) return;
        self.wrapped[self.physRow(row)] = value;
    }

    /// Map a logical row to its physical row. Single conditional subtract (both
    /// operands are < rows), so no division in the hot path.
    pub inline fn physRow(self: *const Self, row: u16) usize {
        var p = self.row_offset + @as(usize, row);
        if (p >= self.rows) p -= self.rows;
        return p;
    }

    /// Contiguous slice of one logical row (length == cols).
    pub inline fn rowSlice(self: *Self, row: u16) []Cell {
        const start = self.physRow(row) * @as(usize, self.cols);
        return self.cells[start .. start + self.cols];
    }

    pub fn getCell(self: *Self, row: u16, col: u16) *Cell {
        const idx = self.physRow(row) * @as(usize, self.cols) + @as(usize, col);
        return &self.cells[idx];
    }

    pub fn getCellConst(self: *const Self, row: u16, col: u16) *const Cell {
        const idx = self.physRow(row) * @as(usize, self.cols) + @as(usize, col);
        return &self.cells[idx];
    }

    pub fn clearRegion(self: *Self, top: u16, left: u16, bottom: u16, right: u16, template: Cell) void {
        var r = top;
        while (r <= bottom and r < self.rows) : (r += 1) {
            var c = left;
            while (c <= right and c < self.cols) : (c += 1) {
                self.getCell(r, c).* = template;
            }
            // Clearing through the last column removes whatever filled it, so any
            // recorded soft-wrap for this row no longer holds — drop it.
            if (right >= self.cols - 1) self.setRowWrapped(r, false);
        }
    }

    pub fn scrollUp(self: *Self, top: u16, bottom: u16, count: u16, template: Cell) void {
        if (count == 0 or top >= bottom) return;
        const region = bottom - top + 1;
        const n = @min(count, region);

        // Full-screen scroll: O(1) ring rotation. Logical row 0 advances; the
        // rows that scrolled off the top become the (now-cleared) bottom rows.
        if (top == 0 and bottom == self.rows - 1) {
            self.row_offset += n;
            while (self.row_offset >= self.rows) self.row_offset -= self.rows;
            self.clearRegion(self.rows - n, 0, self.rows - 1, self.cols - 1, template);
            return;
        }

        // Sub-region scroll: shift logical rows up via contiguous per-row copies
        // (rowSlice maps through the ring, so this stays correct).
        const lines_to_move = region - n;
        if (lines_to_move > 0) {
            var dst_row = top;
            var src_row = top + n;
            while (src_row <= bottom) : ({
                dst_row += 1;
                src_row += 1;
            }) {
                @memcpy(self.rowSlice(dst_row), self.rowSlice(src_row));
                self.setRowWrapped(dst_row, self.isRowWrapped(src_row));
            }
        }
        const clear_start = if (lines_to_move > 0) bottom - n + 1 else top;
        self.clearRegion(clear_start, 0, bottom, self.cols - 1, template);
    }

    pub fn scrollDown(self: *Self, top: u16, bottom: u16, count: u16, template: Cell) void {
        if (count == 0 or top >= bottom) return;
        const region = bottom - top + 1;
        const n = @min(count, region);

        // Full-screen scroll: rotate the ring backwards; the top rows become the
        // (now-cleared) new content.
        if (top == 0 and bottom == self.rows - 1) {
            self.row_offset += self.rows - (@as(usize, n) % self.rows);
            while (self.row_offset >= self.rows) self.row_offset -= self.rows;
            self.clearRegion(0, 0, n - 1, self.cols - 1, template);
            return;
        }

        const lines_to_move = region - n;
        if (lines_to_move > 0) {
            var dst_row = bottom;
            var src_row = bottom - n;
            while (true) {
                @memcpy(self.rowSlice(dst_row), self.rowSlice(src_row));
                self.setRowWrapped(dst_row, self.isRowWrapped(src_row));
                if (src_row == top) break;
                dst_row -= 1;
                src_row -= 1;
            }
        }
        const clear_end = if (lines_to_move > 0) top + n - 1 else bottom;
        self.clearRegion(top, 0, clear_end, self.cols - 1, template);
    }

    pub fn resize(self: *Self, new_rows: u16, new_cols: u16) !void {
        const new_size = @as(usize, new_rows) * @as(usize, new_cols);
        const new_cells = try self.allocator.alloc(Cell, new_size);
        errdefer self.allocator.free(new_cells);
        @memset(new_cells, Cell.default);

        // Copy existing content in LOGICAL order, normalizing the ring back to
        // offset 0 (the new buffer is laid out logically).
        const copy_rows = @min(self.rows, new_rows);
        const copy_cols = @min(self.cols, new_cols);

        var r: u16 = 0;
        while (r < copy_rows) : (r += 1) {
            const old_start = self.physRow(r) * @as(usize, self.cols);
            const new_start = @as(usize, r) * @as(usize, new_cols);
            @memcpy(
                new_cells[new_start .. new_start + copy_cols],
                self.cells[old_start .. old_start + copy_cols],
            );
        }

        // Soft-wrap flags don't survive a width change (reflow is out of scope);
        // start fresh, all rows unwrapped.
        const new_wrapped = try self.allocator.alloc(bool, new_rows);
        @memset(new_wrapped, false);

        self.allocator.free(self.cells);
        self.allocator.free(self.wrapped);
        self.cells = new_cells;
        self.wrapped = new_wrapped;
        self.rows = new_rows;
        self.cols = new_cols;
        self.row_offset = 0;
    }
};

/// Scrollback history, stored as a single preallocated flat ring of rows
/// (`capacity_lines * cols` cells). `push` copies a scrolled-off row into the
/// next slot with no heap allocation — so the PTY-ingest hot path never calls
/// the allocator. The buffer is sized once at init / resize.
pub const Scrollback = struct {
    allocator: std.mem.Allocator,
    cells: []Cell,
    cols: u16,
    capacity_lines: usize,
    head: usize, // index of the oldest retained line
    len: usize, // number of retained lines

    pub fn init(allocator: std.mem.Allocator, capacity_lines: usize, cols: u16) !Scrollback {
        const cells = try allocator.alloc(Cell, capacity_lines * @as(usize, cols));
        return .{
            .allocator = allocator,
            .cells = cells,
            .cols = cols,
            .capacity_lines = capacity_lines,
            .head = 0,
            .len = 0,
        };
    }

    pub fn deinit(self: *Scrollback) void {
        self.allocator.free(self.cells);
    }

    /// Copy a row into the ring. Allocation-free; oldest line is evicted when
    /// full. `row` is the visible-width slice; only up to `cols` cells are kept.
    pub fn push(self: *Scrollback, row: []const Cell) void {
        if (self.capacity_lines == 0) return;
        const slot = (self.head + self.len) % self.capacity_lines;
        const start = slot * @as(usize, self.cols);
        const n = @min(row.len, @as(usize, self.cols));
        @memcpy(self.cells[start .. start + n], row[0..n]);
        if (self.len < self.capacity_lines) {
            self.len += 1;
        } else {
            self.head = (self.head + 1) % self.capacity_lines;
        }
    }

    pub fn clear(self: *Scrollback) void {
        self.head = 0;
        self.len = 0;
    }

    /// One retained line by history index: 0 = oldest, len-1 = newest.
    /// Caller must keep `index < len`.
    pub fn line(self: *const Scrollback, index: usize) []const Cell {
        const slot = (self.head + index) % self.capacity_lines;
        const start = slot * @as(usize, self.cols);
        return self.cells[start .. start + self.cols];
    }

    /// Reallocate for a new column width (rare; resize path only). History is
    /// PRESERVED: each line is truncated or blank-padded to the new width.
    /// (Reflow — re-wrapping long lines across the new width — stays out of
    /// scope; a narrower window loses the clipped tails, not the lines.)
    pub fn resizeCols(self: *Scrollback, new_cols: u16) !void {
        if (new_cols == self.cols) return;
        const new_cells = try self.allocator.alloc(Cell, self.capacity_lines * @as(usize, new_cols));
        // Compact the ring into the new buffer starting at slot 0.
        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            const src = self.line(i);
            const dst = new_cells[i * @as(usize, new_cols) .. (i + 1) * @as(usize, new_cols)];
            const n = @min(src.len, dst.len);
            @memcpy(dst[0..n], src[0..n]);
            @memset(dst[n..], Cell.default);
        }
        self.allocator.free(self.cells);
        self.cells = new_cells;
        self.cols = new_cols;
        self.head = 0;
        // len unchanged — the history survives the resize.
    }
};

/// Main terminal emulator
pub const Terminal = struct {
    allocator: std.mem.Allocator,

    // Grid state
    grid: Grid,
    alt_grid: ?Grid, // Alternate screen buffer

    // Cursor
    cursor: Cursor,
    saved_cursor: ?SavedCursor,
    saved_cursor_alt: ?SavedCursor,
    /// xterm deferred autowrap: the last printable filled the final column and
    /// the cursor stays on it until the next printable forces the wrap. Any
    /// explicit cursor motion (CR, CUP, CUU/CUD/CUF/CUB, LF, BS, TAB) cancels.
    pending_wrap: bool = false,

    // Attributes for new characters
    current_attrs: CellAttrs,
    current_fg: CellColor,
    current_bg: CellColor,

    // Scroll region
    scroll_region: ScrollRegion,

    // Modes
    modes: Modes,

    // Character sets
    charsets: [4]Charset,
    gl: CharsetSlot, // G0-G3 in GL
    gr: CharsetSlot, // G0-G3 in GR

    // Scrollback
    scrollback: Scrollback,
    scrollback_offset: usize, // View offset into scrollback
    /// The offset the ANSI renderer last painted — lets it repaint history
    /// rows only when the view moves (renderer-side state, one renderer per
    /// terminal in the standalone).
    view_offset_rendered: usize = 0,

    // Dirty tracking for efficient rendering
    dirty_rows: std.DynamicBitSet,

    // Tab stops
    tab_stops: std.DynamicBitSet,

    // Terminal title (set via OSC)
    title: [256]u8,
    title_len: usize,

    // DECSCUSR cursor style (CSI Ps SP q). Default = blinking block.
    cursor_shape: u8 = 0, // 0 block, 1 underline, 2 bar
    cursor_blink: bool = true,

    /// Wall-clock ms when the current DEC 2026 sync block opened — lets the
    /// host time out a block the app never closed (crash mid-repaint) instead
    /// of freezing the view forever.
    sync_began_ms: i64 = 0,

    // Host-side effect queues the parser can't perform itself: bell strokes
    // (BEL) and the last OSC 52 clipboard payload ("Pc;Pd", Pd = base64).
    // The C API's take_* calls read-and-clear these.
    bell_pending: u32 = 0,
    clipboard_pending: [4096]u8 = undefined,
    clipboard_len: usize = 0,

    /// Device-report replies the emulator owes the app: DA1/DA2 (`CSI c`),
    /// DSR-CPR (`CSI 6 n`), OSC 10/11 colour queries. The emulator must not
    /// write to the PTY — the host owns input — so replies queue here and the
    /// host drains them via `tmux_take_responses` and sends them back.
    /// Bounded on purpose: an app that spams queries while the host is not
    /// draining drops replies instead of growing the terminal without limit.
    resp_pending: [RESP_CAPACITY]u8 = undefined,
    resp_len: usize = 0,

    // ---- Inline graphics (Kitty protocol, Phase 1) ----
    // Per-screen graphics state (images + placements), riding the alt-screen
    // swap exactly like `grid`/`alt_grid`: `graphics` is always the ACTIVE
    // screen's state; `alt_graphics` holds the stashed PRIMARY while in alt.
    graphics: gfx.GraphicsState = .empty,
    alt_graphics: ?gfx.GraphicsState = null,
    /// Image ids freed since the host last drained (a=d, eviction, alt-exit,
    /// overwrite). Read-and-clear via tmux_take_freed_images — the VRAM guard.
    graphics_freed: std.ArrayListUnmanaged(u32) = .empty,
    /// Monotonic counter; bumps when placements/images change so the host only
    /// re-uploads textures when something actually moved.
    graphics_gen: u64 = 0,
    /// Streaming APC payload accumulator (heap-backed, size-bounded — distinct
    /// from the 2 KiB OSC control buffer). Holds one APC string's raw bytes.
    apc_accum: std.ArrayListUnmanaged(u8) = .empty,
    /// Set when the current APC payload exceeded the cap; the string is dropped.
    apc_overflow: bool = false,
    /// In-flight chunked transmission (Kitty m=1 continuation).
    graphics_pending: ?GfxPending = null,

    pub const GfxPending = struct {
        id: u32,
        format: gfx.ImageFormat,
        width: u32,
        height: u32,
        action: gfx.Action,
        cols: u16,
        rows: u16,
        col: u16,
        row: u16,
        data: std.ArrayListUnmanaged(u8) = .empty, // accumulated base64
    };

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, rows: u16, cols: u16, scrollback_lines: u32) !Self {
        var grid = try Grid.init(allocator, rows, cols);
        errdefer grid.deinit();

        var scrollback = try Scrollback.init(allocator, scrollback_lines, cols);
        errdefer scrollback.deinit();

        var dirty_rows = try std.DynamicBitSet.initEmpty(allocator, rows);
        errdefer dirty_rows.deinit();
        dirty_rows.setRangeValue(.{ .start = 0, .end = rows }, true);

        var tab_stops = try std.DynamicBitSet.initEmpty(allocator, cols);
        errdefer tab_stops.deinit();
        // Default tab stops every 8 columns
        var col: usize = 8;
        while (col < cols) : (col += 8) {
            tab_stops.set(col);
        }

        return Self{
            .allocator = allocator,
            .grid = grid,
            .alt_grid = null,
            .cursor = .{},
            .saved_cursor = null,
            .saved_cursor_alt = null,
            .current_attrs = .{},
            .current_fg = .{ .default = {} },
            .current_bg = .{ .default = {} },
            .scroll_region = .{ .top = 0, .bottom = rows - 1 },
            .modes = .{},
            .charsets = .{ .ascii, .ascii, .ascii, .ascii },
            .gl = .g0,
            .gr = .g1,
            .scrollback = scrollback,
            .scrollback_offset = 0,
            .dirty_rows = dirty_rows,
            .tab_stops = tab_stops,
            .title = undefined,
            .title_len = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.grid.deinit();
        if (self.alt_grid) |*g| {
            g.deinit();
        }

        self.scrollback.deinit();

        self.dirty_rows.deinit();
        self.tab_stops.deinit();

        // Graphics: free both screens' image bytes + containers (no freed-id
        // signalling on teardown — the host is going away too).
        self.graphics.deinit(self.allocator, null);
        if (self.alt_graphics) |*g| g.deinit(self.allocator, null);
        self.graphics_freed.deinit(self.allocator);
        self.apc_accum.deinit(self.allocator);
        if (self.graphics_pending) |*p| p.data.deinit(self.allocator);
    }

    /// Check if a character is wide (occupies 2 columns).
    /// Anchor: Unicode 15 EastAsianWidth.txt `W`/`F` entries (UAX #11) — the
    /// same table libc wcwidth follows, so cursor math agrees with the shell.
    fn isWideChar(char: u21) bool {
        return switch (char) {
            // Emoji & pictographs outside the CJK blocks (EAW `W`):
            0x231A...0x231B => true, // watch, hourglass
            0x23E9...0x23EC => true, // fast-forward etc.
            0x23F0, 0x23F3 => true,
            0x25FD...0x25FE => true, // small squares
            0x2614...0x2615 => true, // umbrella, hot beverage
            0x2648...0x2653 => true, // zodiac
            0x267F, 0x2693, 0x26A1 => true,
            0x26AA...0x26AB => true,
            0x26BD...0x26BE => true,
            0x26C4...0x26C5 => true,
            0x26CE, 0x26D4, 0x26EA => true,
            0x26F2...0x26F3 => true,
            0x26F5, 0x26FA, 0x26FD => true,
            0x2705 => true,
            0x270A...0x270B => true,
            0x2728, 0x274C, 0x274E => true,
            0x2753...0x2755 => true,
            0x2757 => true,
            0x2795...0x2797 => true,
            0x27B0, 0x27BF => true,
            0x2B1B...0x2B1C => true,
            0x2B50, 0x2B55 => true,
            0x1F004, 0x1F0CF, 0x1F18E => true,
            0x1F191...0x1F19A => true,
            0x1F201...0x1F202 => true,
            0x1F21A, 0x1F22F => true,
            0x1F232...0x1F23A => true,
            0x1F250...0x1F251 => true,
            0x1F300...0x1F64F => true, // symbols & pictographs, emoticons
            0x1F680...0x1F6FF => true, // transport (🚀 …)
            0x1F7E0...0x1F7EB => true, // colored circles/squares
            0x1F90C...0x1F9FF => true, // supplemental symbols
            0x1FA70...0x1FAFF => true, // symbols extended-A
            // Hangul Jamo
            0x1100...0x115F => true,
            // CJK Radicals, Kangxi, Ideographic Description Characters
            0x2E80...0x303E => true,
            // Hiragana, Katakana, Bopomofo, CJK Compatibility
            0x3040...0x33FF => true,
            // CJK Unified Ideographs Extension A
            0x3400...0x4DBF => true,
            // CJK Unified Ideographs
            0x4E00...0x9FFF => true,
            // Hangul Syllables
            0xAC00...0xD7AF => true,
            // CJK Compatibility Ideographs
            0xF900...0xFAFF => true,
            // CJK Compatibility Forms, Small Form Variants
            0xFE10...0xFE6F => true,
            // Fullwidth Forms
            0xFF01...0xFF60 => true,
            0xFFE0...0xFFE6 => true,
            // CJK Unified Ideographs Extensions B, C, D, E, F, G, H, etc. (SMP and beyond)
            0x20000...0x2FFFF => true,
            0x30000...0x3FFFF => true,
            else => false,
        };
    }

    /// Zero-width codepoints (combining marks, joiners, variation selectors)
    /// occupy no cell. Full grapheme composition can't be represented by the
    /// single-codepoint Cell, so they are dropped — per esctest, the one thing
    /// they must never do is advance the cursor.
    fn isZeroWidth(char: u21) bool {
        return switch (char) {
            0x0300...0x036F => true, // combining diacriticals
            0x0483...0x0489 => true, // Cyrillic combining
            0x0591...0x05BD, 0x05BF => true, // Hebrew points
            0x0610...0x061A, 0x064B...0x065F, 0x0670 => true, // Arabic marks
            0x200B...0x200F => true, // ZWSP ZWNJ ZWJ LRM RLM
            0x1AB0...0x1AFF => true, // combining diacriticals extended
            0x1DC0...0x1DFF => true, // combining diacriticals supplement
            0x20D0...0x20FF => true, // combining marks for symbols
            0xFE00...0xFE0F => true, // variation selectors (emoji/text)
            0xFE20...0xFE2F => true, // combining half marks
            0xFEFF => true, // ZWNBSP / BOM
            0xE0100...0xE01EF => true, // variation selectors supplement
            else => false,
        };
    }

    /// Resolve a pending autowrap: the previous printable filled the last
    /// column and the wrap was deferred until now (xterm DECAWM semantics).
    fn resolvePendingWrap(self: *Self) void {
        if (!self.pending_wrap) return;
        self.pending_wrap = false;
        // The row being left soft-wrapped (no explicit CR/LF).
        self.grid.setRowWrapped(self.cursor.row, true);
        self.newline();
        self.cursor.col = 0;
    }

    /// Write a character at the current cursor position
    pub fn putChar(self: *Self, char: u21) void {
        if (isZeroWidth(char)) return;

        const width: u2 = if (isWideChar(char)) 2 else 1;

        // Deferred autowrap (xterm "pending wrap" / esctest DECAWM cases):
        // printing the last column leaves the cursor ON it; the wrap happens
        // when the NEXT printable arrives. Anything else (CR, CUP, …) cancels.
        self.resolvePendingWrap();

        // A wide glyph never splits across rows: when only the last column is
        // left, blank it as a spacer and wrap first (autowrap on).
        if (width == 2 and self.cursor.col + 1 >= self.grid.cols and self.modes.autowrap) {
            self.grid.getCell(self.cursor.row, self.grid.cols - 1).* = .{
                .char = ' ',
                .fg = self.current_fg,
                .bg = self.current_bg,
                .attrs = self.current_attrs,
                .width = 1,
            };
            self.markDirty(self.cursor.row);
            self.grid.setRowWrapped(self.cursor.row, true);
            self.newline();
            self.cursor.col = 0;
        }

        const cell = self.grid.getCell(self.cursor.row, self.cursor.col);
        cell.* = .{
            .char = char,
            .fg = self.current_fg,
            .bg = self.current_bg,
            .attrs = self.current_attrs,
            .width = width,
        };

        // A wide glyph occupies two columns: blank the continuation cell
        // (width 0) so renderers see a defined placeholder instead of whatever
        // stale glyph was there — the ANSI renderer would otherwise repaint the
        // stale cell over the wide glyph's right half.
        if (width == 2 and self.cursor.col + 1 < self.grid.cols) {
            const cont = self.grid.getCell(self.cursor.row, self.cursor.col + 1);
            cont.* = .{
                .char = 0,
                .fg = self.current_fg,
                .bg = self.current_bg,
                .attrs = self.current_attrs,
                .width = 0,
            };
        }

        self.markDirty(self.cursor.row);
        if (@as(u17, self.cursor.col) + width >= self.grid.cols) {
            // Filled the last column: stay on it. With autowrap the wrap is
            // now pending; without, the next printable overwrites in place.
            self.cursor.col = self.grid.cols - 1;
            self.pending_wrap = self.modes.autowrap;
        } else {
            self.cursor.col += width;
        }
    }

    /// Bulk-write a run of printable, width-1 ASCII bytes at the cursor,
    /// honoring autowrap and scrolling. Semantically equivalent to calling
    /// putChar for each byte, but writes whole same-row spans at once and marks
    /// each touched row dirty only once. The SIMD fast path in processOutput
    /// calls this; `bytes` must contain only printable ASCII (0x20..0x7E).
    pub fn putPrintableRun(self: *Self, bytes: []const u8) void {
        const cols: usize = self.grid.cols;
        var idx: usize = 0;
        while (idx < bytes.len) {
            // Resolve a deferred wrap exactly as putChar does. Without
            // autowrap the cursor is already clamped to the last column and
            // every further chunk overwrites it (room == 1 below).
            self.resolvePendingWrap();

            const room: usize = cols - self.cursor.col; // always >= 1
            const n: usize = @min(bytes.len - idx, room);

            // Hoist style + the destination slice out of the loop: indexing `self.grid.cells[base+k]` and
            // reading `self.current_*` through the `self` pointer every iteration defeats hoisting (the
            // compiler can't prove the writes don't alias them). A local slice + local style → tight loop.
            const fg = self.current_fg;
            const bg = self.current_bg;
            const at = self.current_attrs;
            const base = self.grid.physRow(self.cursor.row) * cols + self.cursor.col;
            const dst = self.grid.cells[base .. base + n];
            for (dst, 0..) |*cell, k| {
                cell.* = .{ .char = bytes[idx + k], .fg = fg, .bg = bg, .attrs = at, .width = 1 };
            }
            self.markDirty(self.cursor.row);

            self.cursor.col += @intCast(n);
            idx += n;
            if (self.cursor.col >= cols) {
                // Filled the last column: cursor stays on it, wrap deferred.
                self.cursor.col = @intCast(cols - 1);
                self.pending_wrap = self.modes.autowrap;
            }
        }
    }

    /// Handle newline
    pub fn newline(self: *Self) void {
        self.pending_wrap = false;
        if (self.cursor.row == self.scroll_region.bottom) {
            self.scrollUp(1);
        } else if (self.cursor.row < self.grid.rows - 1) {
            self.cursor.row += 1;
        }
        self.markDirty(self.cursor.row);
    }

    /// Handle carriage return
    pub fn carriageReturn(self: *Self) void {
        // An explicit CR is a hard control of this row — it is not a soft-wrap
        // continuation, so drop any recorded wrap for it.
        self.pending_wrap = false;
        self.grid.setRowWrapped(self.cursor.row, false);
        self.cursor.col = 0;
    }

    /// Handle tab
    pub fn tab(self: *Self) void {
        self.pending_wrap = false;
        var col = self.cursor.col + 1;
        while (col < self.grid.cols) : (col += 1) {
            if (self.tab_stops.isSet(col)) {
                self.cursor.col = @intCast(col);
                return;
            }
        }
        self.cursor.col = self.grid.cols - 1;
    }

    /// Handle backspace
    pub fn backspace(self: *Self) void {
        self.pending_wrap = false;
        if (self.cursor.col > 0) {
            self.cursor.col -= 1;
        }
    }

    /// Scroll up by n lines
    pub fn scrollUp(self: *Self, n: u16) void {
        // Save scrolled-off lines to scrollback (main buffer only). Allocation-
        // free: push copies the row into the preallocated ring. Capture must
        // happen BEFORE grid.scrollUp rotates/clears these rows.
        if (!self.modes.alt_screen) {
            var i: u16 = 0;
            while (i < n and self.scroll_region.top + i <= self.scroll_region.bottom) : (i += 1) {
                self.scrollback.push(self.grid.rowSlice(self.scroll_region.top + i));
            }
        }

        const template = Cell{
            .char = ' ',
            .fg = self.current_fg,
            .bg = self.current_bg,
            .attrs = .{},
            .width = 1,
        };

        self.grid.scrollUp(self.scroll_region.top, self.scroll_region.bottom, n, template);
        self.markAllDirty();

        // Advance the graphics epoch (grid row 0's absolute line index) and evict
        // any placement that has scrolled entirely out of retained history.
        self.graphics.epoch += n;
        const min_retained = self.graphicsMinRetainedAbs();
        if (self.graphics.prune(self.allocator, min_retained, &self.graphics_freed)) {
            self.graphics_gen +%= 1;
        }
    }

    /// Scroll down by n lines
    pub fn scrollDown(self: *Self, n: u16) void {
        const template = Cell{
            .char = ' ',
            .fg = self.current_fg,
            .bg = self.current_bg,
            .attrs = .{},
            .width = 1,
        };

        self.grid.scrollDown(self.scroll_region.top, self.scroll_region.bottom, n, template);
        self.markAllDirty();

        // Content moved down: grid row 0's absolute line index retreats.
        self.graphics.epoch -= n;
    }

    /// Erase display (ED)
    pub fn eraseDisplay(self: *Self, mode: u8) void {
        const template = Cell{
            .char = ' ',
            .fg = self.current_fg,
            .bg = self.current_bg,
            .attrs = .{},
            .width = 1,
        };

        switch (mode) {
            0 => {
                // Erase from cursor to end
                self.grid.clearRegion(self.cursor.row, self.cursor.col, self.cursor.row, self.grid.cols - 1, template);
                if (self.cursor.row + 1 < self.grid.rows) {
                    self.grid.clearRegion(self.cursor.row + 1, 0, self.grid.rows - 1, self.grid.cols - 1, template);
                }
            },
            1 => {
                // Erase from start to cursor
                self.grid.clearRegion(0, 0, self.cursor.row, self.cursor.col, template);
                if (self.cursor.row > 0) {
                    self.grid.clearRegion(0, 0, self.cursor.row - 1, self.grid.cols - 1, template);
                }
            },
            2, 3 => {
                // Erase entire display
                self.grid.clearRegion(0, 0, self.grid.rows - 1, self.grid.cols - 1, template);
                if (mode == 3) {
                    // Also clear scrollback
                    self.scrollback.clear();
                }
                // Clearing the whole display clears its image overlays too.
                self.graphicsClearScreen();
            },
            else => {},
        }
        self.markAllDirty();
    }

    /// Erase line (EL)
    pub fn eraseLine(self: *Self, mode: u8) void {
        const template = Cell{
            .char = ' ',
            .fg = self.current_fg,
            .bg = self.current_bg,
            .attrs = .{},
            .width = 1,
        };

        switch (mode) {
            0 => {
                // Erase from cursor to end of line
                self.grid.clearRegion(self.cursor.row, self.cursor.col, self.cursor.row, self.grid.cols - 1, template);
            },
            1 => {
                // Erase from start of line to cursor
                self.grid.clearRegion(self.cursor.row, 0, self.cursor.row, self.cursor.col, template);
            },
            2 => {
                // Erase entire line
                self.grid.clearRegion(self.cursor.row, 0, self.cursor.row, self.grid.cols - 1, template);
            },
            else => {},
        }
        self.markDirty(self.cursor.row);
    }

    /// Insert blank characters at cursor (ICH)
    pub fn insertChar(self: *Self, count: u16) void {
        self.pending_wrap = false;
        if (self.cursor.col >= self.grid.cols) return;

        const row = self.cursor.row;
        const start_col = self.cursor.col;
        const end_col: i32 = @intCast(self.grid.cols - 1);

        // Calculate actual number of characters to insert (can't exceed line width)
        const insert_count: i32 = if (start_col + count >= self.grid.cols)
            @intCast(self.grid.cols - start_col - 1)
        else
            @intCast(count);

        // Shift characters right from end to start
        var col: i32 = end_col;
        while (col >= start_col + insert_count) : (col -= 1) {
            const src = self.grid.getCell(row, @intCast(col - insert_count));
            const dst = self.grid.getCell(row, @intCast(col));
            dst.* = src.*;
        }

        // Fill inserted positions with blanks
        const blank = Cell{
            .char = ' ',
            .fg = self.current_fg,
            .bg = self.current_bg,
            .attrs = .{},
            .width = 1,
        };

        var fill_col: u16 = start_col;
        while (fill_col < start_col + @as(u16, @intCast(insert_count))) : (fill_col += 1) {
            self.grid.getCell(row, fill_col).* = blank;
        }

        self.markDirty(row);
    }

    /// Delete characters at cursor (DCH) — ECMA-48 §8.3.26: the tail of the
    /// row slides left over the deleted cells; the freed end fills with blanks.
    pub fn deleteChar(self: *Self, count: u16) void {
        self.pending_wrap = false;
        if (self.cursor.col >= self.grid.cols or count == 0) return;
        const row = self.cursor.row;
        const cols = self.grid.cols;
        const n: u16 = @min(count, cols - self.cursor.col);

        var col: u16 = self.cursor.col;
        while (col + n < cols) : (col += 1) {
            self.grid.getCell(row, col).* = self.grid.getCell(row, col + n).*;
        }
        const blank = Cell{
            .char = ' ',
            .fg = self.current_fg,
            .bg = self.current_bg,
            .attrs = .{},
            .width = 1,
        };
        while (col < cols) : (col += 1) {
            self.grid.getCell(row, col).* = blank;
        }
        self.markDirty(row);
    }

    /// Erase characters at cursor (ECH) — ECMA-48 §8.3.41: N cells blanked in
    /// place; unlike DCH nothing shifts.
    pub fn eraseChars(self: *Self, count: u16) void {
        self.pending_wrap = false;
        if (self.cursor.col >= self.grid.cols or count == 0) return;
        const n: u16 = @min(count, self.grid.cols - self.cursor.col);
        const blank = Cell{
            .char = ' ',
            .fg = self.current_fg,
            .bg = self.current_bg,
            .attrs = .{},
            .width = 1,
        };
        var col: u16 = self.cursor.col;
        const end = self.cursor.col + n;
        while (col < end) : (col += 1) {
            self.grid.getCell(self.cursor.row, col).* = blank;
        }
        self.markDirty(self.cursor.row);
    }

    /// Set cursor position (CUP)
    pub fn setCursorPos(self: *Self, row: u16, col: u16) void {
        self.pending_wrap = false;
        const base_row: u16 = if (self.modes.origin) self.scroll_region.top else 0;
        const max_row: u16 = if (self.modes.origin) self.scroll_region.bottom else self.grid.rows - 1;

        self.cursor.row = @min(base_row + row, max_row);
        self.cursor.col = @min(col, self.grid.cols - 1);
        // Explicit cursor repositioning breaks any soft-wrap chain into this row.
        self.grid.setRowWrapped(self.cursor.row, false);
    }

    /// Move cursor up (CUU)
    pub fn cursorUp(self: *Self, n: u16) void {
        self.pending_wrap = false;
        const min_row: u16 = if (self.modes.origin) self.scroll_region.top else 0;
        if (self.cursor.row >= min_row + n) {
            self.cursor.row -= n;
        } else {
            self.cursor.row = min_row;
        }
    }

    /// Move cursor down (CUD)
    pub fn cursorDown(self: *Self, n: u16) void {
        self.pending_wrap = false;
        const max_row: u16 = if (self.modes.origin) self.scroll_region.bottom else self.grid.rows - 1;
        if (self.cursor.row + n <= max_row) {
            self.cursor.row += n;
        } else {
            self.cursor.row = max_row;
        }
    }

    /// Move cursor forward (CUF)
    pub fn cursorForward(self: *Self, n: u16) void {
        self.pending_wrap = false;
        if (self.cursor.col + n < self.grid.cols) {
            self.cursor.col += n;
        } else {
            self.cursor.col = self.grid.cols - 1;
        }
    }

    /// Move cursor backward (CUB)
    pub fn cursorBackward(self: *Self, n: u16) void {
        self.pending_wrap = false;
        if (self.cursor.col >= n) {
            self.cursor.col -= n;
        } else {
            self.cursor.col = 0;
        }
    }

    /// Save cursor state (DECSC)
    pub fn saveCursor(self: *Self) void {
        const saved = SavedCursor{
            .row = self.cursor.row,
            .col = self.cursor.col,
            .attrs = self.current_attrs,
            .fg = self.current_fg,
            .bg = self.current_bg,
            .origin_mode = self.modes.origin,
            .autowrap = self.modes.autowrap,
            .pending_wrap = self.pending_wrap,
        };

        if (self.modes.alt_screen) {
            self.saved_cursor_alt = saved;
        } else {
            self.saved_cursor = saved;
        }
    }

    /// Restore cursor state (DECRC)
    pub fn restoreCursor(self: *Self) void {
        const saved = if (self.modes.alt_screen) self.saved_cursor_alt else self.saved_cursor;

        if (saved) |s| {
            self.cursor.row = @min(s.row, self.grid.rows - 1);
            self.cursor.col = @min(s.col, self.grid.cols - 1);
            self.current_attrs = s.attrs;
            self.current_fg = s.fg;
            self.current_bg = s.bg;
            self.modes.origin = s.origin_mode;
            self.modes.autowrap = s.autowrap;
            self.pending_wrap = s.pending_wrap;
        } else {
            self.pending_wrap = false;
        }
    }

    /// Switch to the alternate screen buffer — SWAP semantics: the primary
    /// grid is stashed aside untouched and `self.grid` becomes a fresh blank
    /// grid, so every write path (putChar, erases, scrolls — they all target
    /// `self.grid`) is alt-correct with no per-callsite dispatch. The old
    /// design kept writing to the primary while readers looked at an
    /// always-empty alt grid: vim rendered into your scrollback and quitting
    /// it never restored the screen.
    pub fn enterAltScreen(self: *Self) !void {
        if (self.modes.alt_screen) return;

        const fresh = try Grid.init(self.allocator, self.grid.rows, self.grid.cols);
        self.alt_grid = self.grid; // stash the primary
        self.grid = fresh;
        // Graphics ride the SAME swap: stash the primary placements/images and
        // give the alt screen a fresh empty set (DOOM's per-frame placements
        // must never leak back to the primary). Any in-flight transmission is
        // abandoned at the screen boundary.
        self.alt_graphics = self.graphics;
        self.graphics = .empty;
        self.abandonGraphicsTransmission();
        self.modes.alt_screen = true;
        self.pending_wrap = false;
        self.markAllDirty();
        self.graphics_gen +%= 1;
    }

    /// Return to the main screen buffer: discard the alt contents and restore
    /// the stashed primary grid byte-exact (what `less`/vim quitting expects).
    pub fn exitAltScreen(self: *Self) void {
        if (!self.modes.alt_screen) return;

        if (self.alt_grid) |g| {
            self.grid.deinit(); // the alt screen's contents die here
            self.grid = g;
            self.alt_grid = null;
        }
        // Discard the alt screen's graphics (freeing every image and signalling
        // the freed ids so the host releases the textures) and restore the
        // stashed primary set byte-for-byte.
        if (self.alt_graphics) |primary| {
            self.graphics.deinit(self.allocator, &self.graphics_freed);
            self.graphics = primary;
            self.alt_graphics = null;
        }
        self.abandonGraphicsTransmission();
        self.modes.alt_screen = false;
        self.pending_wrap = false;
        self.markAllDirty();
        self.graphics_gen +%= 1;
    }

    /// Resize terminal
    pub fn resize(self: *Self, rows: u16, cols: u16) !void {
        try self.grid.resize(rows, cols);
        if (self.alt_grid) |*g| {
            try g.resize(rows, cols);
        }
        try self.scrollback.resizeCols(cols);

        self.scroll_region = .{ .top = 0, .bottom = rows - 1 };

        // Ensure cursor is in bounds
        if (self.cursor.row >= rows) self.cursor.row = rows - 1;
        if (self.cursor.col >= cols) self.cursor.col = cols - 1;

        // Resize dirty tracking
        self.dirty_rows.deinit();
        self.dirty_rows = try std.DynamicBitSet.initFull(self.allocator, rows);

        // Resize tab stops
        self.tab_stops.deinit();
        self.tab_stops = try std.DynamicBitSet.initEmpty(self.allocator, cols);
        var col: usize = 8;
        while (col < cols) : (col += 8) {
            self.tab_stops.set(col);
        }
    }

    /// Mark a row as dirty (needs redraw)
    pub fn markDirty(self: *Self, row: u16) void {
        if (row < self.dirty_rows.capacity()) {
            self.dirty_rows.set(row);
        }
    }

    /// Mark all rows as dirty
    pub fn markAllDirty(self: *Self) void {
        self.dirty_rows.setRangeValue(.{ .start = 0, .end = self.grid.rows }, true);
    }

    /// Clear all dirty flags
    pub fn clearDirty(self: *Self) void {
        self.dirty_rows.setRangeValue(.{ .start = 0, .end = self.grid.rows }, false);
    }

    /// Check if a row is dirty
    pub fn isDirty(self: *const Self, row: u16) bool {
        if (row < self.dirty_rows.capacity()) {
            return self.dirty_rows.isSet(row);
        }
        return true;
    }

    /// Get current grid (main or alt)
    /// The grid being displayed AND written. With swap-based alt screen this
    /// is always `self.grid` — `alt_grid` only ever holds the stashed PRIMARY
    /// while alt mode is active (never render that one).
    pub fn getCurrentGrid(self: *Self) *Grid {
        return &self.grid;
    }

    /// Reset terminal to initial state
    /// DECSCUSR (CSI Ps SP q): 0/1 blinking block, 2 steady block, 3/4 underline,
    /// 5/6 bar — odd numbers blink, even are steady.
    pub fn setCursorStyle(self: *Self, n: u16) void {
        switch (n) {
            0, 1 => { self.cursor_shape = 0; self.cursor_blink = true; },
            2 => { self.cursor_shape = 0; self.cursor_blink = false; },
            3 => { self.cursor_shape = 1; self.cursor_blink = true; },
            4 => { self.cursor_shape = 1; self.cursor_blink = false; },
            5 => { self.cursor_shape = 2; self.cursor_blink = true; },
            6 => { self.cursor_shape = 2; self.cursor_blink = false; },
            else => {},
        }
    }

    /// Queue a device-report reply for the host to write back to the PTY.
    /// Dropped whole when it does not fit: a truncated escape sequence on the
    /// wire is worse than no answer at all, because the app parses the
    /// fragment as literal keystrokes.
    pub fn queueResponse(self: *Self, bytes: []const u8) void {
        if (bytes.len > self.resp_pending.len - self.resp_len) return;
        @memcpy(self.resp_pending[self.resp_len..][0..bytes.len], bytes);
        self.resp_len += bytes.len;
    }

    pub fn reset(self: *Self) void {
        self.cursor = .{};
        self.resp_len = 0; // RIS: replies owed to the pre-reset app are void
        self.current_attrs = .{};
        self.current_fg = .{ .default = {} };
        self.current_bg = .{ .default = {} };
        self.scroll_region = .{ .top = 0, .bottom = self.grid.rows - 1 };
        self.modes = .{};
        self.charsets = .{ .ascii, .ascii, .ascii, .ascii };
        self.gl = .g0;
        self.gr = .g1;

        self.grid.clearRegion(0, 0, self.grid.rows - 1, self.grid.cols - 1, Cell.default);
        self.markAllDirty();

        self.graphicsClearScreen();
        self.abandonGraphicsTransmission();
    }

    // =========================================================================
    // Inline graphics (Kitty protocol, Phase 1)
    // =========================================================================

    /// Absolute line index of grid logical row 0 for the active screen, adjusted
    /// for the current scrollback view (the top visible line).
    pub fn graphicsViewportTopAbs(self: *const Self) i64 {
        const back: i64 = if (self.modes.alt_screen)
            0
        else
            @intCast(@min(self.scrollback_offset, self.scrollback.len));
        return self.graphics.epoch - back;
    }

    /// Oldest absolute line index still retained (in the grid or scrollback).
    /// A placement whose whole rect is above this has scrolled out of history.
    fn graphicsMinRetainedAbs(self: *const Self) i64 {
        if (self.modes.alt_screen) return self.graphics.epoch;
        return self.graphics.epoch - @as(i64, @intCast(self.scrollback.len));
    }

    /// Free every image/placement on the active screen (ED2/3, reset).
    fn graphicsClearScreen(self: *Self) void {
        if (self.graphics.placements.items.len == 0 and self.graphics.images.items.len == 0) return;
        self.graphics.clearAll(self.allocator, &self.graphics_freed);
        self.graphics_gen +%= 1;
    }

    /// Drop any in-flight chunked transmission + reset the APC accumulator.
    fn abandonGraphicsTransmission(self: *Self) void {
        if (self.graphics_pending) |*p| {
            p.data.deinit(self.allocator);
            self.graphics_pending = null;
        }
        self.apc_accum.clearRetainingCapacity();
        self.apc_overflow = false;
    }

    /// APC begin (ESC _): reset the payload accumulator.
    pub fn graphicsApcStart(self: *Self) void {
        self.apc_accum.clearRetainingCapacity();
        self.apc_overflow = false;
    }

    /// APC payload byte: append to the streaming accumulator (size-bounded).
    pub fn graphicsApcPut(self: *Self, byte: u8) void {
        if (self.apc_overflow) return;
        if (self.apc_accum.items.len >= gfx.APC_ACCUM_CAP) {
            self.apc_overflow = true;
            return;
        }
        self.apc_accum.append(self.allocator, byte) catch {
            self.apc_overflow = true;
        };
    }

    /// APC terminated (ST): parse + dispatch the Kitty graphics command.
    pub fn graphicsApcEnd(self: *Self) void {
        defer self.apc_accum.clearRetainingCapacity();
        if (self.apc_overflow) {
            self.abandonGraphicsTransmission();
            return;
        }
        const payload = self.apc_accum.items;
        // Kitty graphics commands begin with 'G'. Anything else is some other
        // APC string we don't handle — ignore it (never touches the grid).
        if (payload.len == 0 or payload[0] != 'G') return;

        const body = payload[1..];
        const semi = std.mem.indexOfScalar(u8, body, ';');
        const ctrl_s = if (semi) |s| body[0..s] else body;
        const data_s = if (semi) |s| body[s + 1 ..] else body[body.len..];
        const ctrl = gfx.Control.parse(ctrl_s);

        // Continuation of an in-flight chunked transmission.
        if (self.graphics_pending != null) {
            self.graphicsAppendChunk(data_s);
            if (!(ctrl.has_m and ctrl.m == 1)) self.graphicsFinalizePending();
            return;
        }

        switch (ctrl.a) {
            .place => {
                self.graphicsPlace(ctrl.i, @intCast(@min(ctrl.c, 65535)), @intCast(@min(ctrl.r, 65535)));
            },
            .delete => self.graphicsDelete(ctrl.d, ctrl.i),
            .transmit, .transmit_place => {
                // Whitelist: direct base64 only; RGB/RGBA/PNG only.
                if (ctrl.t != 'd') return;
                const fmt = gfx.ImageFormat.fromKitty(ctrl.f) orelse return;
                if (ctrl.has_m and ctrl.m == 1) {
                    // First frame of a chunked transmission — start accumulating.
                    var pend = GfxPending{
                        .id = ctrl.i,
                        .format = fmt,
                        .width = ctrl.s,
                        .height = ctrl.v,
                        .action = ctrl.a,
                        .cols = @intCast(@min(ctrl.c, 65535)),
                        .rows = @intCast(@min(ctrl.r, 65535)),
                        .col = self.cursor.col,
                        .row = self.cursor.row,
                    };
                    pend.data.appendSlice(self.allocator, data_s) catch {
                        pend.data.deinit(self.allocator);
                        return;
                    };
                    self.graphics_pending = pend;
                } else {
                    // Single-frame transmission — decode directly, no copy.
                    self.graphicsCommit(fmt, ctrl.i, ctrl.s, ctrl.v, ctrl.a, @intCast(@min(ctrl.c, 65535)), @intCast(@min(ctrl.r, 65535)), self.cursor.col, self.cursor.row, data_s);
                }
            },
            .unknown => {},
        }
    }

    fn graphicsAppendChunk(self: *Self, data_s: []const u8) void {
        const p = &self.graphics_pending.?;
        if (p.data.items.len + data_s.len > gfx.APC_ACCUM_CAP) {
            // Over cap — abandon this transmission.
            p.data.deinit(self.allocator);
            self.graphics_pending = null;
            return;
        }
        p.data.appendSlice(self.allocator, data_s) catch {
            p.data.deinit(self.allocator);
            self.graphics_pending = null;
        };
    }

    fn graphicsFinalizePending(self: *Self) void {
        const p = self.graphics_pending orelse return;
        self.graphics_pending = null;
        var data = p.data;
        defer data.deinit(self.allocator);
        self.graphicsCommit(p.format, p.id, p.width, p.height, p.action, p.cols, p.rows, p.col, p.row, data.items);
    }

    /// Decode the base64 payload, store the image, and (for a=T) place it.
    fn graphicsCommit(
        self: *Self,
        fmt: gfx.ImageFormat,
        id: u32,
        width: u32,
        height: u32,
        action: gfx.Action,
        cols: u16,
        rows: u16,
        col: u16,
        row: u16,
        b64: []const u8,
    ) void {
        const decoded = decodeBase64(self.allocator, b64) orelse return;
        const img = gfx.Image{
            .id = id,
            .width = width,
            .height = height,
            .format = fmt,
            .bytes = decoded,
        };
        if (!self.graphics.putImage(self.allocator, img, &self.graphics_freed)) {
            // Over the per-pane cap — drop.
            self.allocator.free(decoded);
            return;
        }
        self.graphics_gen +%= 1;
        if (action == .transmit_place) {
            self.graphicsPlaceAt(id, cols, rows, col, row);
        }
    }

    /// Place an already-transmitted image (a=p) at the current cursor.
    fn graphicsPlace(self: *Self, id: u32, cols: u16, rows: u16) void {
        self.graphicsPlaceAt(id, cols, rows, self.cursor.col, self.cursor.row);
    }

    fn graphicsPlaceAt(self: *Self, id: u32, cols: u16, rows: u16, col: u16, row: u16) void {
        if (self.graphics.findImage(id) == null) return; // no such image
        self.graphics.placements.append(self.allocator, .{
            .image_id = id,
            .anchor_line = self.graphics.epoch + @as(i64, row),
            .col = col,
            .cell_w = cols,
            .cell_h = rows,
            .z = 0,
        }) catch return;
        self.graphics_gen +%= 1;
    }

    /// Delete (a=d). d='i'/'I' → by image id; d='a'/'A' → all.
    fn graphicsDelete(self: *Self, d: u8, id: u32) void {
        switch (d) {
            'a', 'A' => self.graphics.clearAll(self.allocator, &self.graphics_freed),
            'i', 'I' => self.graphics.freeImage(self.allocator, id, &self.graphics_freed),
            else => self.graphics.freeImage(self.allocator, id, &self.graphics_freed),
        }
        self.graphics_gen +%= 1;
    }
};

/// Decode standard (padded) base64 into a freshly allocated buffer, or null on
/// malformed input.
fn decodeBase64(allocator: std.mem.Allocator, src: []const u8) ?[]u8 {
    const dec = std.base64.standard.Decoder;
    const n = dec.calcSizeForSlice(src) catch return null;
    const buf = allocator.alloc(u8, n) catch return null;
    dec.decode(buf, src) catch {
        allocator.free(buf);
        return null;
    };
    return buf;
}

// =============================================================================
// Tests
// =============================================================================

test "cell attrs packed size" {
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(CellAttrs));
}

test "grid basic operations" {
    const allocator = std.testing.allocator;

    var grid = try Grid.init(allocator, 24, 80);
    defer grid.deinit();

    try std.testing.expectEqual(@as(u16, 24), grid.rows);
    try std.testing.expectEqual(@as(u16, 80), grid.cols);

    // Write a character
    const cell = grid.getCell(0, 0);
    cell.char = 'A';

    try std.testing.expectEqual(@as(u21, 'A'), grid.getCellConst(0, 0).char);
}

test "terminal init and deinit" {
    const allocator = std.testing.allocator;

    var term = try Terminal.init(allocator, 24, 80, 1000);
    defer term.deinit();

    try std.testing.expectEqual(@as(u16, 24), term.grid.rows);
    try std.testing.expectEqual(@as(u16, 80), term.grid.cols);
}

test "terminal putChar" {
    const allocator = std.testing.allocator;

    var term = try Terminal.init(allocator, 24, 80, 100);
    defer term.deinit();

    term.putChar('H');
    term.putChar('i');

    try std.testing.expectEqual(@as(u21, 'H'), term.grid.getCellConst(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'i'), term.grid.getCellConst(0, 1).char);
    try std.testing.expectEqual(@as(u16, 2), term.cursor.col);
}

test "full-screen scroll rotates the ring and preserves logical order" {
    const allocator = std.testing.allocator;

    var term = try Terminal.init(allocator, 4, 8, 100);
    defer term.deinit();

    // One distinct char per row at column 0: '0' '1' '2' '3'.
    var r: u16 = 0;
    while (r < 4) : (r += 1) {
        term.setCursorPos(r, 0);
        term.putChar('0' + @as(u21, r));
    }

    term.scrollUp(1); // O(1) ring rotation on the full screen

    try std.testing.expectEqual(@as(u21, '1'), term.grid.getCellConst(0, 0).char);
    try std.testing.expectEqual(@as(u21, '2'), term.grid.getCellConst(1, 0).char);
    try std.testing.expectEqual(@as(u21, '3'), term.grid.getCellConst(2, 0).char);
    try std.testing.expectEqual(@as(u21, ' '), term.grid.getCellConst(3, 0).char); // new blank
    try std.testing.expect(term.grid.row_offset != 0); // rotated, not memcpy'd
    try std.testing.expectEqual(@as(usize, 1), term.scrollback.len); // '0' captured

    // scrollDown brings it back and re-blanks the top.
    term.scrollDown(1);
    try std.testing.expectEqual(@as(u21, ' '), term.grid.getCellConst(0, 0).char);
    try std.testing.expectEqual(@as(u21, '1'), term.grid.getCellConst(1, 0).char);
    try std.testing.expectEqual(@as(u21, '2'), term.grid.getCellConst(2, 0).char);
}

test "putPrintableRun matches byte-by-byte putChar (incl. autowrap)" {
    const allocator = std.testing.allocator;

    var a = try Terminal.init(allocator, 4, 10, 50);
    defer a.deinit();
    var b = try Terminal.init(allocator, 4, 10, 50);
    defer b.deinit();

    const text = "Hello, World! 123"; // 17 chars over 10 cols => wraps once

    for (text) |ch| a.putChar(ch);
    b.putPrintableRun(text);

    var i: u16 = 0;
    while (i < 4 * 10) : (i += 1) {
        const rr = i / 10;
        const cc = i % 10;
        try std.testing.expectEqual(a.grid.getCellConst(rr, cc).char, b.grid.getCellConst(rr, cc).char);
    }
    try std.testing.expectEqual(a.cursor.row, b.cursor.row);
    try std.testing.expectEqual(a.cursor.col, b.cursor.col);
}

test "ring buffer" {
    const allocator = std.testing.allocator;

    var rb = try RingBuffer(u32).init(allocator, 3);
    defer rb.deinit(allocator);

    rb.push(1);
    rb.push(2);
    rb.push(3);

    try std.testing.expectEqual(@as(u32, 1), rb.get(0).?.*);
    try std.testing.expectEqual(@as(u32, 2), rb.get(1).?.*);
    try std.testing.expectEqual(@as(u32, 3), rb.get(2).?.*);

    // Push more, oldest should be overwritten
    rb.push(4);
    try std.testing.expectEqual(@as(u32, 2), rb.get(0).?.*);
    try std.testing.expectEqual(@as(u32, 3), rb.get(1).?.*);
    try std.testing.expectEqual(@as(u32, 4), rb.get(2).?.*);
}
