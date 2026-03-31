// Glyph Rasterizer
//
// Converts TrueType glyph outlines to pixel bitmaps.
// Uses scanline anti-aliasing for smooth rendering.
//
// TrueType glyphs use quadratic bezier curves (unlike PDF's cubic beziers).
// The glyph coordinate system has Y increasing upward.

const std = @import("std");
const truetype = @import("truetype.zig");
const bitmap_mod = @import("../bitmap.zig");
const path_mod = @import("../path.zig");
const rasterizer_mod = @import("../rasterizer.zig");

const Font = truetype.Font;
const Glyph = truetype.Glyph;
const SimpleGlyph = truetype.SimpleGlyph;
const GlyphPoint = truetype.GlyphPoint;
const GlyphComponent = truetype.GlyphComponent;
const Bitmap = bitmap_mod.Bitmap;
const Color = bitmap_mod.Color;
const PathBuilder = path_mod.PathBuilder;
const Rasterizer = rasterizer_mod.Rasterizer;

/// Glyph metrics in pixels
pub const GlyphMetrics = struct {
    width: u32,
    height: u32,
    bearing_x: i32, // Offset from origin to left edge
    bearing_y: i32, // Offset from baseline to top edge
    advance: f32, // Advance to next glyph
};

/// Rendered glyph bitmap
pub const RenderedGlyph = struct {
    bitmap: Bitmap,
    metrics: GlyphMetrics,

    pub fn deinit(self: *RenderedGlyph) void {
        self.bitmap.deinit();
    }
};

