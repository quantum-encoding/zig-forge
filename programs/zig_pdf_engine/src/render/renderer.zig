// PDF Renderer - Main API
//
// High-level API for rendering PDF pages to bitmaps.
// Designed for FFI integration with Android/iOS/Desktop.

const std = @import("std");
const bitmap_mod = @import("bitmap.zig");
const gs_mod = @import("graphics_state.zig");
const path_mod = @import("path.zig");
const rasterizer_mod = @import("rasterizer.zig");
const interpreter_mod = @import("interpreter.zig");

pub const Bitmap = bitmap_mod.Bitmap;
pub const Color = bitmap_mod.Color;
pub const Matrix = gs_mod.Matrix;
pub const GraphicsState = gs_mod.GraphicsState;
pub const PathBuilder = path_mod.PathBuilder;
pub const Point = path_mod.Point;
pub const Rasterizer = rasterizer_mod.Rasterizer;
pub const FillRule = rasterizer_mod.FillRule;
pub const Interpreter = interpreter_mod.Interpreter;

/// Render quality settings
pub const RenderQuality = enum {
    Draft, // Fast, lower quality (no AA)
    Normal, // Good balance (4x AA)
    High, // Best quality (8x AA)

    pub fn getAALevel(self: RenderQuality) u8 {
        return switch (self) {
            .Draft => 1,
            .Normal => 4,
            .High => 8,
        };
    }
};

/// Page size information
pub const PageSize = struct {
    width: f32, // In points (1/72 inch)
    height: f32,

    /// Common page sizes
    pub const letter: PageSize = .{ .width = 612, .height = 792 };
    pub const a4: PageSize = .{ .width = 595, .height = 842 };
    pub const legal: PageSize = .{ .width = 612, .height = 1008 };

    /// Convert to pixels at given DPI
    pub fn toPixels(self: PageSize, dpi: f32) struct { width: u32, height: u32 } {
        return .{
            .width = @intFromFloat(@ceil(self.width * dpi / 72.0)),
            .height = @intFromFloat(@ceil(self.height * dpi / 72.0)),
        };
    }
};

/// Render result
pub const RenderResult = struct {
    bitmap: Bitmap,
    width: u32,
    height: u32,

    pub fn deinit(self: *RenderResult) void {
        self.bitmap.deinit();
    }

    /// Get raw RGBA bytes for FFI
    pub fn getBytes(self: *const RenderResult) []const u8 {
        return self.bitmap.getRawBytes();
    }
};

