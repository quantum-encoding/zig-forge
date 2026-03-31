//! Progress bar widget - visual progress indicator
//!
//! Displays progress as a horizontal bar with optional label.

const std = @import("std");
const core = @import("../core/core.zig");
const widget_mod = @import("../widget/mod.zig");

pub const Buffer = core.Buffer;
pub const Rect = core.Rect;
pub const Size = core.Size;
pub const Style = core.Style;
pub const Color = core.Color;
pub const Widget = widget_mod.Widget;
pub const makeWidget = widget_mod.makeWidget;

/// Progress bar style
pub const ProgressStyle = enum {
    block,      // ████████░░░░
    ascii,      // [========  ]
    dots,       // ●●●●●○○○○○
    gradient,   // Uses colors
};

/// Label position
pub const LabelPosition = enum {
    none,
    left,
    right,
    center,   // Overlaid on bar
    above,
    below,
};

/// Progress bar widget
pub const ProgressBar = struct {
    value: f32,           // 0.0 to 1.0
    min_value: f32,
    max_value: f32,

    // Display options
    progress_style: ProgressStyle,
    label_position: LabelPosition,
    show_percentage: bool,
    custom_label: ?[]const u8,

    // Styles
    filled_style: Style,
    empty_style: Style,
    label_style: Style,
    border_style: Style,

    // Characters
    filled_char: u21,
    empty_char: u21,

    // Animation for indeterminate
    indeterminate: bool,
    animation_offset: u16,

    const Self = @This();

    /// Get Widget interface
    pub fn widget(self: *Self) Widget {
        return makeWidget(Self, self);
    }

    /// Create a new progress bar
    pub fn init() Self {
        return .{
            .value = 0.0,
            .min_value = 0.0,
            .max_value = 1.0,
            .progress_style = .block,
            .label_position = .right,
            .show_percentage = true,
            .custom_label = null,
            .filled_style = Style{ .fg = Color.green },
            .empty_style = Style{ .fg = Color.gray },
            .label_style = Style{ .fg = Color.white },
            .border_style = Style{ .fg = Color.white },
            .filled_char = '█',
            .empty_char = '░',
            .indeterminate = false,
            .animation_offset = 0,
        };
    }

    /// Create progress bar with initial value
    pub fn withValue(value: f32) Self {
        var self = init();
        self.value = std.math.clamp(value, 0.0, 1.0);
        return self;
    }

    /// Set progress value (0.0 to 1.0)
    pub fn setValue(self: *Self, value: f32) *Self {
        self.value = std.math.clamp(value, self.min_value, self.max_value);
        return self;
    }

    /// Set progress from range (e.g., 50 out of 100)
    pub fn setProgress(self: *Self, current: u64, total: u64) *Self {
        if (total == 0) {
            self.value = 0.0;
        } else {
            self.value = @as(f32, @floatFromInt(current)) / @as(f32, @floatFromInt(total));
        }
        return self;
    }

    /// Set progress style
    pub fn setStyle(self: *Self, style: ProgressStyle) *Self {
        self.progress_style = style;
        // Update characters based on style
        switch (style) {
            .block => {
                self.filled_char = '█';
                self.empty_char = '░';
            },
            .ascii => {
                self.filled_char = '=';
                self.empty_char = ' ';
            },
            .dots => {
                self.filled_char = '●';
                self.empty_char = '○';
            },
            .gradient => {
                self.filled_char = '█';
                self.empty_char = '░';
            },
        }
        return self;
    }

    /// Set colors
    pub fn setColors(self: *Self, filled: Color, empty: Color) *Self {
        self.filled_style.fg = filled;
        self.empty_style.fg = empty;
        return self;
    }

    /// Set label position
    pub fn setLabelPosition(self: *Self, pos: LabelPosition) *Self {
        self.label_position = pos;
        return self;
    }

    /// Set custom label
    pub fn setLabel(self: *Self, label: []const u8) *Self {
        self.custom_label = label;
        return self;
    }

    /// Set indeterminate mode (animated, unknown progress)
    pub fn setIndeterminate(self: *Self, indeterminate: bool) *Self {
        self.indeterminate = indeterminate;
        return self;
    }

    /// Advance animation (call on tick events)
    pub fn tick(self: *Self) void {
        self.animation_offset +%= 1;
    }

    /// Get percentage as integer (0-100)
    pub fn getPercentage(self: *const Self) u8 {
        const normalized = (self.value - self.min_value) / (self.max_value - self.min_value);
        return @intFromFloat(std.math.clamp(normalized * 100.0, 0.0, 100.0));
    }

    // Widget interface

    pub fn render(self: *Self, area: Rect, buf: *Buffer, state: Widget.RenderState) void {
        _ = state;
        if (area.isEmpty()) return;

        var bar_x = area.x;
        var bar_width = area.width;
        var bar_y = area.y;

        // Handle label positioning
        var label_buf: [32]u8 = undefined;
        const label = if (self.custom_label) |l|
            l
        else if (self.show_percentage)
            std.fmt.bufPrint(&label_buf, "{d}%", .{self.getPercentage()}) catch "??%"
        else
            "";

        const label_len: u16 = @intCast(label.len);

        switch (self.label_position) {
            .left => {
                if (label_len > 0) {
                    _ = buf.writeStr(area.x, bar_y, label, self.label_style);
                    bar_x = area.x + label_len + 1;
                    bar_width = if (area.width > label_len + 1) area.width - label_len - 1 else 0;
                }
            },
            .right => {
                if (label_len > 0) {
                    bar_width = if (area.width > label_len + 1) area.width - label_len - 1 else area.width;
                    _ = buf.writeStr(area.x + bar_width + 1, bar_y, label, self.label_style);
                }
            },
            .above => {
                if (area.height > 1 and label_len > 0) {
                    _ = buf.writeStr(area.x, area.y, label, self.label_style);
                    bar_y = area.y + 1;
                }
            },
            .below => {
                if (area.height > 1 and label_len > 0) {
                    _ = buf.writeStr(area.x, area.y + 1, label, self.label_style);
                }
            },
            .center => {
                // Label will be drawn on top of bar later
            },
            .none => {},
        }

        if (bar_width == 0) return;

        // Draw the progress bar
        if (self.indeterminate) {
            self.renderIndeterminate(buf, bar_x, bar_y, bar_width);
        } else {
            self.renderDeterminate(buf, bar_x, bar_y, bar_width);
        }

        // Draw centered label on top of bar
        if (self.label_position == .center and label_len > 0) {
            const label_x = bar_x + (bar_width - label_len) / 2;
            _ = buf.writeStr(label_x, bar_y, label, self.label_style);
        }
    }

    fn renderDeterminate(self: *Self, buf: *Buffer, x: u16, y: u16, width: u16) void {
        const normalized = (self.value - self.min_value) / (self.max_value - self.min_value);
        const filled_width: u16 = @intFromFloat(normalized * @as(f32, @floatFromInt(width)));

        // Draw based on style
        switch (self.progress_style) {
            .ascii => {
                buf.setChar(x, y, '[', self.border_style);
                var i: u16 = 0;
                while (i < width - 2) : (i += 1) {
                    const char: u21 = if (i < filled_width) self.filled_char else self.empty_char;
                    const style = if (i < filled_width) self.filled_style else self.empty_style;
                    buf.setChar(x + 1 + i, y, char, style);
                }
                buf.setChar(x + width - 1, y, ']', self.border_style);
            },
            .gradient => {
                var i: u16 = 0;
                while (i < width) : (i += 1) {
                    if (i < filled_width) {
                        // Gradient from green to yellow to red based on position
                        const ratio = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(width));
                        const r: u8 = @intFromFloat(ratio * 255.0);
                        const g: u8 = @intFromFloat((1.0 - ratio * 0.5) * 255.0);
                        buf.setChar(x + i, y, self.filled_char, Style{ .fg = Color.fromRgb(r, g, 0) });
                    } else {
                        buf.setChar(x + i, y, self.empty_char, self.empty_style);
                    }
                }
            },
            else => {
                var i: u16 = 0;
                while (i < width) : (i += 1) {
                    const char: u21 = if (i < filled_width) self.filled_char else self.empty_char;
                    const style = if (i < filled_width) self.filled_style else self.empty_style;
                    buf.setChar(x + i, y, char, style);
                }
            },
        }
    }

    fn renderIndeterminate(self: *Self, buf: *Buffer, x: u16, y: u16, width: u16) void {
        const pulse_width: u16 = @min(5, width / 3);
        const cycle_len = width + pulse_width;
        const offset = self.animation_offset % cycle_len;

        var i: u16 = 0;
        while (i < width) : (i += 1) {
            const in_pulse = (i >= offset -| pulse_width) and (i < offset);
            const char: u21 = if (in_pulse) self.filled_char else self.empty_char;
            const style = if (in_pulse) self.filled_style else self.empty_style;
            buf.setChar(x + i, y, char, style);
        }
    }

    pub fn handleEvent(self: *Self, event: anytype) bool {
        _ = self;
        _ = event;
        return false; // Progress bars don't handle input
    }

    pub fn minSize(self: *Self) Size {
        _ = self;
        return .{ .width = 10, .height = 1 };
    }

    pub fn canFocus(self: *Self) bool {
        _ = self;
        return false; // Progress bars are not focusable
    }
};