/// Glyph rasterizer
pub const GlyphRasterizer = struct {
    allocator: std.mem.Allocator,
    path_builder: PathBuilder,
    rasterizer: Rasterizer,

    pub fn init(allocator: std.mem.Allocator) GlyphRasterizer {
        var rast = Rasterizer.init(allocator);
        // Use faster settings for glyph rendering
        rast.flatness = 1.5; // Higher flatness = fewer segments = faster
        rast.setAntiAliasing(1); // Disable AA for speed (1x sampling)

        return .{
            .allocator = allocator,
            .path_builder = PathBuilder.init(allocator),
            .rasterizer = rast,
        };
    }

    pub fn deinit(self: *GlyphRasterizer) void {
        self.path_builder.deinit();
        self.rasterizer.deinit();
    }

    /// Render a glyph at a given size
    pub fn renderGlyph(
        self: *GlyphRasterizer,
        font: *Font,
        glyph_index: u16,
        size_px: f32,
    ) !RenderedGlyph {
        // Get glyph data
        const glyph = try font.getGlyph(glyph_index);
        const hmetrics = font.getHMetrics(glyph_index);

        // Calculate scale
        const units_per_em = font.getUnitsPerEm();
        const scale = size_px / @as(f32, @floatFromInt(units_per_em));

        // Build path from glyph outline
        self.path_builder.clear();
        try self.glyphToPath(font, glyph, scale);

        // Get bounds
        const bounds = self.path_builder.getBounds();

        if (bounds.isEmpty()) {
            // Empty glyph (e.g., space)
            return .{
                .bitmap = try Bitmap.init(self.allocator, 1, 1),
                .metrics = .{
                    .width = 1,
                    .height = 1,
                    .bearing_x = 0,
                    .bearing_y = 0,
                    .advance = @as(f32, @floatFromInt(hmetrics.advance_width)) * scale,
                },
            };
        }

        // Add padding for anti-aliasing
        const padding: i32 = 2;
        const width: u32 = @intFromFloat(@ceil(bounds.width()) + @as(f32, @floatFromInt(padding * 2)));
        const height: u32 = @intFromFloat(@ceil(bounds.height()) + @as(f32, @floatFromInt(padding * 2)));

        // Create bitmap
        var bitmap = try Bitmap.init(self.allocator, @max(1, width), @max(1, height));
        errdefer bitmap.deinit();
        bitmap.clear(Color.transparent);

        // Translate path to bitmap coordinates
        const offset_x = -bounds.min_x + @as(f32, @floatFromInt(padding));
        const offset_y = -bounds.min_y + @as(f32, @floatFromInt(padding));

        const translate = path_mod.Point{ .x = offset_x, .y = offset_y };
        for (self.path_builder.segments.items) |*seg| {
            seg.p1.x += translate.x;
            seg.p1.y += translate.y;
            seg.p2.x += translate.x;
            seg.p2.y += translate.y;
            seg.p3.x += translate.x;
            seg.p3.y += translate.y;
        }

        // Rasterize
        const gs = @import("../graphics_state.zig");
        try self.rasterizer.fill(&bitmap, &self.path_builder, Color.white, .NonZero, gs.Matrix.identity);

        return .{
            .bitmap = bitmap,
            .metrics = .{
                .width = width,
                .height = height,
                .bearing_x = @as(i32, @intFromFloat(bounds.min_x)) - padding,
                .bearing_y = @as(i32, @intFromFloat(bounds.max_y)) + padding, // Top edge
                .advance = @as(f32, @floatFromInt(hmetrics.advance_width)) * scale,
            },
        };
    }

    /// Convert glyph outline to path
    fn glyphToPath(self: *GlyphRasterizer, font: *Font, glyph: Glyph, scale: f32) !void {
        switch (glyph) {
            .empty => {},
            .simple => |simple| {
                try self.simpleGlyphToPath(simple, scale);
            },
            .compound => |components| {
                for (components) |comp| {
                    const child_glyph = try font.getGlyph(comp.glyph_index);

                    // Apply component transformation matrix from TrueType composite glyph
                    // Component stores transformation: scale/rotation in a,b,c,d and translation in e,f
                    // If the component has a scale matrix (not just identity), apply it
                    const has_scale = comp.a != 1 or comp.b != 0 or comp.c != 0 or comp.d != 1;

                    const child_scale = if (has_scale)
                        // Component has explicit scale - use it
                        @sqrt(comp.a * comp.a + comp.b * comp.b) * scale
                    else
                        // No explicit scale - use base scale
                        scale;

                    const tx = comp.e * scale;
                    const ty = comp.f * scale;

                    switch (child_glyph) {
                        .simple => |simple| {
                            try self.simpleGlyphToPathTransformed(simple, child_scale, tx, ty);
                        },
                        else => {},
                    }
                }
            },
        }
    }

    /// Convert simple glyph to path
    fn simpleGlyphToPath(self: *GlyphRasterizer, glyph: SimpleGlyph, scale: f32) !void {
        try self.simpleGlyphToPathTransformed(glyph, scale, 0, 0);
    }

    /// Convert simple glyph to path with transformation
    fn simpleGlyphToPathTransformed(
        self: *GlyphRasterizer,
        glyph: SimpleGlyph,
        scale: f32,
        tx: f32,
        ty: f32,
    ) !void {
        if (glyph.points.len == 0) return;

        var contour_start: usize = 0;

        for (glyph.contour_end_points) |end_point| {
            const contour_end = @as(usize, end_point) + 1;
            if (contour_end > glyph.points.len) break;

            const points = glyph.points[contour_start..contour_end];
            try self.contourToPath(points, scale, tx, ty);

            contour_start = contour_end;
        }
    }

    /// Convert a contour to path segments
    fn contourToPath(
        self: *GlyphRasterizer,
        points: []const GlyphPoint,
        scale: f32,
        tx: f32,
        ty: f32,
    ) !void {
        if (points.len == 0) return;

        // Transform function
        const transformX = struct {
            fn f(x: i16, s: f32, t: f32) f32 {
                return @as(f32, @floatFromInt(x)) * s + t;
            }
        }.f;

        const transformY = struct {
            fn f(y: i16, s: f32, t: f32) f32 {
                // Flip Y coordinate (glyph Y up, screen Y down)
                return -@as(f32, @floatFromInt(y)) * s + t;
            }
        }.f;

        // TrueType contours use quadratic bezier curves
        // Off-curve points are control points
        // If two off-curve points are adjacent, there's an implicit on-curve point between them

        // Find first on-curve point or synthesize one
        var start_idx: usize = 0;
        var start_point: struct { x: f32, y: f32 } = undefined;

        for (points, 0..) |pt, i| {
            if (pt.on_curve) {
                start_idx = i;
                start_point = .{
                    .x = transformX(pt.x, scale, tx),
                    .y = transformY(pt.y, scale, ty),
                };
                break;
            }
        } else {
            // All off-curve - synthesize first point
            const p0 = points[0];
            const p1 = points[points.len - 1];
            start_point = .{
                .x = (transformX(p0.x, scale, tx) + transformX(p1.x, scale, tx)) / 2,
                .y = (transformY(p0.y, scale, ty) + transformY(p1.y, scale, ty)) / 2,
            };
        }

        try self.path_builder.moveTo(start_point.x, start_point.y);

        var i = (start_idx + 1) % points.len;
        var current_x = start_point.x;
        var current_y = start_point.y;

        while (true) {
            const pt = points[i];
            const px = transformX(pt.x, scale, tx);
            const py = transformY(pt.y, scale, ty);

            if (pt.on_curve) {
                // Line to on-curve point
                try self.path_builder.lineTo(px, py);
                current_x = px;
                current_y = py;
            } else {
                // Off-curve point - need to make a quadratic bezier
                // Look at next point
                const next_idx = (i + 1) % points.len;
                const next_pt = points[next_idx];
                const npx = transformX(next_pt.x, scale, tx);
                const npy = transformY(next_pt.y, scale, ty);

                var end_x: f32 = undefined;
                var end_y: f32 = undefined;

                if (next_pt.on_curve) {
                    // Quadratic to the on-curve point
                    end_x = npx;
                    end_y = npy;
                    i = next_idx;
                } else {
                    // Two consecutive off-curve points - implicit on-curve between
                    end_x = (px + npx) / 2;
                    end_y = (py + npy) / 2;
                }

                // Convert quadratic bezier to cubic bezier for our path builder
                // Q(t) = (1-t)²P0 + 2(1-t)tP1 + t²P2
                // C(t) = (1-t)³P0 + 3(1-t)²tC1 + 3(1-t)t²C2 + t³P3
                // C1 = P0 + 2/3(P1 - P0)
                // C2 = P2 + 2/3(P1 - P2)
                const c1x = current_x + 2.0 / 3.0 * (px - current_x);
                const c1y = current_y + 2.0 / 3.0 * (py - current_y);
                const c2x = end_x + 2.0 / 3.0 * (px - end_x);
                const c2y = end_y + 2.0 / 3.0 * (py - end_y);

                try self.path_builder.curveTo(c1x, c1y, c2x, c2y, end_x, end_y);

                current_x = end_x;
                current_y = end_y;

                if (next_pt.on_curve) {
                    // Already advanced i
                } else {
                    // Don't advance - we'll process this off-curve point next
                }
            }

            i = (i + 1) % points.len;
            if (i == (start_idx + 1) % points.len) break;
        }

        try self.path_builder.closePath();
    }
};

