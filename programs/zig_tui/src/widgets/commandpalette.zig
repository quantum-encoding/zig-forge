//! Command Palette widget - quick command search and execution
//!
//! Provides a searchable command interface similar to VS Code's Ctrl+Shift+P.

const std = @import("std");
const core = @import("../core/core.zig");
const widget_mod = @import("../widget/mod.zig");
const input_mod = @import("../input/input.zig");

pub const Buffer = core.Buffer;
pub const Rect = core.Rect;
pub const Size = core.Size;
pub const Style = core.Style;
pub const Color = core.Color;
pub const Widget = widget_mod.Widget;
pub const makeWidget = widget_mod.makeWidget;
pub const Event = input_mod.Event;
pub const Key = input_mod.Key;

/// Command definition
pub const Command = struct {
    id: []const u8,
    label: []const u8,
    description: ?[]const u8,
    shortcut: ?[]const u8,
    category: ?[]const u8,
    enabled: bool,
    data: ?*anyopaque,
};

/// Command execution callback
pub const CommandCallback = *const fn (*CommandPalette, *const Command) void;

/// Command palette widget
pub const CommandPalette = struct {
    allocator: std.mem.Allocator,

    // Commands
    commands: std.ArrayListUnmanaged(Command),
    filtered: std.ArrayListUnmanaged(usize), // Indices into commands

    // State
    visible: bool,
    query: [256]u8,
    query_len: usize,
    selected_idx: usize,
    scroll_offset: usize,

    // Options
    max_visible: u16,
    show_shortcuts: bool,
    show_descriptions: bool,
    fuzzy_search: bool,

    // Styles
    background_style: Style,
    border_style: Style,
    input_style: Style,
    item_style: Style,
    selected_style: Style,
    match_style: Style,
    shortcut_style: Style,
    description_style: Style,
    placeholder_style: Style,

    // Callback
    on_execute: ?CommandCallback,
    on_cancel: ?*const fn (*CommandPalette) void,

    // Dimensions
    width: u16,
    height: u16,

    const Self = @This();

    /// Get Widget interface
    pub fn widget(self: *Self) Widget {
        return makeWidget(Self, self);
    }

    /// Create a new CommandPalette
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .commands = .{},
            .filtered = .{},
            .visible = false,
            .query = [_]u8{0} ** 256,
            .query_len = 0,
            .selected_idx = 0,
            .scroll_offset = 0,
            .max_visible = 10,
            .show_shortcuts = true,
            .show_descriptions = true,
            .fuzzy_search = true,
            .background_style = Style{ .bg = Color.bright_black },
            .border_style = Style{ .fg = Color.cyan },
            .input_style = Style{ .fg = Color.white },
            .item_style = Style{ .fg = Color.white },
            .selected_style = Style{ .fg = Color.black, .bg = Color.cyan },
            .match_style = Style{ .fg = Color.yellow, .attrs = .{ .bold = true } },
            .shortcut_style = Style{ .fg = Color.gray },
            .description_style = Style{ .fg = Color.gray },
            .placeholder_style = Style{ .fg = Color.gray },
            .on_execute = null,
            .on_cancel = null,
            .width = 60,
            .height = 15,
        };
    }

    pub fn deinit(self: *Self) void {
        self.commands.deinit(self.allocator);
        self.filtered.deinit(self.allocator);
    }

    /// Register a command
    pub fn addCommand(self: *Self, command: Command) !void {
        try self.commands.append(self.allocator, command);
    }

    /// Register multiple commands
    pub fn addCommands(self: *Self, commands: []const Command) !void {
        for (commands) |cmd| {
            try self.addCommand(cmd);
        }
    }

    /// Clear all commands
    pub fn clearCommands(self: *Self) void {
        self.commands.clearRetainingCapacity();
        self.filtered.clearRetainingCapacity();
    }

    /// Show the palette
    pub fn show(self: *Self) !void {
        self.visible = true;
        self.query_len = 0;
        @memset(&self.query, 0);
        self.selected_idx = 0;
        self.scroll_offset = 0;
        try self.updateFilter();
    }

    /// Hide the palette
    pub fn hide(self: *Self) void {
        self.visible = false;
    }

    /// Check if visible
    pub fn isVisible(self: *const Self) bool {
        return self.visible;
    }

    /// Set execution callback
    pub fn onExecute(self: *Self, callback: CommandCallback) *Self {
        self.on_execute = callback;
        return self;
    }

    /// Set cancel callback
    pub fn onCancel(self: *Self, callback: *const fn (*CommandPalette) void) *Self {
        self.on_cancel = callback;
        return self;
    }

    /// Update filtered results based on query
    fn updateFilter(self: *Self) !void {
        self.filtered.clearRetainingCapacity();

        const query_slice = self.query[0..self.query_len];

        for (self.commands.items, 0..) |cmd, i| {
            if (!cmd.enabled) continue;

            if (query_slice.len == 0) {
                // No query - show all enabled commands
                try self.filtered.append(self.allocator, i);
            } else if (self.fuzzy_search) {
                // Fuzzy match
                if (self.fuzzyMatch(cmd.label, query_slice) or
                    (cmd.category != null and self.fuzzyMatch(cmd.category.?, query_slice)))
                {
                    try self.filtered.append(self.allocator, i);
                }
            } else {
                // Substring match (case insensitive)
                if (self.containsIgnoreCase(cmd.label, query_slice) or
                    (cmd.category != null and self.containsIgnoreCase(cmd.category.?, query_slice)))
                {
                    try self.filtered.append(self.allocator, i);
                }
            }
        }

        // Reset selection
        self.selected_idx = 0;
        self.scroll_offset = 0;
    }

    fn fuzzyMatch(_: *Self, haystack: []const u8, needle: []const u8) bool {
        var needle_idx: usize = 0;
        for (haystack) |c| {
            if (needle_idx >= needle.len) break;
            const nc = needle[needle_idx];
            if (std.ascii.toLower(c) == std.ascii.toLower(nc)) {
                needle_idx += 1;
            }
        }
        return needle_idx == needle.len;
    }

    fn containsIgnoreCase(_: *Self, haystack: []const u8, needle: []const u8) bool {
        if (needle.len > haystack.len) return false;

        var i: usize = 0;
        outer: while (i <= haystack.len - needle.len) : (i += 1) {
            for (needle, 0..) |nc, j| {
                if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(nc)) {
                    continue :outer;
                }
            }
            return true;
        }
        return false;
    }

    /// Execute selected command
    fn executeSelected(self: *Self) void {
        if (self.selected_idx < self.filtered.items.len) {
            const cmd_idx = self.filtered.items[self.selected_idx];
            if (cmd_idx < self.commands.items.len) {
                const cmd = &self.commands.items[cmd_idx];
                self.visible = false;
                if (self.on_execute) |cb| {
                    cb(self, cmd);
                }
            }
        }
    }

    // Widget interface

    pub fn render(self: *Self, area: Rect, buf: *Buffer, state: Widget.RenderState) void {
        _ = state;
        if (!self.visible) return;

        // Calculate centered position
        const palette_x = area.x + (area.width - self.width) / 2;
        const palette_y = area.y + 2; // Near top

        const palette_area = Rect{
            .x = palette_x,
            .y = palette_y,
            .width = @min(self.width, area.width),
            .height = @min(self.height, area.height),
        };

        // Draw background
        buf.fill(palette_area, core.Cell.styled(' ', self.background_style));

        // Draw border
        buf.drawBorder(palette_area, .rounded, self.border_style);

        // Draw search icon and input
        const input_y = palette_y + 1;
        buf.setChar(palette_x + 2, input_y, '>', self.border_style);

        // Draw query or placeholder
        if (self.query_len == 0) {
            _ = buf.writeTruncated(palette_x + 4, input_y, self.width - 6, "Type to search commands...", self.placeholder_style);
        } else {
            _ = buf.writeTruncated(palette_x + 4, input_y, self.width - 6, self.query[0..self.query_len], self.input_style);
        }

        // Draw cursor
        const cursor_x = palette_x + 4 + @as(u16, @intCast(self.query_len));
        if (cursor_x < palette_x + self.width - 2) {
            buf.setChar(cursor_x, input_y, '_', Style{ .fg = Color.white, .attrs = .{ .bold = true } });
        }

        // Draw separator
        buf.hLine(palette_x + 1, input_y + 1, self.width - 2, '─', self.border_style);

        // Draw results
        const results_y = input_y + 2;
        const max_results = @min(self.max_visible, self.height - 4);

        // Ensure selection is visible
        if (self.selected_idx < self.scroll_offset) {
            self.scroll_offset = self.selected_idx;
        } else if (self.selected_idx >= self.scroll_offset + max_results) {
            self.scroll_offset = self.selected_idx - max_results + 1;
        }

        var y: u16 = 0;
        while (y < max_results) : (y += 1) {
            const result_idx = self.scroll_offset + y;
            if (result_idx >= self.filtered.items.len) break;

            const cmd_idx = self.filtered.items[result_idx];
            const cmd = self.commands.items[cmd_idx];
            const is_selected = result_idx == self.selected_idx;

            const row_y = results_y + y;
            const style = if (is_selected) self.selected_style else self.item_style;

            // Fill background for selected
            if (is_selected) {
                buf.fill(
                    Rect{ .x = palette_x + 1, .y = row_y, .width = self.width - 2, .height = 1 },
                    core.Cell.styled(' ', style),
                );
            }

            var x = palette_x + 2;

            // Draw category if present
            if (cmd.category) |cat| {
                _ = buf.writeStr(x, row_y, cat, if (is_selected) style else self.description_style);
                x += @intCast(cat.len);
                _ = buf.writeStr(x, row_y, ": ", if (is_selected) style else self.description_style);
                x += 2;
            }

            // Draw label
            const label_width = self.width - (x - palette_x) - 2;
            _ = buf.writeTruncated(x, row_y, label_width, cmd.label, style);

            // Draw shortcut on the right
            if (self.show_shortcuts) {
                if (cmd.shortcut) |shortcut| {
                    const shortcut_x = palette_x + self.width - @as(u16, @intCast(shortcut.len)) - 3;
                    _ = buf.writeStr(shortcut_x, row_y, shortcut, if (is_selected) style else self.shortcut_style);
                }
            }
        }

        // Draw result count
        const count_y = palette_y + self.height - 1;
        var count_buf: [32]u8 = undefined;
        const count_str = std.fmt.bufPrint(&count_buf, " {d} commands ", .{self.filtered.items.len}) catch " ? commands ";
        _ = buf.writeStr(palette_x + 2, count_y, count_str, self.description_style);
    }

    pub fn handleEvent(self: *Self, event: Event) bool {
        if (!self.visible) return false;

        switch (event) {
            .key => |k| {
                switch (k.key) {
                    .special => |s| switch (s) {
                        .escape => {
                            self.visible = false;
                            if (self.on_cancel) |cb| cb(self);
                            return true;
                        },
                        .enter => {
                            self.executeSelected();
                            return true;
                        },
                        .up => {
                            if (self.selected_idx > 0) {
                                self.selected_idx -= 1;
                            }
                            return true;
                        },
                        .down => {
                            if (self.selected_idx < self.filtered.items.len - 1) {
                                self.selected_idx += 1;
                            }
                            return true;
                        },
                        .backspace => {
                            if (self.query_len > 0) {
                                self.query_len -= 1;
                                self.query[self.query_len] = 0;
                                self.updateFilter() catch {};
                            }
                            return true;
                        },
                        .tab => {
                            // Tab cycles through results
                            if (self.filtered.items.len > 0) {
                                self.selected_idx = (self.selected_idx + 1) % self.filtered.items.len;
                            }
                            return true;
                        },
                        else => {},
                    },
                    .char => |c| {
                        // Add character to query
                        if (c >= 0x20 and c < 0x7F and self.query_len < self.query.len - 1) {
                            self.query[self.query_len] = @intCast(c);
                            self.query_len += 1;
                            self.updateFilter() catch {};
                        }
                        return true;
                    },
                }
            },
            .mouse => |m| {
                if (m.kind == .press and m.button == .left) {
                    // Check if clicked on a result
                    const results_y = 5; // Approximate
                    if (m.y >= results_y and m.y < results_y + self.max_visible) {
                        const clicked_idx = self.scroll_offset + (m.y - results_y);
                        if (clicked_idx < self.filtered.items.len) {
                            self.selected_idx = clicked_idx;
                            self.executeSelected();
                            return true;
                        }
                    }
                }
            },
            else => {},
        }
        return true; // Consume all events when visible
    }

    pub fn minSize(self: *Self) Size {
        return .{ .width = self.width, .height = self.height };
    }

    pub fn canFocus(self: *Self) bool {
        return self.visible;
    }
};

test "CommandPalette basic" {
    var cp = CommandPalette.init(std.testing.allocator);
    defer cp.deinit();

    try cp.addCommand(.{
        .id = "test.command",
        .label = "Test Command",
        .description = "A test command",
        .shortcut = "Ctrl+T",
        .category = "Test",
        .enabled = true,
        .data = null,
    });

    try cp.show();
    try std.testing.expect(cp.isVisible());
    try std.testing.expectEqual(@as(usize, 1), cp.filtered.items.len);
}
