//! Checkbox widget - toggleable boolean control
//!
//! Displays a checkbox with label that can be toggled on/off.

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

/// Checkbox style variant
pub const CheckboxStyle = enum {
    square,      // [x] [ ]
    round,       // (●) ( )
    check,       // ✓  ✗
    filled,      // ■  □
};

/// Callback when checkbox state changes
pub const ToggleCallback = *const fn (*Checkbox, bool) void;

/// Checkbox widget
pub const Checkbox = struct {
    label: []const u8,
    checked: bool,
    enabled: bool,
    checkbox_style: CheckboxStyle,

    // Styles
    label_style: Style,
    checked_style: Style,
    unchecked_style: Style,
    disabled_style: Style,
    focused_style: Style,

    // Callback
    on_toggle: ?ToggleCallback,

    // State
    focused: bool,

    const Self = @This();

    /// Get Widget interface
    pub fn widget(self: *Self) Widget {
        return makeWidget(Self, self);
    }

    /// Create a new checkbox
    pub fn init(label: []const u8, checked: bool) Self {
        return .{
            .label = label,
            .checked = checked,
            .enabled = true,
            .checkbox_style = .square,
            .label_style = Style{ .fg = Color.white },
            .checked_style = Style{ .fg = Color.green },
            .unchecked_style = Style{ .fg = Color.gray },
            .disabled_style = Style{ .fg = Color.bright_black },
            .focused_style = Style{ .fg = Color.cyan },
            .on_toggle = null,
            .focused = false,
        };
    }

    /// Set checkbox style
    pub fn setCheckboxStyle(self: *Self, style: CheckboxStyle) *Self {
        self.checkbox_style = style;
        return self;
    }

    /// Set enabled state
    pub fn setEnabled(self: *Self, enabled: bool) *Self {
        self.enabled = enabled;
        return self;
    }

    /// Set toggle callback
    pub fn onToggle(self: *Self, callback: ToggleCallback) *Self {
        self.on_toggle = callback;
        return self;
    }

    /// Get checked state
    pub fn isChecked(self: *const Self) bool {
        return self.checked;
    }

    /// Set checked state
    pub fn setChecked(self: *Self, checked: bool) void {
        if (self.checked != checked) {
            self.checked = checked;
            if (self.on_toggle) |cb| cb(self, checked);
        }
    }

    /// Toggle checked state
    pub fn toggle(self: *Self) void {
        if (!self.enabled) return;
        self.checked = !self.checked;
        if (self.on_toggle) |cb| cb(self, self.checked);
    }

    /// Get checkbox characters based on style
    fn getCheckChars(self: *const Self) struct { checked: []const u8, unchecked: []const u8 } {
        return switch (self.checkbox_style) {
            .square => .{ .checked = "[x]", .unchecked = "[ ]" },
            .round => .{ .checked = "(●)", .unchecked = "( )" },
            .check => .{ .checked = " ✓ ", .unchecked = " ✗ " },
            .filled => .{ .checked = " ■ ", .unchecked = " □ " },
        };
    }

    // Widget interface

    pub fn render(self: *Self, area: Rect, buf: *Buffer, state: Widget.RenderState) void {
        if (area.isEmpty()) return;

        self.focused = state.focused;

        const chars = self.getCheckChars();
        const check_str = if (self.checked) chars.checked else chars.unchecked;

        // Determine styles
        const check_style = if (!self.enabled)
            self.disabled_style
        else if (state.focused)
            self.focused_style
        else if (self.checked)
            self.checked_style
        else
            self.unchecked_style;

        const lbl_style = if (!self.enabled)
            self.disabled_style
        else
            self.label_style;

        // Draw checkbox
        _ = buf.writeStr(area.x, area.y, check_str, check_style);

        // Draw label
        const label_x = area.x + @as(u16, @intCast(check_str.len)) + 1;
        if (label_x < area.x + area.width) {
            const label_width = area.width - @as(u16, @intCast(check_str.len)) - 1;
            _ = buf.writeTruncated(label_x, area.y, label_width, self.label, lbl_style);
        }
    }

    pub fn handleEvent(self: *Self, event: Event) bool {
        if (!self.enabled) return false;

        switch (event) {
            .key => |k| {
                switch (k.key) {
                    .special => |s| {
                        if (s == .enter) {
                            self.toggle();
                            return true;
                        }
                    },
                    .char => |c| {
                        if (c == ' ') {
                            self.toggle();
                            return true;
                        }
                    },
                }
            },
            .mouse => |m| {
                if (m.kind == .press and m.button == .left) {
                    self.toggle();
                    return true;
                }
            },
            else => {},
        }
        return false;
    }

    pub fn minSize(self: *Self) Size {
        const chars = self.getCheckChars();
        return .{
            .width = @intCast(chars.checked.len + 1 + self.label.len),
            .height = 1,
        };
    }

    pub fn canFocus(self: *Self) bool {
        return self.enabled;
    }
};

