//! Label widget - static text display
//!
//! Displays text with optional styling and alignment.

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

/// Label widget for displaying text
pub const Label = struct {
    text: []const u8,
    style: Style,
    alignment: Align,

    const Self = @This();

    /// Get Widget interface
    pub fn widget(self: *Self) Widget {
        return makeWidget(Self, self);
    }

    /// Create a new label
    pub fn init(text: []const u8) Self {
        return .{
            .text = text,
            .style = .{},
            .alignment = .left,
        };
    }

    /// Set text content
    pub fn setText(self: *Self, text: []const u8) *Self {
        self.text = text;
        return self;
    }

    /// Set style
    pub fn setStyle(self: *Self, style: Style) *Self {
        self.style = style;
        return self;
    }

    /// Set foreground color
    pub fn setFg(self: *Self, color: Color) *Self {
        self.style.fg = color;
        return self;
    }

    /// Set background color
    pub fn setBg(self: *Self, color: Color) *Self {
        self.style.bg = color;
        return self;
    }

    /// Set alignment
    pub fn setAlign(self: *Self, alignment: Align) *Self {
        self.alignment = alignment;
        return self;
    }

    /// Center alignment shorthand
    pub fn center(self: *Self) *Self {
        return self.setAlign(.center);
    }

    /// Right alignment shorthand
    pub fn right(self: *Self) *Self {
        return self.setAlign(.right);
    }

    /// Bold text
    pub fn bold(self: *Self) *Self {
        self.style.attrs.bold = true;
        return self;
    }

    // Widget interface

    pub fn render(self: *Self, area: Rect, buf: *Buffer, state: Widget.RenderState) void {
        _ = state;
        if (area.isEmpty()) return;

        // Calculate text position based on alignment
        const text_len: u16 = @intCast(@min(self.text.len, area.width));
        const x_offset: u16 = switch (self.alignment) {
            .left => 0,
            .center => (area.width - text_len) / 2,
            .right => area.width - text_len,
        };

        _ = buf.writeStr(area.x + x_offset, area.y, self.text, self.style);
    }

    pub fn handleEvent(self: *Self, event: Event) bool {
        _ = self;
        _ = event;
        return false; // Labels don't handle events
    }

    pub fn minSize(self: *Self) Size {
        return .{
            .width = @intCast(@min(self.text.len, 65535)),
            .height = 1,
        };
    }

    pub fn canFocus(self: *Self) bool {
        _ = self;
        return false; // Labels are not focusable
    }
};

/// Create a centered label
pub fn centered(text: []const u8) Label {
    var label = Label.init(text);
    _ = label.center();
    return label;
}

/// Create a bold label
pub fn boldLabel(text: []const u8) Label {
    var label = Label.init(text);
    _ = label.bold();
    return label;
}

test "Label basic" {
    var label = Label.init("Hello");
    try std.testing.expectEqualStrings("Hello", label.text);
    try std.testing.expect(!label.canFocus());
}

test "Label alignment" {
    var label = Label.init("Test");
    _ = label.center();
    try std.testing.expectEqual(Align.center, label.alignment);
}
