//! PDF Document Builder
//!
//! Low-level PDF-1.4 document writer with support for:
//! - Pages with content streams
//! - Text rendering with built-in fonts
//! - Image embedding (JPEG, PNG via raw embedding)
//! - Vector graphics (lines, rectangles, paths)
//! - Color support (RGB, grayscale)
//!
//! PDF Structure:
//! %PDF-1.4
//! 1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj
//! 2 0 obj << /Type /Pages /Kids [...] /Count N >> endobj
//! 3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [...] /Contents X 0 R /Resources << ... >> >> endobj
//! ...
//! xref
//! trailer
//! %%EOF

const std = @import("std");

// =============================================================================
// Constants
// =============================================================================

/// A4 page dimensions in points (72 points = 1 inch)
pub const A4_WIDTH: f32 = 595.276;
pub const A4_HEIGHT: f32 = 841.890;

/// Letter page dimensions
pub const LETTER_WIDTH: f32 = 612.0;
pub const LETTER_HEIGHT: f32 = 792.0;

/// Maximum objects in a PDF document
const MAX_OBJECTS = 4096;
const MAX_PAGES = 1024;
const MAX_FONTS = 16;
const MAX_IMAGES = 1024;

// =============================================================================
// PDF Object Types
// =============================================================================

pub const PageSize = struct {
    width: f32,
    height: f32,

    pub const a4 = PageSize{ .width = A4_WIDTH, .height = A4_HEIGHT };
    pub const letter = PageSize{ .width = LETTER_WIDTH, .height = LETTER_HEIGHT };
};

pub const Color = struct {
    r: f32, // 0.0 - 1.0
    g: f32,
    b: f32,

    pub const black = Color{ .r = 0, .g = 0, .b = 0 };
    pub const white = Color{ .r = 1, .g = 1, .b = 1 };
    pub const red = Color{ .r = 1, .g = 0, .b = 0 };
    pub const green = Color{ .r = 0, .g = 1, .b = 0 };
    pub const blue = Color{ .r = 0, .g = 0, .b = 1 };

    /// Parse hex color string like "#b39a7d" or "b39a7d"
    pub fn fromHex(hex: []const u8) Color {
        var start: usize = 0;
        if (hex.len > 0 and hex[0] == '#') {
            start = 1;
        }

        if (hex.len - start < 6) return Color.black;

        const r = std.fmt.parseInt(u8, hex[start .. start + 2], 16) catch 0;
        const g = std.fmt.parseInt(u8, hex[start + 2 .. start + 4], 16) catch 0;
        const b_val = std.fmt.parseInt(u8, hex[start + 4 .. start + 6], 16) catch 0;

        return Color{
            .r = @as(f32, @floatFromInt(r)) / 255.0,
            .g = @as(f32, @floatFromInt(g)) / 255.0,
            .b = @as(f32, @floatFromInt(b_val)) / 255.0,
        };
    }
};

/// Decode one UTF-8 code point from `text` at `*pos` and return the
/// WinAnsiEncoding byte. Advances `*pos` past the consumed bytes.
/// Code points outside WinAnsiEncoding (> U+00FF or in the 0x80-0x9F
/// gap that maps to Windows-1252 specials) are mapped to '?' (0x3F).
/// The 0x80-0x9F Windows-1252 range (€, curly quotes, em dash, etc.)
/// is mapped correctly via a lookup table.
pub fn utf8ToWinAnsi(text: []const u8, pos: *usize) u8 {
    const i = pos.*;
    if (i >= text.len) {
        pos.* = text.len;
        return '?';
    }
    const b0 = text[i];

    // ASCII: 1-byte sequence, pass through directly
    if (b0 < 0x80) {
        pos.* = i + 1;
        return b0;
    }

    // 2-byte sequence: 110xxxxx 10xxxxxx → U+0080..U+07FF
    if (b0 >= 0xC0 and b0 < 0xE0 and i + 1 < text.len) {
        const cp: u16 = (@as(u16, b0 & 0x1F) << 6) | (text[i + 1] & 0x3F);
        pos.* = i + 2;
        // U+00A0..U+00FF map 1:1 to WinAnsiEncoding byte values
        if (cp >= 0x00A0 and cp <= 0x00FF) return @intCast(cp);
        // U+0080..U+009F: Windows-1252 specials (€, smart quotes, etc.)
        return win1252FromCodepoint(cp);
    }

    // 3-byte sequence: 1110xxxx 10xxxxxx 10xxxxxx → U+0800..U+FFFF
    if (b0 >= 0xE0 and b0 < 0xF0 and i + 2 < text.len) {
        const cp: u21 = (@as(u21, b0 & 0x0F) << 12) |
            (@as(u21, text[i + 1] & 0x3F) << 6) |
            (text[i + 2] & 0x3F);
        pos.* = i + 3;
        // Common Windows-1252 code points in the BMP (€, smart quotes, etc.)
        return win1252FromCodepoint(@intCast(@min(cp, 0xFFFF)));
    }

    // 4-byte sequence: skip (no WinAnsi mapping for supplementary planes)
    if (b0 >= 0xF0 and i + 3 < text.len) {
        pos.* = i + 4;
        return '?';
    }

    // Invalid/orphan continuation byte — skip one byte
    pos.* = i + 1;
    return '?';
}

/// Map Unicode code points in the Windows-1252 "hole" (U+0080..U+009F are
/// control characters in ISO 8859-1 but printable in Windows-1252) plus
/// common BMP code points (€, smart quotes, em dash, etc.) to their
/// WinAnsiEncoding byte positions.
fn win1252FromCodepoint(cp: u16) u8 {
    return switch (cp) {
        0x20AC => 0x80, // €
        0x201A => 0x82, // ‚
        0x0192 => 0x83, // ƒ
        0x201E => 0x84, // „
        0x2026 => 0x85, // …
        0x2020 => 0x86, // †
        0x2021 => 0x87, // ‡
        0x02C6 => 0x88, // ˆ
        0x2030 => 0x89, // ‰
        0x0160 => 0x8A, // Š
        0x2039 => 0x8B, // ‹
        0x0152 => 0x8C, // Œ
        0x017D => 0x8E, // Ž
        0x2018 => 0x91, // '
        0x2019 => 0x92, // '
        0x201C => 0x93, // "
        0x201D => 0x94, // "
        0x2022 => 0x95, // •
        0x2013 => 0x96, // –
        0x2014 => 0x97, // —
        0x02DC => 0x98, // ˜
        0x2122 => 0x99, // ™
        0x0161 => 0x9A, // š
        0x203A => 0x9B, // ›
        0x0153 => 0x9C, // œ
        0x017E => 0x9E, // ž
        0x0178 => 0x9F, // Ÿ
        else => '?',
    };
}

