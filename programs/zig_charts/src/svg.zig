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

    /// Write a string with XML metacharacters escaped. Safe for both element
    /// text content and double-quoted attribute values: escaping `< > & "`
    /// covers the attribute-injection vectors (a `"` closes the value, `<`/`&`
    /// open a new node/entity) as well as text-content well-formedness. Today
    /// every caller passes library-internal constants, but the JSON spec is
    /// attacker-influenceable, so any future config knob that reaches an `id`,
    /// `class`, or `font-family` cannot smuggle markup into the emitted SVG.
    fn writeEscaped(self: *Self, s: []const u8) void {
        for (s) |c| {
            switch (c) {
                '<' => self.write("&lt;"),
                '>' => self.write("&gt;"),
                '&' => self.write("&amp;"),
                '"' => self.write("&quot;"),
                else => self.writeByte(c),
            }
        }
    }

    fn sanitizeFloat(f: f64) bool {
        return !std.math.isNan(f) and !std.math.isInf(f);
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
        if (!sanitizeFloat(x1) or !sanitizeFloat(y1) or !sanitizeFloat(x2) or !sanitizeFloat(y2)) return;
        self.writeIndent();

        var buf: [128]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "<line x1=\"{d:.2}\" y1=\"{d:.2}\" x2=\"{d:.2}\" y2=\"{d:.2}\"", .{ x1, y1, x2, y2 }) catch return;
        self.write(line);
        self.writeStrokeAttrs(style);
        self.write("/>\n");
    }

    fn drawRect(ptr: *anyopaque, rect: Rect, stroke: ?StrokeStyle, fill: ?FillStyle) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (!sanitizeFloat(rect.x) or !sanitizeFloat(rect.y) or !sanitizeFloat(rect.width) or !sanitizeFloat(rect.height)) return;
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
        if (!sanitizeFloat(cx) or !sanitizeFloat(cy) or !sanitizeFloat(r)) return;
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

        // Secure Check: if any coordinate is NaN or Inf, skip rendering entirely
        for (path.commands.items) |cmd| {
            switch (cmd) {
                .move_to => |p| {
                    if (!sanitizeFloat(p.x) or !sanitizeFloat(p.y)) return;
                },
                .line_to => |p| {
                    if (!sanitizeFloat(p.x) or !sanitizeFloat(p.y)) return;
                },
                .quad_to => |q| {
                    if (!sanitizeFloat(q.control.x) or !sanitizeFloat(q.control.y) or !sanitizeFloat(q.end.x) or !sanitizeFloat(q.end.y)) return;
                },
                .cubic_to => |c| {
                    if (!sanitizeFloat(c.control1.x) or !sanitizeFloat(c.control1.y) or !sanitizeFloat(c.control2.x) or !sanitizeFloat(c.control2.y) or !sanitizeFloat(c.end.x) or !sanitizeFloat(c.end.y)) return;
                },
                .arc_to => |a| {
                    if (!sanitizeFloat(a.rx) or !sanitizeFloat(a.ry) or !sanitizeFloat(a.rotation) or !sanitizeFloat(a.end.x) or !sanitizeFloat(a.end.y)) return;
                },
                .close => {},
            }
        }

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
        if (!sanitizeFloat(x) or !sanitizeFloat(y)) return;
        self.writeIndent();

        var buf: [256]u8 = undefined;
        var color_buf: [32]u8 = undefined;

        const coord_start = std.fmt.bufPrint(&buf, "<text x=\"{d:.2}\" y=\"{d:.2}\" font-family=\"", .{ x, y }) catch return;
        self.write(coord_start);
        self.writeEscaped(style.font_family);
        const size_part = std.fmt.bufPrint(&buf, "\" font-size=\"{d:.1}\"", .{style.font_size}) catch return;
        self.write(size_part);

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

        self.writeEscaped(text);

        self.write("</text>\n");
    }

    fn beginGroup(ptr: *anyopaque, id: ?[]const u8, class: ?[]const u8) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.writeIndent();
        self.write("<g");

        if (id) |i| {
            self.write(" id=\"");
            self.writeEscaped(i);
            self.writeByte('"');
        }
        if (class) |c| {
            self.write(" class=\"");
            self.writeEscaped(c);
            self.writeByte('"');
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
            if (!sanitizeFloat(r.x) or !sanitizeFloat(r.y) or !sanitizeFloat(r.width) or !sanitizeFloat(r.height)) return;
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
        const tx = if (sanitizeFloat(x)) x else 0.0;
        const ty = if (sanitizeFloat(y)) y else 0.0;
        self.writeIndent();

        var buf: [96]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "<g transform=\"translate({d:.2},{d:.2})\">\n", .{ tx, ty }) catch return;
        self.write(s);
        self.indent_level += 1;
        self.transform_depth += 1;
    }

    fn rotate(ptr: *anyopaque, angle: f64) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const ta = if (sanitizeFloat(angle)) angle else 0.0;
        self.writeIndent();

        var buf: [64]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "<g transform=\"rotate({d:.2})\">\n", .{ta}) catch return;
        self.write(s);
        self.indent_level += 1;
        self.transform_depth += 1;
    }

    fn svgScale(ptr: *anyopaque, sx: f64, sy: f64) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const tsx = if (sanitizeFloat(sx)) sx else 1.0;
        const tsy = if (sanitizeFloat(sy)) sy else 1.0;
        self.writeIndent();

        var buf: [64]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "<g transform=\"scale({d:.2},{d:.2})\">\n", .{ tsx, tsy }) catch return;
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

