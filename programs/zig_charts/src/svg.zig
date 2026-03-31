//! SVG Canvas Backend
//!
//! Renders charts to SVG (Scalable Vector Graphics) format.
//! Text-based output is easy to test, diff, and embed in HTML/PDF.

const std = @import("std");
const canvas = @import("canvas.zig");
const Color = @import("color.zig").Color;

const Canvas = canvas.Canvas;
const Point = canvas.Point;
const Rect = canvas.Rect;
const Path = canvas.Path;
const PathCommand = canvas.PathCommand;
const StrokeStyle = canvas.StrokeStyle;
const FillStyle = canvas.FillStyle;
const TextStyle = canvas.TextStyle;
const TextAnchor = canvas.TextAnchor;
const FontWeight = canvas.FontWeight;

/// SVG canvas implementation
pub const SvgCanvas = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayListUnmanaged(u8),
    width: f64,
    height: f64,
    background: ?Color,
    indent_level: usize = 0,
    clip_counter: usize = 0,
    transform_depth: usize = 0,

    const Self = @This();

    /// Create a new SVG canvas
    pub fn init(allocator: std.mem.Allocator, width: f64, height: f64) Self {
        var self = Self{
            .allocator = allocator,
            .buffer = .empty,
            .width = width,
            .height = height,
            .background = null,
        };

        // Write SVG header
        self.writeHeader();
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.buffer.deinit(self.allocator);
    }

    /// Set background color (must be called before drawing)
    pub fn setBackground(self: *Self, color: Color) void {
        self.background = color;
    }

    fn write(self: *Self, data: []const u8) void {
        self.buffer.appendSlice(self.allocator, data) catch {};
    }

    fn writeByte(self: *Self, byte: u8) void {
        self.buffer.append(self.allocator, byte) catch {};
    }

    fn writeHeader(self: *Self) void {
        var buf: [512]u8 = undefined;
        const header = std.fmt.bufPrint(&buf,
            \\<?xml version="1.0" encoding="UTF-8"?>
            \\<svg xmlns="http://www.w3.org/2000/svg"
            \\     width="{d}" height="{d}"
            \\     viewBox="0 0 {d} {d}">
            \\
        , .{ self.width, self.height, self.width, self.height }) catch return;
        self.write(header);

        if (self.background) |bg| {
            var hex_buf: [6]u8 = undefined;
            var rect_buf: [128]u8 = undefined;
            const rect = std.fmt.bufPrint(&rect_buf,
                \\  <rect width="100%" height="100%" fill="#{s}"/>
                \\
            , .{bg.toHex(&hex_buf)}) catch return;
            self.write(rect);
        }
    }

    fn writeIndent(self: *Self) void {
        for (0..self.indent_level + 1) |_| {
            self.write("  ");
        }
    }

    fn colorToString(color: Color, buf: *[32]u8) []const u8 {
        if (color.a == 255) {
            var hex_buf: [6]u8 = undefined;
            const hex = color.toHex(&hex_buf);
            const len = std.fmt.bufPrint(buf, "#{s}", .{hex}) catch return "#000000";
            return len;
        } else if (color.a == 0) {
            return "none";
        } else {
            const len = std.fmt.bufPrint(buf, "rgba({d},{d},{d},{d:.2})", .{
                color.r,
                color.g,
                color.b,
                @as(f32, @floatFromInt(color.a)) / 255.0,
            }) catch return "#000000";
            return len;
        }
    }

    fn writeStrokeAttrs(self: *Self, style: StrokeStyle) void {
        var buf: [128]u8 = undefined;
        var color_buf: [32]u8 = undefined;

        const stroke = std.fmt.bufPrint(&buf, " stroke=\"{s}\" stroke-width=\"{d:.2}\"", .{
            colorToString(style.color, &color_buf),
            style.width,
        }) catch return;
        self.write(stroke);

        if (style.dash_array) |dashes| {
            self.write(" stroke-dasharray=\"");
            for (dashes, 0..) |d, i| {
                if (i > 0) self.writeByte(',');
                var dash_buf: [16]u8 = undefined;
                const dash = std.fmt.bufPrint(&dash_buf, "{d:.1}", .{d}) catch continue;
                self.write(dash);
            }
            self.writeByte('"');
        }

        switch (style.line_cap) {
            .round => self.write(" stroke-linecap=\"round\""),
            .square => self.write(" stroke-linecap=\"square\""),
            .butt => {},
        }

        switch (style.line_join) {
            .round => self.write(" stroke-linejoin=\"round\""),
            .bevel => self.write(" stroke-linejoin=\"bevel\""),
            .miter => {},
        }
    }

    fn writeFillAttr(self: *Self, style: FillStyle) void {
        var buf: [64]u8 = undefined;
        var color_buf: [32]u8 = undefined;
        const fill = std.fmt.bufPrint(&buf, " fill=\"{s}\"", .{colorToString(style.color, &color_buf)}) catch return;
        self.write(fill);
    }

    // =========================================================================
    // Canvas Interface Implementation
    // =========================================================================

    fn drawLine(ptr: *anyopaque, x1: f64, y1: f64, x2: f64, y2: f64, style: StrokeStyle) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.writeIndent();

        var buf: [128]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "<line x1=\"{d:.2}\" y1=\"{d:.2}\" x2=\"{d:.2}\" y2=\"{d:.2}\"", .{ x1, y1, x2, y2 }) catch return;
        self.write(line);
        self.writeStrokeAttrs(style);
        self.write("/>\n");
    }

    fn drawRect(ptr: *anyopaque, rect: Rect, stroke: ?StrokeStyle, fill: ?FillStyle) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.writeIndent();

        var buf: [128]u8 = undefined;
        const r = std.fmt.bufPrint(&buf, "<rect x=\"{d:.2}\" y=\"{d:.2}\" width=\"{d:.2}\" height=\"{d:.2}\"", .{
            rect.x,
            rect.y,
            rect.width,
            rect.height,
        }) catch return;
        self.write(r);

        if (fill) |f| {
            self.writeFillAttr(f);
        } else {
            self.write(" fill=\"none\"");
        }

        if (stroke) |s| {
            self.writeStrokeAttrs(s);
        }

        self.write("/>\n");
    }

    fn drawCircle(ptr: *anyopaque, cx: f64, cy: f64, r: f64, stroke: ?StrokeStyle, fill: ?FillStyle) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.writeIndent();

        var buf: [96]u8 = undefined;
        const circle = std.fmt.bufPrint(&buf, "<circle cx=\"{d:.2}\" cy=\"{d:.2}\" r=\"{d:.2}\"", .{ cx, cy, r }) catch return;
        self.write(circle);

        if (fill) |f| {
            self.writeFillAttr(f);
        } else {
            self.write(" fill=\"none\"");
        }

        if (stroke) |s| {
            self.writeStrokeAttrs(s);
        }

        self.write("/>\n");
    }

    fn drawPath(ptr: *anyopaque, path: *const Path, stroke: ?StrokeStyle, fill: ?FillStyle) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (path.commands.items.len == 0) return;

        self.writeIndent();
        self.write("<path d=\"");

        for (path.commands.items) |cmd| {
            var buf: [128]u8 = undefined;
            switch (cmd) {
                .move_to => |p| {
                    const s = std.fmt.bufPrint(&buf, "M{d:.2},{d:.2} ", .{ p.x, p.y }) catch continue;
                    self.write(s);
                },
                .line_to => |p| {
                    const s = std.fmt.bufPrint(&buf, "L{d:.2},{d:.2} ", .{ p.x, p.y }) catch continue;
                    self.write(s);
                },
                .quad_to => |q| {
                    const s = std.fmt.bufPrint(&buf, "Q{d:.2},{d:.2} {d:.2},{d:.2} ", .{
                        q.control.x,
                        q.control.y,
                        q.end.x,
                        q.end.y,
                    }) catch continue;
                    self.write(s);
                },
                .cubic_to => |c| {
                    const s = std.fmt.bufPrint(&buf, "C{d:.2},{d:.2} {d:.2},{d:.2} {d:.2},{d:.2} ", .{
                        c.control1.x,
                        c.control1.y,
                        c.control2.x,
                        c.control2.y,
                        c.end.x,
                        c.end.y,
                    }) catch continue;
                    self.write(s);
                },
                .arc_to => |a| {
                    const s = std.fmt.bufPrint(&buf, "A{d:.2},{d:.2} {d:.2} {d},{d} {d:.2},{d:.2} ", .{
                        a.rx,
                        a.ry,
                        a.rotation,
                        @as(u8, if (a.large_arc) 1 else 0),
                        @as(u8, if (a.sweep) 1 else 0),
                        a.end.x,
                        a.end.y,
                    }) catch continue;
                    self.write(s);
                },
                .close => self.write("Z "),
            }
        }

        self.writeByte('"');

        if (fill) |f| {
            self.writeFillAttr(f);
        } else {
            self.write(" fill=\"none\"");
        }

        if (stroke) |s| {
            self.writeStrokeAttrs(s);
        }

        self.write("/>\n");
    }

    fn drawText(ptr: *anyopaque, text: []const u8, x: f64, y: f64, style: TextStyle) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.writeIndent();

        var buf: [256]u8 = undefined;
        var color_buf: [32]u8 = undefined;

        const text_start = std.fmt.bufPrint(&buf, "<text x=\"{d:.2}\" y=\"{d:.2}\" font-family=\"{s}\" font-size=\"{d:.1}\"", .{
            x,
            y,
            style.font_family,
            style.font_size,
        }) catch return;
        self.write(text_start);

        if (style.font_weight == .bold) {
            self.write(" font-weight=\"bold\"");
        }

        // Color
        var fill_buf: [64]u8 = undefined;
        const fill = std.fmt.bufPrint(&fill_buf, " fill=\"{s}\"", .{colorToString(style.color, &color_buf)}) catch return;
        self.write(fill);

        // Anchor
        switch (style.anchor) {
            .start => {},
            .middle => self.write(" text-anchor=\"middle\""),
            .end => self.write(" text-anchor=\"end\""),
        }

        // Baseline
        switch (style.baseline) {
            .top => self.write(" dominant-baseline=\"hanging\""),
            .middle => self.write(" dominant-baseline=\"middle\""),
            .bottom => self.write(" dominant-baseline=\"ideographic\""),
            .alphabetic => {},
        }

        self.writeByte('>');

        // Escape text content
        for (text) |c| {
            switch (c) {
                '<' => self.write("&lt;"),
                '>' => self.write("&gt;"),
                '&' => self.write("&amp;"),
                '"' => self.write("&quot;"),
                else => self.writeByte(c),
            }
        }

        self.write("</text>\n");
    }

    fn beginGroup(ptr: *anyopaque, id: ?[]const u8, class: ?[]const u8) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.writeIndent();
        self.write("<g");

        if (id) |i| {
            var buf: [64]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, " id=\"{s}\"", .{i}) catch return;
            self.write(s);
        }
        if (class) |c| {
            var buf: [64]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, " class=\"{s}\"", .{c}) catch return;
            self.write(s);
        }

        self.write(">\n");
        self.indent_level += 1;
    }

    fn endGroup(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (self.indent_level > 0) self.indent_level -= 1;
        self.writeIndent();
        self.write("</g>\n");
    }

    fn setClipRect(ptr: *anyopaque, rect: ?Rect) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (rect) |r| {
            self.clip_counter += 1;
            self.writeIndent();

            var buf: [256]u8 = undefined;
            const clip = std.fmt.bufPrint(&buf, "<defs><clipPath id=\"clip{d}\"><rect x=\"{d:.2}\" y=\"{d:.2}\" width=\"{d:.2}\" height=\"{d:.2}\"/></clipPath></defs>\n", .{
                self.clip_counter,
                r.x,
                r.y,
                r.width,
                r.height,
            }) catch return;
            self.write(clip);

            self.writeIndent();
            var ref_buf: [64]u8 = undefined;
            const ref = std.fmt.bufPrint(&ref_buf, "<g clip-path=\"url(#clip{d})\">\n", .{self.clip_counter}) catch return;
            self.write(ref);
            self.indent_level += 1;
        } else {
            if (self.indent_level > 0) self.indent_level -= 1;
            self.writeIndent();
            self.write("</g>\n");
        }
    }

    fn translate(ptr: *anyopaque, x: f64, y: f64) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.writeIndent();

        var buf: [96]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "<g transform=\"translate({d:.2},{d:.2})\">\n", .{ x, y }) catch return;
        self.write(s);
        self.indent_level += 1;
        self.transform_depth += 1;
    }

    fn rotate(ptr: *anyopaque, angle: f64) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.writeIndent();

        var buf: [64]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "<g transform=\"rotate({d:.2})\">\n", .{angle}) catch return;
        self.write(s);
        self.indent_level += 1;
        self.transform_depth += 1;
    }

    fn svgScale(ptr: *anyopaque, sx: f64, sy: f64) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.writeIndent();

        var buf: [64]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "<g transform=\"scale({d:.2},{d:.2})\">\n", .{ sx, sy }) catch return;
        self.write(s);
        self.indent_level += 1;
        self.transform_depth += 1;
    }

    fn resetTransform(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        while (self.transform_depth > 0) {
            self.transform_depth -= 1;
            if (self.indent_level > 0) self.indent_level -= 1;
            self.writeIndent();
            self.write("</g>\n");
        }
    }

    fn finish(ptr: *anyopaque) anyerror![]const u8 {
        const self: *Self = @ptrCast(@alignCast(ptr));

        // Close any remaining transforms
        while (self.transform_depth > 0) {
            self.transform_depth -= 1;
            if (self.indent_level > 0) self.indent_level -= 1;
            self.writeIndent();
            self.write("</g>\n");
        }

        // Close SVG
        self.write("</svg>\n");
        return self.buffer.items;
    }

    /// Get the canvas interface
    pub fn canvas(self: *Self) Canvas {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    const vtable = Canvas.VTable{
        .drawLine = drawLine,
        .drawRect = drawRect,
        .drawCircle = drawCircle,
        .drawPath = drawPath,
        .drawText = drawText,
        .beginGroup = beginGroup,
        .endGroup = endGroup,
        .setClipRect = setClipRect,
        .translate = translate,
        .rotate = rotate,
        .scale = svgScale,
        .resetTransform = resetTransform,
        .finish = finish,
    };
};