pub const Font = enum {
    helvetica,
    helvetica_bold,
    helvetica_oblique,
    helvetica_bold_oblique,
    times_roman,
    times_bold,
    times_italic,
    times_bold_italic,
    courier,
    courier_bold,
    courier_oblique,
    courier_bold_oblique,

    pub fn pdfName(self: Font) []const u8 {
        return switch (self) {
            .helvetica => "Helvetica",
            .helvetica_bold => "Helvetica-Bold",
            .helvetica_oblique => "Helvetica-Oblique",
            .helvetica_bold_oblique => "Helvetica-BoldOblique",
            .times_roman => "Times-Roman",
            .times_bold => "Times-Bold",
            .times_italic => "Times-Italic",
            .times_bold_italic => "Times-BoldItalic",
            .courier => "Courier",
            .courier_bold => "Courier-Bold",
            .courier_oblique => "Courier-Oblique",
            .courier_bold_oblique => "Courier-BoldOblique",
        };
    }

    /// Get approximate character width for basic metrics (in 1/1000 of font size)
    pub fn avgCharWidth(self: Font) f32 {
        return switch (self) {
            .helvetica, .helvetica_oblique => 0.52,
            .helvetica_bold, .helvetica_bold_oblique => 0.55,
            .times_roman, .times_italic => 0.45,
            .times_bold, .times_bold_italic => 0.48,
            .courier, .courier_bold, .courier_oblique, .courier_bold_oblique => 0.60,
        };
    }

    /// Get WinAnsiEncoding character width in thousandths of an em.
    /// Full 256-entry table from Adobe's AFM metrics for Helvetica.
    pub fn charWidth(self: Font, char: u8) u16 {
        // Helvetica: full WinAnsiEncoding width table (positions 0-255)
        const helvetica_widths = [256]u16{
            // 0-31: control characters (zero width)
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            // 32-47: space ! " # $ % & ' ( ) * + , - . /
            278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, 278, 278,
            // 48-63: 0-9 : ; < = > ?
            556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 278, 278, 584, 584, 584, 556,
            // 64-79: @ A-O
            1015, 667, 667, 722, 722, 667, 611, 778, 722, 278, 500, 667, 556, 833, 722, 778,
            // 80-95: P-Z [ \ ] ^ _
            667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 278, 278, 278, 469, 556,
            // 96-111: ` a-o
            333, 556, 556, 500, 556, 556, 278, 556, 556, 222, 222, 500, 222, 833, 556, 556,
            // 112-127: p-~ DEL
            556, 556, 333, 500, 278, 556, 500, 722, 500, 500, 500, 334, 260, 334, 584, 278,
            // 128-143: € . ‚ ƒ „ … † ‡ ˆ ‰ Š ‹ Œ . Ž .
            556, 278, 222, 556, 333, 1000, 556, 556, 333, 1000, 667, 333, 1000, 278, 611, 278,
            // 144-159: . ' ' " " • – — ˜ ™ š › œ . ž Ÿ
            278, 222, 222, 333, 333, 350, 556, 1000, 333, 1000, 500, 333, 944, 278, 500, 667,
            // 160-175: nbsp ¡ ¢ £ ¤ ¥ ¦ § ¨ © ª « ¬ SHY ® ¯
            278, 333, 556, 556, 556, 556, 260, 556, 333, 737, 370, 556, 584, 333, 737, 333,
            // 176-191: ° ± ² ³ ´ µ ¶ · ¸ ¹ º » ¼ ½ ¾ ¿
            400, 584, 333, 333, 333, 556, 537, 278, 333, 333, 365, 556, 834, 834, 834, 611,
            // 192-207: À Á Â Ã Ä Å Æ Ç È É Ê Ë Ì Í Î Ï
            667, 667, 667, 667, 667, 667, 1000, 722, 667, 667, 667, 667, 278, 278, 278, 278,
            // 208-223: Ð Ñ Ò Ó Ô Õ Ö × Ø Ù Ú Û Ü Ý Þ ß
            722, 722, 778, 778, 778, 778, 778, 584, 778, 722, 722, 722, 722, 667, 667, 611,
            // 224-239: à á â ã ä å æ ç è é ê ë ì í î ï
            556, 556, 556, 556, 556, 556, 889, 500, 556, 556, 556, 556, 278, 278, 278, 278,
            // 240-255: ð ñ ò ó ô õ ö ÷ ø ù ú û ü ý þ ÿ
            556, 556, 556, 556, 556, 556, 556, 584, 611, 556, 556, 556, 556, 500, 556, 500,
        };

        const helvetica_bold_widths = [256]u16{
            // 0-31: control characters
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            // 32-47
            278, 333, 474, 556, 556, 889, 722, 238, 333, 333, 389, 584, 278, 333, 278, 278,
            // 48-63
            556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 333, 333, 584, 584, 584, 611,
            // 64-79
            975, 722, 722, 722, 722, 667, 611, 778, 722, 278, 556, 722, 611, 833, 722, 778,
            // 80-95
            667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 333, 278, 333, 584, 556,
            // 96-111
            333, 556, 611, 556, 611, 556, 333, 611, 611, 278, 278, 556, 278, 889, 611, 611,
            // 112-127
            611, 611, 389, 556, 333, 611, 556, 778, 556, 556, 500, 389, 280, 389, 584, 278,
            // 128-143
            556, 278, 278, 556, 389, 1000, 556, 556, 333, 1000, 667, 333, 1000, 278, 611, 278,
            // 144-159
            278, 278, 278, 389, 389, 350, 556, 1000, 333, 1000, 556, 333, 944, 278, 500, 667,
            // 160-175
            278, 333, 556, 556, 556, 556, 280, 556, 333, 737, 370, 556, 584, 333, 737, 333,
            // 176-191
            400, 584, 333, 333, 333, 611, 556, 278, 333, 333, 365, 556, 834, 834, 834, 611,
            // 192-207
            722, 722, 722, 722, 722, 722, 1000, 722, 667, 667, 667, 667, 278, 278, 278, 278,
            // 208-223
            722, 722, 778, 778, 778, 778, 778, 584, 778, 722, 722, 722, 722, 667, 667, 611,
            // 224-239
            556, 556, 556, 556, 556, 556, 889, 556, 556, 556, 556, 556, 278, 278, 278, 278,
            // 240-255
            611, 611, 611, 611, 611, 611, 611, 584, 611, 611, 611, 611, 611, 556, 611, 556,
        };

        const courier_width: u16 = 600;

        return switch (self) {
            .helvetica, .helvetica_oblique => helvetica_widths[char],
            .helvetica_bold, .helvetica_bold_oblique => helvetica_bold_widths[char],
            .times_roman, .times_italic => helvetica_widths[char],
            .times_bold, .times_bold_italic => helvetica_bold_widths[char],
            .courier, .courier_bold, .courier_oblique, .courier_bold_oblique => courier_width,
        };
    }

    /// Measure text width in points. Decodes UTF-8 → WinAnsiEncoding.
    pub fn measureText(self: Font, text: []const u8, font_size: f32) f32 {
        var total_width: f32 = 0;
        var i: usize = 0;
        while (i < text.len) {
            const winansi = utf8ToWinAnsi(text, &i);
            total_width += @as(f32, @floatFromInt(self.charWidth(winansi))) * font_size / 1000.0;
        }
        return total_width;
    }
};

// =============================================================================
// Text Wrapping Utilities
// =============================================================================

