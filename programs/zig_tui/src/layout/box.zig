//! Box layout - arranges widgets horizontally or vertically
//!
//! Supports fixed, flex, and percentage-based sizing.

const std = @import("std");
const core = @import("../core/core.zig");
const widget_mod = @import("../widget/mod.zig");
const input = @import("../input/input.zig");

pub const Buffer = core.Buffer;
pub const Rect = core.Rect;
pub const Size = core.Size;
pub const Constraint = core.Constraint;
pub const Widget = widget_mod.Widget;
pub const makeWidget = widget_mod.makeWidget;
pub const Event = input.Event;

/// Layout direction
pub const Direction = enum {
    horizontal,
    vertical,
};

/// Child entry with constraint
pub const LayoutChild = struct {
    widget: Widget,
    constraint: Constraint,
};

/// Box layout container
pub const BoxLayout = struct {
    direction: Direction,
    children_list: std.ArrayListUnmanaged(LayoutChild),
    spacing: u16,
    padding: u16,
    computed_areas: std.ArrayListUnmanaged(Rect),
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Get Widget interface for this layout
    pub fn widget(self: *Self) Widget {
        return makeWidget(Self, self);
    }

    pub fn init(allocator: std.mem.Allocator, direction: Direction) Self {
        return .{
            .direction = direction,
            .children_list = .{},
            .spacing = 0,
            .padding = 0,
            .computed_areas = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.children_list.deinit(self.allocator);
        self.computed_areas.deinit(self.allocator);
    }

    /// Add a child with flex sizing (default)
    pub fn add(self: *Self, w: Widget) !void {
        try self.addConstrained(w, .{ .flex = 1 });
    }

    /// Add a child with specific constraint
    pub fn addConstrained(self: *Self, w: Widget, constraint: Constraint) !void {
        try self.children_list.append(self.allocator, .{
            .widget = w,
            .constraint = constraint,
        });
    }

    /// Add a fixed-size child
    pub fn addFixed(self: *Self, w: Widget, size: u16) !void {
        try self.addConstrained(w, .{ .fixed = size });
    }

    /// Set spacing between children
    pub fn setSpacing(self: *Self, spacing: u16) void {
        self.spacing = spacing;
    }

    /// Set padding around content
    pub fn setPadding(self: *Self, padding: u16) void {
        self.padding = padding;
    }

    /// Compute layout for given area
    pub fn computeLayout(self: *Self, area: Rect) void {
        self.computed_areas.clearRetainingCapacity();

        const inner = area.shrink(self.padding);
        if (inner.isEmpty() or self.children_list.items.len == 0) return;

        const n = self.children_list.items.len;
        const total_spacing = if (n > 1) self.spacing * @as(u16, @intCast(n - 1)) else 0;

        const available = switch (self.direction) {
            .horizontal => @as(i32, inner.width) - @as(i32, total_spacing),
            .vertical => @as(i32, inner.height) - @as(i32, total_spacing),
        };

        if (available <= 0) return;

        // First pass: calculate fixed sizes and total flex
        var fixed_total: u32 = 0;
        var flex_total: u32 = 0;

        for (self.children_list.items) |child| {
            switch (child.constraint) {
                .fixed => |f| fixed_total += f,
                .flex => |f| flex_total += f,
                .percent => |p| fixed_total += @as(u32, @intCast(available)) * p / 100,
                else => {},
            }
        }

        // Calculate remaining space for flex items
        const flex_space: u32 = if (@as(u32, @intCast(available)) > fixed_total)
            @as(u32, @intCast(available)) - fixed_total
        else
            0;

        // Second pass: compute actual sizes
        var pos: u16 = switch (self.direction) {
            .horizontal => inner.x,
            .vertical => inner.y,
        };

        for (self.children_list.items) |child| {
            const child_size: u16 = switch (child.constraint) {
                .fixed => |f| f,
                .flex => |f| if (flex_total > 0)
                    @intCast(flex_space * f / flex_total)
                else
                    0,
                .percent => |p| @intCast(@as(u32, @intCast(available)) * p / 100),
                .min => |m| @max(m, child.widget.minSize().width),
                .max => |m| @min(m, @as(u16, @intCast(available))),
            };

            const child_area = switch (self.direction) {
                .horizontal => Rect{
                    .x = pos,
                    .y = inner.y,
                    .width = child_size,
                    .height = inner.height,
                },
                .vertical => Rect{
                    .x = inner.x,
                    .y = pos,
                    .width = inner.width,
                    .height = child_size,
                },
            };

            self.computed_areas.append(self.allocator, child_area) catch {};
            pos += child_size + self.spacing;
        }
    }

    // Widget interface implementation

    pub fn render(self: *Self, area: Rect, buf: *Buffer, state: Widget.RenderState) void {
        self.computeLayout(area);

        for (self.children_list.items, 0..) |child, i| {
            if (i < self.computed_areas.items.len) {
                const child_area = self.computed_areas.items[i];
                if (!child_area.isEmpty()) {
                    child.widget.render(child_area, buf, state);
                }
            }
        }
    }

    pub fn handleEvent(self: *Self, event: Event) bool {
        // Forward to children
        for (self.children_list.items) |child| {
            if (child.widget.handleEvent(event)) {
                return true;
            }
        }
        return false;
    }

    pub fn minSize(self: *Self) Size {
        var total_w: u16 = 0;
        var total_h: u16 = 0;
        var max_w: u16 = 0;
        var max_h: u16 = 0;

        for (self.children_list.items) |child| {
            const min = child.widget.minSize();
            total_w += min.width;
            total_h += min.height;
            max_w = @max(max_w, min.width);
            max_h = @max(max_h, min.height);
        }

        const n = self.children_list.items.len;
        const spacing = if (n > 1) self.spacing * @as(u16, @intCast(n - 1)) else 0;
        const padding2 = self.padding * 2;

        return switch (self.direction) {
            .horizontal => .{
                .width = total_w + spacing + padding2,
                .height = max_h + padding2,
            },
            .vertical => .{
                .width = max_w + padding2,
                .height = total_h + spacing + padding2,
            },
        };
    }

    pub fn canFocus(self: *Self) bool {
        _ = self;
        return false; // Container itself is not focusable
    }

    pub fn children(self: *Self) []Widget {
        // Return widgets from children_list
        // Note: This creates a temporary slice - in production would cache this
        var widgets: [32]Widget = undefined;
        const n = @min(self.children_list.items.len, 32);
        for (self.children_list.items[0..n], 0..) |child, i| {
            widgets[i] = child.widget;
        }
        return widgets[0..n];
    }
};

/// Convenience function to create horizontal box
pub fn hbox(allocator: std.mem.Allocator) BoxLayout {
    return BoxLayout.init(allocator, .horizontal);
}

/// Convenience function to create vertical box
pub fn vbox(allocator: std.mem.Allocator) BoxLayout {
    return BoxLayout.init(allocator, .vertical);
}

test "BoxLayout basic" {
    var layout = BoxLayout.init(std.testing.allocator, .vertical);
    defer layout.deinit();

    try std.testing.expectEqual(Direction.vertical, layout.direction);
}
