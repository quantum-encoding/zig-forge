// Desktop state manager — central orchestrator for the Zigix TUI desktop environment.
// Manages the window list, focus, layout modes, and PTY lifecycle.

const std = @import("std");
const platform = @import("platform.zig");
const tui = if (platform.is_linux) @import("zig_tui") else @import("tui_pure.zig");
const Window = @import("window.zig").Window;
const theme = @import("theme.zig");

const mux = if (platform.is_linux) @import("terminal_mux") else struct {
    pub const Pane = void;
    pub const Rect = struct { x: u16, y: u16, width: u16, height: u16 };
};

const Pane = mux.Pane;
const MuxRect = mux.Rect;
const TuiRect = tui.Rect;

pub const MAX_WINDOWS: usize = 16;
const DEFAULT_SHELL = "/bin/bash";
const DEFAULT_SCROLLBACK: u32 = 4000;

pub const Layout = enum {
    single,
    split_h,
    split_v,
    tiled,
};

pub const Desktop = struct {
    windows: [MAX_WINDOWS]Window = undefined,
    window_count: u8 = 0,
    focused_idx: u8 = 0,
    layout: Layout = .tiled,
    next_id: u16 = 1,
    allocator: std.mem.Allocator,

    // Content area (everything above the panel)
    content_x: u16 = 0,
    content_y: u16 = 0,
    content_w: u16 = 80,
    content_h: u16 = 22,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        var i: usize = 0;
        while (i < self.window_count) : (i += 1) {
            self.windows[i].deinit();
        }
        self.window_count = 0;
    }

    /// Spawn a new window running the given shell command.
    pub fn createWindow(self: *Self, shell: []const u8) !void {
        if (self.window_count >= MAX_WINDOWS) return error.TooManyWindows;

        const base_name = baseName(shell);
        const idx = self.window_count;

        if (platform.is_linux) {
            // Linux: use terminal_mux Pane with PTY
            const pane_rect = MuxRect{ .x = 0, .y = 0, .width = 80, .height = 24 };
            const pane = try Pane.init(self.allocator, self.next_id, pane_rect, DEFAULT_SCROLLBACK);
            errdefer pane.deinit();

            const env = std.c.environ;
            try pane.spawn(shell, env);
            setNonBlocking(pane.getFd()) catch {};

            self.windows[idx] = Window.init(pane, self.next_id, base_name);
        } else {
            // Zigix: spawn process via fork+execve
            const handle = try platform.spawnProcess(shell, self.allocator);
            self.windows[idx] = Window.initZigix(handle, self.next_id, base_name);
        }

        self.window_count += 1;
        self.next_id +%= 1;
        self.focused_idx = @intCast(idx);
        self.updateFocus();
        self.recalculateLayout();
    }

    /// Spawn a window with the default shell.
    pub fn createDefaultWindow(self: *Self) !void {
        const shell = if (platform.is_zigix) "/bin/zsh" else DEFAULT_SHELL;
        try self.createWindow(shell);
    }

    /// Close the currently focused window.
    pub fn closeFocused(self: *Self) void {
        if (self.window_count == 0) return;

        const idx: usize = self.focused_idx;
        self.windows[idx].deinit();

        // Shift remaining windows down
        var i: usize = idx;
        while (i + 1 < self.window_count) : (i += 1) {
            self.windows[i] = self.windows[i + 1];
        }
        self.window_count -= 1;

        // Adjust focus
        if (self.window_count == 0) {
            self.focused_idx = 0;
        } else if (self.focused_idx >= self.window_count) {
            self.focused_idx = self.window_count - 1;
        }
        self.updateFocus();
        self.recalculateLayout();
    }

    /// Close a specific window by index.
    pub fn closeWindow(self: *Self, idx: usize) void {
        if (idx >= self.window_count) return;

        self.windows[idx].deinit();

        var i: usize = idx;
        while (i + 1 < self.window_count) : (i += 1) {
            self.windows[i] = self.windows[i + 1];
        }
        self.window_count -= 1;

        if (self.window_count == 0) {
            self.focused_idx = 0;
        } else if (self.focused_idx >= self.window_count) {
            self.focused_idx = self.window_count - 1;
        }
        self.updateFocus();
        self.recalculateLayout();
    }

    /// Cycle focus to the next window.
    pub fn focusNext(self: *Self) void {
        if (self.window_count <= 1) return;
        self.focused_idx = @intCast((@as(usize, self.focused_idx) + 1) % self.window_count);
        self.updateFocus();
    }

    /// Cycle focus to the previous window.
    pub fn focusPrev(self: *Self) void {
        if (self.window_count <= 1) return;
        if (self.focused_idx == 0) {
            self.focused_idx = self.window_count - 1;
        } else {
            self.focused_idx -= 1;
        }
        self.updateFocus();
    }

    /// Focus window by number (1-based, maps to 0-based index).
    pub fn focusByNumber(self: *Self, n: u8) void {
        if (n == 0 or n > self.window_count) return;
        self.focused_idx = n - 1;
        self.updateFocus();
    }

    /// Set the layout mode and recalculate.
    pub fn setLayout(self: *Self, new_layout: Layout) void {
        self.layout = new_layout;
        self.recalculateLayout();
    }

    /// Get the currently focused window (if any).
    pub fn getFocused(self: *Self) ?*Window {
        if (self.window_count == 0) return null;
        return &self.windows[self.focused_idx];
    }

    /// Set the content area (called on resize or panel change).
    pub fn setContentArea(self: *Self, x: u16, y: u16, w: u16, h: u16) void {
        self.content_x = x;
        self.content_y = y;
        self.content_w = w;
        self.content_h = h;
        self.recalculateLayout();
    }

    /// Poll all windows for PTY output. Called on each tick.
    pub fn pollAllOutputs(self: *Self) void {
        var i: usize = 0;
        while (i < self.window_count) : (i += 1) {
            _ = self.windows[i].pollOutput();
        }
    }

    /// Reap dead windows (process exited). Returns true if any were removed.
    pub fn reapDead(self: *Self) bool {
        var removed = false;
        var i: usize = 0;
        while (i < self.window_count) {
            if (!self.windows[i].isAlive()) {
                self.closeWindow(i);
                removed = true;
                // Don't increment — array shifted down
            } else {
                i += 1;
            }
        }
        return removed;
    }

    /// Get all windows as a slice (for rendering).
    pub fn getWindows(self: *Self) []Window {
        return self.windows[0..self.window_count];
    }

    // ── Layout engine ────────────────────────────────────────────────────────

    fn recalculateLayout(self: *Self) void {
        if (self.window_count == 0) return;

        const x = self.content_x;
        const y = self.content_y;
        const w = self.content_w;
        const h = self.content_h;

        switch (self.layout) {
            .single => self.layoutSingle(x, y, w, h),
            .split_h => self.layoutSplitH(x, y, w, h),
            .split_v => self.layoutSplitV(x, y, w, h),
            .tiled => self.layoutTiled(x, y, w, h),
        }
    }

    fn layoutSingle(self: *Self, x: u16, y: u16, w: u16, h: u16) void {
        // Only the focused window is visible at full size
        self.windows[self.focused_idx].setRect(x, y, w, h);
    }

    fn layoutSplitH(self: *Self, x: u16, y: u16, w: u16, h: u16) void {
        if (self.window_count == 1) {
            self.windows[0].setRect(x, y, w, h);
            return;
        }

        const left_w = w / 2;
        const right_w = w - left_w;

        self.windows[0].setRect(x, y, left_w, h);

        if (self.window_count >= 2) {
            self.windows[1].setRect(x + left_w, y, right_w, h);
        }

        // Additional windows stack in the right pane (evenly split vertically)
        if (self.window_count > 2) {
            const count: u16 = @intCast(self.window_count - 1);
            const per_h = h / count;
            var i: u16 = 1;
            while (i < count + 1) : (i += 1) {
                const wy = y + (i - 1) * per_h;
                const wh = if (i == count) h - (i - 1) * per_h else per_h;
                self.windows[i].setRect(x + left_w, wy, right_w, wh);
            }
        }
    }

    fn layoutSplitV(self: *Self, x: u16, y: u16, w: u16, h: u16) void {
        if (self.window_count == 1) {
            self.windows[0].setRect(x, y, w, h);
            return;
        }

        const top_h = h / 2;
        const bot_h = h - top_h;

        self.windows[0].setRect(x, y, w, top_h);

        if (self.window_count >= 2) {
            self.windows[1].setRect(x, y + top_h, w, bot_h);
        }

        // Additional windows stack in the bottom half
        if (self.window_count > 2) {
            const count: u16 = @intCast(self.window_count - 1);
            const per_w = w / count;
            var i: u16 = 1;
            while (i < count + 1) : (i += 1) {
                const wx = x + (i - 1) * per_w;
                const ww = if (i == count) w - (i - 1) * per_w else per_w;
                self.windows[i].setRect(wx, y + top_h, ww, bot_h);
            }
        }
    }

    fn layoutTiled(self: *Self, x: u16, y: u16, w: u16, h: u16) void {
        const count: u16 = @intCast(self.window_count);

        if (count == 1) {
            self.windows[0].setRect(x, y, w, h);
            return;
        }

        // Grid calculation: find cols/rows that fit count
        const cols = tiledCols(count);
        const rows = (count + cols - 1) / cols;

        var idx: u16 = 0;
        var row: u16 = 0;
        while (row < rows) : (row += 1) {
            // How many windows in this row
            const remaining = count - idx;
            const in_this_row = if (remaining < cols) remaining else cols;

            var col: u16 = 0;
            while (col < in_this_row) : (col += 1) {
                const wx = x + col * (w / in_this_row);
                const wy = y + row * (h / rows);
                const ww = if (col + 1 == in_this_row) w - col * (w / in_this_row) else w / in_this_row;
                const wh = if (row + 1 == rows) h - row * (h / rows) else h / rows;

                self.windows[idx].setRect(wx, wy, ww, wh);
                idx += 1;
            }
        }
    }

    fn updateFocus(self: *Self) void {
        var i: usize = 0;
        while (i < self.window_count) : (i += 1) {
            self.windows[i].focused = (i == self.focused_idx);
        }
    }
};

// ── Helpers ──────────────────────────────────────────────────────────────────

/// Calculate number of columns for a tiled grid.
fn tiledCols(n: u16) u16 {
    if (n <= 1) return 1;
    if (n <= 2) return 2;
    if (n <= 4) return 2;
    if (n <= 6) return 3;
    if (n <= 9) return 3;
    return 4;
}

/// Extract the base filename from a path (e.g., "/bin/bash" → "bash").
fn baseName(path: []const u8) []const u8 {
    var i = path.len;
    while (i > 0) : (i -= 1) {
        if (path[i - 1] == '/') return path[i..];
    }
    return path;
}

/// Set a file descriptor to non-blocking mode (Linux only).
fn setNonBlocking(fd_opt: anytype) !void {
    if (!platform.is_linux) return;
    const posix = std.posix;
    const c = @cImport({ @cInclude("fcntl.h"); });
    const fd: posix.fd_t = fd_opt orelse return;
    const flags = c.fcntl(fd, c.F_GETFL, @as(c_int, 0));
    if (flags == -1) return error.FcntlFailed;
    const rc = c.fcntl(fd, c.F_SETFL, flags | c.O_NONBLOCK);
    if (rc == -1) return error.FcntlFailed;
}
