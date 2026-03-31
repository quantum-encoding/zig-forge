//! Focus management
//!
//! Handles focus traversal between widgets, supporting Tab/Shift+Tab
//! navigation and mouse click-to-focus.

const std = @import("std");
const widget_mod = @import("widget.zig");
const input = @import("../input/input.zig");
const core = @import("../core/core.zig");

pub const Widget = widget_mod.Widget;
pub const Event = input.Event;
pub const Key = input.Key;
pub const Rect = core.Rect;

/// Focus manager for widget trees
pub const FocusManager = struct {
    /// Flattened list of focusable widgets
    focusable: std.ArrayListUnmanaged(FocusEntry),
    /// Allocator for the list
    allocator: std.mem.Allocator,
    /// Current focus index (-1 = none)
    focus_index: i32,
    /// Whether focus is trapped (modal dialogs)
    focus_trap: bool,

    const Self = @This();

    pub const FocusEntry = struct {
        widget: Widget,
        area: Rect,
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .focusable = .{},
            .allocator = allocator,
            .focus_index = -1,
            .focus_trap = false,
        };
    }

    pub fn deinit(self: *Self) void {
        self.focusable.deinit(self.allocator);
    }

    /// Clear the focusable list
    pub fn clear(self: *Self) void {
        self.focusable.clearRetainingCapacity();
    }

    /// Register a focusable widget
    pub fn register(self: *Self, wdg: Widget, area: Rect) !void {
        if (wdg.canFocus()) {
            try self.focusable.append(self.allocator, .{ .widget = wdg, .area = area });
        }
    }

    /// Build focus list from widget tree
    pub fn buildFromTree(self: *Self, root: Widget, root_area: Rect) !void {
        self.clear();
        try self.collectFocusable(root, root_area);
    }

    fn collectFocusable(self: *Self, wdg: Widget, area: Rect) !void {
        if (wdg.canFocus()) {
            try self.focusable.append(self.allocator, .{ .widget = wdg, .area = area });
        }

        // Recurse into children
        const child_widgets = wdg.children();
        if (child_widgets.len == 0) return;

        // Estimate child areas using minSize hints.
        // Default to vertical stacking since we don't know the container's layout direction.
        var y_offset: u16 = area.y;
        const per_child_height = if (child_widgets.len > 0)
            area.height / @as(u16, @intCast(child_widgets.len))
        else
            area.height;

        for (child_widgets) |child| {
            const child_min = child.minSize();
            const child_height = if (child_min.height > 0 and child_min.height < per_child_height)
                child_min.height
            else
                per_child_height;

            const remaining_height = if (y_offset >= area.y + area.height) 0 else area.y + area.height - y_offset;
            const actual_height = @min(child_height, remaining_height);

            if (actual_height == 0) break;

            const child_area = Rect{
                .x = area.x,
                .y = y_offset,
                .width = area.width,
                .height = actual_height,
            };
            try self.collectFocusable(child, child_area);
            y_offset += actual_height;
        }
    }

    /// Get currently focused widget
    pub fn getFocused(self: *const Self) ?Widget {
        if (self.focus_index < 0 or self.focus_index >= @as(i32, @intCast(self.focusable.items.len))) {
            return null;
        }
        return self.focusable.items[@intCast(self.focus_index)].widget;
    }

    /// Focus next widget
    pub fn focusNext(self: *Self) void {
        if (self.focusable.items.len == 0) return;

        // Blur current
        if (self.getFocused()) |current| {
            current.onBlur();
        }

        // Move to next
        self.focus_index += 1;
        if (self.focus_index >= @as(i32, @intCast(self.focusable.items.len))) {
            self.focus_index = 0;
        }

        // Focus new
        if (self.getFocused()) |next| {
            next.onFocus();
        }
    }

    /// Focus previous widget
    pub fn focusPrevious(self: *Self) void {
        if (self.focusable.items.len == 0) return;

        // Blur current
        if (self.getFocused()) |current| {
            current.onBlur();
        }

        // Move to previous
        self.focus_index -= 1;
        if (self.focus_index < 0) {
            self.focus_index = @intCast(self.focusable.items.len - 1);
        }

        // Focus new
        if (self.getFocused()) |prev| {
            prev.onFocus();
        }
    }

    /// Focus widget at specific index
    pub fn focusIndex(self: *Self, index: usize) void {
        if (index >= self.focusable.items.len) return;

        // Blur current
        if (self.getFocused()) |current| {
            current.onBlur();
        }

        self.focus_index = @intCast(index);

        // Focus new
        if (self.getFocused()) |next| {
            next.onFocus();
        }
    }

    /// Focus widget by ID
    pub fn focusById(self: *Self, id: []const u8) bool {
        for (self.focusable.items, 0..) |entry, i| {
            if (entry.widget.getId()) |wid| {
                if (std.mem.eql(u8, wid, id)) {
                    self.focusIndex(i);
                    return true;
                }
            }
        }
        return false;
    }

    /// Focus widget at screen position (for mouse clicks)
    pub fn focusAt(self: *Self, x: u16, y: u16) bool {
        for (self.focusable.items, 0..) |entry, i| {
            if (entry.area.contains(x, y)) {
                self.focusIndex(i);
                return true;
            }
        }
        return false;
    }

    /// Clear focus
    pub fn clearFocus(self: *Self) void {
        if (self.getFocused()) |current| {
            current.onBlur();
        }
        self.focus_index = -1;
    }

    /// Check if widget at index is focused
    pub fn isFocused(self: *const Self, index: usize) bool {
        return self.focus_index == @as(i32, @intCast(index));
    }

    /// Check if specific widget is focused
    pub fn isWidgetFocused(self: *const Self, widget: Widget) bool {
        if (self.focus_index < 0) return false;
        const focused = self.focusable.items[@intCast(self.focus_index)];
        return focused.widget.ptr == widget.ptr;
    }

    /// Handle focus-related events
    /// Returns true if event was consumed
    pub fn handleEvent(self: *Self, event: Event) bool {
        switch (event) {
            .key => |k| {
                switch (k.key) {
                    .special => |s| switch (s) {
                        .tab => {
                            self.focusNext();
                            return true;
                        },
                        .backtab => {
                            self.focusPrevious();
                            return true;
                        },
                        else => {},
                    },
                    .char => {},
                }
            },
            .mouse => |m| {
                if (m.kind == .press) {
                    return self.focusAt(m.x, m.y);
                }
            },
            else => {},
        }
        return false;
    }

    /// Enable focus trap (modal mode)
    pub fn enableTrap(self: *Self) void {
        self.focus_trap = true;
    }

    /// Disable focus trap
    pub fn disableTrap(self: *Self) void {
        self.focus_trap = false;
    }
};

test "FocusManager basic" {
    var fm = FocusManager.init(std.testing.allocator);
    defer fm.deinit();

    try std.testing.expect(fm.getFocused() == null);
}
