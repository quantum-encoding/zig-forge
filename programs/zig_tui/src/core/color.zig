//! Terminal colors
//!
//! Supports 16 standard colors, 256-color palette, and true color (24-bit RGB).

const std = @import("std");

/// Terminal color representation
pub const Color = union(enum) {
    /// Default terminal color (foreground or background)
    default,
    /// 16 standard ANSI colors (0-15)
    ansi: u4,
    /// 256-color palette (0-255)
    palette: u8,
    /// True color RGB
    rgb: RGB,

    pub const RGB = struct {
        r: u8,
        g: u8,
        b: u8,
    };

    // Standard ANSI colors
    pub const black = Color{ .ansi = 0 };
    pub const red = Color{ .ansi = 1 };
    pub const green = Color{ .ansi = 2 };
    pub const yellow = Color{ .ansi = 3 };
    pub const blue = Color{ .ansi = 4 };
    pub const magenta = Color{ .ansi = 5 };
    pub const cyan = Color{ .ansi = 6 };
    pub const white = Color{ .ansi = 7 };

    // Bright variants
    pub const bright_black = Color{ .ansi = 8 };
    pub const bright_red = Color{ .ansi = 9 };
    pub const bright_green = Color{ .ansi = 10 };
    pub const bright_yellow = Color{ .ansi = 11 };
    pub const bright_blue = Color{ .ansi = 12 };
    pub const bright_magenta = Color{ .ansi = 13 };
    pub const bright_cyan = Color{ .ansi = 14 };
    pub const bright_white = Color{ .ansi = 15 };

    // Aliases
    pub const gray = bright_black;
    pub const dark_gray = bright_black;
    pub const light_gray = white;

    /// Create RGB color from components
    pub fn fromRgb(r: u8, g: u8, b: u8) Color {
        return .{ .rgb = .{ .r = r, .g = g, .b = b } };
    }

    /// Create color from hex value (0xRRGGBB)
    pub fn fromHex(hex: u24) Color {
        return .{ .rgb = .{
            .r = @truncate(hex >> 16),
            .g = @truncate(hex >> 8),
            .b = @truncate(hex),
        } };
    }

    /// Create 256-palette color
    pub fn from256(idx: u8) Color {
        return .{ .palette = idx };
    }

    /// Convert to closest 256-palette color
    pub fn to256(self: Color) u8 {
        return switch (self) {
            .default => 0,
            .ansi => |c| c,
            .palette => |c| c,
            .rgb => |c| rgbTo256(c.r, c.g, c.b),
        };
    }

    /// Check if colors are equal
    pub fn eql(self: Color, other: Color) bool {
        return switch (self) {
            .default => other == .default,
            .ansi => |a| switch (other) {
                .ansi => |b| a == b,
                else => false,
            },
            .palette => |a| switch (other) {
                .palette => |b| a == b,
                else => false,
            },
            .rgb => |a| switch (other) {
                .rgb => |b| a.r == b.r and a.g == b.g and a.b == b.b,
                else => false,
            },
        };
    }
};

/// Convert RGB to nearest 256-color palette index
fn rgbTo256(r: u8, g: u8, b: u8) u8 {
    // Check for grayscale (232-255)
    if (r == g and g == b) {
        if (r < 8) return 16; // Black
        if (r > 248) return 231; // White
        // Grayscale ramp: 232 + (r - 8) / 10
        return @as(u8, @intCast(232 + @as(u16, r - 8) * 24 / 240));
    }

    // Color cube (16-231): 6x6x6 cube
    // Each component maps to 0-5
    const ri: u8 = if (r < 48) 0 else if (r < 115) 1 else @as(u8, @intCast(@min(5, (r - 35) / 40)));
    const gi: u8 = if (g < 48) 0 else if (g < 115) 1 else @as(u8, @intCast(@min(5, (g - 35) / 40)));
    const bi: u8 = if (b < 48) 0 else if (b < 115) 1 else @as(u8, @intCast(@min(5, (b - 35) / 40)));

    return 16 + ri * 36 + gi * 6 + bi;
}

/// Cell text attributes
pub const Attrs = packed struct {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    blink: bool = false,
    reverse: bool = false,
    hidden: bool = false,
    strikethrough: bool = false,

    pub const none = Attrs{};

    pub fn eql(self: Attrs, other: Attrs) bool {
        return @as(u8, @bitCast(self)) == @as(u8, @bitCast(other));
    }

    pub fn toU8(self: Attrs) u8 {
        return @bitCast(self);
    }

    pub fn fromU8(v: u8) Attrs {
        return @bitCast(v);
    }
};

/// Complete cell style (foreground, background, attributes)
pub const Style = struct {
    fg: Color = .default,
    bg: Color = .default,
    attrs: Attrs = .{},

    pub const default = Style{};

    pub fn init(fg: Color, bg: Color) Style {
        return .{ .fg = fg, .bg = bg };
    }

    pub fn withFg(self: Style, fg: Color) Style {
        var s = self;
        s.fg = fg;
        return s;
    }

    pub fn withBg(self: Style, bg: Color) Style {
        var s = self;
        s.bg = bg;
        return s;
    }

    pub fn bold(self: Style) Style {
        var s = self;
        s.attrs.bold = true;
        return s;
    }

    pub fn dim(self: Style) Style {
        var s = self;
        s.attrs.dim = true;
        return s;
    }

    pub fn italic(self: Style) Style {
        var s = self;
        s.attrs.italic = true;
        return s;
    }

    pub fn underline(self: Style) Style {
        var s = self;
        s.attrs.underline = true;
        return s;
    }

    pub fn reverse(self: Style) Style {
        var s = self;
        s.attrs.reverse = true;
        return s;
    }

    pub fn eql(self: Style, other: Style) bool {
        return self.fg.eql(other.fg) and
            self.bg.eql(other.bg) and
            self.attrs.eql(other.attrs);
    }
};

test "Color.fromHex" {
    const c = Color.fromHex(0xFF8040);
    try std.testing.expect(c == .rgb);
    try std.testing.expectEqual(@as(u8, 0xFF), c.rgb.r);
    try std.testing.expectEqual(@as(u8, 0x80), c.rgb.g);
    try std.testing.expectEqual(@as(u8, 0x40), c.rgb.b);
}

test "rgbTo256" {
    // Black
    try std.testing.expectEqual(@as(u8, 16), rgbTo256(0, 0, 0));
    // White
    try std.testing.expectEqual(@as(u8, 231), rgbTo256(255, 255, 255));
    // Pure red
    try std.testing.expectEqual(@as(u8, 196), rgbTo256(255, 0, 0));
}
