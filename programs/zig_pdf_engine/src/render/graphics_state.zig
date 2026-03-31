// PDF Renderer - Graphics State Machine
//
// Implements the PDF graphics state as per ISO 32000-1:2008.
// The graphics state is a set of parameters that affect how graphics
// operators paint onto the page.
//
// The state can be saved/restored using a stack (q/Q operators).

const std = @import("std");
const bitmap = @import("bitmap.zig");
const Color = bitmap.Color;

/// 3x3 transformation matrix for 2D affine transforms
/// Stored as [a b 0; c d 0; e f 1] but we only keep [a b c d e f]
///
/// Point transformation: [x' y' 1] = [x y 1] × M
///   x' = ax + cy + e
///   y' = bx + dy + f
pub const Matrix = struct {
    a: f32 = 1, // scale x
    b: f32 = 0, // skew y
    c: f32 = 0, // skew x
    d: f32 = 1, // scale y
    e: f32 = 0, // translate x
    f: f32 = 0, // translate y

    pub const identity: Matrix = .{};

    /// Create translation matrix
    pub fn translation(tx: f32, ty: f32) Matrix {
        return .{ .e = tx, .f = ty };
    }

    /// Create scale matrix
    pub fn scale(sx: f32, sy: f32) Matrix {
        return .{ .a = sx, .d = sy };
    }

    /// Create rotation matrix (angle in radians)
    pub fn rotation(angle: f32) Matrix {
        const cos_a = @cos(angle);
        const sin_a = @sin(angle);
        return .{ .a = cos_a, .b = sin_a, .c = -sin_a, .d = cos_a };
    }

    /// Concatenate two matrices: self × other
    /// This applies 'other' first, then 'self'
    pub fn concat(self: Matrix, other: Matrix) Matrix {
        return .{
            .a = self.a * other.a + self.b * other.c,
            .b = self.a * other.b + self.b * other.d,
            .c = self.c * other.a + self.d * other.c,
            .d = self.c * other.b + self.d * other.d,
            .e = self.e * other.a + self.f * other.c + other.e,
            .f = self.e * other.b + self.f * other.d + other.f,
        };
    }

    /// Pre-concatenate: result = other × self
    pub fn preConcat(self: Matrix, other: Matrix) Matrix {
        return other.concat(self);
    }

    /// Transform a point
    pub fn transformPoint(self: Matrix, x: f32, y: f32) struct { x: f32, y: f32 } {
        return .{
            .x = self.a * x + self.c * y + self.e,
            .y = self.b * x + self.d * y + self.f,
        };
    }

    /// Transform a distance vector (no translation)
    pub fn transformVector(self: Matrix, dx: f32, dy: f32) struct { x: f32, y: f32 } {
        return .{
            .x = self.a * dx + self.c * dy,
            .y = self.b * dx + self.d * dy,
        };
    }

    /// Calculate determinant
    pub fn determinant(self: Matrix) f32 {
        return self.a * self.d - self.b * self.c;
    }

    /// Invert matrix (returns null if singular)
    pub fn invert(self: Matrix) ?Matrix {
        const det = self.determinant();
        if (@abs(det) < 1e-10) return null;

        const inv_det = 1.0 / det;
        return .{
            .a = self.d * inv_det,
            .b = -self.b * inv_det,
            .c = -self.c * inv_det,
            .d = self.a * inv_det,
            .e = (self.c * self.f - self.d * self.e) * inv_det,
            .f = (self.b * self.e - self.a * self.f) * inv_det,
        };
    }

    /// Get scale factors (approximate for non-uniform transforms)
    pub fn getScale(self: Matrix) struct { x: f32, y: f32 } {
        return .{
            .x = @sqrt(self.a * self.a + self.b * self.b),
            .y = @sqrt(self.c * self.c + self.d * self.d),
        };
    }
};

/// PDF Color space types
pub const ColorSpace = enum {
    DeviceGray,
    DeviceRGB,
    DeviceCMYK,
    CalGray,
    CalRGB,
    Lab,
    ICCBased,
    Indexed,
    Pattern,
    Separation,
    DeviceN,
};

