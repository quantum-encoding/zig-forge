//! Terminal renderer with differential output
//!
//! Renders buffers to the terminal using ANSI escape sequences.
//! Supports differential rendering for efficient updates.

const std = @import("std");
const core = @import("../core/core.zig");

pub const Buffer = core.Buffer;
pub const Cell = core.Cell;
pub const Color = core.Color;
pub const Style = core.Style;
pub const Attrs = core.Attrs;

/// Terminal renderer
pub const Renderer = struct {
    /// Output buffer for batching writes
    output: std.ArrayListUnmanaged(u8),
    /// Allocator
    allocator: std.mem.Allocator,
    /// Previous frame buffer for differential updates
    prev_buffer: ?Buffer,
    /// Current cursor position
    cursor_x: u16,
    cursor_y: u16,
    /// Current style state (to minimize SGR codes)
    current_style: Style,
    /// Terminal file descriptor
    term_fd: std.posix.fd_t,
    /// Use true color (24-bit) or 256-color
    true_color: bool,

    const Self = @This();

    /// Create a new renderer
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .output = .empty,
            .allocator = allocator,
            .prev_buffer = null,
            .cursor_x = 0,
            .cursor_y = 0,
            .current_style = .{},
            .term_fd = std.posix.STDOUT_FILENO,
            .true_color = true,
        };
    }

    /// Clean up resources
    pub fn deinit(self: *Self) void {
        self.output.deinit(self.allocator);
        if (self.prev_buffer) |*buf| {
            buf.deinit();
        }
    }

    /// Render a buffer to the terminal
    pub fn render(self: *Self, buffer: *const Buffer) !void {
        // Clear output buffer
        self.output.clearRetainingCapacity();

        // Hide cursor during rendering
        try self.output.appendSlice(self.allocator, "\x1b[?25l");

        if (self.prev_buffer) |*prev| {
            // Differential render
            try self.renderDiff(buffer, prev);
            // Update previous buffer
            self.copyBuffer(prev, buffer);
        } else {
            // Full render
            try self.renderFull(buffer);
            // Create previous buffer
            self.prev_buffer = try Buffer.init(self.allocator, buffer.width, buffer.height);
            self.copyBuffer(&self.prev_buffer.?, buffer);
        }

        // Show cursor
        try self.output.appendSlice(self.allocator, "\x1b[?25h");

        // Flush to terminal
        try self.flush();
    }

    /// Force full redraw on next render
    pub fn invalidate(self: *Self) void {
        if (self.prev_buffer) |*buf| {
            buf.deinit();
            self.prev_buffer = null;
        }
    }

    /// Resize handling
    pub fn handleResize(self: *Self, width: u16, height: u16) !void {
        if (self.prev_buffer) |*buf| {
            try buf.resize(width, height);
        }
    }

    fn renderFull(self: *Self, buffer: *const Buffer) !void {
        // Move to home position
        try self.output.appendSlice(self.allocator, "\x1b[H");
        self.cursor_x = 0;
        self.cursor_y = 0;

        // Reset style
        try self.output.appendSlice(self.allocator, "\x1b[0m");
        self.current_style = .{};

        var y: u16 = 0;
        while (y < buffer.height) : (y += 1) {
            if (y > 0) {
                try self.output.appendSlice(self.allocator, "\r\n");
                self.cursor_x = 0;
                self.cursor_y = y;
            }

            var x: u16 = 0;
            while (x < buffer.width) : (x += 1) {
                const cell = buffer.get(x, y) orelse Cell.empty;
                try self.renderCell(cell);
            }
        }
    }

    fn renderDiff(self: *Self, current: *const Buffer, previous: *const Buffer) !void {
        var y: u16 = 0;
        while (y < current.height) : (y += 1) {
            var x: u16 = 0;
            while (x < current.width) : (x += 1) {
                const curr = current.get(x, y) orelse Cell.empty;
                const prev = previous.get(x, y) orelse Cell.empty;

                if (!curr.eql(prev)) {
                    // Move cursor if not already there
                    if (self.cursor_x != x or self.cursor_y != y) {
                        try self.moveCursor(x, y);
                    }
                    try self.renderCell(curr);
                    self.cursor_x = x + 1;
                }
            }
        }
    }

    fn renderCell(self: *Self, cell: Cell) !void {
        // Skip wide char spacers
        if (cell.isSpacer()) return;

        // Apply style changes
        try self.applyStyle(cell.style);

        // Output character
        if (cell.char == 0 or cell.char == ' ') {
            try self.output.append(self.allocator, ' ');
        } else {
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cell.char, &buf) catch 1;
            try self.output.appendSlice(self.allocator, buf[0..len]);
        }

        self.cursor_x += 1;
    }

    fn applyStyle(self: *Self, style: Style) !void {
        if (self.current_style.eql(style)) return;

        // Check if we need full reset
        const need_reset = self.needsReset(self.current_style, style);

        if (need_reset) {
            try self.output.appendSlice(self.allocator, "\x1b[0m");
            self.current_style = .{};
        }

        // Apply attributes
        try self.applyAttrs(style.attrs);

        // Apply foreground
        if (!self.current_style.fg.eql(style.fg)) {
            try self.applyForeground(style.fg);
        }

        // Apply background
        if (!self.current_style.bg.eql(style.bg)) {
            try self.applyBackground(style.bg);
        }

        self.current_style = style;
    }

    fn needsReset(self: *Self, old: Style, new: Style) bool {
        _ = self;
        // Need reset if any attribute is being turned off
        const old_attrs = old.attrs.toU8();
        const new_attrs = new.attrs.toU8();
        return (old_attrs & ~new_attrs) != 0;
    }

    fn applyAttrs(self: *Self, attrs: Attrs) !void {
        if (attrs.bold and !self.current_style.attrs.bold) {
            try self.output.appendSlice(self.allocator, "\x1b[1m");
        }
        if (attrs.dim and !self.current_style.attrs.dim) {
            try self.output.appendSlice(self.allocator, "\x1b[2m");
        }
        if (attrs.italic and !self.current_style.attrs.italic) {
            try self.output.appendSlice(self.allocator, "\x1b[3m");
        }
        if (attrs.underline and !self.current_style.attrs.underline) {
            try self.output.appendSlice(self.allocator, "\x1b[4m");
        }
        if (attrs.blink and !self.current_style.attrs.blink) {
            try self.output.appendSlice(self.allocator, "\x1b[5m");
        }
        if (attrs.reverse and !self.current_style.attrs.reverse) {
            try self.output.appendSlice(self.allocator, "\x1b[7m");
        }
        if (attrs.hidden and !self.current_style.attrs.hidden) {
            try self.output.appendSlice(self.allocator, "\x1b[8m");
        }
        if (attrs.strikethrough and !self.current_style.attrs.strikethrough) {
            try self.output.appendSlice(self.allocator, "\x1b[9m");
        }
    }

    fn applyForeground(self: *Self, fg: Color) !void {
        switch (fg) {
            .default => try self.output.appendSlice(self.allocator, "\x1b[39m"),
            .ansi => |c| {
                if (c < 8) {
                    try self.appendSgr(30 + @as(u8, c));
                } else {
                    try self.appendSgr(90 + @as(u8, c) - 8);
                }
            },
            .palette => |c| {
                try self.output.appendSlice(self.allocator, "\x1b[38;5;");
                try self.appendNumber(c);
                try self.output.append(self.allocator, 'm');
            },
            .rgb => |c| {
                if (self.true_color) {
                    try self.output.appendSlice(self.allocator, "\x1b[38;2;");
                    try self.appendNumber(c.r);
                    try self.output.append(self.allocator, ';');
                    try self.appendNumber(c.g);
                    try self.output.append(self.allocator, ';');
                    try self.appendNumber(c.b);
                    try self.output.append(self.allocator, 'm');
                } else {
                    // Fallback to 256-color
                    try self.output.appendSlice(self.allocator, "\x1b[38;5;");
                    try self.appendNumber(fg.to256());
                    try self.output.append(self.allocator, 'm');
                }
            },
        }
    }

    fn applyBackground(self: *Self, bg: Color) !void {
        switch (bg) {
            .default => try self.output.appendSlice(self.allocator, "\x1b[49m"),
            .ansi => |c| {
                if (c < 8) {
                    try self.appendSgr(40 + @as(u8, c));
                } else {
                    try self.appendSgr(100 + @as(u8, c) - 8);
                }
            },
            .palette => |c| {
                try self.output.appendSlice(self.allocator, "\x1b[48;5;");
                try self.appendNumber(c);
                try self.output.append(self.allocator, 'm');
            },
            .rgb => |c| {
                if (self.true_color) {
                    try self.output.appendSlice(self.allocator, "\x1b[48;2;");
                    try self.appendNumber(c.r);
                    try self.output.append(self.allocator, ';');
                    try self.appendNumber(c.g);
                    try self.output.append(self.allocator, ';');
                    try self.appendNumber(c.b);
                    try self.output.append(self.allocator, 'm');
                } else {
                    try self.output.appendSlice(self.allocator, "\x1b[48;5;");
                    try self.appendNumber(bg.to256());
                    try self.output.append(self.allocator, 'm');
                }
            },
        }
    }

    fn appendSgr(self: *Self, code: u8) !void {
        try self.output.appendSlice(self.allocator, "\x1b[");
        try self.appendNumber(code);
        try self.output.append(self.allocator, 'm');
    }

    fn appendNumber(self: *Self, n: anytype) !void {
        var buf: [10]u8 = undefined;
        var val: u32 = @intCast(n);
        var len: usize = 0;

        if (val == 0) {
            try self.output.append(self.allocator, '0');
            return;
        }

        while (val > 0) {
            buf[len] = @intCast('0' + val % 10);
            val /= 10;
            len += 1;
        }

        // Reverse
        var i: usize = 0;
        while (i < len) : (i += 1) {
            try self.output.append(self.allocator, buf[len - 1 - i]);
        }
    }

    fn moveCursor(self: *Self, x: u16, y: u16) !void {
        // CUP - Cursor Position (1-indexed)
        try self.output.appendSlice(self.allocator, "\x1b[");
        try self.appendNumber(y + 1);
        try self.output.append(self.allocator, ';');
        try self.appendNumber(x + 1);
        try self.output.append(self.allocator, 'H');
        self.cursor_x = x;
        self.cursor_y = y;
    }

    fn copyBuffer(self: *Self, dest: *Buffer, src: *const Buffer) void {
        _ = self;
        const copy_w = @min(dest.width, src.width);
        const copy_h = @min(dest.height, src.height);
        var y: u16 = 0;
        while (y < copy_h) : (y += 1) {
            const dest_row = @as(usize, y) * dest.width;
            const src_row = @as(usize, y) * src.width;
            @memcpy(dest.cells[dest_row..][0..copy_w], src.cells[src_row..][0..copy_w]);
        }
    }

    fn flush(self: *Self) !void {
        if (self.output.items.len == 0) return;
        _ = std.c.write(self.term_fd, self.output.items.ptr, self.output.items.len);
    }
};

