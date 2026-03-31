//! SVG Generation Utilities
//!
//! Helper functions for generating SVG graphics.

const std = @import("std");

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn toHex(self: Color) [7]u8 {
        var buf: [7]u8 = undefined;
        _ = std.fmt.bufPrint(&buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ self.r, self.g, self.b }) catch unreachable;
        return buf;
    }

    pub const white = Color{ .r = 255, .g = 255, .b = 255 };
    pub const black = Color{ .r = 0, .g = 0, .b = 0 };
    pub const red = Color{ .r = 255, .g = 0, .b = 0 };
    pub const green = Color{ .r = 0, .g = 255, .b = 0 };
    pub const blue = Color{ .r = 0, .g = 0, .b = 255 };
    pub const gray = Color{ .r = 128, .g = 128, .b = 128 };
    pub const lightGreen = Color{ .r = 144, .g = 238, .b = 144 };
    pub const lightGray = Color{ .r = 221, .g = 221, .b = 221 };
};

/// Color palette for register fields
pub const fieldColors = [_]Color{
    Color{ .r = 144, .g = 238, .b = 144 }, // Light green
    Color{ .r = 173, .g = 216, .b = 230 }, // Light blue
    Color{ .r = 255, .g = 218, .b = 185 }, // Peach
    Color{ .r = 221, .g = 160, .b = 221 }, // Plum
    Color{ .r = 255, .g = 255, .b = 224 }, // Light yellow
    Color{ .r = 176, .g = 224, .b = 230 }, // Powder blue
    Color{ .r = 255, .g = 182, .b = 193 }, // Light pink
    Color{ .r = 152, .g = 251, .b = 152 }, // Pale green
};

pub fn getFieldColor(index: usize) Color {
    return fieldColors[index % fieldColors.len];
}

/// Write SVG header
pub fn writeHeader(writer: anytype, width: u32, height: u32) !void {
    try writer.print(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {d} {d}" width="{d}" height="{d}">
        \\
    , .{ width, height, width, height });
}

/// Write SVG footer
pub fn writeFooter(writer: anytype) !void {
    try writer.writeAll("</svg>\n");
}

/// Write a rectangle
pub fn writeRect(writer: anytype, x: u32, y: u32, width: u32, height: u32, fill: Color, stroke: Color) !void {
    const fill_hex = fill.toHex();
    const stroke_hex = stroke.toHex();
    try writer.print(
        \\  <rect x="{d}" y="{d}" width="{d}" height="{d}" fill="{s}" stroke="{s}" stroke-width="1"/>
        \\
    , .{ x, y, width, height, fill_hex, stroke_hex });
}

/// Write text
pub fn writeText(writer: anytype, x: u32, y: u32, text: []const u8, font_size: u32, anchor: []const u8) !void {
    try writer.print(
        \\  <text x="{d}" y="{d}" font-family="monospace" font-size="{d}" text-anchor="{s}">{s}</text>
        \\
    , .{ x, y, font_size, anchor, text });
}

test "Color.toHex" {
    const c = Color{ .r = 255, .g = 128, .b = 0 };
    const hex = c.toHex();
    try std.testing.expectEqualStrings("#ff8000", &hex);
}
