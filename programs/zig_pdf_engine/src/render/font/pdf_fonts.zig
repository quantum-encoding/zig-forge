// PDF Font Manager
//
// Manages PDF fonts for text rendering, including:
// - Standard 14 PDF fonts (built-in metrics)
// - Embedded TrueType/OpenType fonts
// - CID/Type0 fonts with ToUnicode mappings
//
// Provides glyph outlines and metrics for the text renderer.

const std = @import("std");
const truetype = @import("truetype.zig");
const glyph_mod = @import("glyph.zig");
const bitmap_mod = @import("../bitmap.zig");

const Font = truetype.Font;
const GlyphRasterizer = glyph_mod.GlyphRasterizer;
const GlyphCache = glyph_mod.GlyphCache;
const RenderedGlyph = glyph_mod.RenderedGlyph;
const TextRenderer = glyph_mod.TextRenderer;
const Bitmap = bitmap_mod.Bitmap;
const Color = bitmap_mod.Color;

/// PDF font types
pub const FontType = enum {
    Type1, // PostScript Type 1 font
    TrueType, // TrueType font
    Type0, // CID-keyed font (composite)
    Type3, // User-defined font (not supported)
    MMType1, // Multiple master Type 1
    CIDFontType0, // CID font with Type 1 outlines
    CIDFontType2, // CID font with TrueType outlines
};

/// Standard 14 PDF fonts (guaranteed to be available)
pub const StandardFont = enum {
    Courier,
    CourierBold,
    CourierOblique,
    CourierBoldOblique,
    Helvetica,
    HelveticaBold,
    HelveticaOblique,
    HelveticaBoldOblique,
    TimesRoman,
    TimesBold,
    TimesItalic,
    TimesBoldItalic,
    Symbol,
    ZapfDingbats,

    pub fn fromName(name: []const u8) ?StandardFont {
        const mappings = [_]struct { name: []const u8, font: StandardFont }{
            .{ .name = "Courier", .font = .Courier },
            .{ .name = "Courier-Bold", .font = .CourierBold },
            .{ .name = "Courier-Oblique", .font = .CourierOblique },
            .{ .name = "Courier-BoldOblique", .font = .CourierBoldOblique },
            .{ .name = "Helvetica", .font = .Helvetica },
            .{ .name = "Helvetica-Bold", .font = .HelveticaBold },
            .{ .name = "Helvetica-Oblique", .font = .HelveticaOblique },
            .{ .name = "Helvetica-BoldOblique", .font = .HelveticaBoldOblique },
            .{ .name = "Times-Roman", .font = .TimesRoman },
            .{ .name = "Times-Bold", .font = .TimesBold },
            .{ .name = "Times-Italic", .font = .TimesItalic },
            .{ .name = "Times-BoldItalic", .font = .TimesBoldItalic },
            .{ .name = "Symbol", .font = .Symbol },
            .{ .name = "ZapfDingbats", .font = .ZapfDingbats },
            // Common aliases
            .{ .name = "ArialMT", .font = .Helvetica },
            .{ .name = "Arial", .font = .Helvetica },
            .{ .name = "Arial-BoldMT", .font = .HelveticaBold },
            .{ .name = "Arial-ItalicMT", .font = .HelveticaOblique },
            .{ .name = "TimesNewRomanPSMT", .font = .TimesRoman },
            .{ .name = "TimesNewRomanPS-BoldMT", .font = .TimesBold },
        };

        for (mappings) |m| {
            if (std.mem.eql(u8, name, m.name)) {
                return m.font;
            }
        }
        return null;
    }

    /// Get default character width (in 1/1000 em units)
    pub fn getDefaultWidth(self: StandardFont) u16 {
        return switch (self) {
            .Courier, .CourierBold, .CourierOblique, .CourierBoldOblique => 600,
            else => 500,
        };
    }

    /// Check if font is monospace
    pub fn isMonospace(self: StandardFont) bool {
        return switch (self) {
            .Courier, .CourierBold, .CourierOblique, .CourierBoldOblique => true,
            else => false,
        };
    }
};

