//! Core types for zig_tui
//!
//! Fundamental primitives used throughout the TUI framework.

const std = @import("std");

/// 2D size
pub const Size = struct {
    width: u16,
    height: u16,

    pub const zero = Size{ .width = 0, .height = 0 };

    pub fn area(self: Size) u32 {
        return @as(u32, self.width) * @as(u32, self.height);
    }

    pub fn contains(self: Size, x: u16, y: u16) bool {
        return x < self.width and y < self.height;
    }
};

/// 2D position
pub const Position = struct {
    x: u16,
    y: u16,

    pub const zero = Position{ .x = 0, .y = 0 };

    pub fn offset(self: Position, dx: i16, dy: i16) Position {
        return .{
            .x = @intCast(@max(0, @as(i32, self.x) + dx)),
            .y = @intCast(@max(0, @as(i32, self.y) + dy)),
        };
    }
};

/// Rectangle (position + size)
pub const Rect = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,

    pub const zero = Rect{ .x = 0, .y = 0, .width = 0, .height = 0 };

    pub fn init(x: u16, y: u16, width: u16, height: u16) Rect {
        return .{ .x = x, .y = y, .width = width, .height = height };
    }

    pub fn fromSize(s: Size) Rect {
        return .{ .x = 0, .y = 0, .width = s.width, .height = s.height };
    }

    pub fn position(self: Rect) Position {
        return .{ .x = self.x, .y = self.y };
    }

    pub fn size(self: Rect) Size {
        return .{ .width = self.width, .height = self.height };
    }

    pub fn right(self: Rect) u16 {
        return self.x + self.width;
    }

    pub fn bottom(self: Rect) u16 {
        return self.y + self.height;
    }

    pub fn area(self: Rect) u32 {
        return @as(u32, self.width) * @as(u32, self.height);
    }

    pub fn isEmpty(self: Rect) bool {
        return self.width == 0 or self.height == 0;
    }

    pub fn contains(self: Rect, x: u16, y: u16) bool {
        return x >= self.x and x < self.right() and
            y >= self.y and y < self.bottom();
    }

    pub fn containsPoint(self: Rect, pos: Position) bool {
        return self.contains(pos.x, pos.y);
    }

    /// Return intersection of two rectangles
    pub fn intersect(self: Rect, other: Rect) Rect {
        const x1 = @max(self.x, other.x);
        const y1 = @max(self.y, other.y);
        const x2 = @min(self.right(), other.right());
        const y2 = @min(self.bottom(), other.bottom());

        if (x2 <= x1 or y2 <= y1) {
            return Rect.zero;
        }
        return .{
            .x = x1,
            .y = y1,
            .width = x2 - x1,
            .height = y2 - y1,
        };
    }

    /// Shrink rectangle by margin on all sides
    pub fn shrink(self: Rect, margin: u16) Rect {
        const double_margin = margin * 2;
        if (self.width <= double_margin or self.height <= double_margin) {
            return Rect.zero;
        }
        return .{
            .x = self.x + margin,
            .y = self.y + margin,
            .width = self.width - double_margin,
            .height = self.height - double_margin,
        };
    }

    /// Shrink with different margins per side
    pub fn shrinkSides(self: Rect, top: u16, right_m: u16, bottom_m: u16, left: u16) Rect {
        const h_margin = left + right_m;
        const v_margin = top + bottom_m;
        if (self.width <= h_margin or self.height <= v_margin) {
            return Rect.zero;
        }
        return .{
            .x = self.x + left,
            .y = self.y + top,
            .width = self.width - h_margin,
            .height = self.height - v_margin,
        };
    }
};

/// Text alignment
pub const Align = enum {
    left,
    center,
    right,
};

/// Vertical alignment
pub const VAlign = enum {
    top,
    middle,
    bottom,
};

/// Border style
pub const BorderStyle = enum {
    none,
    single,
    double,
    rounded,
    thick,
    ascii,

    /// Get border characters for this style
    pub fn chars(self: BorderStyle) BorderChars {
        return switch (self) {
            .none => .{
                .top_left = ' ',
                .top_right = ' ',
                .bottom_left = ' ',
                .bottom_right = ' ',
                .horizontal = ' ',
                .vertical = ' ',
            },
            .single => .{
                .top_left = '┌',
                .top_right = '┐',
                .bottom_left = '└',
                .bottom_right = '┘',
                .horizontal = '─',
                .vertical = '│',
            },
            .double => .{
                .top_left = '╔',
                .top_right = '╗',
                .bottom_left = '╚',
                .bottom_right = '╝',
                .horizontal = '═',
                .vertical = '║',
            },
            .rounded => .{
                .top_left = '╭',
                .top_right = '╮',
                .bottom_left = '╰',
                .bottom_right = '╯',
                .horizontal = '─',
                .vertical = '│',
            },
            .thick => .{
                .top_left = '┏',
                .top_right = '┓',
                .bottom_left = '┗',
                .bottom_right = '┛',
                .horizontal = '━',
                .vertical = '┃',
            },
            .ascii => .{
                .top_left = '+',
                .top_right = '+',
                .bottom_left = '+',
                .bottom_right = '+',
                .horizontal = '-',
                .vertical = '|',
            },
        };
    }
};

pub const BorderChars = struct {
    top_left: u21,
    top_right: u21,
    bottom_left: u21,
    bottom_right: u21,
    horizontal: u21,
    vertical: u21,
};

/// Layout constraints
pub const Constraint = union(enum) {
    /// Fixed pixel/cell size
    fixed: u16,
    /// Percentage of parent (0-100)
    percent: u8,
    /// Flexible ratio (like CSS flex-grow)
    flex: u16,
    /// Minimum size
    min: u16,
    /// Maximum size
    max: u16,

    pub fn resolve(self: Constraint, available: u16, total_flex: u16) u16 {
        return switch (self) {
            .fixed => |v| @min(v, available),
            .percent => |p| @as(u16, @intCast(@as(u32, available) * p / 100)),
            .flex => |f| if (total_flex > 0)
                @as(u16, @intCast(@as(u32, available) * f / total_flex))
            else
                0,
            .min => |m| @max(m, available),
            .max => |m| @min(m, available),
        };
    }
};

test "Rect.intersect" {
    const a = Rect.init(0, 0, 10, 10);
    const b = Rect.init(5, 5, 10, 10);
    const c = a.intersect(b);
    try std.testing.expectEqual(@as(u16, 5), c.x);
    try std.testing.expectEqual(@as(u16, 5), c.y);
    try std.testing.expectEqual(@as(u16, 5), c.width);
    try std.testing.expectEqual(@as(u16, 5), c.height);
}

test "Rect.shrink" {
    const r = Rect.init(0, 0, 20, 20);
    const s = r.shrink(2);
    try std.testing.expectEqual(@as(u16, 2), s.x);
    try std.testing.expectEqual(@as(u16, 2), s.y);
    try std.testing.expectEqual(@as(u16, 16), s.width);
    try std.testing.expectEqual(@as(u16, 16), s.height);
}