/// PDF Page Renderer
pub const PageRenderer = struct {
    allocator: std.mem.Allocator,
    interpreter: Interpreter,
    quality: RenderQuality,
    dpi: f32,
    background: Color,

    // Font system (will be initialized with font module)
    // font_cache: ?*FontCache,

    pub fn init(allocator: std.mem.Allocator) PageRenderer {
        var renderer = PageRenderer{
            .allocator = allocator,
            .interpreter = Interpreter.init(allocator),
            .quality = .Normal,
            .dpi = 150,
            .background = Color.white,
        };

        renderer.interpreter.rasterizer.setAntiAliasing(renderer.quality.getAALevel());

        return renderer;
    }

    pub fn deinit(self: *PageRenderer) void {
        self.interpreter.deinit();
    }

    /// Set render quality
    pub fn setQuality(self: *PageRenderer, quality: RenderQuality) void {
        self.quality = quality;
        self.interpreter.rasterizer.setAntiAliasing(quality.getAALevel());
    }

    /// Set DPI (dots per inch)
    pub fn setDPI(self: *PageRenderer, dpi: f32) void {
        self.dpi = dpi;
    }

    /// Set background color
    pub fn setBackground(self: *PageRenderer, color: Color) void {
        self.background = color;
    }

    /// Render a PDF content stream to a new bitmap
    pub fn render(
        self: *PageRenderer,
        content: []const u8,
        page_size: PageSize,
    ) !RenderResult {
        return self.renderWithResources(content, page_size, null);
    }

    /// Render with resource provider for font/XObject resolution
    pub fn renderWithResources(
        self: *PageRenderer,
        content: []const u8,
        page_size: PageSize,
        resources: ?interpreter_mod.ResourceProvider,
    ) !RenderResult {
        const pixels = page_size.toPixels(self.dpi);

        var bitmap = try Bitmap.init(self.allocator, pixels.width, pixels.height);
        errdefer bitmap.deinit();

        bitmap.clear(self.background);

        self.interpreter.setTarget(&bitmap);
        if (resources) |res| {
            self.interpreter.setResources(res);
        }
        self.interpreter.initPage(page_size.width, page_size.height, self.dpi);

        try self.interpreter.execute(content);

        return .{
            .bitmap = bitmap,
            .width = pixels.width,
            .height = pixels.height,
        };
    }

    /// Render into an existing bitmap (for tile-based rendering)
    pub fn renderInto(
        self: *PageRenderer,
        target: *Bitmap,
        content: []const u8,
        page_size: PageSize,
        offset_x: i32,
        offset_y: i32,
    ) !void {
        // Apply viewport offset for tile rendering
        self.interpreter.setTarget(target);
        self.interpreter.initPage(page_size.width, page_size.height, self.dpi);

        // Adjust CTM for tile offset
        if (offset_x != 0 or offset_y != 0) {
            const offset_matrix = Matrix.translation(
                -@as(f32, @floatFromInt(offset_x)),
                -@as(f32, @floatFromInt(offset_y)),
            );
            self.interpreter.state_stack.current.ctm = self.interpreter.state_stack.current.ctm.concat(offset_matrix);
        }

        try self.interpreter.execute(content);
    }

    /// Render to a specific pixel region (for zoomed rendering)
    /// page_size defines the PDF coordinate space (in points)
    /// region_* defines the viewport within that coordinate space
    pub fn renderRegion(
        self: *PageRenderer,
        content: []const u8,
        page_size: PageSize,
        region_x: f32,
        region_y: f32,
        region_width: f32,
        region_height: f32,
        output_width: u32,
        output_height: u32,
    ) !RenderResult {
        var bitmap = try Bitmap.init(self.allocator, output_width, output_height);
        errdefer bitmap.deinit();

        bitmap.clear(self.background);

        self.interpreter.setTarget(&bitmap);

        // Clamp region to page bounds
        const clamped_region_width = @min(region_width, page_size.width - region_x);
        const clamped_region_height = @min(region_height, page_size.height - region_y);

        // Calculate scale to fit region into output
        const scale_x = @as(f32, @floatFromInt(output_width)) / clamped_region_width;
        const scale_y = @as(f32, @floatFromInt(output_height)) / clamped_region_height;
        const scale = @min(scale_x, scale_y);

        // Set up transformation for region
        self.interpreter.state_stack.reset();

        // Scale and translate to view the region
        // PDF origin is bottom-left, screen origin is top-left
        const ctm = Matrix{
            .a = scale,
            .b = 0,
            .c = 0,
            .d = -scale, // Flip Y
            .e = -region_x * scale,
            .f = @as(f32, @floatFromInt(output_height)) + region_y * scale,
        };
        self.interpreter.state_stack.current.ctm = ctm;

        try self.interpreter.execute(content);

        return .{
            .bitmap = bitmap,
            .width = output_width,
            .height = output_height,
        };
    }
};