/// Character width data for standard fonts (in 1/1000 em units)
pub const CharWidths = struct {
    widths: [256]u16,
    default_width: u16,

    pub fn getWidth(self: CharWidths, char_code: u8) u16 {
        const w = self.widths[char_code];
        return if (w == 0) self.default_width else w;
    }
};

/// PDF Font instance
pub const PdfFont = struct {
    allocator: std.mem.Allocator,

    // Font identification
    name: []const u8, // Resource name (e.g., "F1")
    base_font: ?[]const u8, // Base font name (e.g., "Helvetica")
    font_type: FontType,
    standard_font: ?StandardFont,

    // Metrics
    first_char: u16,
    last_char: u16,
    widths: ?[]const u16, // Width per character (first_char..last_char)
    default_width: u16, // For missing widths
    ascent: i16,
    descent: i16,
    units_per_em: u16,

    // Embedded font data
    truetype_font: ?Font,
    font_data_owned: bool,

    // ToUnicode CMap (for CID fonts)
    to_unicode: ?[]const u8,

    // Glyph rendering
    glyph_cache: ?GlyphCache,
    rasterizer: ?GlyphRasterizer,

    pub fn init(allocator: std.mem.Allocator, name: []const u8) PdfFont {
        return .{
            .allocator = allocator,
            .name = name,
            .base_font = null,
            .font_type = .TrueType,
            .standard_font = null,
            .first_char = 0,
            .last_char = 255,
            .widths = null,
            .default_width = 1000,
            .ascent = 800,
            .descent = -200,
            .units_per_em = 1000,
            .truetype_font = null,
            .font_data_owned = false,
            .to_unicode = null,
            .glyph_cache = null,
            .rasterizer = null,
        };
    }

    pub fn deinit(self: *PdfFont) void {
        if (self.glyph_cache) |*cache| {
            cache.deinit();
        }
        if (self.rasterizer) |*rast| {
            rast.deinit();
        }
        if (self.truetype_font) |*font| {
            font.deinit();
        }
    }

    /// Load from embedded TrueType data
    pub fn loadTrueType(self: *PdfFont, data: []const u8) !void {
        self.truetype_font = try Font.init(self.allocator, data);
        self.font_data_owned = false;

        // Get metrics from font
        if (self.truetype_font) |*font| {
            self.units_per_em = font.getUnitsPerEm();
            self.ascent = font.getAscender();
            self.descent = font.getDescender();
        }
    }

    /// Set as a standard font
    pub fn setStandardFont(self: *PdfFont, std_font: StandardFont) void {
        self.standard_font = std_font;
        self.default_width = std_font.getDefaultWidth();

        // Set typical metrics for standard fonts
        self.units_per_em = 1000;
        self.ascent = 800;
        self.descent = -200;
    }

    /// Get character width in font units (typically 1/1000 em)
    pub fn getCharWidth(self: *PdfFont, char_code: u32) u16 {
        // Check explicit widths array first
        if (self.widths) |widths| {
            if (char_code >= self.first_char and char_code <= self.last_char) {
                const idx = char_code - self.first_char;
                if (idx < widths.len) {
                    const w = widths[idx];
                    if (w > 0) return w;
                }
            }
        }

        // Try TrueType font metrics
        if (self.truetype_font) |*font| {
            const glyph_idx = font.getGlyphIndex(char_code) catch 0;
            const metrics = font.getHMetrics(glyph_idx);
            return metrics.advance_width;
        }

        // Standard font default
        if (self.standard_font) |std_font| {
            return std_font.getDefaultWidth();
        }

        return self.default_width;
    }

    /// Render a glyph at the given size
    pub fn renderGlyph(self: *PdfFont, glyph_index: u16, size_px: f32) !?RenderedGlyph {
        // Initialize rasterizer if needed
        if (self.rasterizer == null) {
            self.rasterizer = GlyphRasterizer.init(self.allocator);
        }

        if (self.truetype_font) |*font| {
            return try self.rasterizer.?.renderGlyph(font, glyph_index, size_px);
        }

        return null;
    }

    /// Get glyph index for a character code (using ToUnicode or direct mapping)
    pub fn getGlyphIndex(self: *PdfFont, char_code: u32) u16 {
        if (self.truetype_font) |*font| {
            return font.getGlyphIndex(char_code) catch 0;
        }
        return @intCast(char_code & 0xFFFF);
    }
};

