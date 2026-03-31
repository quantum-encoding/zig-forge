//! Modal/Dialog widget - popup dialogs and modals
//!
//! Overlay dialogs for confirmations, alerts, and custom content.

const std = @import("std");
const core = @import("../core/core.zig");
const widget_mod = @import("../widget/mod.zig");
const input_mod = @import("../input/input.zig");

pub const Buffer = core.Buffer;
pub const Rect = core.Rect;
pub const Size = core.Size;
pub const Style = core.Style;
pub const Color = core.Color;
pub const BorderStyle = core.BorderStyle;
pub const Widget = widget_mod.Widget;
pub const makeWidget = widget_mod.makeWidget;
pub const Event = input_mod.Event;
pub const Key = input_mod.Key;

/// Dialog button
pub const DialogButton = struct {
    label: []const u8,
    key: ?u21, // Keyboard shortcut
    style: Style,
    is_default: bool,
    is_cancel: bool,
};

/// Dialog result
pub const DialogResult = enum {
    none,
    ok,
    cancel,
    yes,
    no,
    custom,
};

/// Dialog close callback
pub const DialogCloseCallback = *const fn (*Modal, DialogResult, usize) void;

/// Modal widget
pub const Modal = struct {
    title: []const u8,
    message: []const u8,
    buttons: []const DialogButton,

    // State
    visible: bool,
    selected_button: usize,

    // Options
    width: u16,
    height: u16,
    center: bool,
    show_shadow: bool,
    closeable: bool, // Can be closed with Escape

    // Styles
    title_style: Style,
    message_style: Style,
    border_style: BorderStyle,
    border_color: Style,
    background_style: Style,
    shadow_style: Style,
    button_style: Style,
    button_selected_style: Style,

    // Callback
    on_close: ?DialogCloseCallback,

    // Parent area for centering
    parent_area: Rect,

    const Self = @This();

    /// Standard button sets
    pub const ok_button = [_]DialogButton{
        .{ .label = "  OK  ", .key = 'o', .style = Style{ .fg = Color.black, .bg = Color.white }, .is_default = true, .is_cancel = false },
    };

    pub const ok_cancel_buttons = [_]DialogButton{
        .{ .label = "  OK  ", .key = 'o', .style = Style{ .fg = Color.black, .bg = Color.white }, .is_default = true, .is_cancel = false },
        .{ .label = "Cancel", .key = 'c', .style = Style{ .fg = Color.white }, .is_default = false, .is_cancel = true },
    };

    pub const yes_no_buttons = [_]DialogButton{
        .{ .label = " Yes ", .key = 'y', .style = Style{ .fg = Color.black, .bg = Color.white }, .is_default = true, .is_cancel = false },
        .{ .label = " No  ", .key = 'n', .style = Style{ .fg = Color.white }, .is_default = false, .is_cancel = true },
    };

    pub const yes_no_cancel_buttons = [_]DialogButton{
        .{ .label = " Yes ", .key = 'y', .style = Style{ .fg = Color.black, .bg = Color.green }, .is_default = true, .is_cancel = false },
        .{ .label = "  No  ", .key = 'n', .style = Style{ .fg = Color.black, .bg = Color.red }, .is_default = false, .is_cancel = false },
        .{ .label = "Cancel", .key = 'c', .style = Style{ .fg = Color.white }, .is_default = false, .is_cancel = true },
    };

    /// Get Widget interface
    pub fn widget(self: *Self) Widget {
        return makeWidget(Self, self);
    }

    /// Create a new Modal
    pub fn init(title: []const u8, message: []const u8, buttons: []const DialogButton) Self {
        return .{
            .title = title,
            .message = message,
            .buttons = buttons,
            .visible = false,
            .selected_button = 0,
            .width = 40,
            .height = 10,
            .center = true,
            .show_shadow = true,
            .closeable = true,
            .title_style = Style{ .fg = Color.bright_white, .attrs = .{ .bold = true } },
            .message_style = Style{ .fg = Color.white },
            .border_style = .rounded,
            .border_color = Style{ .fg = Color.cyan },
            .background_style = Style{ .bg = Color.blue },
            .shadow_style = Style{ .fg = Color.black, .bg = Color.black },
            .button_style = Style{ .fg = Color.white },
            .button_selected_style = Style{ .fg = Color.black, .bg = Color.white, .attrs = .{ .bold = true } },
            .on_close = null,
            .parent_area = Rect{ .x = 0, .y = 0, .width = 80, .height = 24 },
        };
    }

    /// Create an alert dialog
    pub fn alert(title: []const u8, message: []const u8) Self {
        return init(title, message, &ok_button);
    }

    /// Create a confirm dialog
    pub fn confirm(title: []const u8, message: []const u8) Self {
        return init(title, message, &ok_cancel_buttons);
    }

    /// Create a yes/no dialog
    pub fn yesNo(title: []const u8, message: []const u8) Self {
        return init(title, message, &yes_no_buttons);
    }

    /// Set size
    pub fn setSize(self: *Self, width: u16, height: u16) *Self {
        self.width = width;
        self.height = height;
        return self;
    }

    /// Set close callback
    pub fn onClose(self: *Self, callback: DialogCloseCallback) *Self {
        self.on_close = callback;
        return self;
    }

    /// Show the modal
    pub fn show(self: *Self) void {
        self.visible = true;
        self.selected_button = 0;
        // Find default button
        for (self.buttons, 0..) |btn, i| {
            if (btn.is_default) {
                self.selected_button = i;
                break;
            }
        }
    }

    /// Hide the modal
    pub fn hide(self: *Self) void {
        self.visible = false;
    }

    /// Check if visible
    pub fn isVisible(self: *const Self) bool {
        return self.visible;
    }

    /// Set parent area for centering
    pub fn setParentArea(self: *Self, area: Rect) void {
        self.parent_area = area;
    }

    /// Close with result
    fn closeWithResult(self: *Self, result: DialogResult) void {
        self.visible = false;
        if (self.on_close) |cb| {
            cb(self, result, self.selected_button);
        }
    }

    // Widget interface

    pub fn render(self: *Self, area: Rect, buf: *Buffer, state: Widget.RenderState) void {
        _ = state;
        if (!self.visible) return;

        // Calculate dialog position
        const dialog_x = if (self.center)
            area.x + (area.width - self.width) / 2
        else
            area.x;

        const dialog_y = if (self.center)
            area.y + (area.height - self.height) / 2
        else
            area.y;

        const dialog_area = Rect{
            .x = dialog_x,
            .y = dialog_y,
            .width = @min(self.width, area.width),
            .height = @min(self.height, area.height),
        };

        // Draw shadow
        if (self.show_shadow) {
            const shadow_area = Rect{
                .x = dialog_area.x + 1,
                .y = dialog_area.y + 1,
                .width = dialog_area.width,
                .height = dialog_area.height,
            };
            buf.fill(shadow_area, core.Cell.styled(' ', self.shadow_style));
        }

        // Draw background
        buf.fill(dialog_area, core.Cell.styled(' ', self.background_style));

        // Draw border
        buf.drawBorder(dialog_area, self.border_style, self.border_color);

        // Draw title
        if (self.title.len > 0) {
            const title_x = dialog_area.x + (dialog_area.width - @as(u16, @intCast(self.title.len)) - 2) / 2;
            buf.setChar(title_x, dialog_area.y, ' ', self.title_style);
            _ = buf.writeStr(title_x + 1, dialog_area.y, self.title, self.title_style);
            buf.setChar(title_x + 1 + @as(u16, @intCast(self.title.len)), dialog_area.y, ' ', self.title_style);
        }

        // Draw message (word wrapped)
        const msg_area = Rect{
            .x = dialog_area.x + 2,
            .y = dialog_area.y + 2,
            .width = if (dialog_area.width > 4) dialog_area.width - 4 else 1,
            .height = if (dialog_area.height > 5) dialog_area.height - 5 else 1,
        };
        _ = buf.writeWrapped(msg_area, self.message, self.message_style);

        // Draw buttons
        const button_y = dialog_area.y + dialog_area.height - 2;
        var total_btn_width: u16 = 0;
        for (self.buttons) |btn| {
            total_btn_width += @intCast(btn.label.len + 2);
        }
        total_btn_width += @intCast((self.buttons.len - 1) * 2); // Spacing

        var btn_x = dialog_area.x + (dialog_area.width - total_btn_width) / 2;

        for (self.buttons, 0..) |btn, i| {
            const is_selected = i == self.selected_button;
            const btn_style = if (is_selected)
                self.button_selected_style
            else
                self.button_style;

            // Draw button with brackets
            buf.setChar(btn_x, button_y, '[', btn_style);
            btn_x += 1;
            _ = buf.writeStr(btn_x, button_y, btn.label, btn_style);
            btn_x += @intCast(btn.label.len);
            buf.setChar(btn_x, button_y, ']', btn_style);
            btn_x += 3; // ] + spacing
        }
    }

    pub fn handleEvent(self: *Self, event: Event) bool {
        if (!self.visible) return false;

        switch (event) {
            .key => |k| {
                switch (k.key) {
                    .special => |s| switch (s) {
                        .escape => {
                            if (self.closeable) {
                                self.closeWithResult(.cancel);
                                return true;
                            }
                        },
                        .left, .backtab => {
                            if (self.selected_button > 0) {
                                self.selected_button -= 1;
                            } else {
                                self.selected_button = self.buttons.len - 1;
                            }
                            return true;
                        },
                        .right, .tab => {
                            self.selected_button = (self.selected_button + 1) % self.buttons.len;
                            return true;
                        },
                        .enter => {
                            const result = self.getResultForButton(self.selected_button);
                            self.closeWithResult(result);
                            return true;
                        },
                        else => {},
                    },
                    .char => |c| {
                        // Check button shortcuts
                        for (self.buttons, 0..) |btn, i| {
                            if (btn.key) |key| {
                                if (c == key or c == std.ascii.toUpper(@intCast(key))) {
                                    self.selected_button = i;
                                    const result = self.getResultForButton(i);
                                    self.closeWithResult(result);
                                    return true;
                                }
                            }
                        }
                    },
                }
            },
            .mouse => |m| {
                if (m.kind == .press and m.button == .left) {
                    // Check if clicked on a button
                    // Simplified - just cycle through buttons on click
                    self.selected_button = (self.selected_button + 1) % self.buttons.len;
                    return true;
                }
            },
            else => {},
        }
        return true; // Modal consumes all events when visible
    }

    fn getResultForButton(self: *Self, idx: usize) DialogResult {
        if (idx >= self.buttons.len) return .none;

        const btn = self.buttons[idx];
        if (btn.is_cancel) return .cancel;
        if (btn.is_default) return .ok;

        // Check label for common results
        if (std.mem.indexOf(u8, btn.label, "Yes") != null) return .yes;
        if (std.mem.indexOf(u8, btn.label, "No") != null) return .no;
        if (std.mem.indexOf(u8, btn.label, "OK") != null) return .ok;
        if (std.mem.indexOf(u8, btn.label, "Cancel") != null) return .cancel;

        return .custom;
    }

    pub fn minSize(self: *Self) Size {
        return .{ .width = self.width, .height = self.height };
    }

    pub fn canFocus(self: *Self) bool {
        return self.visible;
    }
};

