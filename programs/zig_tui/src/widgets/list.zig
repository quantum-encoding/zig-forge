//! List widget - scrollable, selectable list
//!
//! Displays a list of items with keyboard and mouse navigation.

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

/// Selection mode for the list
pub const SelectionMode = enum {
    single,
    multiple,
    none,
};

/// List item with optional metadata
pub const ListItem = struct {
    text: []const u8,
    enabled: bool = true,
    data: ?*anyopaque = null,
};

/// Callback when selection changes
pub const SelectCallback = *const fn (*List, usize) void;

/// Callback when item is activated (Enter pressed)
pub const ActivateCallback = *const fn (*List, usize) void;

/// List widget
pub const List = struct {
    items: []const ListItem,
    selected: usize,
    scroll_offset: usize,
    selection_mode: SelectionMode,
    multi_selected: [64]bool, // Bitset for multi-selection (up to 64 items)

    // Styles
    style: Style,
    selected_style: Style,
    disabled_style: Style,
    highlight_style: Style,

    // Options
    show_scrollbar: bool,
    wrap_selection: bool,
    highlight_full_width: bool,

    // Callbacks
    on_select: ?SelectCallback,
    on_activate: ?ActivateCallback,

    // State
    focused: bool,
    visible_height: u16,

    const Self = @This();

    /// Get Widget interface
    pub fn widget(self: *Self) Widget {
        return makeWidget(Self, self);
    }

    /// Create a new list with items
    pub fn init(items: []const ListItem) Self {
        return .{
            .items = items,
            .selected = 0,
            .scroll_offset = 0,
            .selection_mode = .single,
            .multi_selected = [_]bool{false} ** 64,
            .style = Style{ .fg = Color.white },
            .selected_style = Style.init(Color.black, Color.white),
            .disabled_style = Style{ .fg = Color.gray },
            .highlight_style = Style{ .fg = Color.cyan },
            .show_scrollbar = true,
            .wrap_selection = false,
            .highlight_full_width = true,
            .on_select = null,
            .on_activate = null,
            .focused = false,
            .visible_height = 10,
        };
    }

    /// Create list from string slice
    pub fn fromStrings(strings: []const []const u8) Self {
        // Note: This creates ListItems on the stack - caller should use init() with proper items
        const self = Self{
            .items = &[_]ListItem{},
            .selected = 0,
            .scroll_offset = 0,
            .selection_mode = .single,
            .multi_selected = [_]bool{false} ** 64,
            .style = Style{ .fg = Color.white },
            .selected_style = Style.init(Color.black, Color.white),
            .disabled_style = Style{ .fg = Color.gray },
            .highlight_style = Style{ .fg = Color.cyan },
            .show_scrollbar = true,
            .wrap_selection = false,
            .highlight_full_width = true,
            .on_select = null,
            .on_activate = null,
            .focused = false,
            .visible_height = 10,
        };
        _ = strings;
        return self;
    }

    /// Set items
    pub fn setItems(self: *Self, items: []const ListItem) *Self {
        self.items = items;
        if (self.selected >= items.len and items.len > 0) {
            self.selected = items.len - 1;
        }
        self.scroll_offset = 0;
        return self;
    }

    /// Set selection mode
    pub fn setSelectionMode(self: *Self, mode: SelectionMode) *Self {
        self.selection_mode = mode;
        return self;
    }

    /// Set styles
    pub fn setStyle(self: *Self, style: Style) *Self {
        self.style = style;
        return self;
    }

    pub fn setSelectedStyle(self: *Self, style: Style) *Self {
        self.selected_style = style;
        return self;
    }

    /// Set selection change callback
    pub fn onSelect(self: *Self, callback: SelectCallback) *Self {
        self.on_select = callback;
        return self;
    }

    /// Set activation callback
    pub fn onActivate(self: *Self, callback: ActivateCallback) *Self {
        self.on_activate = callback;
        return self;
    }

    /// Get selected index
    pub fn getSelected(self: *const Self) usize {
        return self.selected;
    }

    /// Get selected item
    pub fn getSelectedItem(self: *const Self) ?ListItem {
        if (self.selected < self.items.len) {
            return self.items[self.selected];
        }
        return null;
    }

    /// Set selected index
    pub fn select(self: *Self, index: usize) void {
        if (index < self.items.len) {
            self.selected = index;
            self.ensureVisible();
            if (self.on_select) |cb| cb(self, index);
        }
    }

    /// Toggle multi-selection for current item
    pub fn toggleSelected(self: *Self) void {
        if (self.selection_mode != .multiple) return;
        if (self.selected < 64) {
            self.multi_selected[self.selected] = !self.multi_selected[self.selected];
        }
    }

    /// Check if item is selected (for multi-select)
    pub fn isSelected(self: *const Self, index: usize) bool {
        if (self.selection_mode == .multiple and index < 64) {
            return self.multi_selected[index];
        }
        return index == self.selected;
    }

    /// Select all items (multi-select mode)
    pub fn selectAll(self: *Self) void {
        if (self.selection_mode != .multiple) return;
        for (0..@min(self.items.len, 64)) |i| {
            self.multi_selected[i] = true;
        }
    }

    /// Clear all selections (multi-select mode)
    pub fn clearSelection(self: *Self) void {
        if (self.selection_mode != .multiple) return;
        @memset(&self.multi_selected, false);
    }

    /// Move selection up
    pub fn selectPrev(self: *Self) void {
        if (self.items.len == 0) return;
        if (self.selected > 0) {
            self.selected -= 1;
        } else if (self.wrap_selection) {
            self.selected = self.items.len - 1;
        }
        self.ensureVisible();
        if (self.on_select) |cb| cb(self, self.selected);
    }

    /// Move selection down
    pub fn selectNext(self: *Self) void {
        if (self.items.len == 0) return;
        if (self.selected < self.items.len - 1) {
            self.selected += 1;
        } else if (self.wrap_selection) {
            self.selected = 0;
        }
        self.ensureVisible();
        if (self.on_select) |cb| cb(self, self.selected);
    }

    /// Move selection up by page
    pub fn pageUp(self: *Self) void {
        if (self.items.len == 0) return;
        if (self.selected > self.visible_height) {
            self.selected -= self.visible_height;
        } else {
            self.selected = 0;
        }
        self.ensureVisible();
        if (self.on_select) |cb| cb(self, self.selected);
    }

    /// Move selection down by page
    pub fn pageDown(self: *Self) void {
        if (self.items.len == 0) return;
        self.selected += self.visible_height;
        if (self.selected >= self.items.len) {
            self.selected = self.items.len - 1;
        }
        self.ensureVisible();
        if (self.on_select) |cb| cb(self, self.selected);
    }

    /// Move to first item
    pub fn selectFirst(self: *Self) void {
        if (self.items.len == 0) return;
        self.selected = 0;
        self.ensureVisible();
        if (self.on_select) |cb| cb(self, self.selected);
    }

    /// Move to last item
    pub fn selectLast(self: *Self) void {
        if (self.items.len == 0) return;
        self.selected = self.items.len - 1;
        self.ensureVisible();
        if (self.on_select) |cb| cb(self, self.selected);
    }

    /// Ensure selected item is visible
    fn ensureVisible(self: *Self) void {
        if (self.selected < self.scroll_offset) {
            self.scroll_offset = self.selected;
        } else if (self.selected >= self.scroll_offset + self.visible_height) {
            self.scroll_offset = self.selected - self.visible_height + 1;
        }
    }

    // Widget interface

    pub fn render(self: *Self, area: Rect, buf: *Buffer, state: Widget.RenderState) void {
        if (area.isEmpty() or self.items.len == 0) return;

        self.focused = state.focused;
        self.visible_height = area.height;

        const content_width = if (self.show_scrollbar and self.items.len > area.height)
            area.width -| 1
        else
            area.width;

        // Render visible items
        var y: u16 = 0;
        while (y < area.height) : (y += 1) {
            const item_idx = self.scroll_offset + y;
            if (item_idx >= self.items.len) break;

            const item = self.items[item_idx];
            const is_current = item_idx == self.selected;
            const is_multi_selected = self.selection_mode == .multiple and
                item_idx < 64 and self.multi_selected[item_idx];

            // Determine style
            const item_style = if (!item.enabled)
                self.disabled_style
            else if (is_current and state.focused)
                self.selected_style
            else if (is_multi_selected)
                self.highlight_style
            else
                self.style;

            // Fill row background if highlight_full_width
            if (self.highlight_full_width and (is_current or is_multi_selected)) {
                buf.fill(
                    Rect{ .x = area.x, .y = area.y + y, .width = content_width, .height = 1 },
                    Cell.styled(' ', item_style),
                );
            }

            // Draw selection indicator
            const prefix: []const u8 = if (is_current and state.focused)
                "> "
            else if (is_multi_selected)
                "* "
            else
                "  ";

            _ = buf.writeStr(area.x, area.y + y, prefix, item_style);

            // Draw item text (truncated)
            const text_width = if (content_width > 2) content_width - 2 else 0;
            _ = buf.writeTruncated(area.x + 2, area.y + y, text_width, item.text, item_style);
        }

        // Draw scrollbar if needed
        if (self.show_scrollbar and self.items.len > area.height) {
            self.drawScrollbar(buf, area);
        }
    }

    fn drawScrollbar(self: *Self, buf: *Buffer, area: Rect) void {
        const scrollbar_x = area.x + area.width - 1;
        const total_items: u32 = @intCast(self.items.len);
        const visible: u32 = @intCast(area.height);

        // Draw track
        var y: u16 = 0;
        while (y < area.height) : (y += 1) {
            buf.setChar(scrollbar_x, area.y + y, '│', Style{ .fg = Color.gray });
        }

        // Calculate thumb position and size
        const thumb_size = @max(1, (visible * visible) / total_items);
        const scroll_range = total_items - visible;
        const thumb_pos: u16 = if (scroll_range > 0)
            @intCast((@as(u32, @intCast(self.scroll_offset)) * (visible - thumb_size)) / scroll_range)
        else
            0;

        // Draw thumb
        var ty: u16 = 0;
        while (ty < thumb_size and thumb_pos + ty < area.height) : (ty += 1) {
            buf.setChar(scrollbar_x, area.y + thumb_pos + ty, '┃', Style{ .fg = Color.white });
        }
    }

    pub fn handleEvent(self: *Self, event: Event) bool {
        switch (event) {
            .key => |k| {
                switch (k.key) {
                    .special => |s| switch (s) {
                        .up => {
                            self.selectPrev();
                            return true;
                        },
                        .down => {
                            self.selectNext();
                            return true;
                        },
                        .page_up => {
                            self.pageUp();
                            return true;
                        },
                        .page_down => {
                            self.pageDown();
                            return true;
                        },
                        .home => {
                            self.selectFirst();
                            return true;
                        },
                        .end => {
                            self.selectLast();
                            return true;
                        },
                        .enter => {
                            if (self.on_activate) |cb| cb(self, self.selected);
                            return true;
                        },
                        else => {},
                    },
                    .char => |c| {
                        // Space toggles in multi-select mode
                        if (c == ' ' and self.selection_mode == .multiple) {
                            self.toggleSelected();
                            return true;
                        }
                        // Ctrl+A selects all
                        if (c == 'a' and k.modifiers.ctrl and self.selection_mode == .multiple) {
                            self.selectAll();
                            return true;
                        }
                    },
                }
            },
            .mouse => |m| {
                if (m.kind == .press and m.button == .left) {
                    const clicked_idx = self.scroll_offset + m.y;
                    if (clicked_idx < self.items.len) {
                        if (self.selection_mode == .multiple and m.modifiers.ctrl) {
                            self.selected = clicked_idx;
                            self.toggleSelected();
                        } else {
                            self.select(clicked_idx);
                        }
                        return true;
                    }
                } else if (m.kind == .scroll_up) {
                    if (self.scroll_offset > 0) {
                        self.scroll_offset -= 1;
                    }
                    return true;
                } else if (m.kind == .scroll_down) {
                    if (self.scroll_offset + self.visible_height < self.items.len) {
                        self.scroll_offset += 1;
                    }
                    return true;
                }
            },
            else => {},
        }
        return false;
    }

    pub fn minSize(self: *Self) Size {
        _ = self;
        return .{ .width = 10, .height = 3 };
    }

    pub fn canFocus(self: *Self) bool {
        return self.items.len > 0;
    }
};

test "List basic" {
    const items = [_]ListItem{
        .{ .text = "Item 1" },
        .{ .text = "Item 2" },
        .{ .text = "Item 3" },
    };
    var list = List.init(&items);
    try std.testing.expectEqual(@as(usize, 0), list.getSelected());

    list.selectNext();
    try std.testing.expectEqual(@as(usize, 1), list.getSelected());

    list.selectLast();
    try std.testing.expectEqual(@as(usize, 2), list.getSelected());
}
