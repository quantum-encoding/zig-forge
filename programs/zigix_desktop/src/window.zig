// Window — wraps a terminal_mux Pane with desktop chrome (title bar, border).
// Handles cell conversion between terminal_mux and zig_tui cell types.

const std = @import("std");
const platform = @import("platform.zig");
const tui = if (platform.is_linux) @import("zig_tui") else @import("tui_pure.zig");
const theme = @import("theme.zig");

const Buffer = tui.Buffer;
const Style = tui.Style;
const Color = tui.Color;
const TuiRect = tui.Rect;
const Cell = tui.Cell;

// terminal_mux types only available on Linux
const mux = if (platform.is_linux) @import("terminal_mux") else struct {
    pub const Pane = void;
    pub const Rect = struct { x: u16, y: u16, width: u16, height: u16 };
    pub const CellColor = void;
    pub const CellAttrs = void;
};

const Pane = mux.Pane;
const MuxRect = mux.Rect;

pub const MAX_TITLE_LEN = 64;

pub const Window = struct {
    pane: if (platform.is_linux) *Pane else void,
    proc_handle: if (platform.is_zigix) platform.ProcessHandle else void,
    title: [MAX_TITLE_LEN]u8,
    title_len: usize,
    focused: bool,
    id: u16,

    // Position/size in screen coordinates (set by layout manager)
    x: u16,
    y: u16,
    width: u16,
    height: u16,

    const Self = @This();

    /// Create a new window wrapping a terminal_mux Pane (Linux).
    pub fn init(pane: anytype, id: u16, name: []const u8) Self {
        var win = Self{
            .pane = if (platform.is_linux) pane else {},
            .proc_handle = if (platform.is_zigix) undefined else {},
            .title = undefined,
            .title_len = 0,
            .focused = false,
            .id = id,
            .x = 0,
            .y = 0,
            .width = 0,
            .height = 0,
        };
        win.setTitle(name);
        return win;
    }

    /// Create a new window with a Zigix process handle (freestanding).
    pub fn initZigix(handle: platform.ProcessHandle, id: u16, name: []const u8) Self {
        var win = Self{
            .pane = if (platform.is_linux) undefined else {},
            .proc_handle = if (platform.is_zigix) handle else {},
            .title = undefined,
            .title_len = 0,
            .focused = false,
            .id = id,
            .x = 0,
            .y = 0,
            .width = 0,
            .height = 0,
        };
        win.setTitle(name);
        return win;
    }

    pub fn setTitle(self: *Self, name: []const u8) void {
        const len = @min(name.len, MAX_TITLE_LEN);
        @memcpy(self.title[0..len], name[0..len]);
        self.title_len = len;
    }

    pub fn getTitle(self: *const Self) []const u8 {
        return self.title[0..self.title_len];
    }

    /// Set the window position and size in screen coordinates.
    pub fn setRect(self: *Self, x: u16, y: u16, w: u16, h: u16) void {
        self.x = x;
        self.y = y;
        self.width = w;
        self.height = h;

        if (platform.is_linux) {
            const content_w = if (w > 2) w - 2 else 1;
            const content_h = if (h > 2) h - 2 else 1;
            const pane_rect = MuxRect{ .x = 0, .y = 0, .width = content_w, .height = content_h };
            self.pane.resize(pane_rect) catch {};
        }
    }

    /// The inner rectangle after subtracting chrome (border + title bar).
    pub fn contentRect(self: *const Self) TuiRect {
        return TuiRect{
            .x = self.x +| 1,
            .y = self.y +| 1,
            .width = if (self.width > 2) self.width - 2 else 0,
            .height = if (self.height > 2) self.height - 2 else 0,
        };
    }

    /// Render the complete window (chrome + terminal content) into a zig_tui Buffer.
    pub fn renderTo(self: *const Self, buf: *Buffer) void {
        if (self.width < 3 or self.height < 3) return;

        const border_style = if (self.focused) theme.active_border else theme.inactive_border;
        const title_style = if (self.focused) theme.active_title else theme.inactive_title;
        const close_style = if (self.focused) theme.active_title_close else theme.inactive_title_close;

        // Draw border using Unicode box drawing
        self.drawBorder(buf, border_style);

        // Draw title bar on the top border row
        self.drawTitleBar(buf, title_style, close_style, border_style);

        // Draw terminal content inside the border
        self.renderTerminalContent(buf);
    }

    fn drawBorder(self: *const Self, buf: *Buffer, style: Style) void {
        const x = self.x;
        const y = self.y;
        const w = self.width;
        const h = self.height;

        // Corners
        buf.setChar(x, y, 0x250C, style); // ┌
        buf.setChar(x +| (w -| 1), y, 0x2510, style); // ┐
        buf.setChar(x, y +| (h -| 1), 0x2514, style); // └
        buf.setChar(x +| (w -| 1), y +| (h -| 1), 0x2518, style); // ┘

        // Horizontal lines (top and bottom)
        var i: u16 = 1;
        while (i < w -| 1) : (i += 1) {
            buf.setChar(x +| i, y, 0x2500, style); // ─
            buf.setChar(x +| i, y +| (h -| 1), 0x2500, style); // ─
        }

        // Vertical lines (left and right)
        var j: u16 = 1;
        while (j < h -| 1) : (j += 1) {
            buf.setChar(x, y +| j, 0x2502, style); // │
            buf.setChar(x +| (w -| 1), y +| j, 0x2502, style); // │
        }
    }

    fn drawTitleBar(self: *const Self, buf: *Buffer, title_style: Style, close_style: Style, border_style: Style) void {
        const y = self.y;
        const inner_start = self.x +| 1;
        const inner_end = self.x +| (self.width -| 1);

        // Fill title bar background
        var tx: u16 = inner_start;
        while (tx < inner_end) : (tx += 1) {
            buf.setChar(tx, y, ' ', title_style);
        }

        // Title text: "[ title ─ Window N ]"
        var title_buf: [MAX_TITLE_LEN + 24]u8 = undefined;
        const title_text = std.fmt.bufPrint(&title_buf, " {s}", .{self.getTitle()}) catch " ? ";
        _ = buf.writeStr(inner_start, y, title_text, title_style);

        // Close indicator [X] at right side
        if (self.width > 6) {
            _ = buf.writeStr(inner_end -| 4, y, " [X]", close_style);
        }

        // Restore border characters at the boundary with corners
        buf.setChar(self.x, y, 0x250C, border_style); // ┌
        buf.setChar(self.x +| (self.width -| 1), y, 0x2510, border_style); // ┐
    }

    fn renderTerminalContent(self: *const Self, buf: *Buffer) void {
        const content = self.contentRect();
        if (content.width == 0 or content.height == 0) return;

        if (platform.is_linux) {
            const grid = &self.pane.terminal.grid;
            const cursor = &self.pane.terminal.cursor;

            var row: u16 = 0;
            while (row < content.height and row < grid.rows) : (row += 1) {
                var col: u16 = 0;
                while (col < content.width and col < grid.cols) : (col += 1) {
                    const tc = grid.getCellConst(row, col);
                    const Attrs = tui.Attrs;
                    const CellColor = @import("terminal_mux").CellColor;
                    const CellAttrs = @import("terminal_mux").CellAttrs;
                    _ = Attrs;
                    const fg_color = switch (tc.fg) {
                        .default => theme.term_default_fg,
                        .indexed => |i| Color.from256(i),
                        .rgb => |c| Color.fromRgb(c.r, c.g, c.b),
                    };
                    _ = CellColor;
                    const bg_color = switch (tc.bg) {
                        .default => theme.term_default_bg,
                        .indexed => |i| Color.from256(i),
                        .rgb => |c| Color.fromRgb(c.r, c.g, c.b),
                    };
                    _ = CellAttrs;
                    const style = Style{ .fg = fg_color, .bg = bg_color };
                    const ch: u21 = if (tc.char == 0) ' ' else tc.char;
                    buf.setChar(content.x +| col, content.y +| row, ch, style);
                }
            }

            if (self.focused and cursor.visible and
                cursor.row < content.height and cursor.col < content.width)
            {
                const cx = content.x +| cursor.col;
                const cy = content.y +| cursor.row;
                if (buf.getMut(cx, cy)) |cell| {
                    cell.style = Style{
                        .fg = theme.term_default_bg,
                        .bg = theme.amber_bright,
                        .attrs = .{ .bold = true },
                    };
                }
            }
        } else {
            // Zigix: show placeholder — full terminal emulation comes later
            const msg = "[ process running ]";
            _ = buf.writeStr(content.x +| 1, content.y +| 1, msg, theme.text_dim);
            if (self.focused) {
                // Show blinking cursor
                buf.setChar(content.x +| 1, content.y +| 2, '_', Style{
                    .fg = theme.amber_bright,
                    .attrs = .{ .bold = true },
                });
            }
        }
    }

    /// Send keyboard input to the underlying PTY/process.
    pub fn sendInput(self: *Self, data: []const u8) void {
        if (platform.is_linux) {
            self.pane.sendInput(data) catch {};
        } else {
            platform.writeProcessInput(self.proc_handle, data);
        }
    }

    /// Read available output from PTY/process.
    pub fn pollOutput(self: *Self) bool {
        if (platform.is_linux) {
            var read_buf: [4096]u8 = undefined;
            var got_data = false;
            while (true) {
                const n = self.pane.readOutput(&read_buf) catch break;
                if (n == 0) break;
                self.pane.processOutput(read_buf[0..n]);
                got_data = true;
            }
            return got_data;
        } else {
            var read_buf: [4096]u8 = undefined;
            const n = platform.readProcessOutput(self.proc_handle, &read_buf);
            return n > 0;
        }
    }

    /// Check if the underlying process is still running.
    pub fn isAlive(self: *const Self) bool {
        if (platform.is_linux) return self.pane.isAlive();
        return platform.isProcessAlive(self.proc_handle);
    }

    /// Kill the pane and clean up.
    pub fn deinit(self: *Self) void {
        if (platform.is_linux) {
            self.pane.deinit();
        }
    }
};

// Cell conversion functions moved inline into renderTerminalContent (Linux path only).
