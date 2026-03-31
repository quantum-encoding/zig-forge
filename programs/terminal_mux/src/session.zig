//! Session Management
//!
//! Manages the hierarchy of sessions, windows, and panes.
//! Each session can have multiple windows, and each window can have multiple panes.

const std = @import("std");
const pty_mod = @import("pty.zig");
const terminal_mod = @import("terminal.zig");
const parser_mod = @import("parser.zig");
const config = @import("config.zig");

const Pty = pty_mod.Pty;
const Terminal = terminal_mod.Terminal;
const Parser = parser_mod.Parser;

/// Unique identifier for panes
pub const PaneId = u32;

/// Pane split direction
pub const SplitDirection = enum {
    horizontal, // Split left/right
    vertical, // Split top/bottom
};

/// Rectangle representing pane dimensions
pub const Rect = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,

    pub fn contains(self: Rect, x: u16, y: u16) bool {
        return x >= self.x and x < self.x + self.width and
            y >= self.y and y < self.y + self.height;
    }

    pub fn splitHorizontal(self: Rect, ratio: f32) struct { left: Rect, right: Rect } {
        const left_width: u16 = @intFromFloat(@as(f32, @floatFromInt(self.width)) * ratio);
        const right_width = self.width - left_width - 1; // -1 for border

        return .{
            .left = .{
                .x = self.x,
                .y = self.y,
                .width = left_width,
                .height = self.height,
            },
            .right = .{
                .x = self.x + left_width + 1,
                .y = self.y,
                .width = right_width,
                .height = self.height,
            },
        };
    }

    pub fn splitVertical(self: Rect, ratio: f32) struct { top: Rect, bottom: Rect } {
        const top_height: u16 = @intFromFloat(@as(f32, @floatFromInt(self.height)) * ratio);
        const bottom_height = self.height - top_height - 1; // -1 for border

        return .{
            .top = .{
                .x = self.x,
                .y = self.y,
                .width = self.width,
                .height = top_height,
            },
            .bottom = .{
                .x = self.x,
                .y = self.y + top_height + 1,
                .width = self.width,
                .height = bottom_height,
            },
        };
    }
};

/// A single pane (terminal + shell)
pub const Pane = struct {
    id: PaneId,
    allocator: std.mem.Allocator,

    // PTY and process
    pty: ?Pty,

    // Terminal emulation
    terminal: Terminal,
    parser: Parser,

    // Pane geometry within window
    rect: Rect,

    // Pane state
    active: bool,
    zoomed: bool,
    title: [256]u8,
    title_len: usize,

    // Working directory
    cwd: [std.fs.max_path_bytes]u8,
    cwd_len: usize,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, id: PaneId, rect: Rect, scrollback: u32) !*Self {
        const pane = try allocator.create(Self);
        errdefer allocator.destroy(pane);

        pane.* = .{
            .id = id,
            .allocator = allocator,
            .pty = null,
            .terminal = try Terminal.init(allocator, rect.height, rect.width, scrollback),
            .parser = Parser.init(),
            .rect = rect,
            .active = false,
            .zoomed = false,
            .title = undefined,
            .title_len = 0,
            .cwd = undefined,
            .cwd_len = 0,
        };

        return pane;
    }

    pub fn deinit(self: *Self) void {
        if (self.pty) |*p| {
            p.close();
        }
        self.terminal.deinit();
        self.allocator.destroy(self);
    }

    /// Spawn a shell in this pane
    pub fn spawn(self: *Self, shell: []const u8, env: [*:null]const ?[*:0]const u8) !void {
        var pty = try Pty.create();
        errdefer pty.close();

        // Set PTY size to match terminal
        try pty.setSize(self.rect.height, self.rect.width);

        // Build argv
        var shell_buf: [256:0]u8 = undefined;
        @memcpy(shell_buf[0..shell.len], shell);
        shell_buf[shell.len] = 0;

        const argv = [_][*:0]const u8{&shell_buf};
        try pty.spawn(&argv, env);

        self.pty = pty;
    }

    /// Process input data from the PTY
    pub fn processOutput(self: *Self, data: []const u8) void {
        for (data) |byte| {
            const action = self.parser.feed(byte);
            parser_mod.applyAction(&self.terminal, action);
        }
    }

    /// Send input to the PTY
    pub fn sendInput(self: *Self, data: []const u8) !void {
        if (self.pty) |*p| {
            _ = try p.write(data);
        }
    }

    /// Read available output from PTY
    pub fn readOutput(self: *Self, buf: []u8) !usize {
        if (self.pty) |*p| {
            return p.read(buf);
        }
        return 0;
    }

    /// Resize the pane
    pub fn resize(self: *Self, rect: Rect) !void {
        self.rect = rect;
        try self.terminal.resize(rect.height, rect.width);
        if (self.pty) |*p| {
            try p.setSize(rect.height, rect.width);
        }
    }

    /// Check if the pane's process is still alive
    pub fn isAlive(self: *const Self) bool {
        if (self.pty) |*p| {
            return p.isAlive();
        }
        return false;
    }

    /// Get the master fd for polling
    pub fn getFd(self: *const Self) ?std.posix.fd_t {
        if (self.pty) |p| {
            return p.master_fd;
        }
        return null;
    }
};

