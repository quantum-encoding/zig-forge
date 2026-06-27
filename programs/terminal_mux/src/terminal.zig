//! Terminal Emulator
//!
//! Virtual terminal implementation supporting VT100/ANSI escape sequences.
//! Each pane contains one of these to track terminal state.

const std = @import("std");
const config = @import("config.zig");
const Color = config.Color;

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

/// Saved cursor state (for ESC 7 / ESC 8)
pub const SavedCursor = struct {
    row: u16,
    col: u16,
    attrs: CellAttrs,
    fg: CellColor,
    bg: CellColor,
    origin_mode: bool,
    autowrap: bool,
};

/// Scroll region
pub const ScrollRegion = struct {
    top: u16,
    bottom: u16,
};

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
    /// Focus events
    focus_events: bool = false,

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
    rows: u16,
    cols: u16,
    /// Physical index of logical row 0. Advanced on scroll; never memcpy.
    row_offset: usize = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, rows: u16, cols: u16) !Self {
        const size = @as(usize, rows) * @as(usize, cols);
        const cells = try allocator.alloc(Cell, size);
        @memset(cells, Cell.default);

        return Self{
            .allocator = allocator,
            .cells = cells,
            .rows = rows,
            .cols = cols,
            .row_offset = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.cells);
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

        self.allocator.free(self.cells);
        self.cells = new_cells;
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

    /// Reallocate for a new column width (rare; resize path only). Clears
    /// history — reflow across widths is out of scope.
    pub fn resizeCols(self: *Scrollback, new_cols: u16) !void {
        if (new_cols == self.cols) return;
        const new_cells = try self.allocator.alloc(Cell, self.capacity_lines * @as(usize, new_cols));
        self.allocator.free(self.cells);
        self.cells = new_cells;
        self.cols = new_cols;
        self.head = 0;
        self.len = 0;
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

    // Dirty tracking for efficient rendering
    dirty_rows: std.DynamicBitSet,

    // Tab stops
    tab_stops: std.DynamicBitSet,

    // Terminal title (set via OSC)
    title: [256]u8,
    title_len: usize,

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
    }

    /// Check if a character is wide (occupies 2 columns)
    fn isWideChar(char: u21) bool {
        return switch (char) {
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

    /// Write a character at the current cursor position
    pub fn putChar(self: *Self, char: u21) void {
        if (self.cursor.col >= self.grid.cols) {
            if (self.modes.autowrap) {
                self.newline();
                self.cursor.col = 0;
            } else {
                self.cursor.col = self.grid.cols - 1;
            }
        }

        const width: u2 = if (isWideChar(char)) 2 else 1;
        const cell = self.grid.getCell(self.cursor.row, self.cursor.col);
        cell.* = .{
            .char = char,
            .fg = self.current_fg,
            .bg = self.current_bg,
            .attrs = self.current_attrs,
            .width = width,
        };

        self.markDirty(self.cursor.row);
        self.cursor.col += width;
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
            // Resolve a pending wrap exactly as putChar does.
            if (self.cursor.col >= self.grid.cols) {
                if (self.modes.autowrap) {
                    self.newline();
                    self.cursor.col = 0;
                } else {
                    // Overwrite mode: every further byte lands on the last cell.
                    self.cursor.col = self.grid.cols - 1;
                }
            }

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
        }
    }

    /// Handle newline
    pub fn newline(self: *Self) void {
        if (self.cursor.row == self.scroll_region.bottom) {
            self.scrollUp(1);
        } else if (self.cursor.row < self.grid.rows - 1) {
            self.cursor.row += 1;
        }
        self.markDirty(self.cursor.row);
    }

    /// Handle carriage return
    pub fn carriageReturn(self: *Self) void {
        self.cursor.col = 0;
    }

    /// Handle tab
    pub fn tab(self: *Self) void {
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

    /// Set cursor position (CUP)
    pub fn setCursorPos(self: *Self, row: u16, col: u16) void {
        const base_row: u16 = if (self.modes.origin) self.scroll_region.top else 0;
        const max_row: u16 = if (self.modes.origin) self.scroll_region.bottom else self.grid.rows - 1;

        self.cursor.row = @min(base_row + row, max_row);
        self.cursor.col = @min(col, self.grid.cols - 1);
    }

    /// Move cursor up (CUU)
    pub fn cursorUp(self: *Self, n: u16) void {
        const min_row: u16 = if (self.modes.origin) self.scroll_region.top else 0;
        if (self.cursor.row >= min_row + n) {
            self.cursor.row -= n;
        } else {
            self.cursor.row = min_row;
        }
    }

    /// Move cursor down (CUD)
    pub fn cursorDown(self: *Self, n: u16) void {
        const max_row: u16 = if (self.modes.origin) self.scroll_region.bottom else self.grid.rows - 1;
        if (self.cursor.row + n <= max_row) {
            self.cursor.row += n;
        } else {
            self.cursor.row = max_row;
        }
    }

    /// Move cursor forward (CUF)
    pub fn cursorForward(self: *Self, n: u16) void {
        if (self.cursor.col + n < self.grid.cols) {
            self.cursor.col += n;
        } else {
            self.cursor.col = self.grid.cols - 1;
        }
    }

    /// Move cursor backward (CUB)
    pub fn cursorBackward(self: *Self, n: u16) void {
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
        }
    }

    /// Switch to alternate screen buffer
    pub fn enterAltScreen(self: *Self) !void {
        if (self.modes.alt_screen) return;

        self.alt_grid = try Grid.init(self.allocator, self.grid.rows, self.grid.cols);
        self.modes.alt_screen = true;
        self.markAllDirty();
    }

    /// Return to main screen buffer
    pub fn exitAltScreen(self: *Self) void {
        if (!self.modes.alt_screen) return;

        if (self.alt_grid) |*g| {
            g.deinit();
            self.alt_grid = null;
        }
        self.modes.alt_screen = false;
        self.markAllDirty();
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
    pub fn getCurrentGrid(self: *Self) *Grid {
        if (self.modes.alt_screen) {
            if (self.alt_grid) |*g| {
                return g;
            }
        }
        return &self.grid;
    }

    /// Reset terminal to initial state
    pub fn reset(self: *Self) void {
        self.cursor = .{};
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
    }
};

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