/// System font paths for standard PDF fonts
const SystemFontPaths = struct {
    // Sans-serif (Helvetica, Arial)
    pub const sans_regular = "/usr/share/fonts/noto/NotoSans-Regular.ttf";
    pub const sans_bold = "/usr/share/fonts/noto/NotoSans-Bold.ttf";
    pub const sans_italic = "/usr/share/fonts/noto/NotoSans-Italic.ttf";
    pub const sans_bold_italic = "/usr/share/fonts/noto/NotoSans-BoldItalic.ttf";

    // Serif (Times)
    pub const serif_regular = "/usr/share/fonts/noto/NotoSerif-Regular.ttf";
    pub const serif_bold = "/usr/share/fonts/noto/NotoSerif-Bold.ttf";
    pub const serif_italic = "/usr/share/fonts/noto/NotoSerif-Italic.ttf";
    pub const serif_bold_italic = "/usr/share/fonts/noto/NotoSerif-BoldItalic.ttf";

    // Monospace (Courier)
    pub const mono_regular = "/usr/share/fonts/noto/NotoSansMono-Regular.ttf";
    pub const mono_bold = "/usr/share/fonts/noto/NotoSansMono-Bold.ttf";

    pub fn forStandardFont(std_font: StandardFont) ?[]const u8 {
        return switch (std_font) {
            .Helvetica => sans_regular,
            .HelveticaBold => sans_bold,
            .HelveticaOblique => sans_italic,
            .HelveticaBoldOblique => sans_bold_italic,
            .TimesRoman => serif_regular,
            .TimesBold => serif_bold,
            .TimesItalic => serif_italic,
            .TimesBoldItalic => serif_bold_italic,
            .Courier => mono_regular,
            .CourierBold => mono_bold,
            .CourierOblique => mono_regular, // No oblique variant
            .CourierBoldOblique => mono_bold,
            .Symbol, .ZapfDingbats => null, // No system equivalent
        };
    }
};