/// Result of text wrapping - contains lines that fit within max_width
pub const WrappedText = struct {
    lines: [][]const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *WrappedText) void {
        self.allocator.free(self.lines);
    }
};

/// Wrap text to fit within max_width at word boundaries.
/// UTF-8 aware: multi-byte characters are measured as single WinAnsi glyphs.
/// Returns slices into the original UTF-8 text (no string data allocation).
pub fn wrapText(allocator: std.mem.Allocator, text: []const u8, font: Font, font_size: f32, max_width: f32) !WrappedText {
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer lines.deinit(allocator);

    if (text.len == 0) {
        return .{ .lines = try lines.toOwnedSlice(allocator), .allocator = allocator };
    }

    var line_start: usize = 0;
    var last_space: ?usize = null;
    var current_width: f32 = 0;

    var i: usize = 0;
    while (i < text.len) {
        const byte_pos = i;
        const winansi = utf8ToWinAnsi(text, &i);
        // i now points past the consumed UTF-8 bytes
        const char_width = @as(f32, @floatFromInt(font.charWidth(winansi))) * font_size / 1000.0;

        // Track word boundaries (space is always 1 byte in UTF-8)
        if (winansi == ' ') {
            last_space = byte_pos;
        }

        // Check if adding this character exceeds max width
        if (current_width + char_width > max_width and byte_pos > line_start) {
            // Need to wrap
            if (last_space) |space_idx| {
                if (space_idx > line_start) {
                    // Wrap at last space
                    try lines.append(allocator, text[line_start..space_idx]);
                    line_start = space_idx + 1; // Skip the space
                    last_space = null;
                    // Recalculate width from new line start using measureText
                    current_width = font.measureText(text[line_start..i], font_size);
                    continue;
                }
            }
            // No space found - force break at current position (mid-word)
            // Force break at current code point boundary
            try lines.append(allocator, text[line_start..byte_pos]);
            line_start = byte_pos;
            current_width = char_width;
            last_space = null;
        } else {
            current_width += char_width;
        }
    }

    // Add remaining text as final line
    if (line_start < text.len) {
        try lines.append(allocator, text[line_start..]);
    }

    return .{ .lines = try lines.toOwnedSlice(allocator), .allocator = allocator };
}

pub const TextAlign = enum {
    left,
    center,
    right,
};

// =============================================================================
// Image Support
// =============================================================================

pub const ImageFormat = enum {
    jpeg,
    png_rgb,
    png_rgba,
    raw_rgb,
    raw_rgba,
};

pub const Image = struct {
    width: u32,
    height: u32,
    format: ImageFormat,
    data: []const u8,
    object_id: u32 = 0,
};

// =============================================================================
// Content Stream Builder
// =============================================================================