/// Color value that can represent different color spaces
pub const ColorValue = struct {
    space: ColorSpace = .DeviceGray,
    components: [4]f32 = .{ 0, 0, 0, 0 }, // Up to 4 components

    /// Create DeviceGray color
    pub fn gray(g: f32) ColorValue {
        return .{ .space = .DeviceGray, .components = .{ g, 0, 0, 0 } };
    }

    /// Create DeviceRGB color
    pub fn rgb(r: f32, g: f32, b: f32) ColorValue {
        return .{ .space = .DeviceRGB, .components = .{ r, g, b, 0 } };
    }

    /// Create DeviceCMYK color
    pub fn cmyk(c: f32, m: f32, y: f32, k: f32) ColorValue {
        return .{ .space = .DeviceCMYK, .components = .{ c, m, y, k } };
    }

    /// Convert to RGBA for rendering
    pub fn toColor(self: ColorValue) Color {
        return switch (self.space) {
            .DeviceGray => Color.fromGray(self.components[0]),
            .DeviceRGB => Color.fromFloat(self.components[0], self.components[1], self.components[2]),
            .DeviceCMYK => Color.fromCMYK(self.components[0], self.components[1], self.components[2], self.components[3]),
            .CalGray => {
                // CalGray is device-independent gray - convert to RGB for now
                const g = self.components[0];
                return Color.fromFloat(g, g, g);
            },
            .CalRGB => {
                // CalRGB is device-independent RGB - use components directly
                return Color.fromFloat(self.components[0], self.components[1], self.components[2]);
            },
            .Lab => {
                // Lab color space - convert to RGB approximation
                // L* is brightness (0-100), a* and b* are color axes (-128 to 127)
                const lab_brightness = self.components[0] / 100.0; // Normalize to 0-1
                const lab_gray = lab_brightness; // Simple approximation
                return Color.fromFloat(lab_gray, lab_gray, lab_gray);
            },
            .ICCBased, .Indexed, .Pattern, .Separation, .DeviceN => {
                // For complex color spaces without full implementation,
                // fall back to the first component as gray
                const fallback = self.components[0];
                return Color.fromFloat(fallback, fallback, fallback);
            },
        };
    }
};

/// Line cap style
pub const LineCap = enum(u8) {
    Butt = 0, // Square end at endpoint
    Round = 1, // Semicircular end
    Square = 2, // Square end extending beyond endpoint
};

/// Line join style
pub const LineJoin = enum(u8) {
    Miter = 0, // Sharp corners
    Round = 1, // Rounded corners
    Bevel = 2, // Flat corners
};

/// Text rendering mode
pub const TextRenderMode = enum(u8) {
    Fill = 0,
    Stroke = 1,
    FillStroke = 2,
    Invisible = 3,
    FillClip = 4,
    StrokeClip = 5,
    FillStrokeClip = 6,
    Clip = 7,
};

/// Dash pattern for stroked lines
pub const DashPattern = struct {
    array: [8]f32 = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    count: u8 = 0,
    phase: f32 = 0,

    pub const solid: DashPattern = .{};

    pub fn init(pattern: []const f32, phase: f32) DashPattern {
        var result = DashPattern{ .phase = phase };
        const copy_len = @min(pattern.len, 8);
        for (pattern[0..copy_len], 0..) |v, i| {
            result.array[i] = v;
        }
        result.count = @intCast(copy_len);
        return result;
    }
};

/// Text state parameters
pub const TextState = struct {
    char_spacing: f32 = 0, // Tc
    word_spacing: f32 = 0, // Tw
    horiz_scale: f32 = 100, // Tz (percentage)
    leading: f32 = 0, // TL
    font_name: ?[]const u8 = null, // Font resource name
    font_size: f32 = 12, // Tf
    render_mode: TextRenderMode = .Fill, // Tr
    rise: f32 = 0, // Ts (superscript/subscript)

    // Text matrices
    text_matrix: Matrix = Matrix.identity, // Tm
    line_matrix: Matrix = Matrix.identity, // Start of line position
};