/// Font manager for PDF rendering
pub const FontManager = struct {
    allocator: std.mem.Allocator,
    fonts: std.StringHashMap(PdfFont),
    default_font: ?*PdfFont,

    // System font cache (keyed by path)
    system_fonts: std.StringHashMap(SystemFontEntry),

    const SystemFontEntry = struct {
        data: []const u8,
        font: Font,
    };

    pub fn init(allocator: std.mem.Allocator) FontManager {
        return .{
            .allocator = allocator,
            .fonts = std.StringHashMap(PdfFont).init(allocator),
            .default_font = null,
            .system_fonts = std.StringHashMap(SystemFontEntry).init(allocator),
        };
    }

    pub fn deinit(self: *FontManager) void {
        var iter = self.fonts.valueIterator();
        while (iter.next()) |font| {
            var f = font.*;
            f.deinit();
        }
        self.fonts.deinit();

        // Free system fonts
        var sys_iter = self.system_fonts.valueIterator();
        while (sys_iter.next()) |entry| {
            var e = entry.*;
            e.font.deinit();
            self.allocator.free(e.data);
        }
        self.system_fonts.deinit();
    }

    /// Load a system font from disk, caching it for reuse
    fn loadSystemFontCached(self: *FontManager, path: []const u8) ?*Font {
        // Check cache first
        if (self.system_fonts.getPtr(path)) |entry| {
            return &entry.font;
        }

        // Load from disk using Zig 0.16 I/O API
        const io = std.Io.Threaded.global_single_threaded.io();
        const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
        defer file.close(io);

        const stat = file.stat(io) catch return null;

        const data = self.allocator.alloc(u8, stat.size) catch return null;
        errdefer self.allocator.free(data);

        _ = file.readPositionalAll(io, data, 0) catch {
            self.allocator.free(data);
            return null;
        };

        const font = Font.init(self.allocator, data) catch {
            self.allocator.free(data);
            return null;
        };

        self.system_fonts.put(path, .{ .data = data, .font = font }) catch {
            var f = font;
            f.deinit();
            self.allocator.free(data);
            return null;
        };

        return &self.system_fonts.getPtr(path).?.font;
    }

    /// Register a font from PDF font dictionary
    pub fn registerFont(
        self: *FontManager,
        name: []const u8,
        base_font: ?[]const u8,
        font_type: FontType,
        embedded_data: ?[]const u8,
    ) !*PdfFont {
        var font = PdfFont.init(self.allocator, name);
        font.base_font = base_font;
        font.font_type = font_type;

        var std_font_type: ?StandardFont = null;

        // Check if it's a standard font
        if (base_font) |bf| {
            if (StandardFont.fromName(bf)) |std_font| {
                font.setStandardFont(std_font);
                std_font_type = std_font;
            }
        }

        // Load embedded font data
        var loaded_embedded = false;
        if (embedded_data) |data| {
            font.loadTrueType(data) catch {
                // Failed to parse - will try system font
            };
            if (font.truetype_font != null) {
                loaded_embedded = true;
            }
        }

        // If no embedded font, try to load a system font for metrics
        // Note: System fonts provide accurate character widths for proper text spacing
        const use_system_fonts = true;
        if (!loaded_embedded and use_system_fonts) {
            const font_path = if (std_font_type) |sf|
                SystemFontPaths.forStandardFont(sf)
            else
                SystemFontPaths.sans_regular;

            if (font_path) |path| {
                if (self.loadSystemFontCached(path)) |sys_font| {
                    // Copy font data reference (not the font struct itself)
                    font.truetype_font = sys_font.*;
                    font.units_per_em = sys_font.getUnitsPerEm();
                    font.ascent = sys_font.getAscender();
                    font.descent = sys_font.getDescender();
                }
            }
        }

        try self.fonts.put(name, font);
        return self.fonts.getPtr(name).?;
    }

    /// Get font by name
    pub fn getFont(self: *FontManager, name: []const u8) ?*PdfFont {
        return self.fonts.getPtr(name);
    }

    /// Get or create a default font for fallback
    pub fn getDefaultFont(self: *FontManager) ?*PdfFont {
        if (self.default_font) |font| return font;

        // Create a Helvetica fallback with system font
        self.default_font = self.registerFont("_default", "Helvetica", .Type1, null) catch null;
        return self.default_font;
    }

    /// Try to load a system font as fallback (legacy method)
    pub fn loadSystemFont(self: *FontManager, path: []const u8) !void {
        _ = self.loadSystemFontCached(path) orelse return error.FileNotFound;
    }
};