/// Glyph cache for efficient text rendering
pub const GlyphCache = struct {
    allocator: std.mem.Allocator,
    font: *Font,
    cache: std.AutoHashMap(CacheKey, RenderedGlyph),
    rasterizer: GlyphRasterizer,

    const CacheKey = struct {
        glyph_index: u16,
        size_x16: u16, // Size in 1/16 pixels for precision
    };

    pub fn init(allocator: std.mem.Allocator, font: *Font) GlyphCache {
        return .{
            .allocator = allocator,
            .font = font,
            .cache = std.AutoHashMap(CacheKey, RenderedGlyph).init(allocator),
            .rasterizer = GlyphRasterizer.init(allocator),
        };
    }

    pub fn deinit(self: *GlyphCache) void {
        var iter = self.cache.valueIterator();
        while (iter.next()) |glyph| {
            var g = glyph.*;
            g.deinit();
        }
        self.cache.deinit();
        self.rasterizer.deinit();
    }

    /// Get or render a glyph
    pub fn getGlyph(self: *GlyphCache, glyph_index: u16, size_px: f32) !*const RenderedGlyph {
        const key = CacheKey{
            .glyph_index = glyph_index,
            .size_x16 = @intFromFloat(size_px * 16),
        };

        if (self.cache.getPtr(key)) |cached| {
            return cached;
        }

        // Render and cache
        const rendered = try self.rasterizer.renderGlyph(self.font, glyph_index, size_px);
        try self.cache.put(key, rendered);
        return self.cache.getPtr(key).?;
    }

    /// Clear the cache
    pub fn clear(self: *GlyphCache) void {
        var iter = self.cache.valueIterator();
        while (iter.next()) |glyph| {
            var g = glyph.*;
            g.deinit();
        }
        self.cache.clearRetainingCapacity();
    }
};