/// Simple drawing context for creating content programmatically
pub const DrawingContext = struct {
    allocator: std.mem.Allocator,
    content: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) DrawingContext {
        return .{
            .allocator = allocator,
            .content = .{},
        };
    }

    pub fn deinit(self: *DrawingContext) void {
        self.content.deinit(self.allocator);
    }

    pub fn getContent(self: *const DrawingContext) []const u8 {
        return self.content.items;
    }

    /// Save graphics state
    pub fn save(self: *DrawingContext) !void {
        try self.content.appendSlice(self.allocator, "q\n");
    }

    /// Restore graphics state
    pub fn restore(self: *DrawingContext) !void {
        try self.content.appendSlice(self.allocator, "Q\n");
    }

    /// Set fill color (RGB)
    pub fn setFillColor(self: *DrawingContext, r: f32, g: f32, b: f32) !void {
        var buf: [64]u8 = undefined;
        const slice = std.fmt.bufPrint(&buf, "{d:.3} {d:.3} {d:.3} rg\n", .{ r, g, b }) catch return;
        try self.content.appendSlice(self.allocator, slice);
    }

    /// Set stroke color (RGB)
    pub fn setStrokeColor(self: *DrawingContext, r: f32, g: f32, b: f32) !void {
        var buf: [64]u8 = undefined;
        const slice = std.fmt.bufPrint(&buf, "{d:.3} {d:.3} {d:.3} RG\n", .{ r, g, b }) catch return;
        try self.content.appendSlice(self.allocator, slice);
    }

    /// Set line width
    pub fn setLineWidth(self: *DrawingContext, width: f32) !void {
        var buf: [32]u8 = undefined;
        const slice = std.fmt.bufPrint(&buf, "{d:.3} w\n", .{width}) catch return;
        try self.content.appendSlice(self.allocator, slice);
    }

    /// Move to point
    pub fn moveTo(self: *DrawingContext, x: f32, y: f32) !void {
        var buf: [64]u8 = undefined;
        const slice = std.fmt.bufPrint(&buf, "{d:.3} {d:.3} m\n", .{ x, y }) catch return;
        try self.content.appendSlice(self.allocator, slice);
    }

    /// Line to point
    pub fn lineTo(self: *DrawingContext, x: f32, y: f32) !void {
        var buf: [64]u8 = undefined;
        const slice = std.fmt.bufPrint(&buf, "{d:.3} {d:.3} l\n", .{ x, y }) catch return;
        try self.content.appendSlice(self.allocator, slice);
    }

    /// Cubic bezier curve
    pub fn curveTo(self: *DrawingContext, x1: f32, y1: f32, x2: f32, y2: f32, x3: f32, y3: f32) !void {
        var buf: [128]u8 = undefined;
        const slice = std.fmt.bufPrint(&buf, "{d:.3} {d:.3} {d:.3} {d:.3} {d:.3} {d:.3} c\n", .{ x1, y1, x2, y2, x3, y3 }) catch return;
        try self.content.appendSlice(self.allocator, slice);
    }

    /// Draw rectangle
    pub fn rectangle(self: *DrawingContext, x: f32, y: f32, w: f32, h: f32) !void {
        var buf: [128]u8 = undefined;
        const slice = std.fmt.bufPrint(&buf, "{d:.3} {d:.3} {d:.3} {d:.3} re\n", .{ x, y, w, h }) catch return;
        try self.content.appendSlice(self.allocator, slice);
    }

    /// Close path
    pub fn closePath(self: *DrawingContext) !void {
        try self.content.appendSlice(self.allocator, "h\n");
    }

    /// Fill current path
    pub fn fill(self: *DrawingContext) !void {
        try self.content.appendSlice(self.allocator, "f\n");
    }

    /// Stroke current path
    pub fn stroke(self: *DrawingContext) !void {
        try self.content.appendSlice(self.allocator, "S\n");
    }

    /// Fill and stroke
    pub fn fillAndStroke(self: *DrawingContext) !void {
        try self.content.appendSlice(self.allocator, "B\n");
    }

    /// Concatenate transformation matrix
    pub fn transform(self: *DrawingContext, a: f32, b: f32, c: f32, d: f32, e: f32, f_val: f32) !void {
        var buf: [128]u8 = undefined;
        const slice = std.fmt.bufPrint(&buf, "{d:.3} {d:.3} {d:.3} {d:.3} {d:.3} {d:.3} cm\n", .{ a, b, c, d, e, f_val }) catch return;
        try self.content.appendSlice(self.allocator, slice);
    }

    /// Translate
    pub fn translate(self: *DrawingContext, tx: f32, ty: f32) !void {
        try self.transform(1, 0, 0, 1, tx, ty);
    }

    /// Scale
    pub fn scale(self: *DrawingContext, sx: f32, sy: f32) !void {
        try self.transform(sx, 0, 0, sy, 0, 0);
    }

    /// Rotate (angle in radians)
    pub fn rotate(self: *DrawingContext, angle: f32) !void {
        const cos_a = @cos(angle);
        const sin_a = @sin(angle);
        try self.transform(cos_a, sin_a, -sin_a, cos_a, 0, 0);
    }

    /// Begin text object
    pub fn beginText(self: *DrawingContext) !void {
        try self.content.appendSlice(self.allocator, "BT\n");
    }

    /// End text object
    pub fn endText(self: *DrawingContext) !void {
        try self.content.appendSlice(self.allocator, "ET\n");
    }

    /// Set font and size
    pub fn setFont(self: *DrawingContext, font_name: []const u8, size: f32) !void {
        var buf: [64]u8 = undefined;
        const slice = std.fmt.bufPrint(&buf, "/{s} {d:.3} Tf\n", .{ font_name, size }) catch return;
        try self.content.appendSlice(self.allocator, slice);
    }

    /// Set text position
    pub fn textPosition(self: *DrawingContext, x: f32, y: f32) !void {
        var buf: [64]u8 = undefined;
        const slice = std.fmt.bufPrint(&buf, "{d:.3} {d:.3} Td\n", .{ x, y }) catch return;
        try self.content.appendSlice(self.allocator, slice);
    }

    /// Show text
    pub fn showText(self: *DrawingContext, text: []const u8) !void {
        try self.content.append(self.allocator, '(');
        // Escape special characters
        for (text) |c| {
            if (c == '(' or c == ')' or c == '\\') {
                try self.content.append(self.allocator, '\\');
            }
            try self.content.append(self.allocator, c);
        }
        try self.content.appendSlice(self.allocator, ") Tj\n");
    }

    /// Draw a filled circle (approximated with bezier curves)
    pub fn circle(self: *DrawingContext, cx: f32, cy: f32, r: f32) !void {
        // Approximation using 4 cubic bezier curves
        const k: f32 = 0.5522847498; // Magic number for circular arcs

        try self.moveTo(cx + r, cy);
        try self.curveTo(cx + r, cy + r * k, cx + r * k, cy + r, cx, cy + r);
        try self.curveTo(cx - r * k, cy + r, cx - r, cy + r * k, cx - r, cy);
        try self.curveTo(cx - r, cy - r * k, cx - r * k, cy - r, cx, cy - r);
        try self.curveTo(cx + r * k, cy - r, cx + r, cy - r * k, cx + r, cy);
        try self.closePath();
    }

    /// Draw a rounded rectangle
    pub fn roundedRect(self: *DrawingContext, x: f32, y: f32, w: f32, h: f32, radius: f32) !void {
        const r = @min(radius, @min(w / 2, h / 2));
        const k: f32 = 0.5522847498;

        try self.moveTo(x + r, y);
        try self.lineTo(x + w - r, y);
        try self.curveTo(x + w - r + r * k, y, x + w, y + r - r * k, x + w, y + r);
        try self.lineTo(x + w, y + h - r);
        try self.curveTo(x + w, y + h - r + r * k, x + w - r + r * k, y + h, x + w - r, y + h);
        try self.lineTo(x + r, y + h);
        try self.curveTo(x + r - r * k, y + h, x, y + h - r + r * k, x, y + h - r);
        try self.lineTo(x, y + r);
        try self.curveTo(x, y + r - r * k, x + r - r * k, y, x + r, y);
        try self.closePath();
    }
};

