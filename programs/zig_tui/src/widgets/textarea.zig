//! TextArea widget - multi-line text editor
//!
//! Supports scrolling, cursor navigation, and text editing.

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

/// Text changed callback
pub const TextChangeCallback = *const fn (*TextArea) void;

/// TextArea widget for multi-line text editing
pub const TextArea = struct {
    // Content storage
    lines: std.ArrayListUnmanaged([]u8),
    allocator: std.mem.Allocator,

    // Cursor position
    cursor_line: usize,
    cursor_col: usize,

    // Scroll position
    scroll_y: usize,
    scroll_x: usize,

    // Display options
    line_numbers: bool,
    word_wrap: bool,
    read_only: bool,
    max_lines: ?usize,

    // Styles
    text_style: Style,
    line_number_style: Style,
    cursor_style: Style,
    selection_style: Style,

    // Selection
    selection_start: ?struct { line: usize, col: usize },

    // Callback
    on_change: ?TextChangeCallback,

    // State
    focused: bool,
    visible_width: u16,
    visible_height: u16,

    const Self = @This();

    /// Get Widget interface
    pub fn widget(self: *Self) Widget {
        return makeWidget(Self, self);
    }

    /// Create a new TextArea
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .lines = .{},
            .allocator = allocator,
            .cursor_line = 0,
            .cursor_col = 0,
            .scroll_y = 0,
            .scroll_x = 0,
            .line_numbers = false,
            .word_wrap = false,
            .read_only = false,
            .max_lines = null,
            .text_style = Style{ .fg = Color.white },
            .line_number_style = Style{ .fg = Color.gray },
            .cursor_style = Style{ .fg = Color.black, .bg = Color.white },
            .selection_style = Style{ .fg = Color.white, .bg = Color.blue },
            .selection_start = null,
            .on_change = null,
            .focused = false,
            .visible_width = 80,
            .visible_height = 24,
        };
    }

    /// Create with initial text
    pub fn withText(allocator: std.mem.Allocator, text: []const u8) !Self {
        var self = init(allocator);
        try self.setText(text);
        return self;
    }

    pub fn deinit(self: *Self) void {
        for (self.lines.items) |line| {
            self.allocator.free(line);
        }
        self.lines.deinit(self.allocator);
    }

    /// Set the text content
    pub fn setText(self: *Self, text: []const u8) !void {
        // Clear existing lines
        for (self.lines.items) |line| {
            self.allocator.free(line);
        }
        self.lines.clearRetainingCapacity();

        // Split text into lines
        var iter = std.mem.splitScalar(u8, text, '\n');
        while (iter.next()) |line| {
            const line_copy = try self.allocator.dupe(u8, line);
            try self.lines.append(self.allocator, line_copy);
        }

        // Ensure at least one empty line
        if (self.lines.items.len == 0) {
            const empty = try self.allocator.alloc(u8, 0);
            try self.lines.append(self.allocator, empty);
        }

        self.cursor_line = 0;
        self.cursor_col = 0;
        self.scroll_y = 0;
        self.scroll_x = 0;
    }

    /// Get the text content
    pub fn getText(self: *const Self, allocator: std.mem.Allocator) ![]u8 {
        var total_len: usize = 0;
        for (self.lines.items) |line| {
            total_len += line.len + 1; // +1 for newline
        }
        if (total_len > 0) total_len -= 1; // Remove last newline

        const result = try allocator.alloc(u8, total_len);
        var pos: usize = 0;
        for (self.lines.items, 0..) |line, i| {
            @memcpy(result[pos..][0..line.len], line);
            pos += line.len;
            if (i < self.lines.items.len - 1) {
                result[pos] = '\n';
                pos += 1;
            }
        }
        return result;
    }

    /// Get line count
    pub fn getLineCount(self: *const Self) usize {
        return self.lines.items.len;
    }

    /// Get current line
    pub fn getCurrentLine(self: *const Self) []const u8 {
        if (self.cursor_line < self.lines.items.len) {
            return self.lines.items[self.cursor_line];
        }
        return "";
    }

    /// Set line numbers visibility
    pub fn setLineNumbers(self: *Self, show: bool) *Self {
        self.line_numbers = show;
        return self;
    }

    /// Set word wrap
    pub fn setWordWrap(self: *Self, wrap: bool) *Self {
        self.word_wrap = wrap;
        return self;
    }

    /// Set read-only mode
    pub fn setReadOnly(self: *Self, read_only: bool) *Self {
        self.read_only = read_only;
        return self;
    }

    /// Set change callback
    pub fn onChange(self: *Self, callback: TextChangeCallback) *Self {
        self.on_change = callback;
        return self;
    }

    /// Insert character at cursor
    pub fn insertChar(self: *Self, char: u8) !void {
        if (self.read_only) return;
        if (self.cursor_line >= self.lines.items.len) return;

        const line = self.lines.items[self.cursor_line];
        const col = @min(self.cursor_col, line.len);

        // Create new line with inserted character
        const new_line = try self.allocator.alloc(u8, line.len + 1);
        @memcpy(new_line[0..col], line[0..col]);
        new_line[col] = char;
        @memcpy(new_line[col + 1 ..], line[col..]);

        self.allocator.free(line);
        self.lines.items[self.cursor_line] = new_line;
        self.cursor_col = col + 1;

        if (self.on_change) |cb| cb(self);
    }

    /// Insert newline at cursor
    pub fn insertNewline(self: *Self) !void {
        if (self.read_only) return;
        if (self.max_lines) |max| {
            if (self.lines.items.len >= max) return;
        }
        if (self.cursor_line >= self.lines.items.len) return;

        const line = self.lines.items[self.cursor_line];
        const col = @min(self.cursor_col, line.len);

        // Split line at cursor
        const line_before = try self.allocator.dupe(u8, line[0..col]);
        const line_after = try self.allocator.dupe(u8, line[col..]);

        self.allocator.free(line);
        self.lines.items[self.cursor_line] = line_before;

        // Insert new line after
        try self.lines.insert(self.allocator, self.cursor_line + 1, line_after);

        self.cursor_line += 1;
        self.cursor_col = 0;

        if (self.on_change) |cb| cb(self);
    }

    /// Delete character before cursor (backspace)
    pub fn deleteCharBefore(self: *Self) !void {
        if (self.read_only) return;

        if (self.cursor_col > 0) {
            // Delete within line
            const line = self.lines.items[self.cursor_line];
            const col = @min(self.cursor_col, line.len);

            if (col > 0) {
                const new_line = try self.allocator.alloc(u8, line.len - 1);
                @memcpy(new_line[0 .. col - 1], line[0 .. col - 1]);
                @memcpy(new_line[col - 1 ..], line[col..]);

                self.allocator.free(line);
                self.lines.items[self.cursor_line] = new_line;
                self.cursor_col = col - 1;
            }
        } else if (self.cursor_line > 0) {
            // Join with previous line
            const prev_line = self.lines.items[self.cursor_line - 1];
            const curr_line = self.lines.items[self.cursor_line];

            const new_line = try self.allocator.alloc(u8, prev_line.len + curr_line.len);
            @memcpy(new_line[0..prev_line.len], prev_line);
            @memcpy(new_line[prev_line.len..], curr_line);

            self.cursor_col = prev_line.len;

            self.allocator.free(prev_line);
            self.allocator.free(curr_line);

            self.lines.items[self.cursor_line - 1] = new_line;
            _ = self.lines.orderedRemove(self.cursor_line);

            self.cursor_line -= 1;
        }

        if (self.on_change) |cb| cb(self);
    }

    /// Delete character at cursor (delete)
    pub fn deleteCharAt(self: *Self) !void {
        if (self.read_only) return;
        if (self.cursor_line >= self.lines.items.len) return;

        const line = self.lines.items[self.cursor_line];
        const col = @min(self.cursor_col, line.len);

        if (col < line.len) {
            // Delete within line
            const new_line = try self.allocator.alloc(u8, line.len - 1);
            @memcpy(new_line[0..col], line[0..col]);
            @memcpy(new_line[col..], line[col + 1 ..]);

            self.allocator.free(line);
            self.lines.items[self.cursor_line] = new_line;
        } else if (self.cursor_line < self.lines.items.len - 1) {
            // Join with next line
            const next_line = self.lines.items[self.cursor_line + 1];

            const new_line = try self.allocator.alloc(u8, line.len + next_line.len);
            @memcpy(new_line[0..line.len], line);
            @memcpy(new_line[line.len..], next_line);

            self.allocator.free(line);
            self.allocator.free(next_line);

            self.lines.items[self.cursor_line] = new_line;
            _ = self.lines.orderedRemove(self.cursor_line + 1);
        }

        if (self.on_change) |cb| cb(self);
    }

    /// Move cursor
    pub fn moveCursor(self: *Self, dir: enum { left, right, up, down, home, end, page_up, page_down }) void {
        switch (dir) {
            .left => {
                if (self.cursor_col > 0) {
                    self.cursor_col -= 1;
                } else if (self.cursor_line > 0) {
                    self.cursor_line -= 1;
                    self.cursor_col = self.lines.items[self.cursor_line].len;
                }
            },
            .right => {
                const line_len = if (self.cursor_line < self.lines.items.len)
                    self.lines.items[self.cursor_line].len
                else
                    0;
                if (self.cursor_col < line_len) {
                    self.cursor_col += 1;
                } else if (self.cursor_line < self.lines.items.len - 1) {
                    self.cursor_line += 1;
                    self.cursor_col = 0;
                }
            },
            .up => {
                if (self.cursor_line > 0) {
                    self.cursor_line -= 1;
                    const line_len = self.lines.items[self.cursor_line].len;
                    self.cursor_col = @min(self.cursor_col, line_len);
                }
            },
            .down => {
                if (self.cursor_line < self.lines.items.len - 1) {
                    self.cursor_line += 1;
                    const line_len = self.lines.items[self.cursor_line].len;
                    self.cursor_col = @min(self.cursor_col, line_len);
                }
            },
            .home => {
                self.cursor_col = 0;
            },
            .end => {
                if (self.cursor_line < self.lines.items.len) {
                    self.cursor_col = self.lines.items[self.cursor_line].len;
                }
            },
            .page_up => {
                if (self.cursor_line >= self.visible_height) {
                    self.cursor_line -= self.visible_height;
                } else {
                    self.cursor_line = 0;
                }
                const line_len = self.lines.items[self.cursor_line].len;
                self.cursor_col = @min(self.cursor_col, line_len);
            },
            .page_down => {
                self.cursor_line = @min(
                    self.cursor_line + self.visible_height,
                    self.lines.items.len - 1,
                );
                const line_len = self.lines.items[self.cursor_line].len;
                self.cursor_col = @min(self.cursor_col, line_len);
            },
        }

        self.ensureCursorVisible();
    }

    fn ensureCursorVisible(self: *Self) void {
        // Vertical scroll
        if (self.cursor_line < self.scroll_y) {
            self.scroll_y = self.cursor_line;
        } else if (self.cursor_line >= self.scroll_y + self.visible_height) {
            self.scroll_y = self.cursor_line - self.visible_height + 1;
        }

        // Horizontal scroll
        const line_num_width: usize = if (self.line_numbers) 5 else 0;
        const text_width = if (self.visible_width > line_num_width) self.visible_width - @as(u16, @intCast(line_num_width)) else 0;

        if (self.cursor_col < self.scroll_x) {
            self.scroll_x = self.cursor_col;
        } else if (self.cursor_col >= self.scroll_x + text_width) {
            self.scroll_x = self.cursor_col - text_width + 1;
        }
    }

    // Widget interface

    pub fn render(self: *Self, area: Rect, buf: *Buffer, state: Widget.RenderState) void {
        if (area.isEmpty()) return;

        self.focused = state.focused;
        self.visible_width = area.width;
        self.visible_height = area.height;

        const line_num_width: u16 = if (self.line_numbers) 5 else 0;
        const text_x = area.x + line_num_width;
        const text_width = if (area.width > line_num_width) area.width - line_num_width else 0;

        var y: u16 = 0;
        while (y < area.height) : (y += 1) {
            const line_idx = self.scroll_y + y;
            if (line_idx >= self.lines.items.len) break;

            // Draw line number
            if (self.line_numbers) {
                var num_buf: [5]u8 = undefined;
                const num_str = std.fmt.bufPrint(&num_buf, "{d:>4} ", .{line_idx + 1}) catch "???? ";
                _ = buf.writeStr(area.x, area.y + y, num_str, self.line_number_style);
            }

            // Draw line content
            const line = self.lines.items[line_idx];
            if (text_width > 0 and self.scroll_x < line.len) {
                const visible_start = self.scroll_x;
                const visible_end = @min(line.len, self.scroll_x + text_width);
                const visible_text = line[visible_start..visible_end];
                _ = buf.writeTruncated(text_x, area.y + y, text_width, visible_text, self.text_style);
            }

            // Draw cursor
            if (state.focused and line_idx == self.cursor_line) {
                const cursor_screen_x = if (self.cursor_col >= self.scroll_x)
                    @as(u16, @intCast(self.cursor_col - self.scroll_x))
                else
                    0;

                if (cursor_screen_x < text_width) {
                    const cursor_char: u21 = if (self.cursor_col < line.len)
                        line[self.cursor_col]
                    else
                        ' ';
                    buf.setChar(text_x + cursor_screen_x, area.y + y, cursor_char, self.cursor_style);
                }
            }
        }
    }

    pub fn handleEvent(self: *Self, event: Event) bool {
        switch (event) {
            .key => |k| {
                switch (k.key) {
                    .special => |s| switch (s) {
                        .left => {
                            self.moveCursor(.left);
                            return true;
                        },
                        .right => {
                            self.moveCursor(.right);
                            return true;
                        },
                        .up => {
                            self.moveCursor(.up);
                            return true;
                        },
                        .down => {
                            self.moveCursor(.down);
                            return true;
                        },
                        .home => {
                            self.moveCursor(.home);
                            return true;
                        },
                        .end => {
                            self.moveCursor(.end);
                            return true;
                        },
                        .page_up => {
                            self.moveCursor(.page_up);
                            return true;
                        },
                        .page_down => {
                            self.moveCursor(.page_down);
                            return true;
                        },
                        .backspace => {
                            self.deleteCharBefore() catch {};
                            return true;
                        },
                        .delete => {
                            self.deleteCharAt() catch {};
                            return true;
                        },
                        .enter => {
                            self.insertNewline() catch {};
                            return true;
                        },
                        else => {},
                    },
                    .char => |c| {
                        if (c >= 0x20 and c < 0x7F) {
                            self.insertChar(@intCast(c)) catch {};
                            return true;
                        }
                    },
                }
            },
            else => {},
        }
        return false;
    }

    pub fn minSize(self: *Self) Size {
        _ = self;
        return .{ .width = 20, .height = 3 };
    }

    pub fn canFocus(self: *Self) bool {
        _ = self;
        return true;
    }
};

test "TextArea basic" {
    var ta = TextArea.init(std.testing.allocator);
    defer ta.deinit();

    try ta.setText("Hello\nWorld");
    try std.testing.expectEqual(@as(usize, 2), ta.getLineCount());
}
