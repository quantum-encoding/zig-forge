//! PDF Canvas Backend for zig_charts
//!
//! Implements the zig_charts Canvas interface, rendering chart primitives
//! directly into PDF ContentStream commands. No SVG intermediate, no rasterization.
//! Charts become native PDF vector paths — sharp at any zoom level.

const std = @import("std");
const document = @import("document.zig");

// zig_charts types (imported as source, not as dependency)
const chart_canvas = @import("chart_canvas.zig"); // Lightweight type bridge

const ContentStream = document.ContentStream;
const Color = document.Color;

/// PDF Canvas that renders zig_charts primitives into a PDF ContentStream.
/// Positioned at (origin_x, origin_y) on the PDF page with given width/height.
/// PDF Y-axis is flipped (0 = bottom), so we transform: pdf_y = page_height - chart_y.
pub const PdfCanvas = struct {
    content: *ContentStream,
    allocator: std.mem.Allocator,
    font_regular: []const u8,

    // Position on PDF page (in points)
    origin_x: f32,
    origin_y: f32, // Top of chart area (PDF coords, measured from bottom)
    width: f32,
    height: f32,

    /// Convert chart X coordinate to PDF X
    fn pdfX(self: *PdfCanvas, x: f64) f32 {
        return self.origin_x + @as(f32, @floatCast(x));
    }

    /// Convert chart Y coordinate to PDF Y (flip Y axis)
    fn pdfY(self: *PdfCanvas, y: f64) f32 {
        return self.origin_y - @as(f32, @floatCast(y));
    }

    fn toPdfColor(r: u8, g: u8, b: u8) Color {
        return .{
            .r = @as(f32, @floatFromInt(r)) / 255.0,
            .g = @as(f32, @floatFromInt(g)) / 255.0,
            .b = @as(f32, @floatFromInt(b)) / 255.0,
        };
    }

    /// Draw a line
    pub fn drawLine(self: *PdfCanvas, x1: f64, y1: f64, x2: f64, y2: f64, color_r: u8, color_g: u8, color_b: u8, width: f64) void {
        self.content.drawLine(
            self.pdfX(x1), self.pdfY(y1),
            self.pdfX(x2), self.pdfY(y2),
            toPdfColor(color_r, color_g, color_b),
            @floatCast(width),
        ) catch {};
    }

    /// Draw a filled/stroked rectangle
    pub fn drawRect(self: *PdfCanvas, x: f64, y: f64, w: f64, h: f64, fill_r: u8, fill_g: u8, fill_b: u8) void {
        self.content.drawRect(
            self.pdfX(x), self.pdfY(y + h), // PDF Y is bottom of rect
            @floatCast(w), @floatCast(h),
            toPdfColor(fill_r, fill_g, fill_b),
            null,
        ) catch {};
    }

    /// Draw text
    pub fn drawText(self: *PdfCanvas, text: []const u8, x: f64, y: f64, font_size: f64, color_r: u8, color_g: u8, color_b: u8) void {
        self.content.drawText(
            text,
            self.pdfX(x), self.pdfY(y),
            self.font_regular,
            @floatCast(font_size),
            toPdfColor(color_r, color_g, color_b),
        ) catch {};
    }

    /// Draw a circle (approximated with 4 Bézier curves)
    pub fn drawCircle(self: *PdfCanvas, cx: f64, cy: f64, r: f64, fill_r: u8, fill_g: u8, fill_b: u8) void {
        self.content.drawCircle(
            self.pdfX(cx), self.pdfY(cy),
            @floatCast(r),
            toPdfColor(fill_r, fill_g, fill_b),
            null,
        ) catch {};
    }

    /// Draw a pie segment path (moveTo + lineTo + arcTo + close).
    /// For pie/donut charts. Converts SVG arc to PDF Bézier approximation.
    pub fn drawPieSegment(
        self: *PdfCanvas,
        cx: f64, cy: f64,
        radius: f64,
        start_angle: f64,
        sweep: f64,
        fill_r: u8, fill_g: u8, fill_b: u8,
    ) void {
        const color = toPdfColor(fill_r, fill_g, fill_b);
        const pcx = self.pdfX(cx);
        const pcy = self.pdfY(cy);
        const r: f32 = @floatCast(radius);

        // PDF pie segment: moveTo center, lineTo arc start, arc, close
        self.content.setFillColor(color) catch {};
        self.content.moveTo(pcx, pcy) catch {};

        const sa: f32 = @floatCast(start_angle);
        const sx = pcx + @cos(sa) * r;
        const sy = pcy + @sin(-sa) * r; // Flip Y for PDF

        self.content.lineTo(sx, sy) catch {};

        // Approximate arc with line segments (simple subdivision)
        const steps: u32 = 32;
        const step_angle: f32 = @as(f32, @floatCast(sweep)) / @as(f32, @floatFromInt(steps));
        var angle: f32 = sa;
        var s: u32 = 0;
        while (s <= steps) : (s += 1) {
            angle += step_angle;
            const ax = pcx + @cos(angle) * r;
            const ay = pcy + @sin(-angle) * r;
            self.content.lineTo(ax, ay) catch {};
        }

        self.content.closePath() catch {};
        self.content.fill() catch {};

        // White stroke between segments
        self.content.setStrokeColor(.{ .r = 1, .g = 1, .b = 1 }) catch {};
        self.content.setLineWidth(1) catch {};
        self.content.stroke() catch {};
    }
};