/// Text renderer using glyph cache
pub const TextRenderer = struct {
    allocator: std.mem.Allocator,
    glyph_cache: ?GlyphCache,

    pub fn init(allocator: std.mem.Allocator) TextRenderer {
        return .{
            .allocator = allocator,
            .glyph_cache = null,
        };
    }

    pub fn deinit(self: *TextRenderer) void {
        if (self.glyph_cache) |*cache| {
            cache.deinit();
        }
    }

    /// Set the font to use
    pub fn setFont(self: *TextRenderer, font: *Font) void {
        if (self.glyph_cache) |*cache| {
            cache.deinit();
        }
        self.glyph_cache = GlyphCache.init(self.allocator, font);
    }

    /// Render text string to bitmap
    pub fn renderText(
        self: *TextRenderer,
        target: *Bitmap,
        text: []const u8,
        x: i32,
        y: i32, // Baseline position
        size_px: f32,
        color: Color,
    ) !void {
        var cache = &(self.glyph_cache orelse return);

        var cursor_x: f32 = @floatFromInt(x);

        for (text) |char| {
            const glyph_idx = try cache.font.getGlyphIndex(char);
            const glyph = try cache.getGlyph(glyph_idx, size_px);

            // Calculate position
            const gx: i32 = @as(i32, @intFromFloat(cursor_x)) + glyph.metrics.bearing_x;
            const gy: i32 = y - glyph.metrics.bearing_y;

            // Blit glyph with color
            self.blitGlyph(target, &glyph.bitmap, gx, gy, color);

            cursor_x += glyph.metrics.advance;
        }
    }

    /// Blit a glyph bitmap with color tinting
    fn blitGlyph(self: *const TextRenderer, target: *Bitmap, glyph: *const Bitmap, x: i32, y: i32, color: Color) void {
        _ = self;

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
                    // Use glyph alpha as coverage for the color
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

    /// Measure text width
    pub fn measureText(self: *TextRenderer, text: []const u8, size_px: f32) !f32 {
        var cache = &(self.glyph_cache orelse return 0);

        const scale = size_px / @as(f32, @floatFromInt(cache.font.getUnitsPerEm()));
        var width: f32 = 0;

        for (text) |char| {
            const glyph_idx = try cache.font.getGlyphIndex(char);
            const hmetrics = cache.font.getHMetrics(glyph_idx);
            width += @as(f32, @floatFromInt(hmetrics.advance_width)) * scale;
        }

        return width;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "glyph rasterizer init" {
    var rast = GlyphRasterizer.init(std.testing.allocator);
    defer rast.deinit();

    // Just test initialization
    try std.testing.expect(rast.path_builder.segments.items.len == 0);
}

test "text renderer init" {
    var renderer = TextRenderer.init(std.testing.allocator);
    defer renderer.deinit();

    // Just test initialization
    try std.testing.expect(renderer.glyph_cache == null);
}
