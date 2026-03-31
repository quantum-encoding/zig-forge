//! Button widget - clickable action button
//!
//! Interactive button with hover and focus states.

const std = @import("std");
const core = @import("../core/core.zig");
const widget_mod = @import("../widget/mod.zig");
const input = @import("../input/input.zig");

pub const Buffer = core.Buffer;
pub const Rect = core.Rect;
pub const Size = core.Size;
pub const Style = core.Style;
pub const Color = core.Color;
pub const Align = core.Align;
pub const Widget = widget_mod.Widget;
pub const makeWidget = widget_mod.makeWidget;
pub const Event = input.Event;
pub const Key = input.Key;

/// Button click callback
pub const ClickCallback = *const fn (*Button) void;

/// Button widget
pub const Button = struct {
    label: []const u8,
    style: Style,
    focused_style: Style,
    pressed_style: Style,
    disabled: bool,
    on_click: ?ClickCallback,
    user_data: ?*anyopaque,
    padding_h: u16,
    padding_v: u16,

    const Self = @This();

    /// Get Widget interface
    pub fn widget(self: *Self) Widget {
        return makeWidget(Self, self);
    }

    /// Create a new button
    pub fn init(label: []const u8) Self {
        return .{
            .label = label,
            .style = Style.init(Color.white, Color.blue),
            .focused_style = Style.init(Color.black, Color.cyan),
            .pressed_style = Style.init(Color.black, Color.white),
            .disabled = false,
            .on_click = null,
            .user_data = null,
            .padding_h = 2,
            .padding_v = 0,
        };
    }

    /// Set label text
    pub fn setLabel(self: *Self, label: []const u8) *Self {
        self.label = label;
        return self;
    }

    /// Set normal style
    pub fn setStyle(self: *Self, style: Style) *Self {
        self.style = style;
        return self;
    }

    /// Set focused style
    pub fn setFocusedStyle(self: *Self, style: Style) *Self {
        self.focused_style = style;
        return self;
    }

    /// Set click callback
    pub fn onClick(self: *Self, callback: ClickCallback) *Self {
        self.on_click = callback;
        return self;
    }

    /// Set user data
    pub fn setUserData(self: *Self, data: *anyopaque) *Self {
        self.user_data = data;
        return self;
    }

    /// Set padding
    pub fn setPadding(self: *Self, h: u16, v: u16) *Self {
        self.padding_h = h;
        self.padding_v = v;
        return self;
    }

    /// Disable button
    pub fn setDisabled(self: *Self, disabled: bool) *Self {
        self.disabled = disabled;
        return self;
    }

    /// Trigger click action
    pub fn click(self: *Self) void {
        if (self.disabled) return;
        if (self.on_click) |callback| {
            callback(self);
        }
    }

    // Widget interface

    pub fn render(self: *Self, area: Rect, buf: *Buffer, state: Widget.RenderState) void {
        if (area.isEmpty()) return;

        // Choose style based on state
        const style = if (self.disabled)
            Style{ .fg = Color.gray, .bg = Color.dark_gray }
        else if (state.focused)
            self.focused_style
        else
            self.style;

        // Fill background
        buf.fill(area, core.Cell.styled(' ', style));

        // Calculate text position (centered)
        const text_len: u16 = @intCast(@min(self.label.len, area.width));
        const x_offset: u16 = (area.width - text_len) / 2;
        const y_offset: u16 = area.height / 2;

        // Draw label
        _ = buf.writeStr(
            area.x + x_offset,
            area.y + y_offset,
            self.label,
            style,
        );

        // Draw focus indicator
        if (state.focused and !self.disabled) {
            // Highlight border or brackets
            if (area.width >= 2) {
                buf.setChar(area.x, area.y + y_offset, '[', style.bold());
                buf.setChar(area.x + area.width - 1, area.y + y_offset, ']', style.bold());
            }
        }
    }

    pub fn handleEvent(self: *Self, event: Event) bool {
        if (self.disabled) return false;

        switch (event) {
            .key => |k| {
                switch (k.key) {
                    .special => |s| {
                        if (s == .enter) {
                            self.click();
                            return true;
                        }
                    },
                    .char => |c| {
                        if (c == ' ') {
                            self.click();
                            return true;
                        }
                    },
                }
            },
            .mouse => |m| {
                if (m.kind == .press and m.button == .left) {
                    self.click();
                    return true;
                }
            },
            else => {},
        }
        return false;
    }

    pub fn minSize(self: *Self) Size {
        return .{
            .width = @intCast(@min(self.label.len + self.padding_h * 2, 65535)),
            .height = 1 + self.padding_v * 2,
        };
    }

    pub fn canFocus(self: *Self) bool {
        return !self.disabled;
    }

    pub fn onFocus(self: *Self) void {
        _ = self;
        // Could trigger visual feedback
    }

    pub fn onBlur(self: *Self) void {
        _ = self;
        // Reset visual state
    }
};

test "Button basic" {
    var btn = Button.init("OK");
    try std.testing.expectEqualStrings("OK", btn.label);
    try std.testing.expect(btn.canFocus());
}

test "Button disabled" {
    var btn = Button.init("Submit");
    _ = btn.setDisabled(true);
    try std.testing.expect(!btn.canFocus());
}