/// A window containing panes
pub const Window = struct {
    allocator: std.mem.Allocator,
    panes: std.ArrayListUnmanaged(*Pane),
    active_pane_idx: usize,
    name: [64]u8,
    name_len: usize,
    index: u8, // Window number within session
    layout: Layout,
    next_pane_id: PaneId,

    pub const Layout = enum {
        single,
        horizontal_split,
        vertical_split,
        tiled,
    };

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, index: u8, rect: Rect, scrollback: u32) !*Self {
        const window = try allocator.create(Self);
        errdefer allocator.destroy(window);

        window.* = .{
            .allocator = allocator,
            .panes = .empty,
            .active_pane_idx = 0,
            .name = undefined,
            .name_len = 0,
            .index = index,
            .layout = .single,
            .next_pane_id = 1,
        };

        // Create initial pane
        const pane = try Pane.init(allocator, window.next_pane_id, rect, scrollback);
        window.next_pane_id += 1;
        pane.active = true;

        try window.panes.append(allocator, pane);

        return window;
    }

    pub fn deinit(self: *Self) void {
        for (self.panes.items) |pane| {
            pane.deinit();
        }
        self.panes.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Get the currently active pane
    pub fn getActivePane(self: *Self) *Pane {
        return self.panes.items[self.active_pane_idx];
    }

    /// Split the active pane
    pub fn split(self: *Self, direction: SplitDirection, scrollback: u32) !*Pane {
        const active = self.getActivePane();
        const rect = active.rect;

        // Calculate new rects based on direction
        var active_rect: Rect = undefined;
        var new_rect: Rect = undefined;

        switch (direction) {
            .horizontal => {
                const split_result = rect.splitHorizontal(0.5);
                active_rect = split_result.left;
                new_rect = split_result.right;
            },
            .vertical => {
                const split_result = rect.splitVertical(0.5);
                active_rect = split_result.top;
                new_rect = split_result.bottom;
            },
        }

        // Resize active pane
        try active.resize(active_rect);

        // Create new pane
        const new_pane = try Pane.init(self.allocator, self.next_pane_id, new_rect, scrollback);
        self.next_pane_id += 1;

        try self.panes.append(self.allocator, new_pane);

        // Update layout
        self.layout = switch (direction) {
            .horizontal => .horizontal_split,
            .vertical => .vertical_split,
        };

        return new_pane;
    }

    /// Focus next pane
    pub fn focusNext(self: *Self) void {
        self.panes.items[self.active_pane_idx].active = false;
        self.active_pane_idx = (self.active_pane_idx + 1) % self.panes.items.len;
        self.panes.items[self.active_pane_idx].active = true;
    }

    /// Focus previous pane
    pub fn focusPrev(self: *Self) void {
        self.panes.items[self.active_pane_idx].active = false;
        if (self.active_pane_idx == 0) {
            self.active_pane_idx = self.panes.items.len - 1;
        } else {
            self.active_pane_idx -= 1;
        }
        self.panes.items[self.active_pane_idx].active = true;
    }

    /// Focus pane by ID
    pub fn focusPane(self: *Self, pane_id: PaneId) bool {
        for (self.panes.items, 0..) |pane, i| {
            if (pane.id == pane_id) {
                self.panes.items[self.active_pane_idx].active = false;
                self.active_pane_idx = i;
                pane.active = true;
                return true;
            }
        }
        return false;
    }

    /// Remove a pane
    pub fn removePane(self: *Self, pane_id: PaneId) bool {
        for (self.panes.items, 0..) |pane, i| {
            if (pane.id == pane_id) {
                pane.deinit();
                _ = self.panes.orderedRemove(i);

                // Adjust active pane index
                if (self.panes.items.len > 0) {
                    if (self.active_pane_idx >= self.panes.items.len) {
                        self.active_pane_idx = self.panes.items.len - 1;
                    }
                    self.panes.items[self.active_pane_idx].active = true;
                }

                return true;
            }
        }
        return false;
    }

    /// Resize all panes to fit new window size
    pub fn resize(self: *Self, rect: Rect) !void {
        if (self.panes.items.len == 0) return;

        if (self.panes.items.len == 1) {
            try self.panes.items[0].resize(rect);
            return;
        }

        // For now, simple equal split
        switch (self.layout) {
            .single => {
                try self.panes.items[0].resize(rect);
            },
            .horizontal_split => {
                const width_per_pane = rect.width / @as(u16, @intCast(self.panes.items.len));
                for (self.panes.items, 0..) |pane, i| {
                    const pane_rect = Rect{
                        .x = rect.x + @as(u16, @intCast(i)) * width_per_pane,
                        .y = rect.y,
                        .width = width_per_pane - 1, // -1 for border
                        .height = rect.height,
                    };
                    try pane.resize(pane_rect);
                }
            },
            .vertical_split => {
                const height_per_pane = rect.height / @as(u16, @intCast(self.panes.items.len));
                for (self.panes.items, 0..) |pane, i| {
                    const pane_rect = Rect{
                        .x = rect.x,
                        .y = rect.y + @as(u16, @intCast(i)) * height_per_pane,
                        .width = rect.width,
                        .height = height_per_pane - 1, // -1 for border
                    };
                    try pane.resize(pane_rect);
                }
            },
            .tiled => {
                // Implement tiled layout: divide evenly into grid
                const num_panes = self.panes.items.len;

                // Calculate grid dimensions: aim for roughly square layout
                var cols: u16 = 1;
                var rows: u16 = 1;

                if (num_panes <= 1) {
                    cols = 1;
                    rows = 1;
                } else if (num_panes == 2) {
                    cols = 2;
                    rows = 1;
                } else if (num_panes <= 4) {
                    cols = 2;
                    rows = 2;
                } else {
                    // For 5+ panes, calculate grid to fit all panes
                    cols = @intCast((std.math.sqrt(num_panes) + 1));
                    rows = @intCast((num_panes + cols - 1) / cols); // Ceiling division
                }

                const width_per_pane = if (cols > 1) rect.width / cols else rect.width;
                const height_per_pane = if (rows > 1) rect.height / rows else rect.height;

                var pane_idx: usize = 0;
                var row: u16 = 0;
                while (row < rows and pane_idx < num_panes) : (row += 1) {
                    var col: u16 = 0;
                    while (col < cols and pane_idx < num_panes) : (col += 1) {
                        const pane = self.panes.items[pane_idx];

                        // Calculate position and size
                        const pane_x = rect.x + col * width_per_pane;
                        const pane_y = rect.y + row * height_per_pane;

                        // Check if this is the last column/row for uneven grids
                        const is_last_col = (col == cols - 1);
                        const is_last_row = (row == rows - 1);

                        var pane_width = width_per_pane;
                        var pane_height = height_per_pane;

                        // For last column, use remaining width
                        if (is_last_col) {
                            pane_width = rect.x + rect.width - pane_x;
                        }

                        // For last row, use remaining height
                        if (is_last_row) {
                            pane_height = rect.y + rect.height - pane_y;
                        }

                        // Account for borders between panes
                        if (!is_last_col and pane_width > 1) pane_width -= 1;
                        if (!is_last_row and pane_height > 1) pane_height -= 1;

                        const pane_rect = Rect{
                            .x = pane_x,
                            .y = pane_y,
                            .width = pane_width,
                            .height = pane_height,
                        };

                        try pane.resize(pane_rect);
                        pane_idx += 1;
                    }
                }
            },
        }
    }

    /// Set window name
    pub fn setName(self: *Self, name: []const u8) void {
        const len = @min(name.len, self.name.len);
        @memcpy(self.name[0..len], name[0..len]);
        self.name_len = len;
    }

    /// Get window name
    pub fn getName(self: *const Self) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// A session containing windows
pub const Session = struct {
    allocator: std.mem.Allocator,
    windows: std.ArrayListUnmanaged(*Window),
    active_window_idx: usize,
    last_window_idx: ?usize,
    name: [64]u8,
    name_len: usize,
    rect: Rect, // Total terminal size

    // Configuration
    scrollback_lines: u32,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, name: []const u8, rect: Rect, scrollback: u32) !*Self {
        const session = try allocator.create(Self);
        errdefer allocator.destroy(session);

        const name_len = @min(name.len, 64);
        var name_buf: [64]u8 = undefined;
        @memcpy(name_buf[0..name_len], name[0..name_len]);

        session.* = .{
            .allocator = allocator,
            .windows = .empty,
            .active_window_idx = 0,
            .last_window_idx = null,
            .name = name_buf,
            .name_len = name_len,
            .rect = rect,
            .scrollback_lines = scrollback,
        };

        // Create initial window
        const window = try Window.init(allocator, 0, rect, scrollback);
        try session.windows.append(allocator, window);

        return session;
    }

    pub fn deinit(self: *Self) void {
        for (self.windows.items) |window| {
            window.deinit();
        }
        self.windows.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Get the currently active window
    pub fn getActiveWindow(self: *Self) *Window {
        return self.windows.items[self.active_window_idx];
    }

    /// Create a new window
    pub fn createWindow(self: *Self) !*Window {
        const index: u8 = @intCast(self.windows.items.len);
        const window = try Window.init(self.allocator, index, self.rect, self.scrollback_lines);
        try self.windows.append(self.allocator, window);
        return window;
    }

    /// Switch to window by index
    pub fn selectWindow(self: *Self, index: usize) bool {
        if (index < self.windows.items.len) {
            self.last_window_idx = self.active_window_idx;
            self.active_window_idx = index;
            return true;
        }
        return false;
    }

    /// Switch to next window
    pub fn nextWindow(self: *Self) void {
        self.last_window_idx = self.active_window_idx;
        self.active_window_idx = (self.active_window_idx + 1) % self.windows.items.len;
    }

    /// Switch to previous window
    pub fn prevWindow(self: *Self) void {
        self.last_window_idx = self.active_window_idx;
        if (self.active_window_idx == 0) {
            self.active_window_idx = self.windows.items.len - 1;
        } else {
            self.active_window_idx -= 1;
        }
    }

    /// Switch to last window
    pub fn lastWindow(self: *Self) void {
        if (self.last_window_idx) |last| {
            const current = self.active_window_idx;
            self.active_window_idx = last;
            self.last_window_idx = current;
        }
    }

    /// Remove window by index
    pub fn removeWindow(self: *Self, index: usize) bool {
        if (index >= self.windows.items.len) return false;
        if (self.windows.items.len <= 1) return false; // Keep at least one window

        const window = self.windows.items[index];
        window.deinit();
        _ = self.windows.orderedRemove(index);

        // Adjust indices
        if (self.active_window_idx >= self.windows.items.len) {
            self.active_window_idx = self.windows.items.len - 1;
        }
        self.last_window_idx = null;

        // Re-index remaining windows
        for (self.windows.items, 0..) |w, i| {
            w.index = @intCast(i);
        }

        return true;
    }

    /// Resize all windows
    pub fn resize(self: *Self, rect: Rect) !void {
        self.rect = rect;
        for (self.windows.items) |window| {
            try window.resize(rect);
        }
    }

    /// Set session name
    pub fn setName(self: *Self, name: []const u8) void {
        const len = @min(name.len, self.name.len);
        @memcpy(self.name[0..len], name[0..len]);
        self.name_len = len;
    }

    /// Get session name
    pub fn getName(self: *const Self) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// Session manager - holds all sessions
pub const SessionManager = struct {
    allocator: std.mem.Allocator,
    sessions: std.ArrayListUnmanaged(*Session),
    active_session_idx: usize,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .sessions = .empty,
            .active_session_idx = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.sessions.items) |session| {
            session.deinit();
        }
        self.sessions.deinit(self.allocator);
    }

    /// Create a new session
    pub fn createSession(self: *Self, name: []const u8, rect: Rect, scrollback: u32) !*Session {
        const session = try Session.init(self.allocator, name, rect, scrollback);
        try self.sessions.append(self.allocator, session);
        return session;
    }

    /// Get active session
    pub fn getActiveSession(self: *Self) ?*Session {
        if (self.sessions.items.len == 0) return null;
        return self.sessions.items[self.active_session_idx];
    }

    /// Switch to session by name
    pub fn selectSession(self: *Self, name: []const u8) bool {
        for (self.sessions.items, 0..) |session, i| {
            if (std.mem.eql(u8, session.getName(), name)) {
                self.active_session_idx = i;
                return true;
            }
        }
        return false;
    }

    /// Remove session by name
    pub fn removeSession(self: *Self, name: []const u8) bool {
        for (self.sessions.items, 0..) |session, i| {
            if (std.mem.eql(u8, session.getName(), name)) {
                session.deinit();
                _ = self.sessions.orderedRemove(i);

                if (self.sessions.items.len > 0) {
                    if (self.active_session_idx >= self.sessions.items.len) {
                        self.active_session_idx = self.sessions.items.len - 1;
                    }
                }
                return true;
            }
        }
        return false;
    }

    /// Get all sessions
    pub fn getSessions(self: *const Self) []*Session {
        return self.sessions.items;
    }

    /// Get count of sessions
    pub fn count(self: *const Self) usize {
        return self.sessions.items.len;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "rect split horizontal" {
    const rect = Rect{ .x = 0, .y = 0, .width = 80, .height = 24 };
    const split = rect.splitHorizontal(0.5);

    try std.testing.expectEqual(@as(u16, 0), split.left.x);
    try std.testing.expectEqual(@as(u16, 40), split.left.width);
    try std.testing.expectEqual(@as(u16, 41), split.right.x);
}

test "rect split vertical" {
    const rect = Rect{ .x = 0, .y = 0, .width = 80, .height = 24 };
    const split = rect.splitVertical(0.5);

    try std.testing.expectEqual(@as(u16, 0), split.top.y);
    try std.testing.expectEqual(@as(u16, 12), split.top.height);
    try std.testing.expectEqual(@as(u16, 13), split.bottom.y);
}

test "session manager create session" {
    const allocator = std.testing.allocator;

    var manager = SessionManager.init(allocator);
    defer manager.deinit();

    const rect = Rect{ .x = 0, .y = 0, .width = 80, .height = 24 };
    const session = try manager.createSession("test", rect, 100);

    try std.testing.expectEqualStrings("test", session.getName());
    try std.testing.expectEqual(@as(usize, 1), manager.count());
}

test "window split" {
    const allocator = std.testing.allocator;

    const rect = Rect{ .x = 0, .y = 0, .width = 80, .height = 24 };
    const window = try Window.init(allocator, 0, rect, 100);
    defer window.deinit();

    try std.testing.expectEqual(@as(usize, 1), window.panes.items.len);

    _ = try window.split(.horizontal, 100);

    try std.testing.expectEqual(@as(usize, 2), window.panes.items.len);
}
