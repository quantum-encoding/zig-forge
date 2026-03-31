//! Color Utilities
//!
//! RGB, RGBA, and HSL color representations with conversions.
//! Includes predefined palettes for financial charts.

const std = @import("std");

/// RGBA color with 8-bit components
pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    /// Create from RGB values (0-255)
    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = 255 };
    }

    /// Create from RGBA values (0-255)
    pub fn rgba(r: u8, g: u8, b: u8, a: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    /// Create from hex string (e.g., "#FF5500" or "FF5500")
    pub fn fromHex(hex: []const u8) ?Color {
        @setEvalBranchQuota(10000);
        const start: usize = if (hex.len > 0 and hex[0] == '#') 1 else 0;
        const s = hex[start..];

        if (s.len == 6) {
            const r = std.fmt.parseInt(u8, s[0..2], 16) catch return null;
            const g = std.fmt.parseInt(u8, s[2..4], 16) catch return null;
            const b = std.fmt.parseInt(u8, s[4..6], 16) catch return null;
            return rgb(r, g, b);
        } else if (s.len == 8) {
            const r = std.fmt.parseInt(u8, s[0..2], 16) catch return null;
            const g = std.fmt.parseInt(u8, s[2..4], 16) catch return null;
            const b = std.fmt.parseInt(u8, s[4..6], 16) catch return null;
            const a = std.fmt.parseInt(u8, s[6..8], 16) catch return null;
            return rgba(r, g, b, a);
        }
        return null;
    }

    /// Convert to hex string (without #)
    pub fn toHex(self: Color, buf: *[6]u8) []const u8 {
        _ = std.fmt.bufPrint(buf, "{x:0>2}{x:0>2}{x:0>2}", .{ self.r, self.g, self.b }) catch unreachable;
        return buf[0..6];
    }

    /// Convert to CSS rgba() string
    pub fn toRgbaString(self: Color, buf: []u8) []const u8 {
        if (self.a == 255) {
            const len = std.fmt.bufPrint(buf, "rgb({d},{d},{d})", .{ self.r, self.g, self.b }) catch return "";
            return buf[0..len.len];
        } else {
            const alpha: f32 = @as(f32, @floatFromInt(self.a)) / 255.0;
            const len = std.fmt.bufPrint(buf, "rgba({d},{d},{d},{d:.2})", .{ self.r, self.g, self.b, alpha }) catch return "";
            return buf[0..len.len];
        }
    }

    /// Blend with another color (alpha compositing)
    pub fn blend(self: Color, other: Color) Color {
        const sa: f32 = @as(f32, @floatFromInt(self.a)) / 255.0;
        const da: f32 = @as(f32, @floatFromInt(other.a)) / 255.0;
        const out_a = sa + da * (1.0 - sa);

        if (out_a == 0) return Color{ .r = 0, .g = 0, .b = 0, .a = 0 };

        const blend_channel = struct {
            fn f(src: u8, dst: u8, src_a: f32, dst_a: f32, o_a: f32) u8 {
                const s: f32 = @floatFromInt(src);
                const d: f32 = @floatFromInt(dst);
                const result = (s * src_a + d * dst_a * (1.0 - src_a)) / o_a;
                return @intFromFloat(@min(255.0, @max(0.0, result)));
            }
        }.f;

        return Color{
            .r = blend_channel(self.r, other.r, sa, da, out_a),
            .g = blend_channel(self.g, other.g, sa, da, out_a),
            .b = blend_channel(self.b, other.b, sa, da, out_a),
            .a = @intFromFloat(out_a * 255.0),
        };
    }

    /// Lighten by factor (0.0 = no change, 1.0 = white)
    pub fn lighten(self: Color, factor: f32) Color {
        const f = @min(1.0, @max(0.0, factor));
        return Color{
            .r = @intFromFloat(@as(f32, @floatFromInt(self.r)) + (255.0 - @as(f32, @floatFromInt(self.r))) * f),
            .g = @intFromFloat(@as(f32, @floatFromInt(self.g)) + (255.0 - @as(f32, @floatFromInt(self.g))) * f),
            .b = @intFromFloat(@as(f32, @floatFromInt(self.b)) + (255.0 - @as(f32, @floatFromInt(self.b))) * f),
            .a = self.a,
        };
    }

    /// Darken by factor (0.0 = no change, 1.0 = black)
    pub fn darken(self: Color, factor: f32) Color {
        const f = 1.0 - @min(1.0, @max(0.0, factor));
        return Color{
            .r = @intFromFloat(@as(f32, @floatFromInt(self.r)) * f),
            .g = @intFromFloat(@as(f32, @floatFromInt(self.g)) * f),
            .b = @intFromFloat(@as(f32, @floatFromInt(self.b)) * f),
            .a = self.a,
        };
    }

    /// Set alpha (0-255)
    pub fn withAlpha(self: Color, a: u8) Color {
        return Color{ .r = self.r, .g = self.g, .b = self.b, .a = a };
    }

    /// Interpolate between two colors (t=0 returns self, t=1 returns other)
    pub fn interpolate(self: Color, other: Color, t: f32) Color {
        const t_clamped = @min(1.0, @max(0.0, t));
        const one_minus_t = 1.0 - t_clamped;
        return Color{
            .r = @intFromFloat(@as(f32, @floatFromInt(self.r)) * one_minus_t + @as(f32, @floatFromInt(other.r)) * t_clamped),
            .g = @intFromFloat(@as(f32, @floatFromInt(self.g)) * one_minus_t + @as(f32, @floatFromInt(other.g)) * t_clamped),
            .b = @intFromFloat(@as(f32, @floatFromInt(self.b)) * one_minus_t + @as(f32, @floatFromInt(other.b)) * t_clamped),
            .a = @intFromFloat(@as(f32, @floatFromInt(self.a)) * one_minus_t + @as(f32, @floatFromInt(other.a)) * t_clamped),
        };
    }

    /// Calculate relative luminance (0.0 = black, 1.0 = white)
    /// Based on WCAG formula
    pub fn luminance(self: Color) f32 {
        const r = @as(f32, @floatFromInt(self.r)) / 255.0;
        const g = @as(f32, @floatFromInt(self.g)) / 255.0;
        const b = @as(f32, @floatFromInt(self.b)) / 255.0;
        return 0.2126 * r + 0.7152 * g + 0.0722 * b;
    }

    // =========================================================================
    // Predefined Colors
    // =========================================================================

    pub const black = Color{ .r = 0, .g = 0, .b = 0, .a = 255 };
    pub const white = Color{ .r = 255, .g = 255, .b = 255, .a = 255 };
    pub const transparent = Color{ .r = 0, .g = 0, .b = 0, .a = 0 };

    // Grayscale
    pub const gray_100 = rgb(245, 245, 245);
    pub const gray_200 = rgb(229, 229, 229);
    pub const gray_300 = rgb(212, 212, 212);
    pub const gray_400 = rgb(163, 163, 163);
    pub const gray_500 = rgb(115, 115, 115);
    pub const gray_600 = rgb(82, 82, 82);
    pub const gray_700 = rgb(64, 64, 64);
    pub const gray_800 = rgb(38, 38, 38);
    pub const gray_900 = rgb(23, 23, 23);

    // Financial - Bull/Bear
    pub const bull_green = rgb(34, 197, 94); // Bright green for gains
    pub const bear_red = rgb(239, 68, 68); // Bright red for losses
    pub const bull_green_light = rgb(187, 247, 208);
    pub const bear_red_light = rgb(254, 202, 202);

    // Blues
    pub const blue_500 = rgb(59, 130, 246);
    pub const blue_600 = rgb(37, 99, 235);
    pub const blue_700 = rgb(29, 78, 216);

    // Chart palette (for multi-series)
    pub const palette = [_]Color{
        rgb(59, 130, 246), // Blue
        rgb(239, 68, 68), // Red
        rgb(34, 197, 94), // Green
        rgb(249, 115, 22), // Orange
        rgb(168, 85, 247), // Purple
        rgb(236, 72, 153), // Pink
        rgb(20, 184, 166), // Teal
        rgb(245, 158, 11), // Amber
    };

    /// Get color from palette by index (wraps around)
    pub fn fromPalette(index: usize) Color {
        return palette[index % palette.len];
    }
};

// =============================================================================
// Tests
// =============================================================================

test "color from hex" {
    const c1 = Color.fromHex("#FF5500").?;
    try std.testing.expectEqual(@as(u8, 255), c1.r);
    try std.testing.expectEqual(@as(u8, 85), c1.g);
    try std.testing.expectEqual(@as(u8, 0), c1.b);

    const c2 = Color.fromHex("00FF00").?;
    try std.testing.expectEqual(@as(u8, 0), c2.r);
    try std.testing.expectEqual(@as(u8, 255), c2.g);
    try std.testing.expectEqual(@as(u8, 0), c2.b);
}

test "color to hex" {
    const c = Color.rgb(255, 128, 0);
    var buf: [6]u8 = undefined;
    const hex = c.toHex(&buf);
    try std.testing.expectEqualStrings("ff8000", hex);
}

test "color lighten/darken" {
    const c = Color.rgb(100, 100, 100);
    const lighter = c.lighten(0.5);
    try std.testing.expect(lighter.r > c.r);

    const darker = c.darken(0.5);
    try std.testing.expect(darker.r < c.r);
}