/// Terminal mode management
pub const TerminalMode = struct {
    orig_termios: ?std.posix.termios = null,
    fd: std.posix.fd_t,

    const Self = @This();

    pub fn init() Self {
        return .{ .fd = std.posix.STDIN_FILENO };
    }

    /// Enter raw mode
    pub fn enterRaw(self: *Self) !void {
        self.orig_termios = std.posix.tcgetattr(self.fd) catch null;

        if (self.orig_termios) |orig| {
            var raw = orig;

            // Input flags
            raw.iflag.IGNBRK = false;
            raw.iflag.BRKINT = false;
            raw.iflag.PARMRK = false;
            raw.iflag.ISTRIP = false;
            raw.iflag.INLCR = false;
            raw.iflag.IGNCR = false;
            raw.iflag.ICRNL = false;
            raw.iflag.IXON = false;

            // Output flags
            raw.oflag.OPOST = false;

            // Local flags
            raw.lflag.ECHO = false;
            raw.lflag.ECHONL = false;
            raw.lflag.ICANON = false;
            raw.lflag.ISIG = false;
            raw.lflag.IEXTEN = false;

            // Control flags
            raw.cflag.CSIZE = .CS8;
            raw.cflag.PARENB = false;

            // Control chars
            raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
            raw.cc[@intFromEnum(std.posix.V.TIME)] = 1;

            try std.posix.tcsetattr(self.fd, .NOW, raw);
        }
    }

    /// Exit raw mode
    pub fn exitRaw(self: *Self) void {
        if (self.orig_termios) |orig| {
            std.posix.tcsetattr(self.fd, .NOW, orig) catch {};
            self.orig_termios = null;
        }
    }

    /// Enter alternate screen
    pub fn enterAltScreen(self: *Self) void {
        _ = self;
        const seq = "\x1b[?1049h";
        _ = std.c.write(std.posix.STDOUT_FILENO, seq, seq.len);
    }

    /// Exit alternate screen
    pub fn exitAltScreen(self: *Self) void {
        _ = self;
        const seq = "\x1b[?1049l";
        _ = std.c.write(std.posix.STDOUT_FILENO, seq, seq.len);
    }

    /// Enable mouse tracking (SGR mode)
    pub fn enableMouse(self: *Self) void {
        _ = self;
        // Enable button events, drag events, and SGR encoding
        const seq = "\x1b[?1000h\x1b[?1002h\x1b[?1006h";
        _ = std.c.write(std.posix.STDOUT_FILENO, seq, seq.len);
    }

    /// Disable mouse tracking
    pub fn disableMouse(self: *Self) void {
        _ = self;
        const seq = "\x1b[?1006l\x1b[?1002l\x1b[?1000l";
        _ = std.c.write(std.posix.STDOUT_FILENO, seq, seq.len);
    }

    /// Enable focus tracking
    pub fn enableFocus(self: *Self) void {
        _ = self;
        const seq = "\x1b[?1004h";
        _ = std.c.write(std.posix.STDOUT_FILENO, seq, seq.len);
    }

    /// Disable focus tracking
    pub fn disableFocus(self: *Self) void {
        _ = self;
        const seq = "\x1b[?1004l";
        _ = std.c.write(std.posix.STDOUT_FILENO, seq, seq.len);
    }

    /// Clear screen
    pub fn clearScreen(self: *Self) void {
        _ = self;
        const seq = "\x1b[2J\x1b[H";
        _ = std.c.write(std.posix.STDOUT_FILENO, seq, seq.len);
    }
};

test "Renderer basic" {
    var renderer = Renderer.init(std.testing.allocator);
    defer renderer.deinit();

    var buf = try Buffer.init(std.testing.allocator, 10, 5);
    defer buf.deinit();

    _ = buf.writeStr(0, 0, "Hello", Style.default);

    // Can't actually test terminal output in unit tests
    // Just verify no crashes
}