pub const ContentStream = struct {
    buffer: std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ContentStream {
        return .{
            .buffer = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ContentStream) void {
        self.buffer.deinit(self.allocator);
    }

    // -------------------------------------------------------------------------
    // Graphics State
    // -------------------------------------------------------------------------

    pub fn saveState(self: *ContentStream) !void {
        try self.buffer.appendSlice(self.allocator, "q\n");
    }

    pub fn restoreState(self: *ContentStream) !void {
        try self.buffer.appendSlice(self.allocator, "Q\n");
    }

    // -------------------------------------------------------------------------
    // Color Operations
    // -------------------------------------------------------------------------

    pub fn setFillColor(self: *ContentStream, color: Color) !void {
        var buf: [64]u8 = undefined;
        const len = std.fmt.bufPrint(&buf, "{d:.3} {d:.3} {d:.3} rg\n", .{ color.r, color.g, color.b }) catch return error.BufferTooSmall;
        try self.buffer.appendSlice(self.allocator, len);
    }

    pub fn setStrokeColor(self: *ContentStream, color: Color) !void {
        var buf: [64]u8 = undefined;
        const len = std.fmt.bufPrint(&buf, "{d:.3} {d:.3} {d:.3} RG\n", .{ color.r, color.g, color.b }) catch return error.BufferTooSmall;
        try self.buffer.appendSlice(self.allocator, len);
    }

    pub fn setLineWidth(self: *ContentStream, width: f32) !void {
        var buf: [32]u8 = undefined;
        const len = std.fmt.bufPrint(&buf, "{d:.2} w\n", .{width}) catch return error.BufferTooSmall;
        try self.buffer.appendSlice(self.allocator, len);
    }

    // -------------------------------------------------------------------------
    // Path Operations
    // -------------------------------------------------------------------------

    pub fn moveTo(self: *ContentStream, x: f32, y: f32) !void {
        var buf: [64]u8 = undefined;
        const len = std.fmt.bufPrint(&buf, "{d:.2} {d:.2} m\n", .{ x, y }) catch return error.BufferTooSmall;
        try self.buffer.appendSlice(self.allocator, len);
    }

    pub fn lineTo(self: *ContentStream, x: f32, y: f32) !void {
        var buf: [64]u8 = undefined;
        const len = std.fmt.bufPrint(&buf, "{d:.2} {d:.2} l\n", .{ x, y }) catch return error.BufferTooSmall;
        try self.buffer.appendSlice(self.allocator, len);
    }

    pub fn rect(self: *ContentStream, x: f32, y: f32, width: f32, height: f32) !void {
        var buf: [128]u8 = undefined;
        const len = std.fmt.bufPrint(&buf, "{d:.2} {d:.2} {d:.2} {d:.2} re\n", .{ x, y, width, height }) catch return error.BufferTooSmall;
        try self.buffer.appendSlice(self.allocator, len);
    }

    pub fn stroke(self: *ContentStream) !void {
        try self.buffer.appendSlice(self.allocator, "S\n");
    }

    pub fn fill(self: *ContentStream) !void {
        try self.buffer.appendSlice(self.allocator, "f\n");
    }

    pub fn fillStroke(self: *ContentStream) !void {
        try self.buffer.appendSlice(self.allocator, "B\n");
    }

    pub fn closePath(self: *ContentStream) !void {
        try self.buffer.appendSlice(self.allocator, "h\n");
    }

    // -------------------------------------------------------------------------
    // Rectangle Helpers
    // -------------------------------------------------------------------------

    pub fn drawRect(self: *ContentStream, x: f32, y: f32, width: f32, height: f32, fill_color: ?Color, stroke_color: ?Color) !void {
        try self.saveState();

        if (fill_color) |fc| {
            try self.setFillColor(fc);
        }
        if (stroke_color) |sc| {
            try self.setStrokeColor(sc);
        }

        try self.rect(x, y, width, height);

        if (fill_color != null and stroke_color != null) {
            try self.fillStroke();
        } else if (fill_color != null) {
            try self.fill();
        } else {
            try self.stroke();
        }

        try self.restoreState();
    }

    pub fn drawLine(self: *ContentStream, x1: f32, y1: f32, x2: f32, y2: f32, color: Color, width: f32) !void {
        try self.saveState();
        try self.setStrokeColor(color);
        try self.setLineWidth(width);
        try self.moveTo(x1, y1);
        try self.lineTo(x2, y2);
        try self.stroke();
        try self.restoreState();
    }

    // -------------------------------------------------------------------------
    // Text Operations
    // -------------------------------------------------------------------------

    pub fn beginText(self: *ContentStream) !void {
        try self.buffer.appendSlice(self.allocator, "BT\n");
    }

    pub fn endText(self: *ContentStream) !void {
        try self.buffer.appendSlice(self.allocator, "ET\n");
    }

    pub fn setFont(self: *ContentStream, font_id: []const u8, size: f32) !void {
        var buf: [64]u8 = undefined;
        const len = std.fmt.bufPrint(&buf, "/{s} {d:.1} Tf\n", .{ font_id, size }) catch return error.BufferTooSmall;
        try self.buffer.appendSlice(self.allocator, len);
    }

    pub fn setTextPosition(self: *ContentStream, x: f32, y: f32) !void {
        var buf: [64]u8 = undefined;
        const len = std.fmt.bufPrint(&buf, "{d:.2} {d:.2} Td\n", .{ x, y }) catch return error.BufferTooSmall;
        try self.buffer.appendSlice(self.allocator, len);
    }

    pub fn showText(self: *ContentStream, text: []const u8) !void {
        try self.buffer.append(self.allocator, '(');
        // Decode UTF-8 → WinAnsiEncoding, escaping PDF special characters.
        // Each Unicode code point becomes exactly one WinAnsi byte.
        var i: usize = 0;
        while (i < text.len) {
            const c = utf8ToWinAnsi(text, &i);
            switch (c) {
                '(' => try self.buffer.appendSlice(self.allocator, "\\("),
                ')' => try self.buffer.appendSlice(self.allocator, "\\)"),
                '\\' => try self.buffer.appendSlice(self.allocator, "\\\\"),
                else => try self.buffer.append(self.allocator, c),
            }
        }
        try self.buffer.appendSlice(self.allocator, ") Tj\n");
    }

    /// Draw text at position with font
    pub fn drawText(self: *ContentStream, text: []const u8, x: f32, y: f32, font_id: []const u8, size: f32, color: Color) !void {
        try self.saveState();
        try self.setFillColor(color);
        try self.beginText();
        try self.setFont(font_id, size);
        try self.setTextPosition(x, y);
        try self.showText(text);
        try self.endText();
        try self.restoreState();
    }

    // -------------------------------------------------------------------------
    // Image Operations
    // -------------------------------------------------------------------------

    pub fn drawImage(self: *ContentStream, image_id: []const u8, x: f32, y: f32, width: f32, height: f32) !void {
        try self.saveState();
        // Transformation matrix: scale and translate
        var buf: [128]u8 = undefined;
        const len = std.fmt.bufPrint(&buf, "{d:.2} 0 0 {d:.2} {d:.2} {d:.2} cm\n", .{ width, height, x, y }) catch return error.BufferTooSmall;
        try self.buffer.appendSlice(self.allocator, len);

        var buf2: [32]u8 = undefined;
        const len2 = std.fmt.bufPrint(&buf2, "/{s} Do\n", .{image_id}) catch return error.BufferTooSmall;
        try self.buffer.appendSlice(self.allocator, len2);

        try self.restoreState();
    }

    // -------------------------------------------------------------------------
    // Button Component (for clickable payment links)
    // -------------------------------------------------------------------------

    /// Draw a styled button with centered text
    /// Returns the button bounds for link annotation: (x1, y1, x2, y2)
    pub fn drawButton(
        self: *ContentStream,
        text: []const u8,
        x: f32,
        y: f32,
        width: f32,
        height: f32,
        font_id: []const u8,
        font_size: f32,
        bg_color: Color,
        text_color: Color,
        border_radius: f32,
    ) !struct { x1: f32, y1: f32, x2: f32, y2: f32 } {
        try self.saveState();

        // Draw button background
        if (border_radius > 0) {
            // Rounded rectangle using bezier curves
            try self.drawRoundedRect(x, y, width, height, border_radius, bg_color);
        } else {
            // Simple rectangle
            try self.setFillColor(bg_color);
            try self.rect(x, y, width, height);
            try self.fill();
        }

        // Calculate text centering
        // Approximate character width: 0.5 * font_size for most fonts
        const text_width = @as(f32, @floatFromInt(text.len)) * font_size * 0.5;
        const text_x = x + (width - text_width) / 2;
        const text_y = y + (height - font_size) / 2 + font_size * 0.2; // Baseline adjustment

        // Draw centered text
        try self.setFillColor(text_color);
        try self.beginText();
        try self.setFont(font_id, font_size);
        try self.setTextPosition(text_x, text_y);
        try self.showText(text);
        try self.endText();

        try self.restoreState();

        // Return bounds for link annotation (PDF coordinates)
        return .{
            .x1 = x,
            .y1 = y,
            .x2 = x + width,
            .y2 = y + height,
        };
    }

    /// Draw a rounded rectangle (filled)
    pub fn drawRoundedRect(self: *ContentStream, x: f32, y: f32, width: f32, height: f32, radius: f32, color: Color) !void {
        const r = @min(radius, @min(width, height) / 2);

        try self.setFillColor(color);

        // Bezier control point factor for circular arc approximation
        const k: f32 = 0.5522847498; // (4/3) * tan(pi/8)

        // Start at bottom-left corner (after radius)
        try self.moveTo(x + r, y);

        // Bottom edge
        try self.lineTo(x + width - r, y);
        // Bottom-right corner
        try self.curveTo(
            x + width - r + r * k,
            y,
            x + width,
            y + r - r * k,
            x + width,
            y + r,
        );

        // Right edge
        try self.lineTo(x + width, y + height - r);
        // Top-right corner
        try self.curveTo(
            x + width,
            y + height - r + r * k,
            x + width - r + r * k,
            y + height,
            x + width - r,
            y + height,
        );

        // Top edge
        try self.lineTo(x + r, y + height);
        // Top-left corner
        try self.curveTo(
            x + r - r * k,
            y + height,
            x,
            y + height - r + r * k,
            x,
            y + height - r,
        );

        // Left edge
        try self.lineTo(x, y + r);
        // Bottom-left corner
        try self.curveTo(
            x,
            y + r - r * k,
            x + r - r * k,
            y,
            x + r,
            y,
        );

        try self.closePath();
        try self.fill();
    }

    /// Cubic Bezier curve
    fn curveTo(self: *ContentStream, x1: f32, y1: f32, x2: f32, y2: f32, x3: f32, y3: f32) !void {
        var buf: [128]u8 = undefined;
        const len = std.fmt.bufPrint(&buf, "{d:.2} {d:.2} {d:.2} {d:.2} {d:.2} {d:.2} c\n", .{ x1, y1, x2, y2, x3, y3 }) catch return error.BufferTooSmall;
        try self.buffer.appendSlice(self.allocator, len);
    }

    /// Draw a circle using Bezier curves
    /// center_x, center_y: center of the circle
    /// radius: radius of the circle
    pub fn drawCircle(self: *ContentStream, center_x: f32, center_y: f32, radius: f32, fill_color: ?Color, stroke_color: ?Color) !void {
        try self.saveState();

        if (fill_color) |fc| {
            try self.setFillColor(fc);
        }
        if (stroke_color) |sc| {
            try self.setStrokeColor(sc);
        }

        // Bezier control point factor for circular arc approximation
        // (4/3) * tan(pi/8) gives us a good approximation of a circle with 4 cubic Bezier curves
        const k: f32 = 0.5522847498;
        const k_radius = k * radius;

        // Start at the rightmost point of the circle
        try self.moveTo(center_x + radius, center_y);

        // Top-right arc
        try self.curveTo(
            center_x + radius,
            center_y + k_radius,
            center_x + k_radius,
            center_y + radius,
            center_x,
            center_y + radius,
        );

        // Top-left arc
        try self.curveTo(
            center_x - k_radius,
            center_y + radius,
            center_x - radius,
            center_y + k_radius,
            center_x - radius,
            center_y,
        );

        // Bottom-left arc
        try self.curveTo(
            center_x - radius,
            center_y - k_radius,
            center_x - k_radius,
            center_y - radius,
            center_x,
            center_y - radius,
        );

        // Bottom-right arc
        try self.curveTo(
            center_x + k_radius,
            center_y - radius,
            center_x + radius,
            center_y - k_radius,
            center_x + radius,
            center_y,
        );

        try self.closePath();

        if (fill_color != null and stroke_color != null) {
            try self.fillStroke();
        } else if (fill_color != null) {
            try self.fill();
        } else {
            try self.stroke();
        }

        try self.restoreState();
    }

    pub fn getContent(self: *const ContentStream) []const u8 {
        return self.buffer.items;
    }
};

// =============================================================================
// PDF Document
// =============================================================================

/// Link annotation for clickable URLs in PDF
pub const LinkAnnotation = struct {
    x1: f32,
    y1: f32,
    x2: f32,
    y2: f32,
    url: []const u8,
};

const MAX_ANNOTATIONS = 16;
const MAX_CUSTOM_META = 4;

/// PDF /Info dictionary metadata
pub const PdfInfo = struct {
    title: ?[]const u8 = null,
    author: ?[]const u8 = null,
    subject: ?[]const u8 = null,
    keywords: ?[]const u8 = null,
    creator: ?[]const u8 = null,
    producer: ?[]const u8 = null,
    creation_date: ?[]const u8 = null,
    custom_keys: [MAX_CUSTOM_META]struct { key: []const u8, value: []const u8 } = undefined,
    custom_count: u8 = 0,

    pub fn addCustom(self: *PdfInfo, key: []const u8, value: []const u8) void {
        if (self.custom_count < MAX_CUSTOM_META) {
            self.custom_keys[self.custom_count] = .{ .key = key, .value = value };
            self.custom_count += 1;
        }
    }
};

pub const PdfDocument = struct {
    allocator: std.mem.Allocator,
    page_size: PageSize,

    // Object tracking
    objects: std.ArrayListUnmanaged([]u8),
    object_offsets: [MAX_OBJECTS]u32,
    next_object_id: u32,

    // Fonts
    font_ids: [MAX_FONTS]Font,
    font_count: u8,

    // Images
    images: [MAX_IMAGES]Image,
    image_count: u16,
    image_id_overflow: [16]u8,

    // Pages
    page_content_ids: [MAX_PAGES]u32,
    page_count: u16,

    // Link annotations (clickable URLs)
    annotations: [MAX_ANNOTATIONS]LinkAnnotation,
    annotation_count: u8,

    // PDF metadata (/Info dictionary)
    info: ?PdfInfo = null,

    // Output buffer
    output: std.ArrayListUnmanaged(u8),

    pub fn init(allocator: std.mem.Allocator) PdfDocument {
        return .{
            .allocator = allocator,
            .page_size = PageSize.a4,
            .objects = .empty,
            .object_offsets = [_]u32{0} ** MAX_OBJECTS,
            .next_object_id = 1,
            .font_ids = undefined,
            .font_count = 0,
            .images = undefined,
            .image_count = 0,
            .image_id_overflow = undefined,
            .page_content_ids = undefined,
            .page_count = 0,
            .annotations = undefined,
            .annotation_count = 0,
            .output = .empty,
        };
    }

    pub fn deinit(self: *PdfDocument) void {
        for (self.objects.items) |obj| {
            self.allocator.free(obj);
        }
        self.objects.deinit(self.allocator);
        self.output.deinit(self.allocator);
    }

    pub fn setPageSize(self: *PdfDocument, size: PageSize) void {
        self.page_size = size;
    }

    // -------------------------------------------------------------------------
    // Font Management
    // -------------------------------------------------------------------------

    pub fn addFont(self: *PdfDocument, font: Font) u8 {
        // Check if already added
        for (0..self.font_count) |i| {
            if (self.font_ids[i] == font) {
                return @intCast(i);
            }
        }

        if (self.font_count >= MAX_FONTS) return 0;

        self.font_ids[self.font_count] = font;
        const id = self.font_count;
        self.font_count += 1;
        return id;
    }

    pub fn getFontId(self: *PdfDocument, font: Font) []const u8 {
        const idx = self.addFont(font);
        // Return static string based on index
        return switch (idx) {
            0 => "F0",
            1 => "F1",
            2 => "F2",
            3 => "F3",
            4 => "F4",
            5 => "F5",
            6 => "F6",
            7 => "F7",
            else => "F0",
        };
    }

    // -------------------------------------------------------------------------
    // Image Management
    // -------------------------------------------------------------------------

    pub fn addImage(self: *PdfDocument, image: Image) ![]const u8 {
        if (self.image_count >= MAX_IMAGES) return error.TooManyImages;

        self.images[self.image_count] = image;
        const id = self.image_count;
        self.image_count += 1;

        // Return a stable image ID string
        if (id < image_id_table.len) return image_id_table[id];
        // For ids beyond the table, use a formatted buffer stored in image_id_overflow
        const s = std.fmt.bufPrint(&self.image_id_overflow, "Im{d}", .{id}) catch return "Im0";
        return s;
    }

    const image_id_table = [_][]const u8{
        "Im0",  "Im1",  "Im2",  "Im3",  "Im4",  "Im5",  "Im6",  "Im7",
        "Im8",  "Im9",  "Im10", "Im11", "Im12", "Im13", "Im14", "Im15",
        "Im16", "Im17", "Im18", "Im19", "Im20", "Im21", "Im22", "Im23",
        "Im24", "Im25", "Im26", "Im27", "Im28", "Im29", "Im30", "Im31",
    };

    // -------------------------------------------------------------------------
    // Link Annotations (Clickable URLs)
    // -------------------------------------------------------------------------

    /// Add a clickable hyperlink annotation to the current page
    /// Coordinates are in PDF points (0,0 = bottom-left of page)
    pub fn addLinkAnnotation(self: *PdfDocument, x1: f32, y1: f32, x2: f32, y2: f32, url: []const u8) !void {
        if (self.annotation_count >= MAX_ANNOTATIONS) return error.TooManyAnnotations;

        self.annotations[self.annotation_count] = .{
            .x1 = x1,
            .y1 = y1,
            .x2 = x2,
            .y2 = y2,
            .url = url,
        };
        self.annotation_count += 1;
    }

    // -------------------------------------------------------------------------
    // PDF Metadata
    // -------------------------------------------------------------------------

    pub fn setInfo(self: *PdfDocument, pdfinfo: PdfInfo) void {
        self.info = pdfinfo;
    }

    pub fn addCustomMetadata(self: *PdfDocument, key: []const u8, value: []const u8) void {
        if (self.info == null) {
            self.info = PdfInfo{};
        }
        if (self.info.?.custom_count < MAX_CUSTOM_META) {
            self.info.?.custom_keys[self.info.?.custom_count] = .{ .key = key, .value = value };
            self.info.?.custom_count += 1;
        }
    }

    // -------------------------------------------------------------------------
    // Page Management
    // -------------------------------------------------------------------------

    pub fn addPage(self: *PdfDocument, content: *ContentStream) !void {
        if (self.page_count >= MAX_PAGES) return error.TooManyPages;

        // Store content stream data for later
        const content_copy = try self.allocator.dupe(u8, content.getContent());
        try self.objects.append(self.allocator, content_copy);

        // Track page content (will be assigned object ID during build)
        self.page_content_ids[self.page_count] = @intCast(self.objects.items.len - 1);
        self.page_count += 1;
    }

    /// Add a page with custom dimensions (width, height in points)
    /// Use this for landscape pages or non-standard sizes
    pub fn addPageWithSize(self: *PdfDocument, content: *ContentStream, width: f32, height: f32) !void {
        // Temporarily set page size for this page
        const old_size = self.page_size;
        self.page_size = PageSize{ .width = width, .height = height };
        defer self.page_size = old_size;

        try self.addPage(content);
    }

    // -------------------------------------------------------------------------
    // Build PDF
    // -------------------------------------------------------------------------

    pub fn build(self: *PdfDocument) ![]const u8 {
        self.output.clearRetainingCapacity();

        // PDF Header
        try self.output.appendSlice(self.allocator, "%PDF-1.4\n");
        try self.output.appendSlice(self.allocator, "%\xE2\xE3\xCF\xD3\n"); // Binary marker

        // Object 1: Catalog
        const catalog_id = self.next_object_id;
        self.next_object_id += 1;
        try self.writeObject(catalog_id, "<< /Type /Catalog /Pages 2 0 R >>");

        // Object 2: Pages (placeholder, will update)
        const pages_id = self.next_object_id;
        self.next_object_id += 1;
        _ = self.output.items.len; // Offset tracked for potential future use

        // Build font dictionary
        var font_dict: std.ArrayListUnmanaged(u8) = .empty;
        defer font_dict.deinit(self.allocator);
        try font_dict.appendSlice(self.allocator, "<< ");
        for (0..self.font_count) |i| {
            var buf: [128]u8 = undefined;
            const font_obj_id = self.next_object_id + @as(u32, @intCast(i));
            const len = std.fmt.bufPrint(&buf, "/F{d} {d} 0 R ", .{ i, font_obj_id }) catch continue;
            try font_dict.appendSlice(self.allocator, len);
        }
        try font_dict.appendSlice(self.allocator, ">>");

        // Reserve object IDs for fonts
        const first_font_obj = self.next_object_id;
        self.next_object_id += self.font_count;

        // Build image dictionary (if any)
        var xobject_dict: std.ArrayListUnmanaged(u8) = .empty;
        defer xobject_dict.deinit(self.allocator);
        if (self.image_count > 0) {
            try xobject_dict.appendSlice(self.allocator, "<< ");
            for (0..self.image_count) |i| {
                var buf: [128]u8 = undefined;
                const img_obj_id = self.next_object_id + @as(u32, @intCast(i));
                const len = std.fmt.bufPrint(&buf, "/Im{d} {d} 0 R ", .{ i, img_obj_id }) catch continue;
                try xobject_dict.appendSlice(self.allocator, len);
            }
            try xobject_dict.appendSlice(self.allocator, ">>");
        }

        // Reserve object IDs for images
        const first_image_obj = self.next_object_id;
        self.next_object_id += self.image_count;

        // Build page objects
        var page_refs: std.ArrayListUnmanaged(u8) = .empty;
        defer page_refs.deinit(self.allocator);

        const first_page_obj = self.next_object_id;
        for (0..self.page_count) |i| {
            var buf: [32]u8 = undefined;
            const len = std.fmt.bufPrint(&buf, "{d} 0 R ", .{first_page_obj + @as(u32, @intCast(i)) * 2}) catch continue;
            try page_refs.appendSlice(self.allocator, len);
        }

        // Write Pages object (dynamic buffer for large page counts)
        {
            const pages_str = try std.fmt.allocPrint(self.allocator, "<< /Type /Pages /Kids [ {s}] /Count {d} >>", .{ page_refs.items, self.page_count });
            defer self.allocator.free(pages_str);
            try self.writeObject(pages_id, pages_str);
        }

        // Write Font objects
        for (0..self.font_count) |i| {
            var buf: [256]u8 = undefined;
            const len = std.fmt.bufPrint(&buf, "<< /Type /Font /Subtype /Type1 /BaseFont /{s} /Encoding /WinAnsiEncoding >>", .{self.font_ids[i].pdfName()}) catch continue;
            try self.writeObject(first_font_obj + @as(u32, @intCast(i)), len);
        }

        // Write Image objects
        for (0..self.image_count) |i| {
            const img = &self.images[i];
            try self.writeImageObject(first_image_obj + @as(u32, @intCast(i)), img);
        }

        // Calculate annotation object IDs (after pages)
        const first_annot_obj = first_page_obj + @as(u32, @intCast(self.page_count)) * 2;

        // Write Page and Content Stream objects
        for (0..self.page_count) |i| {
            const page_obj_id = first_page_obj + @as(u32, @intCast(i)) * 2;
            const content_obj_id = page_obj_id + 1;

            // Build resources dictionary
            var resources: std.ArrayListUnmanaged(u8) = .empty;
            defer resources.deinit(self.allocator);
            try resources.appendSlice(self.allocator, "<< /Font ");
            try resources.appendSlice(self.allocator, font_dict.items);
            if (self.image_count > 0) {
                try resources.appendSlice(self.allocator, " /XObject ");
                try resources.appendSlice(self.allocator, xobject_dict.items);
            }
            try resources.appendSlice(self.allocator, " >>");

            // Build annotations array for this page (all annotations go on page 0 for now)
            var annots_str: std.ArrayListUnmanaged(u8) = .empty;
            defer annots_str.deinit(self.allocator);
            if (i == 0 and self.annotation_count > 0) {
                try annots_str.appendSlice(self.allocator, " /Annots [ ");
                for (0..self.annotation_count) |a| {
                    var abuf: [32]u8 = undefined;
                    const alen = std.fmt.bufPrint(&abuf, "{d} 0 R ", .{first_annot_obj + @as(u32, @intCast(a))}) catch continue;
                    try annots_str.appendSlice(self.allocator, alen);
                }
                try annots_str.appendSlice(self.allocator, "]");
            }

            // Page object (with optional annotations)
            var page_buf: [768]u8 = undefined;
            const page_len = std.fmt.bufPrint(&page_buf, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {d:.3} {d:.3}] /Contents {d} 0 R /Resources {s}{s} >>", .{
                self.page_size.width,
                self.page_size.height,
                content_obj_id,
                resources.items,
                annots_str.items,
            }) catch continue;
            try self.writeObject(page_obj_id, page_len);

            // Content stream object
            const content_data = self.objects.items[self.page_content_ids[i]];
            try self.writeStreamObject(content_obj_id, content_data);
        }

        // Write annotation objects (clickable hyperlinks)
        for (0..self.annotation_count) |i| {
            const annot = &self.annotations[i];
            try self.writeAnnotationObject(first_annot_obj + @as(u32, @intCast(i)), annot);
        }

        // Update next_object_id
        self.next_object_id = first_annot_obj + self.annotation_count;

        // Write /Info dictionary (PDF metadata)
        var info_obj_id: u32 = 0;
        if (self.info) |pdfinfo| {
            info_obj_id = self.next_object_id;
            self.next_object_id += 1;

            var info_buf: std.ArrayListUnmanaged(u8) = .empty;
            defer info_buf.deinit(self.allocator);
            try info_buf.appendSlice(self.allocator, "<< ");

            if (pdfinfo.title) |v| {
                try info_buf.appendSlice(self.allocator, "/Title (");
                try appendPdfString(&info_buf, self.allocator, v);
                try info_buf.appendSlice(self.allocator, ") ");
            }
            if (pdfinfo.author) |v| {
                try info_buf.appendSlice(self.allocator, "/Author (");
                try appendPdfString(&info_buf, self.allocator, v);
                try info_buf.appendSlice(self.allocator, ") ");
            }
            if (pdfinfo.subject) |v| {
                try info_buf.appendSlice(self.allocator, "/Subject (");
                try appendPdfString(&info_buf, self.allocator, v);
                try info_buf.appendSlice(self.allocator, ") ");
            }
            if (pdfinfo.keywords) |v| {
                try info_buf.appendSlice(self.allocator, "/Keywords (");
                try appendPdfString(&info_buf, self.allocator, v);
                try info_buf.appendSlice(self.allocator, ") ");
            }
            if (pdfinfo.creator) |v| {
                try info_buf.appendSlice(self.allocator, "/Creator (");
                try appendPdfString(&info_buf, self.allocator, v);
                try info_buf.appendSlice(self.allocator, ") ");
            }
            if (pdfinfo.producer) |v| {
                try info_buf.appendSlice(self.allocator, "/Producer (");
                try appendPdfString(&info_buf, self.allocator, v);
                try info_buf.appendSlice(self.allocator, ") ");
            }
            if (pdfinfo.creation_date) |v| {
                try info_buf.appendSlice(self.allocator, "/CreationDate (");
                try appendPdfString(&info_buf, self.allocator, v);
                try info_buf.appendSlice(self.allocator, ") ");
            }
            // Custom keys (non-standard but extractable)
            for (0..pdfinfo.custom_count) |ci| {
                try info_buf.appendSlice(self.allocator, "/");
                try info_buf.appendSlice(self.allocator, pdfinfo.custom_keys[ci].key);
                try info_buf.appendSlice(self.allocator, " (");
                try appendPdfString(&info_buf, self.allocator, pdfinfo.custom_keys[ci].value);
                try info_buf.appendSlice(self.allocator, ") ");
            }
            try info_buf.appendSlice(self.allocator, ">>");
            try self.writeObject(info_obj_id, info_buf.items);
        }

        // Cross-reference table
        const xref_offset = self.output.items.len;
        try self.output.appendSlice(self.allocator, "xref\n");
        {
            var buf: [64]u8 = undefined;
            const len = std.fmt.bufPrint(&buf, "0 {d}\n", .{self.next_object_id}) catch return error.BufferTooSmall;
            try self.output.appendSlice(self.allocator, len);
        }
        try self.output.appendSlice(self.allocator, "0000000000 65535 f \n");

        for (1..self.next_object_id) |i| {
            var buf: [32]u8 = undefined;
            const len = std.fmt.bufPrint(&buf, "{d:0>10} 00000 n \n", .{self.object_offsets[i]}) catch continue;
            try self.output.appendSlice(self.allocator, len);
        }

        // Trailer
        try self.output.appendSlice(self.allocator, "trailer\n");
        if (info_obj_id > 0) {
            var buf: [192]u8 = undefined;
            const len = std.fmt.bufPrint(&buf, "<< /Size {d} /Root 1 0 R /Info {d} 0 R >>\n", .{ self.next_object_id, info_obj_id }) catch return error.BufferTooSmall;
            try self.output.appendSlice(self.allocator, len);
        } else {
            var buf: [128]u8 = undefined;
            const len = std.fmt.bufPrint(&buf, "<< /Size {d} /Root 1 0 R >>\n", .{self.next_object_id}) catch return error.BufferTooSmall;
            try self.output.appendSlice(self.allocator, len);
        }
        try self.output.appendSlice(self.allocator, "startxref\n");
        {
            var buf: [32]u8 = undefined;
            const len = std.fmt.bufPrint(&buf, "{d}\n", .{xref_offset}) catch return error.BufferTooSmall;
            try self.output.appendSlice(self.allocator, len);
        }
        try self.output.appendSlice(self.allocator, "%%EOF\n");

        return self.output.items;
    }

    fn writeObject(self: *PdfDocument, obj_id: u32, content: []const u8) !void {
        self.object_offsets[obj_id] = @intCast(self.output.items.len);

        var buf: [32]u8 = undefined;
        const header = std.fmt.bufPrint(&buf, "{d} 0 obj\n", .{obj_id}) catch return error.BufferTooSmall;
        try self.output.appendSlice(self.allocator, header);
        try self.output.appendSlice(self.allocator, content);
        try self.output.appendSlice(self.allocator, "\nendobj\n");
    }

    fn writeStreamObject(self: *PdfDocument, obj_id: u32, content: []const u8) !void {
        self.object_offsets[obj_id] = @intCast(self.output.items.len);

        var header_buf: [32]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf, "{d} 0 obj\n", .{obj_id}) catch return error.BufferTooSmall;
        try self.output.appendSlice(self.allocator, header);

        // Compress content stream with FlateDecode (zlib)
        const compressed = deflateCompress(self.allocator, content) catch null;
        const stream_data = if (compressed) |c| c else content;
        const is_compressed = compressed != null;
        defer if (compressed) |c| self.allocator.free(c);

        if (is_compressed) {
            const dict = std.fmt.allocPrint(self.allocator, "<< /Length {d} /Filter /FlateDecode >>\n", .{stream_data.len}) catch return error.BufferTooSmall;
            defer self.allocator.free(dict);
            try self.output.appendSlice(self.allocator, dict);
        } else {
            const dict = std.fmt.allocPrint(self.allocator, "<< /Length {d} >>\n", .{stream_data.len}) catch return error.BufferTooSmall;
            defer self.allocator.free(dict);
            try self.output.appendSlice(self.allocator, dict);
        }

        try self.output.appendSlice(self.allocator, "stream\n");
        try self.output.appendSlice(self.allocator, stream_data);
        try self.output.appendSlice(self.allocator, "\nendstream\nendobj\n");
    }

    fn writeImageObject(self: *PdfDocument, obj_id: u32, image: *const Image) !void {
        self.object_offsets[obj_id] = @intCast(self.output.items.len);

        var header_buf: [32]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf, "{d} 0 obj\n", .{obj_id}) catch return error.BufferTooSmall;
        try self.output.appendSlice(self.allocator, header);

        // Image dictionary
        const color_space: []const u8 = switch (image.format) {
            .jpeg, .png_rgb, .raw_rgb => "/DeviceRGB",
            .png_rgba, .raw_rgba => "/DeviceRGB", // Alpha handled separately
        };

        const filter: []const u8 = switch (image.format) {
            .jpeg => "/DCTDecode",
            else => "", // Raw data, no filter
        };

        // For non-JPEG images, compress raw pixel data with FlateDecode.
        // JPEG data is already compressed (DCTDecode) — write as-is.
        const compressed_img = if (filter.len == 0)
            deflateCompress(self.allocator, image.data) catch null
        else
            null;
        const stream_data = if (compressed_img) |c| c else image.data;
        defer if (compressed_img) |c| self.allocator.free(c);

        const actual_filter: []const u8 = if (filter.len > 0) filter else if (compressed_img != null) "/FlateDecode" else "";

        if (actual_filter.len > 0) {
            const dict = try std.fmt.allocPrint(self.allocator,
                "<< /Type /XObject /Subtype /Image /Width {d} /Height {d} /ColorSpace {s} /BitsPerComponent 8 /Filter {s} /Length {d} >>",
                .{ image.width, image.height, color_space, actual_filter, stream_data.len },
            );
            defer self.allocator.free(dict);
            try self.output.appendSlice(self.allocator, dict);
        } else {
            const dict = try std.fmt.allocPrint(self.allocator,
                "<< /Type /XObject /Subtype /Image /Width {d} /Height {d} /ColorSpace {s} /BitsPerComponent 8 /Length {d} >>",
                .{ image.width, image.height, color_space, stream_data.len },
            );
            defer self.allocator.free(dict);
            try self.output.appendSlice(self.allocator, dict);
        }

        try self.output.appendSlice(self.allocator, "\nstream\n");
        try self.output.appendSlice(self.allocator, stream_data);
        try self.output.appendSlice(self.allocator, "\nendstream\nendobj\n");
    }

    fn writeAnnotationObject(self: *PdfDocument, obj_id: u32, annot: *const LinkAnnotation) !void {
        self.object_offsets[obj_id] = @intCast(self.output.items.len);

        var header_buf: [32]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf, "{d} 0 obj\n", .{obj_id}) catch return error.BufferTooSmall;
        try self.output.appendSlice(self.allocator, header);

        // Link annotation dictionary
        // /Type /Annot - annotation object
        // /Subtype /Link - clickable hyperlink
        // /Rect [x1 y1 x2 y2] - clickable region
        // /Border [0 0 0] - no visible border
        // /A << /Type /Action /S /URI /URI (url) >> - action to open URL
        var dict_buf: [512]u8 = undefined;
        const dict = std.fmt.bufPrint(&dict_buf, "<< /Type /Annot /Subtype /Link /Rect [{d:.2} {d:.2} {d:.2} {d:.2}] /Border [0 0 0] /A << /Type /Action /S /URI /URI ({s}) >> >>", .{
            annot.x1,
            annot.y1,
            annot.x2,
            annot.y2,
            annot.url,
        }) catch return error.BufferTooSmall;
        try self.output.appendSlice(self.allocator, dict);
        try self.output.appendSlice(self.allocator, "\nendobj\n");
    }
};