// =============================================================================
// Tests
// =============================================================================

test "page renderer basic" {
    var renderer = PageRenderer.init(std.testing.allocator);
    defer renderer.deinit();

    renderer.setDPI(72);

    const content = "0.5 0.5 0.5 rg 100 100 200 200 re f";
    var result = try renderer.render(content, PageSize.letter);
    defer result.deinit();

    try std.testing.expectEqual(@as(u32, 612), result.width);
    try std.testing.expectEqual(@as(u32, 792), result.height);
}

test "drawing context" {
    var ctx = DrawingContext.init(std.testing.allocator);
    defer ctx.deinit();

    try ctx.setFillColor(1, 0, 0);
    try ctx.rectangle(10, 10, 100, 100);
    try ctx.fill();

    const content = ctx.getContent();
    try std.testing.expect(std.mem.indexOf(u8, content, "1.000 0.000 0.000 rg") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "re") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "f") != null);
}

test "page size conversion" {
    const size = PageSize.a4;
    const pixels = size.toPixels(150);

    // A4 at 150 DPI should be approximately 1240 x 1755 pixels
    // (595 * 150 / 72 = 1239.58..., 842 * 150 / 72 = 1754.16...)
    // ceil gives 1240 and 1755
    try std.testing.expectEqual(@as(u32, 1240), pixels.width);
    try std.testing.expectEqual(@as(u32, 1755), pixels.height);
}