/// Radio button group for mutually exclusive selection
pub const RadioGroup = struct {
    options: []const []const u8,
    selected: usize,
    enabled: bool,
    radio_style: CheckboxStyle,

    // Styles
    label_style: Style,
    selected_style: Style,
    unselected_style: Style,
    disabled_style: Style,
    focused_style: Style,

    // Callback
    on_change: ?*const fn (*RadioGroup, usize) void,

    // State
    focused: bool,

    const Self = @This();

    /// Get Widget interface
    pub fn widget(self: *Self) Widget {
        return makeWidget(Self, self);
    }

    /// Create a new radio group
    pub fn init(options: []const []const u8) Self {
        return .{
            .options = options,
            .selected = 0,
            .enabled = true,
            .radio_style = .round,
            .label_style = Style{ .fg = Color.white },
            .selected_style = Style{ .fg = Color.green },
            .unselected_style = Style{ .fg = Color.gray },
            .disabled_style = Style{ .fg = Color.bright_black },
            .focused_style = Style{ .fg = Color.cyan },
            .on_change = null,
            .focused = false,
        };
    }

    /// Set selected option
    pub fn setSelected(self: *Self, index: usize) void {
        if (index < self.options.len and self.selected != index) {
            self.selected = index;
            if (self.on_change) |cb| cb(self, index);
        }
    }

    /// Get selected option
    pub fn getSelected(self: *const Self) usize {
        return self.selected;
    }

    /// Get selected option text
    pub fn getSelectedText(self: *const Self) ?[]const u8 {
        if (self.selected < self.options.len) {
            return self.options[self.selected];
        }
        return null;
    }

    /// Set change callback
    pub fn onChange(self: *Self, callback: *const fn (*RadioGroup, usize) void) *Self {
        self.on_change = callback;
        return self;
    }

    fn getRadioChars(self: *const Self) struct { selected: []const u8, unselected: []const u8 } {
        return switch (self.radio_style) {
            .square => .{ .selected = "[x]", .unselected = "[ ]" },
            .round => .{ .selected = "(●)", .unselected = "( )" },
            .check => .{ .selected = " ✓ ", .unselected = "   " },
            .filled => .{ .selected = " ● ", .unselected = " ○ " },
        };
    }

    // Widget interface

    pub fn render(self: *Self, area: Rect, buf: *Buffer, state: Widget.RenderState) void {
        if (area.isEmpty() or self.options.len == 0) return;

        self.focused = state.focused;
        const chars = self.getRadioChars();

        var y: u16 = 0;
        for (self.options, 0..) |option, i| {
            if (y >= area.height) break;

            const is_selected = i == self.selected;
            const radio_str = if (is_selected) chars.selected else chars.unselected;

            // Determine styles
            const radio_style = if (!self.enabled)
                self.disabled_style
            else if (state.focused and is_selected)
                self.focused_style
            else if (is_selected)
                self.selected_style
            else
                self.unselected_style;

            const lbl_style = if (!self.enabled)
                self.disabled_style
            else
                self.label_style;

            // Draw radio button
            _ = buf.writeStr(area.x, area.y + y, radio_str, radio_style);

            // Draw label
            const label_x = area.x + @as(u16, @intCast(radio_str.len)) + 1;
            if (label_x < area.x + area.width) {
                const label_width = area.width - @as(u16, @intCast(radio_str.len)) - 1;
                _ = buf.writeTruncated(label_x, area.y + y, label_width, option, lbl_style);
            }

            y += 1;
        }
    }

    pub fn handleEvent(self: *Self, event: Event) bool {
        if (!self.enabled) return false;

        switch (event) {
            .key => |k| {
                switch (k.key) {
                    .special => |s| switch (s) {
                        .up => {
                            if (self.selected > 0) {
                                self.setSelected(self.selected - 1);
                                return true;
                            }
                        },
                        .down => {
                            if (self.selected < self.options.len - 1) {
                                self.setSelected(self.selected + 1);
                                return true;
                            }
                        },
                        else => {},
                    },
                    .char => |c| {
                        // Number keys 1-9 select options
                        if (c >= '1' and c <= '9') {
                            const idx = c - '1';
                            if (idx < self.options.len) {
                                self.setSelected(idx);
                                return true;
                            }
                        }
                    },
                }
            },
            .mouse => |m| {
                if (m.kind == .press and m.button == .left) {
                    if (m.y < self.options.len) {
                        self.setSelected(m.y);
                        return true;
                    }
                }
            },
            else => {},
        }
        return false;
    }

    pub fn minSize(self: *Self) Size {
        var max_width: u16 = 0;
        for (self.options) |opt| {
            max_width = @max(max_width, @as(u16, @intCast(opt.len)));
        }
        return .{
            .width = max_width + 5, // radio chars + space + label
            .height = @intCast(self.options.len),
        };
    }

    pub fn canFocus(self: *Self) bool {
        return self.enabled and self.options.len > 0;
    }
};

test "Checkbox toggle" {
    var cb = Checkbox.init("Test", false);
    try std.testing.expect(!cb.isChecked());

    cb.toggle();
    try std.testing.expect(cb.isChecked());

    cb.toggle();
    try std.testing.expect(!cb.isChecked());
}