test "svg coordinate security nan/inf" {
    const allocator = std.testing.allocator;
    var svg = SvgCanvas.init(allocator, 400, 300);
    defer svg.deinit();

    const c = svg.canvas();
    const nan = std.math.nan(f64);
    const inf = std.math.inf(f64);

    // Drawing with invalid coordinates should skip completely (no element output)
    c.drawLine(nan, 0, 100, 100, .{ .color = Color.black });
    c.drawRect(canvas.Rect.init(50, inf, 100, 80), null, null);
    c.drawCircle(200, 150, nan, null, null);
    c.drawText("Skipped", nan, 50, .{});

    // Path with any nan should skip completely
    var path = canvas.Path.init(allocator);
    defer path.deinit();
    try path.moveTo(10, 10);
    try path.lineTo(nan, 20);
    c.drawPath(&path, .{ .color = Color.black }, null);

    // Transforms with nan/inf should fall back to 0.0 or 1.0 gracefully without crashing
    c.translate(nan, 50);
    c.rotate(inf);
    c.scale(nan, nan);
    c.resetTransform();

    const output = try c.finish();

    // Verify raw "nan" or "inf" never leaks into any attributes or the document
    try std.testing.expect(std.mem.indexOf(u8, output, "nan") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "inf") == null);

    // Verify elements were skipped and not rendered
    try std.testing.expect(std.mem.indexOf(u8, output, "<line") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<rect") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<circle") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Skipped") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<path") == null);

    // Verify transform groups still balanced out and transformed safely with 0.0/1.0 fallbacks
    try std.testing.expect(std.mem.indexOf(u8, output, "translate(0.00,50.00)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "rotate(0.00)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "scale(1.00,1.00)") != null);
}

