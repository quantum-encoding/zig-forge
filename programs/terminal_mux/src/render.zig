//! Software Renderer
//!
//! Renders terminal content to ANSI escape sequences for output to a terminal.
//! Uses differential rendering - only outputs changed cells.

const std = @import("std");
const terminal = @import("terminal.zig");
const session = @import("session.zig");
const config = @import("config.zig");

const Terminal = terminal.Terminal;
const Cell = terminal.Cell;
const CellAttrs = terminal.CellAttrs;
const CellColor = terminal.CellColor;
const Color = config.Color;
const Pane = session.Pane;
const Window = session.Window;
const Rect = session.Rect;

/// Renderer state
pub const Renderer = struct {
    allocator: std.mem.Allocator,

    // Output buffer
    output: std.ArrayListUnmanaged(u8),

    // Previous frame for diff
    prev_cells: ?[]Cell,
    prev_rows: u16,
    prev_cols: u16,

    // Current cursor position (for optimization)
    cursor_row: u16,
    cursor_col: u16,

    // Current attributes (for optimization)
    current_fg: CellColor,
    current_bg: CellColor,
    current_attrs: CellAttrs,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .output = .empty,
            .prev_cells = null,
            .prev_rows = 0,
            .prev_cols = 0,
            .cursor_row = 0,
            .cursor_col = 0,
            .current_fg = .{ .default = {} },
            .current_bg = .{ .default = {} },
            .current_attrs = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.output.deinit(self.allocator);
        if (self.prev_cells) |cells| {
            self.allocator.free(cells);
        }
    }

    /// Begin a new frame
    pub fn beginFrame(self: *Self) void {
        self.output.clearRetainingCapacity();
    }

    /// Get the output buffer
    pub fn getOutput(self: *const Self) []const u8 {
        return self.output.items;
    }

    /// Render a full window (all panes)
    pub fn renderWindow(self: *Self, window: *Window, show_borders: bool) !void {
        for (window.panes.items) |pane| {
            try self.renderPane(pane, show_borders);
        }

        // Draw borders between panes
        if (show_borders and window.panes.items.len > 1) {
            try self.renderBorders(window);
        }
    }

    /// Render a single pane
    pub fn renderPane(self: *Self, pane: *Pane, show_border: bool) !void {
        const term = &pane.terminal;
        const grid = term.getCurrentGrid();
        const rect = pane.rect;

        // If showing border, adjust rendering area
        const render_offset_x: u16 = if (show_border) 1 else 0;
        const render_offset_y: u16 = if (show_border) 1 else 0;

        var row: u16 = 0;
        while (row < grid.rows) : (row += 1) {
            if (!term.isDirty(row)) continue;

            var col: u16 = 0;
            while (col < grid.cols) : (col += 1) {
                const cell = grid.getCellConst(row, col);

                // Skip if cell hasn't changed (when we have prev frame)
                if (self.prev_cells) |prev| {
                    if (row < self.prev_rows and col < self.prev_cols) {
                        const prev_idx = @as(usize, row) * @as(usize, self.prev_cols) + @as(usize, col);
                        if (prev_idx < prev.len and cell.eql(&prev[prev_idx])) {
                            continue;
                        }
                    }
                }

                const screen_row = rect.y + render_offset_y + row;
                const screen_col = rect.x + render_offset_x + col;

                try self.moveCursor(screen_row, screen_col);
                try self.setAttributes(cell.attrs, cell.fg, cell.bg);
                try self.writeChar(cell.char);

                self.cursor_col += 1;
            }
        }

        // Render cursor
        if (term.modes.cursor_visible) {
            const cursor_row = rect.y + render_offset_y + term.cursor.row;
            const cursor_col = rect.x + render_offset_x + term.cursor.col;
            try self.moveCursor(cursor_row, cursor_col);
        }

        term.clearDirty();
    }

    /// Render borders between panes
    fn renderBorders(self: *Self, window: *Window) !void {
        // Reset attributes for border drawing
        try self.resetAttributes();

        for (window.panes.items) |pane| {
            const rect = pane.rect;

            // Highlight active pane border
            if (pane.active) {
                try self.appendString("\x1b[32m"); // Green for active
            } else {
                try self.appendString("\x1b[90m"); // Gray for inactive
            }

            // Draw right border if not at edge
            if (rect.x + rect.width < window.panes.items[0].rect.x + window.panes.items[0].rect.width) {
                const border_col = rect.x + rect.width;
                var row: u16 = rect.y;
                while (row < rect.y + rect.height) : (row += 1) {
                    try self.moveCursor(row, border_col);
                    try self.appendString("\xe2\x94\x82"); // │
                }
            }

            // Draw bottom border if not at edge
            if (rect.y + rect.height < window.panes.items[0].rect.y + window.panes.items[0].rect.height) {
                const border_row = rect.y + rect.height;
                var col: u16 = rect.x;
                while (col < rect.x + rect.width) : (col += 1) {
                    try self.moveCursor(border_row, col);
                    try self.appendString("\xe2\x94\x80"); // ─
                }
            }
        }

        try self.resetAttributes();
    }

    /// Render status bar
    pub fn renderStatusBar(self: *Self, cfg: *const config.StatusBarConfig, sess_name: []const u8, win_index: u8, rows: u16, cols: u16) !void {
        if (!cfg.enabled) return;

        const row = switch (cfg.position) {
            .top => 0,
            .bottom => rows - 1,
        };

        try self.moveCursor(row, 0);

        // Set status bar colors
        try self.appendString("\x1b[");
        try self.appendNumber(48);
        try self.appendString(";2;");
        try self.appendNumber(cfg.bg.r);
        try self.appendString(";");
        try self.appendNumber(cfg.bg.g);
        try self.appendString(";");
        try self.appendNumber(cfg.bg.b);
        try self.appendString("m");

        try self.appendString("\x1b[");
        try self.appendNumber(38);
        try self.appendString(";2;");
        try self.appendNumber(cfg.fg.r);
        try self.appendString(";");
        try self.appendNumber(cfg.fg.g);
        try self.appendString(";");
        try self.appendNumber(cfg.fg.b);
        try self.appendString("m");

        // Left side: session name
        try self.appendString("[");
        try self.output.appendSlice(self.allocator, sess_name);
        try self.appendString("] ");

        // Window indicator
        try self.appendNumber(win_index);
        try self.appendString(":*");

        // Fill rest of line
        var col: u16 = @intCast(sess_name.len + 6); // Rough estimate
        while (col < cols) : (col += 1) {
            try self.output.append(self.allocator, ' ');
        }

        try self.resetAttributes();
    }

    /// Move cursor to position
    fn moveCursor(self: *Self, row: u16, col: u16) !void {
        if (self.cursor_row == row and self.cursor_col == col) return;

        // CSI row;col H
        try self.appendString("\x1b[");
        try self.appendNumber(row + 1);
        try self.appendString(";");
        try self.appendNumber(col + 1);
        try self.appendString("H");

        self.cursor_row = row;
        self.cursor_col = col;
    }

    /// Set text attributes
    fn setAttributes(self: *Self, attrs: CellAttrs, fg: CellColor, bg: CellColor) !void {
        // Check if anything changed
        if (attrs.eql(self.current_attrs) and fg.eql(self.current_fg) and bg.eql(self.current_bg)) {
            return;
        }

        // Reset and set new attributes
        try self.appendString("\x1b[0");

        if (attrs.bold) try self.appendString(";1");
        if (attrs.dim) try self.appendString(";2");
        if (attrs.italic) try self.appendString(";3");
        if (attrs.underline) try self.appendString(";4");
        if (attrs.blink) try self.appendString(";5");
        if (attrs.inverse) try self.appendString(";7");
        if (attrs.invisible) try self.appendString(";8");
        if (attrs.strikethrough) try self.appendString(";9");

        // Foreground color
        switch (fg) {
            .default => {},
            .indexed => |idx| {
                if (idx < 8) {
                    try self.appendString(";3");
                    try self.appendNumber(idx);
                } else if (idx < 16) {
                    try self.appendString(";9");
                    try self.appendNumber(idx - 8);
                } else {
                    try self.appendString(";38;5;");
                    try self.appendNumber(idx);
                }
            },
            .rgb => |c| {
                try self.appendString(";38;2;");
                try self.appendNumber(c.r);
                try self.appendString(";");
                try self.appendNumber(c.g);
                try self.appendString(";");
                try self.appendNumber(c.b);
            },
        }

        // Background color
        switch (bg) {
            .default => {},
            .indexed => |idx| {
                if (idx < 8) {
                    try self.appendString(";4");
                    try self.appendNumber(idx);
                } else if (idx < 16) {
                    try self.appendString(";10");
                    try self.appendNumber(idx - 8);
                } else {
                    try self.appendString(";48;5;");
                    try self.appendNumber(idx);
                }
            },
            .rgb => |c| {
                try self.appendString(";48;2;");
                try self.appendNumber(c.r);
                try self.appendString(";");
                try self.appendNumber(c.g);
                try self.appendString(";");
                try self.appendNumber(c.b);
            },
        }

        try self.appendString("m");

        self.current_attrs = attrs;
        self.current_fg = fg;
        self.current_bg = bg;
    }

    /// Reset attributes to default
    fn resetAttributes(self: *Self) !void {
        try self.appendString("\x1b[0m");
        self.current_attrs = .{};
        self.current_fg = .{ .default = {} };
        self.current_bg = .{ .default = {} };
    }

    /// Write a character
    fn writeChar(self: *Self, char: u21) !void {
        if (char < 0x80) {
            try self.output.append(self.allocator, @intCast(char));
        } else if (char < 0x800) {
            try self.output.append(self.allocator, @intCast(0xC0 | (char >> 6)));
            try self.output.append(self.allocator, @intCast(0x80 | (char & 0x3F)));
        } else if (char < 0x10000) {
            try self.output.append(self.allocator, @intCast(0xE0 | (char >> 12)));
            try self.output.append(self.allocator, @intCast(0x80 | ((char >> 6) & 0x3F)));
            try self.output.append(self.allocator, @intCast(0x80 | (char & 0x3F)));
        } else {
            try self.output.append(self.allocator, @intCast(0xF0 | (char >> 18)));
            try self.output.append(self.allocator, @intCast(0x80 | ((char >> 12) & 0x3F)));
            try self.output.append(self.allocator, @intCast(0x80 | ((char >> 6) & 0x3F)));
            try self.output.append(self.allocator, @intCast(0x80 | (char & 0x3F)));
        }
    }

    /// Append a string to output
    fn appendString(self: *Self, s: []const u8) !void {
        try self.output.appendSlice(self.allocator, s);
    }

    /// Append a number to output
    fn appendNumber(self: *Self, n: anytype) !void {
        var buf: [16]u8 = undefined;
        const slice = std.fmt.bufPrint(&buf, "{d}", .{n}) catch return;
        try self.output.appendSlice(self.allocator, slice);
    }

    /// Clear the entire screen
    pub fn clearScreen(self: *Self) !void {
        try self.appendString("\x1b[2J");
        try self.appendString("\x1b[H");
        self.cursor_row = 0;
        self.cursor_col = 0;
    }

    /// Hide cursor
    pub fn hideCursor(self: *Self) !void {
        try self.appendString("\x1b[?25l");
    }

    /// Show cursor
    pub fn showCursor(self: *Self) !void {
        try self.appendString("\x1b[?25h");
    }

    /// Enter alternate screen buffer
    pub fn enterAltScreen(self: *Self) !void {
        try self.appendString("\x1b[?1049h");
    }

    /// Exit alternate screen buffer
    pub fn exitAltScreen(self: *Self) !void {
        try self.appendString("\x1b[?1049l");
    }

    /// Enable mouse tracking
    pub fn enableMouse(self: *Self) !void {
        try self.appendString("\x1b[?1000h"); // Enable mouse tracking
        try self.appendString("\x1b[?1006h"); // SGR mouse mode
    }

    /// Disable mouse tracking
    pub fn disableMouse(self: *Self) !void {
        try self.appendString("\x1b[?1000l");
        try self.appendString("\x1b[?1006l");
    }

    /// Set terminal title
    pub fn setTitle(self: *Self, title: []const u8) !void {
        try self.appendString("\x1b]0;");
        try self.appendString(title);
        try self.appendString("\x07");
    }
};

// =============================================================================
// Tests
// =============================================================================

test "renderer init" {
    const allocator = std.testing.allocator;

    var renderer = Renderer.init(allocator);
    defer renderer.deinit();

    try std.testing.expectEqual(@as(usize, 0), renderer.output.items.len);
}

test "renderer clear screen" {
    const allocator = std.testing.allocator;

    var renderer = Renderer.init(allocator);
    defer renderer.deinit();

    try renderer.clearScreen();

    try std.testing.expect(renderer.output.items.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, renderer.output.items, "\x1b[2J") != null);
}

test "renderer move cursor" {
    const allocator = std.testing.allocator;

    var renderer = Renderer.init(allocator);
    defer renderer.deinit();

    try renderer.moveCursor(5, 10);

    // Should contain CSI 6;11 H (1-indexed)
    try std.testing.expect(std.mem.indexOf(u8, renderer.output.items, "\x1b[6;11H") != null);
}