// =============================================================================
// PDF String Escaping Helper
// =============================================================================

/// Escape parentheses and backslashes for PDF string literals
fn appendPdfString(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '(' => try buf.appendSlice(allocator, "\\("),
            ')' => try buf.appendSlice(allocator, "\\)"),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            else => try buf.append(allocator, c),
        }
    }
}

// =============================================================================
// Tests
// =============================================================================

// =============================================================================
// FlateDecode (zlib) Compression
// =============================================================================

/// Compress data using deflate with a zlib wrapper. PDF's /FlateDecode filter
/// expects zlib-format data (2-byte header + deflate + adler32 checksum).
/// Returns owned compressed bytes, or error if compression fails.
fn deflateCompress(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    if (data.len == 0) return error.EmptyInput;

    // Allocate output buffer — compressed size can't exceed input + zlib overhead
    const max_out = data.len + 256;
    var out_slice = try allocator.alloc(u8, max_out);
    errdefer allocator.free(out_slice);

    var fixed_writer: std.Io.Writer = .fixed(out_slice);

    var window_buf: [std.compress.flate.max_window_len]u8 = undefined;

    var compressor = std.compress.flate.Compress.init(
        &fixed_writer,
        &window_buf,
        .zlib,
        .level_6,
    ) catch {
        allocator.free(out_slice);
        return error.CompressFailed;
    };

    compressor.writer.writeAll(data) catch {
        allocator.free(out_slice);
        return error.CompressFailed;
    };
    compressor.finish() catch {
        allocator.free(out_slice);
        return error.CompressFailed;
    };

    const written_len = fixed_writer.end;
    if (written_len == 0 or written_len >= data.len) {
        allocator.free(out_slice);
        return error.NoSizeReduction;
    }

    // Shrink to actual compressed size
    const result = try allocator.dupe(u8, out_slice[0..written_len]);
    allocator.free(out_slice);
    return result;
}

test "create simple PDF" {
    const allocator = std.testing.allocator;

    var doc = PdfDocument.init(allocator);
    defer doc.deinit();

    _ = doc.addFont(.helvetica);
    _ = doc.addFont(.helvetica_bold);

    var content = ContentStream.init(allocator);
    defer content.deinit();

    try content.drawText("Hello, PDF!", 72, 750, "F0", 24, Color.black);
    try content.drawText("Generated with Zig", 72, 720, "F1", 14, Color.blue);
    try content.drawRect(72, 680, 200, 30, Color.fromHex("#f0f0f0"), Color.black);
    try content.drawLine(72, 650, 272, 650, Color.red, 1);

    try doc.addPage(&content);

    const pdf_bytes = try doc.build();
    try std.testing.expect(pdf_bytes.len > 100);
    try std.testing.expect(std.mem.startsWith(u8, pdf_bytes, "%PDF-1.4"));
}

test "color from hex" {
    const color = Color.fromHex("#b39a7d");
    try std.testing.expectApproxEqAbs(@as(f32, 0.702), color.r, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0.604), color.g, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0.490), color.b, 0.01);
}