test "svg xml escaping vectors (attribute + text injection)" {
    // External anchor: the five XML 1.0 predefined entities (W3C XML 1.0 §4.6).
    // Expected outputs are the spec's canonical replacement strings, not values
    // this library invented. A `"` must not close an attribute value, and `<`/`&`
    // must not open a node/entity, for text content OR attribute values.
    const allocator = std.testing.allocator;
    var svg = SvgCanvas.init(allocator, 100, 100);
    defer svg.deinit();

    const c = svg.canvas();

    // Attribute-escape vectors: id/class (beginGroup) and font-family (drawText).
    c.beginGroup("a\"><script>alert(1)</script>", "cls&<b>");
    c.drawText("5 < 10 & \"q\" > 3", 10, 20, .{ .font_family = "Arial\"><rect/>" });
    c.endGroup();

    const output = try c.finish();

    // No raw markup metacharacter survives where it could break out.
    // The only literal '<' allowed are the ones that open real elements
    // (<g, <text, </text>, </g>); the injected "<script>" / "<rect/>" must be gone.
    try std.testing.expect(std.mem.indexOf(u8, output, "<script>") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<rect/>") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "</script>") == null);

    // Canonical entity replacements are present.
    try std.testing.expect(std.mem.indexOf(u8, output, "&lt;script&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "&quot;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "cls&amp;&lt;b&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "5 &lt; 10 &amp; &quot;q&quot; &gt; 3") != null);

    // The emitted document must still be well-formed XML.
    try assertWellFormedXml(output);
}

/// Minimal, allocation-free XML 1.0 well-formedness check for emitted SVG.
/// Enforces the structural rules an external validator (or a browser's SVG
/// parser) would: matched/nested tags, quoted attribute values, no raw `<` or
/// unescaped `&` in text or attribute values. It is a checker, not a parser —
/// its "expected" behavior is defined by the XML spec, so it serves as an
/// external anchor for the SVG the renderer emits, not a roundtrip.
pub fn assertWellFormedXml(s: []const u8) !void {
    var stack: [64][]const u8 = undefined;
    var sp: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == '<') {
            if (std.mem.startsWith(u8, s[i..], "<?")) {
                const end = std.mem.indexOfPos(u8, s, i, "?>") orelse return error.UnterminatedPI;
                i = end + 2;
                continue;
            }
            if (std.mem.startsWith(u8, s[i..], "<!--")) {
                const end = std.mem.indexOfPos(u8, s, i, "-->") orelse return error.UnterminatedComment;
                i = end + 3;
                continue;
            }
            const is_close = i + 1 < s.len and s[i + 1] == '/';
            // Scan to the tag's closing '>', treating quoted regions as literal.
            var j = i + 1;
            var in_quote = false;
            while (j < s.len) : (j += 1) {
                const cj = s[j];
                if (cj == '"') {
                    in_quote = !in_quote;
                } else if (!in_quote and cj == '<') {
                    return error.RawLtInsideTag;
                } else if (!in_quote and cj == '>') {
                    break;
                }
            }
            if (j >= s.len) return error.UnterminatedTag;
            if (in_quote) return error.UnbalancedAttributeQuote;
            const inner = s[i + 1 .. j];
            try validateEntities(inner); // '&' inside attribute values must be an entity
            const self_close = inner.len > 0 and inner[inner.len - 1] == '/';
            const name_start: usize = if (is_close) 1 else 0;
            var name_end = name_start;
            while (name_end < inner.len and !isNameBreak(inner[name_end])) name_end += 1;
            const name = inner[name_start..name_end];
            if (is_close) {
                if (sp == 0 or !std.mem.eql(u8, stack[sp - 1], name)) return error.MismatchedCloseTag;
                sp -= 1;
            } else if (!self_close) {
                if (sp >= stack.len) return error.NestingTooDeep;
                stack[sp] = name;
                sp += 1;
            }
            i = j + 1;
        } else if (c == '&') {
            i = try validateOneEntity(s, i);
        } else if (c == '>') {
            // A bare '>' in text is tolerated by XML, but our emitter always
            // escapes it, so its presence in text signals a leak.
            return error.RawGtInText;
        } else {
            i += 1;
        }
    }
    if (sp != 0) return error.UnbalancedTags;
}

fn isNameBreak(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '/' or c == '>';
}

fn validateEntities(inner: []const u8) !void {
    var i: usize = 0;
    while (i < inner.len) {
        if (inner[i] == '&') {
            i = try validateOneEntity(inner, i);
        } else i += 1;
    }
}

fn validateOneEntity(s: []const u8, at: usize) !usize {
    const semi = std.mem.indexOfScalarPos(u8, s, at, ';') orelse return error.UnterminatedEntity;
    const ent = s[at .. semi + 1];
    const named = [_][]const u8{ "&lt;", "&gt;", "&amp;", "&quot;", "&apos;" };
    for (named) |n| {
        if (std.mem.eql(u8, ent, n)) return semi + 1;
    }
    if (ent.len > 3 and ent[1] == '#') {
        const digits = ent[2 .. ent.len - 1];
        if (digits[0] == 'x' or digits[0] == 'X') {
            for (digits[1..]) |d| if (!std.ascii.isHex(d)) return error.BadEntity;
        } else {
            for (digits) |d| if (!std.ascii.isDigit(d)) return error.BadEntity;
        }
        return semi + 1;
    }
    return error.BadEntity;
}
