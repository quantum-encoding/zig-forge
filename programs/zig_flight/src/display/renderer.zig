//! Frame buffer and ANSI output renderer.
//! Composes a full frame into a character cell buffer, then generates
//! ANSI escape sequences and flushes to stdout in a single write.

const std = @import("std");
const posix = std.posix;
const tui = @import("tui_backend.zig");

pub const MAX_WIDTH: u16 = 120;
pub const MAX_HEIGHT: u16 = 40;

// ============================================================================
// Cell and FrameBuffer
// ============================================================================

pub const Cell = struct {
    char: u21 = ' ',
    fg: tui.Color = .green,
    bg: tui.Color = .black,
    bold: bool = false,
};

pub const FrameBuffer = struct {
    cells: [MAX_HEIGHT][MAX_WIDTH]Cell = [_][MAX_WIDTH]Cell{[_]Cell{.{}} ** MAX_WIDTH} ** MAX_HEIGHT,
    width: u16 = 80,
    height: u16 = 24,

    pub fn clear(self: *FrameBuffer) void {
        for (0..self.height) |r| {
            for (0..self.width) |c| {
                self.cells[r][c] = .{};
            }
        }
    }

    pub fn setCell(self: *FrameBuffer, row: u16, col: u16, char: u21, fg: tui.Color, bg: tui.Color, bold: bool) void {
        if (row >= self.height or col >= self.width) return;
        self.cells[row][col] = .{ .char = char, .fg = fg, .bg = bg, .bold = bold };
    }

    /// Write an ASCII string into the buffer starting at (row, col).
    pub fn putStr(self: *FrameBuffer, row: u16, col: u16, text: []const u8, fg: tui.Color, bg: tui.Color, bold: bool) void {
        var c = col;
        for (text) |byte| {
            if (c >= self.width) break;
            self.cells[row][c] = .{ .char = byte, .fg = fg, .bg = bg, .bold = bold };
            c += 1;
        }
    }

    /// Format and write into the buffer.
    pub fn putFmt(self: *FrameBuffer, row: u16, col: u16, comptime fmt: []const u8, args: anytype, fg: tui.Color, bg: tui.Color, bold: bool) void {
        var buf: [128]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
        self.putStr(row, col, text, fg, bg, bold);
    }

    /// Draw a box with Unicode box-drawing characters.
    pub fn drawBox(self: *FrameBuffer, row: u16, col: u16, w: u16, h: u16, fg: tui.Color) void {
        if (w < 2 or h < 2) return;
        // Corners
        self.setCell(row, col, 0x250C, fg, .black, false); // ┌
        self.setCell(row, col + w - 1, 0x2510, fg, .black, false); // ┐
        self.setCell(row + h - 1, col, 0x2514, fg, .black, false); // └
        self.setCell(row + h - 1, col + w - 1, 0x2518, fg, .black, false); // ┘
        // Top and bottom edges
        var i: u16 = 1;
        while (i < w - 1) : (i += 1) {
            self.setCell(row, col + i, 0x2500, fg, .black, false); // ─
            self.setCell(row + h - 1, col + i, 0x2500, fg, .black, false);
        }
        // Left and right edges
        var j: u16 = 1;
        while (j < h - 1) : (j += 1) {
            self.setCell(row + j, col, 0x2502, fg, .black, false); // │
            self.setCell(row + j, col + w - 1, 0x2502, fg, .black, false);
        }
    }

    /// Draw a horizontal line.
    pub fn drawHLine(self: *FrameBuffer, row: u16, col: u16, len: u16, fg: tui.Color) void {
        var i: u16 = 0;
        while (i < len) : (i += 1) {
            self.setCell(row, col + i, 0x2500, fg, .black, false); // ─
        }
    }

    /// Draw a horizontal bar gauge: ████░░░░ for percentage.
    pub fn drawBarGauge(self: *FrameBuffer, row: u16, col: u16, width: u16, percent: f32, fg: tui.Color, bg_color: tui.Color) void {
        const clamped = @max(0.0, @min(100.0, percent));
        const filled: u16 = @intFromFloat((clamped / 100.0) * @as(f32, @floatFromInt(width)));
        var i: u16 = 0;
        while (i < width) : (i += 1) {
            if (i < filled) {
                self.setCell(row, col + i, 0x2588, fg, .black, false); // █
            } else {
                self.setCell(row, col + i, 0x2591, bg_color, .black, false); // ░
            }
        }
    }
};

