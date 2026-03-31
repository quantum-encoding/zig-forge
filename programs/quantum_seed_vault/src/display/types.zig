//! Display types and color definitions for Quantum Seed Vault
//!
//! Uses RGB565 format for compatibility with ST7789 display.

const std = @import("std");

/// Display dimensions (Waveshare 1.3" LCD HAT)
pub const WIDTH: u16 = 240;
pub const HEIGHT: u16 = 240;

/// RGB565 color (16-bit)
pub const Color = u16;

/// Convert RGB888 to RGB565
pub fn rgb(r: u8, g: u8, b: u8) Color {
    return (@as(u16, r & 0xF8) << 8) |
        (@as(u16, g & 0xFC) << 3) |
        (@as(u16, b) >> 3);
}

/// Standard colors
pub const Colors = struct {
    pub const BLACK: Color = 0x0000;
    pub const WHITE: Color = 0xFFFF;
    pub const RED: Color = 0xF800;
    pub const GREEN: Color = 0x07E0;
    pub const BLUE: Color = 0x001F;
    pub const CYAN: Color = 0x07FF;
    pub const MAGENTA: Color = 0xF81F;
    pub const YELLOW: Color = 0xFFE0;
    pub const ORANGE: Color = rgb(255, 165, 0);
    pub const GRAY: Color = rgb(128, 128, 128);
    pub const DARK_GRAY: Color = rgb(64, 64, 64);
    pub const LIGHT_GRAY: Color = rgb(192, 192, 192);

    // Quantum Seed Vault theme colors
    pub const VAULT_BG: Color = rgb(16, 24, 32); // Dark blue-gray
    pub const VAULT_FG: Color = rgb(0, 255, 136); // Cyber green
    pub const VAULT_ACCENT: Color = rgb(255, 200, 0); // Gold
    pub const VAULT_ERROR: Color = rgb(255, 64, 64); // Soft red
    pub const VAULT_SUCCESS: Color = rgb(64, 255, 128); // Bright green
};

/// 2D point
pub const Point = struct {
    x: i16,
    y: i16,

    pub fn init(x: i16, y: i16) Point {
        return .{ .x = x, .y = y };
    }
};

/// Rectangle
pub const Rect = struct {
    x: i16,
    y: i16,
    width: u16,
    height: u16,

    pub fn init(x: i16, y: i16, width: u16, height: u16) Rect {
        return .{ .x = x, .y = y, .width = width, .height = height };
    }

    pub fn contains(self: Rect, p: Point) bool {
        return p.x >= self.x and
            p.x < self.x + @as(i16, @intCast(self.width)) and
            p.y >= self.y and
            p.y < self.y + @as(i16, @intCast(self.height));
    }
};

/// Text alignment
pub const Align = enum {
    left,
    center,
    right,
};

/// Font size (for built-in bitmap fonts)
pub const FontSize = enum {
    small, // 8x8
    medium, // 8x16
    large, // 16x16

    pub fn charWidth(self: FontSize) u8 {
        return switch (self) {
            .small => 6,
            .medium => 8,
            .large => 16,
        };
    }

    pub fn charHeight(self: FontSize) u8 {
        return switch (self) {
            .small => 8,
            .medium => 16,
            .large => 16,
        };
    }
};

/// UI Theme configuration
pub const Theme = struct {
    background: Color = Colors.VAULT_BG,
    text: Color = Colors.WHITE,
    primary: Color = Colors.VAULT_BG,
    secondary: Color = Colors.DARK_GRAY,
    accent: Color = Colors.VAULT_ACCENT,
    highlight: Color = rgb(32, 48, 64),
    error_color: Color = Colors.VAULT_ERROR,
    success: Color = Colors.VAULT_SUCCESS,
};