/// Toast notification (temporary message)
pub const Toast = struct {
    message: []const u8,
    style: Style,
    duration_ticks: u32,
    remaining_ticks: u32,
    position: enum { top, bottom, center },

    const Self = @This();

    pub fn init(message: []const u8, duration_ticks: u32) Self {
        return .{
            .message = message,
            .style = Style{ .fg = Color.bright_white, .bg = Color.gray },
            .duration_ticks = duration_ticks,
            .remaining_ticks = duration_ticks,
            .position = .bottom,
        };
    }

    /// Check if toast is active
    pub fn isActive(self: *const Self) bool {
        return self.remaining_ticks > 0;
    }

    /// Tick the toast timer
    pub fn tick(self: *Self) void {
        if (self.remaining_ticks > 0) {
            self.remaining_ticks -= 1;
        }
    }

    /// Reset the toast
    pub fn reset(self: *Self) void {
        self.remaining_ticks = self.duration_ticks;
    }

    /// Render the toast
    pub fn render(self: *const Self, area: Rect, buf: *Buffer) void {
        if (!self.isActive()) return;

        const msg_len: u16 = @intCast(@min(self.message.len, area.width - 4));
        const toast_width = msg_len + 4;
        const toast_x = area.x + (area.width - toast_width) / 2;

        const toast_y = switch (self.position) {
            .top => area.y + 1,
            .bottom => area.y + area.height - 2,
            .center => area.y + area.height / 2,
        };

        // Draw toast background
        buf.fill(
            Rect{ .x = toast_x, .y = toast_y, .width = toast_width, .height = 1 },
            core.Cell.styled(' ', self.style),
        );

        // Draw message
        _ = buf.writeTruncated(toast_x + 2, toast_y, msg_len, self.message, self.style);
    }
};

test "Modal basic" {
    var modal = Modal.alert("Test", "This is a test message");
    try std.testing.expect(!modal.isVisible());

    modal.show();
    try std.testing.expect(modal.isVisible());

    modal.hide();
    try std.testing.expect(!modal.isVisible());
}