// ============================================================================
// Renderer — generates ANSI output from FrameBuffer
// ============================================================================

pub const Renderer = struct {
    fb: FrameBuffer = .{},
    out_buf: [65536]u8 = undefined,
    out_len: usize = 0,

    pub fn beginFrame(self: *Renderer) void {
        self.fb.clear();
        self.out_len = 0;
    }

    /// Convert frame buffer to ANSI escape sequences.
    pub fn endFrame(self: *Renderer) void {
        self.out_len = 0;
        // Move cursor home
        self.emit("\x1b[H");

        var prev_fg: tui.Color = .black;
        var prev_bg: tui.Color = .black;
        var prev_bold: bool = false;

        // Reset at start
        self.emit("\x1b[0m");

        var row: u16 = 0;
        while (row < self.fb.height) : (row += 1) {
            // Move to start of row
            self.emitMoveCursor(row, 0);

            var col: u16 = 0;
            while (col < self.fb.width) : (col += 1) {
                const cell = self.fb.cells[row][col];

                // Emit SGR only on change
                if (cell.fg != prev_fg or cell.bg != prev_bg or cell.bold != prev_bold) {
                    self.emitSGR(cell.fg, cell.bg, cell.bold);
                    prev_fg = cell.fg;
                    prev_bg = cell.bg;
                    prev_bold = cell.bold;
                }

                self.emitChar(cell.char);
            }
        }

        // Reset attributes at end
        self.emit("\x1b[0m");
    }

    /// Flush output buffer to stdout in a single write.
    pub fn flush(self: *Renderer) void {
        if (self.out_len > 0) {
            _ = std.c.write(posix.STDOUT_FILENO, &self.out_buf, self.out_len);
        }
    }

    // --- Internal helpers ---

    fn emit(self: *Renderer, s: []const u8) void {
        for (s) |byte| {
            if (self.out_len < self.out_buf.len) {
                self.out_buf[self.out_len] = byte;
                self.out_len += 1;
            }
        }
    }

    fn emitByte(self: *Renderer, byte: u8) void {
        if (self.out_len < self.out_buf.len) {
            self.out_buf[self.out_len] = byte;
            self.out_len += 1;
        }
    }

    fn emitChar(self: *Renderer, char: u21) void {
        // Encode u21 to UTF-8
        if (char < 0x80) {
            self.emitByte(@intCast(char));
        } else if (char < 0x800) {
            self.emitByte(@intCast(0xC0 | (char >> 6)));
            self.emitByte(@intCast(0x80 | (char & 0x3F)));
        } else if (char < 0x10000) {
            self.emitByte(@intCast(0xE0 | (char >> 12)));
            self.emitByte(@intCast(0x80 | ((char >> 6) & 0x3F)));
            self.emitByte(@intCast(0x80 | (char & 0x3F)));
        } else {
            self.emitByte(@intCast(0xF0 | (char >> 18)));
            self.emitByte(@intCast(0x80 | ((char >> 12) & 0x3F)));
            self.emitByte(@intCast(0x80 | ((char >> 6) & 0x3F)));
            self.emitByte(@intCast(0x80 | (char & 0x3F)));
        }
    }

    fn emitMoveCursor(self: *Renderer, row: u16, col: u16) void {
        // ANSI: ESC[{row+1};{col+1}H
        var buf: [16]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "\x1b[{d};{d}H", .{ row + 1, col + 1 }) catch return;
        self.emit(s);
    }

    fn emitSGR(self: *Renderer, fg: tui.Color, bg: tui.Color, bold: bool) void {
        // ESC[0;{bold};38;5;{fg};48;5;{bg}m
        var buf: [32]u8 = undefined;
        const bold_val: u8 = if (bold) 1 else 22;
        const s = std.fmt.bufPrint(&buf, "\x1b[{d};38;5;{d};48;5;{d}m", .{
            bold_val,
            @intFromEnum(fg),
            @intFromEnum(bg),
        }) catch return;
        self.emit(s);
    }
};
