//! Status Bar widget - application status display
//!
//! Displays status information, mode indicators, and notifications.

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

/// Status bar segment alignment
pub const SegmentAlign = enum {
    left,
    center,
    right,
};

/// Status bar segment
pub const Segment = struct {
    content: []const u8,
    style: Style,
    min_width: u16,
    priority: u8, // Lower = higher priority (won't be hidden)
    visible: bool,
};

/// Status bar widget
pub const StatusBar = struct {
    allocator: std.mem.Allocator,

    // Segments
    left_segments: std.ArrayListUnmanaged(Segment),
    center_segments: std.ArrayListUnmanaged(Segment),
    right_segments: std.ArrayListUnmanaged(Segment),

    // Quick access items
    mode: []const u8,
    message: []const u8,
    message_style: Style,
    message_timeout: u32,

    // Position info (for editors)
    line: ?usize,
    column: ?usize,
    percentage: ?u8,

    // File info
    filename: ?[]const u8,
    modified: bool,
    readonly: bool,
    filetype: ?[]const u8,

    // Options
    show_line_col: bool,
    show_percentage: bool,
    separator: []const u8,

    // Styles
    background_style: Style,
    mode_style: Style,
    filename_style: Style,
    modified_style: Style,
    position_style: Style,
    separator_style: Style,

    const Self = @This();

    /// Get Widget interface
    pub fn widget(self: *Self) Widget {
        return makeWidget(Self, self);
    }

    /// Create a new StatusBar
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .left_segments = .{},
            .center_segments = .{},
            .right_segments = .{},
            .mode = "NORMAL",
            .message = "",
            .message_style = Style{ .fg = Color.white },
            .message_timeout = 0,
            .line = null,
            .column = null,
            .percentage = null,
            .filename = null,
            .modified = false,
            .readonly = false,
            .filetype = null,
            .show_line_col = true,
            .show_percentage = true,
            .separator = " | ",
            .background_style = Style{ .fg = Color.black, .bg = Color.white },
            .mode_style = Style{ .fg = Color.black, .bg = Color.cyan, .attrs = .{ .bold = true } },
            .filename_style = Style{ .fg = Color.black, .bg = Color.white },
            .modified_style = Style{ .fg = Color.red, .bg = Color.white, .attrs = .{ .bold = true } },
            .position_style = Style{ .fg = Color.black, .bg = Color.white },
            .separator_style = Style{ .fg = Color.gray, .bg = Color.white },
        };
    }

    pub fn deinit(self: *Self) void {
        self.left_segments.deinit(self.allocator);
        self.center_segments.deinit(self.allocator);
        self.right_segments.deinit(self.allocator);
    }

    /// Set the mode indicator
    pub fn setMode(self: *Self, mode: []const u8) *Self {
        self.mode = mode;
        return self;
    }

    /// Set a temporary message
    pub fn setMessage(self: *Self, message: []const u8, style: Style, timeout: u32) *Self {
        self.message = message;
        self.message_style = style;
        self.message_timeout = timeout;
        return self;
    }

    /// Clear the message
    pub fn clearMessage(self: *Self) void {
        self.message = "";
        self.message_timeout = 0;
    }

    /// Set cursor position
    pub fn setPosition(self: *Self, line: usize, column: usize) *Self {
        self.line = line;
        self.column = column;
        return self;
    }

    /// Set scroll percentage
    pub fn setPercentage(self: *Self, pct: u8) *Self {
        self.percentage = pct;
        return self;
    }

    /// Set filename
    pub fn setFilename(self: *Self, filename: ?[]const u8) *Self {
        self.filename = filename;
        return self;
    }

    /// Set modified flag
    pub fn setModified(self: *Self, modified: bool) *Self {
        self.modified = modified;
        return self;
    }

    /// Set readonly flag
    pub fn setReadonly(self: *Self, readonly: bool) *Self {
        self.readonly = readonly;
        return self;
    }

    /// Set filetype
    pub fn setFiletype(self: *Self, filetype: ?[]const u8) *Self {
        self.filetype = filetype;
        return self;
    }

    /// Add a custom segment
    pub fn addSegment(self: *Self, alignment: SegmentAlign, segment: Segment) !void {
        const list = switch (alignment) {
            .left => &self.left_segments,
            .center => &self.center_segments,
            .right => &self.right_segments,
        };
        try list.append(self.allocator, segment);
    }

    /// Tick for message timeout
    pub fn tick(self: *Self) void {
        if (self.message_timeout > 0) {
            self.message_timeout -= 1;
            if (self.message_timeout == 0) {
                self.clearMessage();
            }
        }
    }

    // Widget interface

    pub fn render(self: *Self, area: Rect, buf: *Buffer, state: Widget.RenderState) void {
        _ = state;
        if (area.isEmpty() or area.height == 0) return;

        // Fill background
        buf.fill(area, core.Cell.styled(' ', self.background_style));

        var left_x = area.x;
        var right_x = area.x + area.width;

        // Draw mode indicator (left)
        if (self.mode.len > 0) {
            const mode_width: u16 = @intCast(self.mode.len + 2);
            buf.setChar(left_x, area.y, ' ', self.mode_style);
            _ = buf.writeStr(left_x + 1, area.y, self.mode, self.mode_style);
            buf.setChar(left_x + mode_width - 1, area.y, ' ', self.mode_style);
            left_x += mode_width;
        }

        // Draw separator after mode
        if (self.mode.len > 0) {
            _ = buf.writeStr(left_x, area.y, self.separator, self.separator_style);
            left_x += @intCast(self.separator.len);
        }

        // Draw filename (left)
        if (self.filename) |fname| {
            const fname_display = if (fname.len > 30) fname[fname.len - 30 ..] else fname;
            _ = buf.writeStr(left_x, area.y, fname_display, self.filename_style);
            left_x += @intCast(fname_display.len);

            // Modified indicator
            if (self.modified) {
                _ = buf.writeStr(left_x, area.y, " [+]", self.modified_style);
                left_x += 4;
            }

            // Readonly indicator
            if (self.readonly) {
                _ = buf.writeStr(left_x, area.y, " [RO]", Style{ .fg = Color.yellow, .bg = Color.white });
                left_x += 5;
            }
        }

        // Draw custom left segments
        for (self.left_segments.items) |seg| {
            if (!seg.visible) continue;
            _ = buf.writeStr(left_x, area.y, self.separator, self.separator_style);
            left_x += @intCast(self.separator.len);
            _ = buf.writeStr(left_x, area.y, seg.content, seg.style);
            left_x += @intCast(seg.content.len);
        }

        // Draw right side items (from right to left)

        // Position info
        if (self.show_line_col) {
            if (self.line) |line| {
                if (self.column) |col| {
                    var pos_buf: [32]u8 = undefined;
                    const pos_str = std.fmt.bufPrint(&pos_buf, "Ln {d}, Col {d}", .{ line, col }) catch "?:?";
                    const pos_width: u16 = @intCast(pos_str.len);
                    right_x -= pos_width;
                    _ = buf.writeStr(right_x, area.y, pos_str, self.position_style);

                    right_x -= @intCast(self.separator.len);
                    _ = buf.writeStr(right_x, area.y, self.separator, self.separator_style);
                }
            }
        }

        // Percentage
        if (self.show_percentage) {
            if (self.percentage) |pct| {
                var pct_buf: [8]u8 = undefined;
                const pct_str = std.fmt.bufPrint(&pct_buf, "{d}%", .{pct}) catch "?%";
                const pct_width: u16 = @intCast(pct_str.len);
                right_x -= pct_width;
                _ = buf.writeStr(right_x, area.y, pct_str, self.position_style);

                right_x -= @intCast(self.separator.len);
                _ = buf.writeStr(right_x, area.y, self.separator, self.separator_style);
            }
        }

        // Filetype
        if (self.filetype) |ft| {
            const ft_width: u16 = @intCast(ft.len);
            right_x -= ft_width;
            _ = buf.writeStr(right_x, area.y, ft, self.position_style);

            right_x -= @intCast(self.separator.len);
            _ = buf.writeStr(right_x, area.y, self.separator, self.separator_style);
        }

        // Custom right segments
        for (self.right_segments.items) |seg| {
            if (!seg.visible) continue;
            const seg_width: u16 = @intCast(seg.content.len);
            right_x -= seg_width;
            _ = buf.writeStr(right_x, area.y, seg.content, seg.style);

            right_x -= @intCast(self.separator.len);
            _ = buf.writeStr(right_x, area.y, self.separator, self.separator_style);
        }

        // Draw message in the center (if any)
        if (self.message.len > 0) {
            const msg_width: u16 = @intCast(@min(self.message.len, area.width));
            const msg_x = area.x + (area.width - msg_width) / 2;
            _ = buf.writeTruncated(msg_x, area.y, msg_width, self.message, self.message_style);
        }

        // Draw custom center segments
        if (self.center_segments.items.len > 0 and self.message.len == 0) {
            var center_width: u16 = 0;
            for (self.center_segments.items) |seg| {
                if (seg.visible) {
                    center_width += @intCast(seg.content.len + self.separator.len);
                }
            }

            var cx = area.x + (area.width - center_width) / 2;
            for (self.center_segments.items) |seg| {
                if (!seg.visible) continue;
                _ = buf.writeStr(cx, area.y, seg.content, seg.style);
                cx += @intCast(seg.content.len);
                _ = buf.writeStr(cx, area.y, self.separator, self.separator_style);
                cx += @intCast(self.separator.len);
            }
        }
    }

    pub fn handleEvent(self: *Self, event: Event) bool {
        _ = self;
        _ = event;
        return false; // Status bar doesn't handle events
    }

    pub fn minSize(self: *Self) Size {
        _ = self;
        return .{ .width = 40, .height = 1 };
    }

    pub fn canFocus(self: *Self) bool {
        _ = self;
        return false; // Status bar is not focusable
    }
};

/// Convenience function to create a minimal status bar
pub fn minimalStatusBar(allocator: std.mem.Allocator) StatusBar {
    var sb = StatusBar.init(allocator);
    sb.show_line_col = false;
    sb.show_percentage = false;
    return sb;
}

/// Convenience function to create an editor-style status bar
pub fn editorStatusBar(allocator: std.mem.Allocator) StatusBar {
    return StatusBar.init(allocator);
}

test "StatusBar basic" {
    var sb = StatusBar.init(std.testing.allocator);
    defer sb.deinit();

    _ = sb.setMode("INSERT");
    _ = sb.setFilename("test.zig");
    _ = sb.setPosition(42, 10);

    try std.testing.expectEqualStrings("INSERT", sb.mode);
}