/// Text renderer for PDF content
pub const PdfTextRenderer = struct {
    allocator: std.mem.Allocator,
    glyph_rasterizer: GlyphRasterizer,

    pub fn init(allocator: std.mem.Allocator) PdfTextRenderer {
        return .{
            .allocator = allocator,
            .glyph_rasterizer = GlyphRasterizer.init(allocator),
        };
    }

    pub fn deinit(self: *PdfTextRenderer) void {
        self.glyph_rasterizer.deinit();
    }

    /// Render text string to target bitmap
    /// text: Raw text data (may be hex-encoded for CID fonts)
    /// font_name: Font resource name (e.g., "F1")
    /// size: Font size in points
    /// x, y: Position in device coordinates (y is baseline)
    /// color: Text color
    pub fn renderText(
        _: *PdfTextRenderer,
        font_manager: *FontManager,
        target: *Bitmap,
        text: []const u8,
        font_name: []const u8,
        size_px: f32,
        x: i32,
        y: i32,
        color: Color,
    ) !void {
        const font = font_manager.getFont(font_name) orelse
            font_manager.getDefaultFont() orelse return;

        var cursor_x: f32 = @floatFromInt(x);

        // Decode text and render each character
        var i: usize = 0;
        while (i < text.len) {
            const char_result = decodeNextChar(text[i..], font);
            const char_code = char_result.code;
            const char_len = char_result.len;

            if (char_len == 0) break;
            i += char_len;

            // Get glyph and render
            const glyph_idx = font.getGlyphIndex(char_code);
            const char_width = font.getCharWidth(char_code);

            // Calculate width in pixels
            const width_px = @as(f32, @floatFromInt(char_width)) * size_px / @as(f32, @floatFromInt(font.units_per_em));

            // Render character
            // Note: Using fast glyph rendering (reduced AA and flatness)
            const render_actual_glyphs = true;

            if (render_actual_glyphs and font.truetype_font != null) {
                if (font.renderGlyph(glyph_idx, size_px)) |rendered_opt| {
                    if (rendered_opt) |rendered| {
                        var glyph = rendered;
                        defer glyph.deinit();

                        // Blit glyph to target
                        const gx = @as(i32, @intFromFloat(cursor_x)) + glyph.metrics.bearing_x;
                        const gy = y - glyph.metrics.bearing_y;
                        blitGlyph(target, &glyph.bitmap, gx, gy, color);
                    }
                } else |_| {}
            } else {
                // Render as rectangle with proper metrics
                renderCharRect(target, @as(i32, @intFromFloat(cursor_x)), y, width_px, size_px, color);
            }

            cursor_x += width_px;
        }
    }

    /// Decode next character from text data
    fn decodeNextChar(text: []const u8, font: *const PdfFont) struct { code: u32, len: usize } {
        if (text.len == 0) return .{ .code = 0, .len = 0 };

        // For CID fonts, characters may be 2-byte encoded
        if (font.font_type == .Type0 or font.font_type == .CIDFontType2) {
            if (text.len >= 2) {
                const code: u32 = (@as(u32, text[0]) << 8) | @as(u32, text[1]);
                return .{ .code = code, .len = 2 };
            }
        }

        // Single byte encoding
        return .{ .code = text[0], .len = 1 };
    }

    /// Blit a rendered glyph to target with color tinting
    fn blitGlyph(target: *Bitmap, glyph: *const Bitmap, x: i32, y: i32, color: Color) void {
        var row: u32 = 0;
        while (row < glyph.height) : (row += 1) {
            const dy = y + @as(i32, @intCast(row));
            if (dy < 0 or dy >= @as(i32, @intCast(target.height))) continue;

            var col: u32 = 0;
            while (col < glyph.width) : (col += 1) {
                const dx = x + @as(i32, @intCast(col));
                if (dx < 0 or dx >= @as(i32, @intCast(target.width))) continue;

                const src_pixel = glyph.getPixelUnchecked(col, row);
                if (src_pixel.a > 0) {
                    // Use glyph alpha as coverage
                    const tinted = Color.rgba(
                        color.r,
                        color.g,
                        color.b,
                        @intCast((@as(u16, src_pixel.a) * @as(u16, color.a)) / 255),
                    );
                    target.blendPixel(dx, dy, tinted);
                }
            }
        }
    }

    /// Fallback: render character as simple rectangle
    fn renderCharRect(target: *Bitmap, x: i32, y: i32, width: f32, height: f32, color: Color) void {
        const char_height = height * 0.7; // Approximate x-height
        const x_end = @as(i32, @intFromFloat(@as(f32, @floatFromInt(x)) + width));
        const y_start = @as(i32, @intFromFloat(@as(f32, @floatFromInt(y)) - char_height));

        var py = y_start;
        while (py < y) : (py += 1) {
            if (py >= 0 and py < @as(i32, @intCast(target.height))) {
                target.fillSpan(py, x, x_end - 1, color);
            }
        }
    }
};

// =============================================================================
// Standard Font Metrics
// =============================================================================