/// Spinner widget for indeterminate loading
pub const Spinner = struct {
    frames: []const []const u8,
    current_frame: usize,
    label: ?[]const u8,
    style: Style,
    label_style: Style,

    const Self = @This();

    /// Default spinner frames
    pub const default_frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
    pub const dots_frames = [_][]const u8{ ".", "..", "...", "..", "." };
    pub const line_frames = [_][]const u8{ "-", "\\", "|", "/" };
    pub const block_frames = [_][]const u8{ "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█", "▇", "▆", "▅", "▄", "▃", "▂" };

    /// Get Widget interface
    pub fn widget(self: *Self) Widget {
        return makeWidget(Self, self);
    }

    /// Create a new spinner
    pub fn init() Self {
        return .{
            .frames = &default_frames,
            .current_frame = 0,
            .label = null,
            .style = Style{ .fg = Color.cyan },
            .label_style = Style{ .fg = Color.white },
        };
    }

    /// Set spinner frames
    pub fn setFrames(self: *Self, frames: []const []const u8) *Self {
        self.frames = frames;
        self.current_frame = 0;
        return self;
    }

    /// Set label
    pub fn setLabel(self: *Self, label: []const u8) *Self {
        self.label = label;
        return self;
    }

    /// Advance to next frame (call on tick)
    pub fn tick(self: *Self) void {
        self.current_frame = (self.current_frame + 1) % self.frames.len;
    }

    // Widget interface

    pub fn render(self: *Self, area: Rect, buf: *Buffer, state: Widget.RenderState) void {
        _ = state;
        if (area.isEmpty() or self.frames.len == 0) return;

        const frame = self.frames[self.current_frame];
        _ = buf.writeStr(area.x, area.y, frame, self.style);

        if (self.label) |lbl| {
            const frame_len: u16 = @intCast(frame.len);
            if (area.width > frame_len + 1) {
                _ = buf.writeTruncated(area.x + frame_len + 1, area.y, area.width - frame_len - 1, lbl, self.label_style);
            }
        }
    }

    pub fn handleEvent(self: *Self, event: anytype) bool {
        _ = self;
        _ = event;
        return false;
    }

    pub fn minSize(self: *Self) Size {
        const frame_width: u16 = if (self.frames.len > 0) @intCast(self.frames[0].len) else 1;
        const label_width: u16 = if (self.label) |l| @intCast(l.len + 1) else 0;
        return .{ .width = frame_width + label_width, .height = 1 };
    }

    pub fn canFocus(self: *Self) bool {
        _ = self;
        return false;
    }
};

test "ProgressBar percentage" {
    var pb = ProgressBar.init();
    _ = pb.setValue(0.5);
    try std.testing.expectEqual(@as(u8, 50), pb.getPercentage());

    _ = pb.setValue(1.0);
    try std.testing.expectEqual(@as(u8, 100), pb.getPercentage());
}