// =============================================================================
// Tests
// =============================================================================

test "svg basic shapes" {
    const allocator = std.testing.allocator;
    var svg = SvgCanvas.init(allocator, 400, 300);
    defer svg.deinit();

    const c = svg.canvas();

    c.drawLine(0, 0, 100, 100, .{ .color = Color.black, .width = 2 });
    c.drawRect(canvas.Rect.init(50, 50, 100, 80), .{ .color = Color.blue_500 }, .{ .color = Color.gray_200 });
    c.drawCircle(200, 150, 40, null, .{ .color = Color.bull_green });
    c.drawText("Hello", 200, 50, .{ .anchor = .middle, .font_size = 16 });

    const output = try c.finish();
    try std.testing.expect(std.mem.indexOf(u8, output, "<svg") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<line") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<rect") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<circle") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<text") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "</svg>") != null);
}

test "svg path" {
    const allocator = std.testing.allocator;
    var svg = SvgCanvas.init(allocator, 200, 200);
    defer svg.deinit();

    var path = canvas.Path.init(allocator);
    defer path.deinit();

    try path.moveTo(10, 10);
    try path.lineTo(100, 10);
    try path.lineTo(100, 100);
    try path.close();

    const c = svg.canvas();
    c.drawPath(&path, .{ .color = Color.black }, .{ .color = Color.bear_red });

    const output = try c.finish();
    try std.testing.expect(std.mem.indexOf(u8, output, "<path") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "M10") != null);
}
