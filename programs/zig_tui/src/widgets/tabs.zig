//! Tabs widget - tabbed container for switching between views
//!
//! Displays a row of tabs with content switching.

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

/// Tab position
pub const TabPosition = enum {
    top,
    bottom,
};

/// Tab style
pub const TabStyle = enum {
    simple,     // | Tab1 | Tab2 |
    rounded,    // ╭─Tab1─╮╭─Tab2─╮
    underline,  // Tab1  Tab2
               //  ───
};

/// Callback when tab changes
pub const TabChangeCallback = *const fn (*Tabs, usize) void;

/// Individual tab definition
pub const Tab = struct {
    title: []const u8,
    enabled: bool = true,
    closeable: bool = false,
};

/// Tabs widget
pub const Tabs = struct {
    tabs: []const Tab,
    selected: usize,
    scroll_offset: usize,  // For when tabs don't fit

    // Options
    position: TabPosition,
    tab_style: TabStyle,
    show_index: bool,      // Show 1, 2, 3 before tabs

    // Styles
    active_style: Style,
    inactive_style: Style,
    disabled_style: Style,
    border_style: Style,

    // Callback
    on_change: ?TabChangeCallback,

    // State
    focused: bool,
    visible_width: u16,

    const Self = @This();

    /// Get Widget interface
    pub fn widget(self: *Self) Widget {
        return makeWidget(Self, self);
    }

    /// Create tabs from titles
    pub fn init(tabs: []const Tab) Self {
        return .{
            .tabs = tabs,
            .selected = 0,
            .scroll_offset = 0,
            .position = .top,
            .tab_style = .simple,
            .show_index = false,
            .active_style = Style{ .fg = Color.black, .bg = Color.white, .attrs = .{ .bold = true } },
            .inactive_style = Style{ .fg = Color.white },
            .disabled_style = Style{ .fg = Color.gray },
            .border_style = Style{ .fg = Color.gray },
            .on_change = null,
            .focused = false,
            .visible_width = 80,
        };
    }

    /// Create tabs from string slice (convenience)
    pub fn fromStrings(comptime titles: []const []const u8) Self {
        comptime var tabs: [titles.len]Tab = undefined;
        inline for (titles, 0..) |title, i| {
            tabs[i] = .{ .title = title };
        }
        return init(&tabs);
    }

    /// Set selected tab
    pub fn select(self: *Self, index: usize) void {
        if (index < self.tabs.len and self.tabs[index].enabled and self.selected != index) {
            self.selected = index;
            self.ensureVisible();
            if (self.on_change) |cb| cb(self, index);
        }
    }

    /// Get selected tab index
    pub fn getSelected(self: *const Self) usize {
        return self.selected;
    }

    /// Get selected tab
    pub fn getSelectedTab(self: *const Self) ?Tab {
        if (self.selected < self.tabs.len) {
            return self.tabs[self.selected];
        }
        return null;
    }

    /// Select next tab
    pub fn selectNext(self: *Self) void {
        var next = self.selected + 1;
        while (next < self.tabs.len) {
            if (self.tabs[next].enabled) {
                self.select(next);
                return;
            }
            next += 1;
        }
        // Wrap around
        next = 0;
        while (next < self.selected) {
            if (self.tabs[next].enabled) {
                self.select(next);
                return;
            }
            next += 1;
        }
    }

    /// Select previous tab
    pub fn selectPrev(self: *Self) void {
        if (self.selected > 0) {
            var prev = self.selected - 1;
            while (true) {
                if (self.tabs[prev].enabled) {
                    self.select(prev);
                    return;
                }
                if (prev == 0) break;
                prev -= 1;
            }
        }
        // Wrap around
        var prev = self.tabs.len - 1;
        while (prev > self.selected) {
            if (self.tabs[prev].enabled) {
                self.select(prev);
                return;
            }
            prev -= 1;
        }
    }

    /// Set tab style
    pub fn setStyle(self: *Self, style: TabStyle) *Self {
        self.tab_style = style;
        return self;
    }

    /// Set tab position
    pub fn setPosition(self: *Self, pos: TabPosition) *Self {
        self.position = pos;
        return self;
    }

    /// Show index numbers
    pub fn setShowIndex(self: *Self, show: bool) *Self {
        self.show_index = show;
        return self;
    }

    /// Set change callback
    pub fn onChange(self: *Self, callback: TabChangeCallback) *Self {
        self.on_change = callback;
        return self;
    }

    fn ensureVisible(self: *Self) void {
        if (self.tabs.len == 0) return;

        // If selected is before scroll window, scroll left to it
        if (self.selected < self.scroll_offset) {
            self.scroll_offset = self.selected;
            return;
        }

        // Calculate if selected tab is visible from current scroll_offset
        // by summing widths from scroll_offset to selected
        while (self.scroll_offset < self.selected) {
            var total_width: u16 = 0;
            var fits = true;
            for (self.tabs[self.scroll_offset..self.selected + 1], self.scroll_offset..) |tab, idx| {
                total_width += self.getTabWidth(tab, idx);
                if (total_width > self.visible_width) {
                    fits = false;
                    break;
                }
            }
            if (fits) break;
            self.scroll_offset += 1;
        }
    }

    fn getTabWidth(self: *const Self, tab: Tab, index: usize) u16 {
        var width: u16 = @intCast(tab.title.len);

        // Add space for index
        if (self.show_index) {
            width += 3; // "1. "
        }

        // Add space for close button
        if (tab.closeable) {
            width += 2; // " x"
        }

        // Add padding/borders based on style
        width += switch (self.tab_style) {
            .simple => 4,     // "| " + " |"
            .rounded => 4,    // "╭─" + "─╮"
            .underline => 2,  // padding
        };

        _ = index;
        return width;
    }

    // Widget interface

    pub fn render(self: *Self, area: Rect, buf: *Buffer, state: Widget.RenderState) void {
        if (area.isEmpty() or self.tabs.len == 0) return;

        self.focused = state.focused;
        self.visible_width = area.width;

        const tab_y = if (self.position == .top) area.y else area.y + area.height - 1;

        switch (self.tab_style) {
            .simple => self.renderSimple(buf, area.x, tab_y, area.width),
            .rounded => self.renderRounded(buf, area.x, tab_y, area.width),
            .underline => self.renderUnderline(buf, area.x, tab_y, area.width),
        }
    }

    fn renderSimple(self: *Self, buf: *Buffer, x: u16, y: u16, width: u16) void {
        var cx = x;

        for (self.tabs[self.scroll_offset..], self.scroll_offset..) |tab, i| {
            if (cx >= x + width) break;

            const is_selected = i == self.selected;
            const style = if (!tab.enabled)
                self.disabled_style
            else if (is_selected)
                self.active_style
            else
                self.inactive_style;

            // Draw separator
            buf.setChar(cx, y, '│', self.border_style);
            cx += 1;

            // Draw index if enabled
            if (self.show_index) {
                var idx_buf: [4]u8 = undefined;
                const idx_str = std.fmt.bufPrint(&idx_buf, "{d}.", .{i + 1}) catch "?.";
                _ = buf.writeStr(cx, y, idx_str, style);
                cx += @intCast(idx_str.len);
            }

            // Draw tab title with padding
            buf.setChar(cx, y, ' ', style);
            cx += 1;

            const title_width = @min(tab.title.len, width - (cx - x) - 2);
            _ = buf.writeStr(cx, y, tab.title[0..title_width], style);
            cx += @intCast(title_width);

            buf.setChar(cx, y, ' ', style);
            cx += 1;

            // Draw close button if closeable
            if (tab.closeable) {
                buf.setChar(cx, y, 'x', Style{ .fg = Color.red });
                cx += 1;
            }
        }

        // Final separator
        if (cx < x + width) {
            buf.setChar(cx, y, '│', self.border_style);
        }
    }

    fn renderRounded(self: *Self, buf: *Buffer, x: u16, y: u16, width: u16) void {
        var cx = x;

        for (self.tabs[self.scroll_offset..], self.scroll_offset..) |tab, i| {
            if (cx >= x + width - 3) break;

            const is_selected = i == self.selected;
            const style = if (!tab.enabled)
                self.disabled_style
            else if (is_selected)
                self.active_style
            else
                self.inactive_style;

            // Top corners/borders
            buf.setChar(cx, y, if (is_selected) '╭' else '┌', self.border_style);
            cx += 1;
            buf.setChar(cx, y, '─', self.border_style);
            cx += 1;

            // Title
            const title_width = @min(tab.title.len, width - (cx - x) - 3);
            _ = buf.writeStr(cx, y, tab.title[0..title_width], style);
            cx += @intCast(title_width);

            buf.setChar(cx, y, '─', self.border_style);
            cx += 1;
            buf.setChar(cx, y, if (is_selected) '╮' else '┐', self.border_style);
            cx += 1;
        }
    }

    fn renderUnderline(self: *Self, buf: *Buffer, x: u16, y: u16, width: u16) void {
        var cx = x;

        for (self.tabs[self.scroll_offset..], self.scroll_offset..) |tab, i| {
            if (cx >= x + width) break;

            const is_selected = i == self.selected;
            const style = if (!tab.enabled)
                self.disabled_style
            else if (is_selected)
                self.active_style
            else
                self.inactive_style;

            // Draw title
            const title_width = @min(tab.title.len, width - (cx - x) - 2);
            _ = buf.writeStr(cx, y, tab.title[0..title_width], style);

            // Draw underline for selected tab
            if (is_selected and y + 1 < 65535) {
                var ux: u16 = 0;
                while (ux < title_width) : (ux += 1) {
                    buf.setChar(cx + ux, y + 1, '─', self.active_style);
                }
            }

            cx += @intCast(title_width);

            // Spacing between tabs
            cx += 2;
        }
    }

    pub fn handleEvent(self: *Self, event: Event) bool {
        switch (event) {
            .key => |k| {
                switch (k.key) {
                    .special => |s| switch (s) {
                        .left => {
                            self.selectPrev();
                            return true;
                        },
                        .right => {
                            self.selectNext();
                            return true;
                        },
                        .home => {
                            self.select(0);
                            return true;
                        },
                        .end => {
                            self.select(self.tabs.len - 1);
                            return true;
                        },
                        else => {},
                    },
                    .char => |c| {
                        // Number keys 1-9 select tabs
                        if (c >= '1' and c <= '9') {
                            const idx: usize = c - '1';
                            if (idx < self.tabs.len) {
                                self.select(idx);
                                return true;
                            }
                        }
                        // Alt+Left/Right for tab switching (common pattern)
                        if (k.modifiers.alt) {
                            if (c == 'h' or c == 'H') {
                                self.selectPrev();
                                return true;
                            } else if (c == 'l' or c == 'L') {
                                self.selectNext();
                                return true;
                            }
                        }
                    },
                }
            },
            .mouse => |m| {
                if (m.kind == .press and m.button == .left) {
                    // Calculate which tab was clicked
                    var cx: u16 = 0;
                    for (self.tabs, 0..) |tab, i| {
                        const tab_width = self.getTabWidth(tab, i);
                        if (m.x >= cx and m.x < cx + tab_width) {
                            self.select(i);
                            return true;
                        }
                        cx += tab_width;
                    }
                }
            },
            else => {},
        }
        return false;
    }

    pub fn minSize(self: *Self) Size {
        var total_width: u16 = 0;
        for (self.tabs, 0..) |tab, i| {
            total_width += self.getTabWidth(tab, i);
        }
        return .{
            .width = total_width,
            .height = if (self.tab_style == .underline) 2 else 1,
        };
    }

    pub fn canFocus(self: *Self) bool {
        return self.tabs.len > 0;
    }
};

test "Tabs selection" {
    const tabs = [_]Tab{
        .{ .title = "Tab 1" },
        .{ .title = "Tab 2" },
        .{ .title = "Tab 3" },
    };
    var t = Tabs.init(&tabs);
    try std.testing.expectEqual(@as(usize, 0), t.getSelected());

    t.selectNext();
    try std.testing.expectEqual(@as(usize, 1), t.getSelected());

    t.selectPrev();
    try std.testing.expectEqual(@as(usize, 0), t.getSelected());
}