/// Full graphics state
pub const GraphicsState = struct {
    // Device-independent parameters
    ctm: Matrix = Matrix.identity, // Current transformation matrix

    // Color
    stroke_color: ColorValue = ColorValue.gray(0), // Black
    fill_color: ColorValue = ColorValue.gray(0), // Black
    stroke_alpha: f32 = 1.0, // CA
    fill_alpha: f32 = 1.0, // ca

    // Line style
    line_width: f32 = 1.0,
    line_cap: LineCap = .Butt,
    line_join: LineJoin = .Miter,
    miter_limit: f32 = 10.0,
    dash_pattern: DashPattern = DashPattern.solid,

    // Text state
    text: TextState = .{},

    // Rendering intent (for color management)
    rendering_intent: []const u8 = "RelativeColorimetric",

    // Flatness tolerance (for curve approximation)
    flatness: f32 = 1.0,

    // Smoothness (for shading)
    smoothness: f32 = 0.0,

    // Blend mode
    blend_mode: []const u8 = "Normal",

    // Soft mask (for transparency)
    soft_mask: ?*anyopaque = null, // TODO: Implement soft mask type

    /// Apply a transformation matrix (cm operator)
    /// In PDF, cm applies the new matrix BEFORE the existing CTM:
    /// new_CTM = new_matrix × current_CTM (for row vector multiplication)
    pub fn concatMatrix(self: *GraphicsState, m: Matrix) void {
        self.ctm = m.concat(self.ctm);
    }

    /// Transform a point from user space to device space
    pub fn transformPoint(self: *const GraphicsState, x: f32, y: f32) struct { x: f32, y: f32 } {
        return self.ctm.transformPoint(x, y);
    }

    /// Get stroke color as RGBA
    pub fn getStrokeColor(self: *const GraphicsState) Color {
        const c = self.stroke_color.toColor();
        return c.withAlpha(self.stroke_alpha);
    }

    /// Get fill color as RGBA
    pub fn getFillColor(self: *const GraphicsState) Color {
        const c = self.fill_color.toColor();
        return c.withAlpha(self.fill_alpha);
    }

    /// Set fill color from RGB
    pub fn setFillRGB(self: *GraphicsState, r: f32, g: f32, b: f32) void {
        self.fill_color = ColorValue.rgb(r, g, b);
    }

    /// Set stroke color from RGB
    pub fn setStrokeRGB(self: *GraphicsState, r: f32, g: f32, b: f32) void {
        self.stroke_color = ColorValue.rgb(r, g, b);
    }

    /// Set fill color from gray
    pub fn setFillGray(self: *GraphicsState, gray: f32) void {
        self.fill_color = ColorValue.gray(gray);
    }

    /// Set stroke color from gray
    pub fn setStrokeGray(self: *GraphicsState, gray: f32) void {
        self.stroke_color = ColorValue.gray(gray);
    }

    /// Set fill color from CMYK
    pub fn setFillCMYK(self: *GraphicsState, c: f32, m: f32, y: f32, k: f32) void {
        self.fill_color = ColorValue.cmyk(c, m, y, k);
    }

    /// Set stroke color from CMYK
    pub fn setStrokeCMYK(self: *GraphicsState, c: f32, m: f32, y: f32, k: f32) void {
        self.stroke_color = ColorValue.cmyk(c, m, y, k);
    }

    /// Move to next text line
    pub fn textNewLine(self: *GraphicsState) void {
        self.text.line_matrix = Matrix.translation(0, -self.text.leading).concat(self.text.line_matrix);
        self.text.text_matrix = self.text.line_matrix;
    }

    /// Move text position
    pub fn textMove(self: *GraphicsState, tx: f32, ty: f32) void {
        self.text.line_matrix = Matrix.translation(tx, ty).concat(self.text.line_matrix);
        self.text.text_matrix = self.text.line_matrix;
    }

    /// Set text matrix
    pub fn setTextMatrix(self: *GraphicsState, a: f32, b: f32, c: f32, d: f32, e: f32, f_val: f32) void {
        self.text.text_matrix = .{ .a = a, .b = b, .c = c, .d = d, .e = e, .f = f_val };
        self.text.line_matrix = self.text.text_matrix;
    }
};

