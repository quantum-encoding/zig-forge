//! Terminal cell representation
//!
//! A cell is the fundamental unit of a terminal display, containing
//! a character and its style (colors and attributes).

const std = @import("std");
const color = @import("color.zig");

pub const Color = color.Color;
pub const Style = color.Style;
pub const Attrs = color.Attrs;

/// A single terminal cell
pub const Cell = struct {
    /// Unicode codepoint (use 0 for empty, ' ' for space)
    char: u21 = ' ',
    /// Cell style
    style: Style = .{},
    /// Wide character flag (second cell of wide char)
    wide: Wide = .narrow,

    pub const Wide = enum(u2) {
        narrow = 0,
        wide = 1,
        wide_spacer = 2, // Placeholder for second cell of wide char
    };

    pub const empty = Cell{};
    pub const space = Cell{ .char = ' ' };

    /// Create cell with character
    pub fn init(char: u21) Cell {
        return .{ .char = char };
    }

    /// Create cell with character and style
    pub fn styled(char: u21, style: Style) Cell {
        return .{ .char = char, .style = style };
    }

    /// Create cell with character and foreground color
    pub fn withFg(char: u21, fg: Color) Cell {
        return .{ .char = char, .style = .{ .fg = fg } };
    }

    /// Create cell with character, foreground, and background
    pub fn withColors(char: u21, fg: Color, bg: Color) Cell {
        return .{ .char = char, .style = .{ .fg = fg, .bg = bg } };
    }

    /// Check if cells are visually equal
    pub fn eql(self: Cell, other: Cell) bool {
        return self.char == other.char and
            self.style.eql(other.style) and
            self.wide == other.wide;
    }

    /// Check if cell is empty (no visible content)
    pub fn isEmpty(self: Cell) bool {
        return self.char == 0 or self.char == ' ';
    }

    /// Check if cell is a wide character spacer
    pub fn isSpacer(self: Cell) bool {
        return self.wide == .wide_spacer;
    }

    /// Get display width of character (1 or 2)
    pub fn width(self: Cell) u8 {
        return if (self.wide == .wide) 2 else 1;
    }
};

/// Calculate display width of a Unicode codepoint
/// Returns 0 for control chars, 1 for normal, 2 for wide (CJK, etc.)
pub fn charWidth(c: u21) u8 {
    // Control characters
    if (c < 0x20 or (c >= 0x7F and c < 0xA0)) return 0;

    // Common ASCII (fast path)
    if (c < 0x300) return 1;

    // Combining characters (zero-width)
    if (isCombining(c)) return 0;

    // Wide characters (CJK, etc.)
    if (isWide(c)) return 2;

    return 1;
}

/// Check if codepoint is a combining character
fn isCombining(c: u21) bool {
    // Combining Diacritical Marks
    if (c >= 0x0300 and c <= 0x036F) return true;
    // Combining Diacritical Marks Extended
    if (c >= 0x1AB0 and c <= 0x1AFF) return true;
    // Combining Diacritical Marks Supplement
    if (c >= 0x1DC0 and c <= 0x1DFF) return true;
    // Combining Diacritical Marks for Symbols
    if (c >= 0x20D0 and c <= 0x20FF) return true;
    // Combining Half Marks
    if (c >= 0xFE20 and c <= 0xFE2F) return true;
    return false;
}

/// Check if codepoint is a wide character (CJK, etc.)
fn isWide(c: u21) bool {
    // CJK Unified Ideographs
    if (c >= 0x4E00 and c <= 0x9FFF) return true;
    // CJK Unified Ideographs Extension A
    if (c >= 0x3400 and c <= 0x4DBF) return true;
    // CJK Compatibility Ideographs
    if (c >= 0xF900 and c <= 0xFAFF) return true;
    // Hangul Syllables
    if (c >= 0xAC00 and c <= 0xD7AF) return true;
    // Hiragana
    if (c >= 0x3040 and c <= 0x309F) return true;
    // Katakana
    if (c >= 0x30A0 and c <= 0x30FF) return true;
    // Fullwidth Forms
    if (c >= 0xFF00 and c <= 0xFFEF) return true;
    // Enclosed CJK Letters and Months
    if (c >= 0x3200 and c <= 0x32FF) return true;
    // CJK Compatibility
    if (c >= 0x3300 and c <= 0x33FF) return true;
    return false;
}

/// Calculate display width of a string
pub fn stringWidth(s: []const u8) usize {
    var width: usize = 0;
    var iter = std.unicode.Utf8Iterator{ .bytes = s, .i = 0 };
    while (iter.nextCodepoint()) |cp| {
        width += charWidth(cp);
    }
    return width;
}

test "charWidth" {
    try std.testing.expectEqual(@as(u8, 1), charWidth('A'));
    try std.testing.expectEqual(@as(u8, 1), charWidth(' '));
    try std.testing.expectEqual(@as(u8, 0), charWidth(0x0300)); // Combining
    try std.testing.expectEqual(@as(u8, 2), charWidth(0x4E00)); // CJK
}

test "stringWidth" {
    try std.testing.expectEqual(@as(usize, 5), stringWidth("Hello"));
    try std.testing.expectEqual(@as(usize, 0), stringWidth(""));
}

test "Cell.eql" {
    const a = Cell.init('A');
    const b = Cell.init('A');
    const c = Cell.init('B');
    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
}
