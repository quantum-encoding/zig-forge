//! TextInput widget - single-line text input
//!
//! Editable text field with cursor and selection support.

const std = @import("std");
const core = @import("../core/core.zig");
const widget_mod = @import("../widget/mod.zig");
const input_mod = @import("../input/input.zig");

pub const Buffer = core.Buffer;
pub const Rect = core.Rect;
pub const Size = core.Size;
pub const Style = core.Style;
pub const Color = core.Color;
pub const Cell = core.Cell;
pub const Widget = widget_mod.Widget;
pub const makeWidget = widget_mod.makeWidget;
pub const Event = input_mod.Event;
pub const Key = input_mod.Key;

/// Text input change callback
pub const ChangeCallback = *const fn (*TextInput) void;

/// Text input widget
pub const TextInput = struct {
    buffer: [256]u8,
    len: usize,
    cursor: usize,
    scroll_offset: usize,
    placeholder: []const u8,
    style: Style,
    focused_style: Style,
    placeholder_style: Style,
    cursor_style: Style,
    disabled: bool,
    password: bool,
    on_change: ?ChangeCallback,
    on_submit: ?ChangeCallback,

    const Self = @This();

    /// Get Widget interface
    pub fn widget(self: *Self) Widget {
        return makeWidget(Self, self);
    }

    /// Create a new text input
    pub fn init() Self {
        return .{
            .buffer = undefined,
            .len = 0,
            .cursor = 0,
            .scroll_offset = 0,
            .placeholder = "",
            .style = Style.init(Color.white, Color.black),
            .focused_style = Style.init(Color.white, Color.blue),
            .placeholder_style = Style{ .fg = Color.gray },
            .cursor_style = Style{ .fg = Color.black, .bg = Color.white },
            .disabled = false,
            .password = false,
            .on_change = null,
            .on_submit = null,
        };
    }

    /// Set placeholder text
    pub fn setPlaceholder(self: *Self, text: []const u8) *Self {
        self.placeholder = text;
        return self;
    }

    /// Set password mode
    pub fn setPassword(self: *Self, password: bool) *Self {
        self.password = password;
        return self;
    }

    /// Set change callback
    pub fn onChange(self: *Self, callback: ChangeCallback) *Self {
        self.on_change = callback;
        return self;
    }

    /// Set submit callback
    pub fn onSubmit(self: *Self, callback: ChangeCallback) *Self {
        self.on_submit = callback;
        return self;
    }

    /// Get current text
    pub fn getText(self: *const Self) []const u8 {
        return self.buffer[0..self.len];
    }

    /// Set text content
    pub fn setText(self: *Self, text: []const u8) *Self {
        const copy_len = @min(text.len, self.buffer.len);
        @memcpy(self.buffer[0..copy_len], text[0..copy_len]);
        self.len = copy_len;
        self.cursor = copy_len;
        return self;
    }

    /// Clear text
    pub fn clear(self: *Self) void {
        self.len = 0;
        self.cursor = 0;
        self.scroll_offset = 0;
    }

    /// Insert character at cursor
    fn insertChar(self: *Self, c: u8) void {
        if (self.len >= self.buffer.len) return;

        // Shift characters right
        if (self.cursor < self.len) {
            var i = self.len;
            while (i > self.cursor) : (i -= 1) {
                self.buffer[i] = self.buffer[i - 1];
            }
        }

        self.buffer[self.cursor] = c;
        self.cursor += 1;
        self.len += 1;

        if (self.on_change) |cb| cb(self);
    }

    /// Delete character before cursor
    fn deleteBack(self: *Self) void {
        if (self.cursor == 0) return;

        // Shift characters left
        var i = self.cursor - 1;
        while (i < self.len - 1) : (i += 1) {
            self.buffer[i] = self.buffer[i + 1];
        }

        self.cursor -= 1;
        self.len -= 1;

        if (self.on_change) |cb| cb(self);
    }

    /// Delete character at cursor
    fn deleteForward(self: *Self) void {
        if (self.cursor >= self.len) return;

        // Shift characters left
        var i = self.cursor;
        while (i < self.len - 1) : (i += 1) {
            self.buffer[i] = self.buffer[i + 1];
        }

        self.len -= 1;

        if (self.on_change) |cb| cb(self);
    }

    // Widget interface

    pub fn render(self: *Self, area: Rect, buf: *Buffer, state: Widget.RenderState) void {
        if (area.isEmpty()) return;

        const style = if (state.focused) self.focused_style else self.style;

        // Fill background
        buf.fill(area, Cell.styled(' ', style));

        // Adjust scroll to keep cursor visible
        const visible_width = area.width;
        if (self.cursor < self.scroll_offset) {
            self.scroll_offset = self.cursor;
        } else if (self.cursor >= self.scroll_offset + visible_width) {
            self.scroll_offset = self.cursor - visible_width + 1;
        }

        // Render text or placeholder
        if (self.len == 0 and self.placeholder.len > 0 and !state.focused) {
            _ = buf.writeStr(area.x, area.y, self.placeholder, self.placeholder_style);
        } else {
            const text = self.buffer[0..self.len];
            const visible_start = @min(self.scroll_offset, self.len);
            const visible_end = @min(self.scroll_offset + visible_width, self.len);

            if (visible_start < visible_end) {
                const display_text = if (self.password)
                    // Show asterisks for password
                    blk: {
                        var pw_buf: [256]u8 = undefined;
                        @memset(pw_buf[0..visible_end - visible_start], '*');
                        break :blk pw_buf[0 .. visible_end - visible_start];
                    }
                else
                    text[visible_start..visible_end];

                _ = buf.writeStr(area.x, area.y, display_text, style);
            }
        }

        // Draw cursor if focused
        if (state.focused and !self.disabled) {
            const cursor_x = area.x + @as(u16, @intCast(self.cursor - self.scroll_offset));
            if (cursor_x < area.x + area.width) {
                const cursor_char: u21 = if (self.cursor < self.len)
                    self.buffer[self.cursor]
                else
                    ' ';
                buf.setChar(cursor_x, area.y, cursor_char, self.cursor_style);
            }
        }
    }

    pub fn handleEvent(self: *Self, event: Event) bool {
        if (self.disabled) return false;

        switch (event) {
            .key => |k| {
                switch (k.key) {
                    .special => |s| {
                        switch (s) {
                            .left => {
                                if (self.cursor > 0) self.cursor -= 1;
                                return true;
                            },
                            .right => {
                                if (self.cursor < self.len) self.cursor += 1;
                                return true;
                            },
                            .home => {
                                self.cursor = 0;
                                return true;
                            },
                            .end => {
                                self.cursor = self.len;
                                return true;
                            },
                            .backspace => {
                                self.deleteBack();
                                return true;
                            },
                            .delete => {
                                self.deleteForward();
                                return true;
                            },
                            .enter => {
                                if (self.on_submit) |cb| cb(self);
                                return true;
                            },
                            else => {},
                        }
                    },
                    .char => |c| {
                        // Handle Ctrl+U (clear line)
                        if (k.modifiers.ctrl and c == 'u') {
                            self.clear();
                            return true;
                        }
                        // Handle Ctrl+A (start of line)
                        if (k.modifiers.ctrl and c == 'a') {
                            self.cursor = 0;
                            return true;
                        }
                        // Handle Ctrl+E (end of line)
                        if (k.modifiers.ctrl and c == 'e') {
                            self.cursor = self.len;
                            return true;
                        }

                        // Insert printable character
                        if (c >= 0x20 and c < 0x7F) {
                            self.insertChar(@intCast(c));
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
        return .{ .width = 10, .height = 1 };
    }

    pub fn canFocus(self: *Self) bool {
        return !self.disabled;
    }
};

test "TextInput basic" {
    var ti = TextInput.init();
    _ = ti.setText("hello");
    try std.testing.expectEqualStrings("hello", ti.getText());
}

test "TextInput insert" {
    var ti = TextInput.init();
    ti.insertChar('a');
    ti.insertChar('b');
    try std.testing.expectEqualStrings("ab", ti.getText());
}