/// Helvetica character widths (most common standard font)
pub const helvetica_widths = [256]u16{
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0, // 0-15
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0, // 16-31
    278, 278, 355, 556, 556, 889, 667, 222, 333, 333, 389, 584, 278, 333, 278, 278, // 32-47 (space-/)
    556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 278, 278, 584, 584, 584, 556, // 48-63 (0-?)
    1015, 667, 667, 722, 722, 667, 611, 778, 722, 278, 500, 667, 556, 833, 722, 778, // 64-79 (@-O)
    667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 278, 278, 278, 469, 556, // 80-95 (P-_)
    222, 556, 556, 500, 556, 556, 278, 556, 556, 222, 222, 500, 222, 833, 556, 556, // 96-111 (`-o)
    556, 556, 333, 500, 278, 556, 500, 722, 500, 500, 500, 334, 260, 334, 584, 0, // 112-127 (p-DEL)
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0, // 128-143
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0, // 144-159
    0,   333, 556, 556, 556, 556, 260, 556, 333, 737, 370, 556, 584, 333, 737, 333, // 160-175
    400, 584, 333, 333, 333, 556, 537, 278, 333, 333, 365, 556, 834, 834, 834, 611, // 176-191
    667, 667, 667, 667, 667, 667, 1000, 722, 667, 667, 667, 667, 278, 278, 278, 278, // 192-207
    722, 722, 778, 778, 778, 778, 778, 584, 778, 722, 722, 722, 722, 667, 667, 611, // 208-223
    556, 556, 556, 556, 556, 556, 889, 500, 556, 556, 556, 556, 278, 278, 278, 278, // 224-239
    556, 556, 556, 556, 556, 556, 556, 584, 611, 556, 556, 556, 556, 500, 556, 500, // 240-255
};

/// Times Roman character widths
pub const times_widths = [256]u16{
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0, // 0-15
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0, // 16-31
    250, 333, 408, 500, 500, 833, 778, 333, 333, 333, 500, 564, 250, 333, 250, 278, // 32-47
    500, 500, 500, 500, 500, 500, 500, 500, 500, 500, 278, 278, 564, 564, 564, 444, // 48-63
    921, 722, 667, 667, 722, 611, 556, 722, 722, 333, 389, 722, 611, 889, 722, 722, // 64-79
    556, 722, 667, 556, 611, 722, 722, 944, 722, 722, 611, 333, 278, 333, 469, 500, // 80-95
    333, 444, 500, 444, 500, 444, 333, 500, 500, 278, 278, 500, 278, 778, 500, 500, // 96-111
    500, 500, 333, 389, 278, 500, 500, 722, 500, 500, 444, 480, 200, 480, 541, 0, // 112-127
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0, // 128-143
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0, // 144-159
    0,   333, 500, 500, 500, 500, 200, 500, 333, 760, 276, 500, 564, 333, 760, 333, // 160-175
    400, 564, 300, 300, 333, 500, 453, 250, 333, 300, 310, 500, 750, 750, 750, 444, // 176-191
    722, 722, 722, 722, 722, 722, 889, 667, 611, 611, 611, 611, 333, 333, 333, 333, // 192-207
    722, 722, 722, 722, 722, 722, 722, 564, 722, 722, 722, 722, 722, 722, 556, 500, // 208-223
    444, 444, 444, 444, 444, 444, 667, 444, 444, 444, 444, 444, 278, 278, 278, 278, // 224-239
    500, 500, 500, 500, 500, 500, 500, 564, 500, 500, 500, 500, 500, 500, 500, 500, // 240-255
};

/// Courier character widths (monospace - all same width)
pub const courier_widths = [256]u16{
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
    600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600,
    600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600,
    600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600,
    600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600,
    600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600,
    600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 0,
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
    0,   600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600,
    600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600,
    600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600,
    600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600,
    600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600,
    600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600, 600,
};

// =============================================================================
// Tests
// =============================================================================

test "standard font lookup" {
    try std.testing.expectEqual(StandardFont.Helvetica, StandardFont.fromName("Helvetica").?);
    try std.testing.expectEqual(StandardFont.Helvetica, StandardFont.fromName("ArialMT").?);
    try std.testing.expectEqual(StandardFont.TimesRoman, StandardFont.fromName("Times-Roman").?);
    try std.testing.expect(StandardFont.fromName("NonExistent") == null);
}

test "helvetica widths" {
    // Space
    try std.testing.expectEqual(@as(u16, 278), helvetica_widths[' ']);
    // 'A'
    try std.testing.expectEqual(@as(u16, 667), helvetica_widths['A']);
    // 'a'
    try std.testing.expectEqual(@as(u16, 556), helvetica_widths['a']);
}

test "font manager init" {
    var manager = FontManager.init(std.testing.allocator);
    defer manager.deinit();

    _ = try manager.registerFont("F1", "Helvetica", .Type1, null);
    const font = manager.getFont("F1");
    try std.testing.expect(font != null);
    try std.testing.expect(font.?.standard_font == .Helvetica);
}