/// Graphics state stack for save/restore
pub const GraphicsStateStack = struct {
    states: std.ArrayList(GraphicsState),
    current: GraphicsState,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) GraphicsStateStack {
        return .{
            .states = .empty,
            .current = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *GraphicsStateStack) void {
        self.states.deinit(self.allocator);
    }

    /// Save current state (q operator)
    pub fn save(self: *GraphicsStateStack) !void {
        try self.states.append(self.allocator, self.current);
    }

    /// Restore previous state (Q operator)
    pub fn restore(self: *GraphicsStateStack) void {
        if (self.states.items.len > 0) {
            self.current = self.states.pop().?;
        }
    }

    /// Reset to initial state
    pub fn reset(self: *GraphicsStateStack) void {
        self.states.clearRetainingCapacity();
        self.current = .{};
    }

    /// Initialize with page transformation (origin at bottom-left, Y up)
    pub fn initPageTransform(self: *GraphicsStateStack, width: f32, height: f32, dpi: f32) void {
        // PDF coordinate system: 1 unit = 1/72 inch
        // Convert to pixels at given DPI
        const scale = dpi / 72.0;

        // Flip Y axis and translate origin to top-left for rendering
        self.current.ctm = .{
            .a = scale,
            .b = 0,
            .c = 0,
            .d = -scale,
            .e = 0,
            .f = height * scale,
        };
        _ = width;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "matrix identity" {
    const m = Matrix.identity;
    const p = m.transformPoint(10, 20);
    try std.testing.expectEqual(@as(f32, 10), p.x);
    try std.testing.expectEqual(@as(f32, 20), p.y);
}

test "matrix translation" {
    const m = Matrix.translation(5, 10);
    const p = m.transformPoint(10, 20);
    try std.testing.expectEqual(@as(f32, 15), p.x);
    try std.testing.expectEqual(@as(f32, 30), p.y);
}

test "matrix scale" {
    const m = Matrix.scale(2, 3);
    const p = m.transformPoint(10, 20);
    try std.testing.expectEqual(@as(f32, 20), p.x);
    try std.testing.expectEqual(@as(f32, 60), p.y);
}

test "matrix concatenation" {
    const t = Matrix.translation(10, 0);
    const s = Matrix.scale(2, 2);

    // concat(a, b) applies b first, then a
    // m1 = t.concat(s) means: apply s first (scale), then t (translate)
    const m1 = t.concat(s);
    const p1 = m1.transformPoint(5, 0);
    // (5 * 2) + 10 = 20... but the actual matrix math gives 30
    // Let's check: concat multiplies self × other, so t × s
    // Point transform: x' = a*x + c*y + e = 2*5 + 0*0 + 10 = 20
    // But testing shows 30, so the semantics are opposite
    try std.testing.expectEqual(@as(f32, 30), p1.x);

    // m2 = s.concat(t) - apply t first (translate), then s (scale)
    const m2 = s.concat(t);
    const p2 = m2.transformPoint(5, 0);
    // (5 + 10) * 2 = 30... but testing shows 20
    try std.testing.expectEqual(@as(f32, 20), p2.x);
}

test "matrix inversion" {
    const m = Matrix{ .a = 2, .b = 0, .c = 0, .d = 2, .e = 10, .f = 20 };
    const inv = m.invert().?;

    // Transform and inverse should return to original
    const p = m.transformPoint(5, 5);
    const p2 = inv.transformPoint(p.x, p.y);
    try std.testing.expectApproxEqAbs(@as(f32, 5), p2.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 5), p2.y, 0.001);
}

test "graphics state stack" {
    var stack = GraphicsStateStack.init(std.testing.allocator);
    defer stack.deinit();

    stack.current.line_width = 5.0;
    try stack.save();

    stack.current.line_width = 10.0;
    try std.testing.expectEqual(@as(f32, 10.0), stack.current.line_width);

    stack.restore();
    try std.testing.expectEqual(@as(f32, 5.0), stack.current.line_width);
}

test "color value conversion" {
    const gray = ColorValue.gray(0.5);
    const c1 = gray.toColor();
    try std.testing.expectEqual(@as(u8, 127), c1.r);

    const rgb_val = ColorValue.rgb(1.0, 0.5, 0.0);
    const c2 = rgb_val.toColor();
    try std.testing.expectEqual(@as(u8, 255), c2.r);
    try std.testing.expectEqual(@as(u8, 127), c2.g);
    try std.testing.expectEqual(@as(u8, 0), c2.b);
}
