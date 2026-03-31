// PDF Renderer - Content Stream Interpreter
//
// Parses and executes PDF content streams (page drawing commands).
// Implements the PDF graphics operators as specified in ISO 32000-1.

const std = @import("std");
const bitmap_mod = @import("bitmap.zig");
const gs_mod = @import("graphics_state.zig");
const path_mod = @import("path.zig");
const rasterizer_mod = @import("rasterizer.zig");
const operators = @import("operators.zig");
const pdf_fonts = @import("font/pdf_fonts.zig");

const Bitmap = bitmap_mod.Bitmap;
const Color = bitmap_mod.Color;
const GraphicsState = gs_mod.GraphicsState;
const GraphicsStateStack = gs_mod.GraphicsStateStack;
const Matrix = gs_mod.Matrix;
const TextState = gs_mod.TextState;
const PathBuilder = path_mod.PathBuilder;
const Point = path_mod.Point;
const Rasterizer = rasterizer_mod.Rasterizer;
const FillRule = rasterizer_mod.FillRule;
const Operator = operators.Operator;
const FontManager = pdf_fonts.FontManager;
const PdfFont = pdf_fonts.PdfFont;
const PdfTextRenderer = pdf_fonts.PdfTextRenderer;

/// Operand on the execution stack
pub const Operand = union(enum) {
    integer: i64,
    real: f64,
    boolean: bool,
    name: []const u8,
    string: []const u8,
    array_start, // '['
    array_end, // ']'
    dict_start, // '<<'
    dict_end, // '>>'

    pub fn asFloat(self: Operand) ?f32 {
        return switch (self) {
            .integer => |i| @floatFromInt(i),
            .real => |r| @floatCast(r),
            else => null,
        };
    }

    pub fn asInt(self: Operand) ?i64 {
        return switch (self) {
            .integer => |i| i,
            .real => |r| @intFromFloat(r),
            else => null,
        };
    }
};

/// Resource provider interface for XObjects, fonts, etc.
pub const ResourceProvider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        getXObject: *const fn (ctx: *anyopaque, name: []const u8) ?XObjectInfo,
        getFont: *const fn (ctx: *anyopaque, name: []const u8) ?FontInfo,
        getColorSpace: *const fn (ctx: *anyopaque, name: []const u8) ?ColorSpaceInfo,
        getExtGState: *const fn (ctx: *anyopaque, name: []const u8) ?ExtGStateInfo,
    };

    pub fn getXObject(self: ResourceProvider, name: []const u8) ?XObjectInfo {
        return self.vtable.getXObject(self.ptr, name);
    }

    pub fn getFont(self: ResourceProvider, name: []const u8) ?FontInfo {
        return self.vtable.getFont(self.ptr, name);
    }

    pub fn getColorSpace(self: ResourceProvider, name: []const u8) ?ColorSpaceInfo {
        return self.vtable.getColorSpace(self.ptr, name);
    }

    pub fn getExtGState(self: ResourceProvider, name: []const u8) ?ExtGStateInfo {
        return self.vtable.getExtGState(self.ptr, name);
    }
};

/// XObject information
pub const XObjectInfo = struct {
    subtype: enum { Image, Form, PS },
    data: []const u8,
    dict: []const u8, // Dictionary bytes
    width: ?u32 = null,
    height: ?u32 = null,
    // Form XObject specific
    matrix: ?[6]f32 = null, // Transformation matrix [a b c d e f]
    bbox: ?[4]f32 = null, // Bounding box [llx lly urx ury]
};

/// Font information
pub const FontInfo = struct {
    subtype: []const u8, // Type1, TrueType, Type0, etc.
    base_font: ?[]const u8,
    encoding: ?[]const u8,
    widths: ?[]const u16,
    first_char: u16,
    // For embedded fonts
    font_data: ?[]const u8,
};

/// Color space info
pub const ColorSpaceInfo = struct {
    name: []const u8,
    family: gs_mod.ColorSpace,
};

/// Extended graphics state info
pub const ExtGStateInfo = struct {
    stroke_alpha: ?f32,
    fill_alpha: ?f32,
    blend_mode: ?[]const u8,
    // Add more as needed
};

/// Content stream interpreter
pub const Interpreter = struct {
    allocator: std.mem.Allocator,
    operand_stack: std.ArrayList(Operand),
    state_stack: GraphicsStateStack,
    path: PathBuilder,
    rasterizer: Rasterizer,
    target: ?*Bitmap,
    resources: ?ResourceProvider,

    // Font management
    font_manager: FontManager,
    text_renderer: ?PdfTextRenderer,

    // Callbacks for text rendering (will be set by renderer)
    render_text_callback: ?*const fn (
        ctx: *anyopaque,
        text: []const u8,
        state: *const GraphicsState,
        target: *Bitmap,
    ) void,
    render_text_ctx: ?*anyopaque,

    // Callbacks for image rendering
    render_image_callback: ?*const fn (
        ctx: *anyopaque,
        info: XObjectInfo,
        state: *const GraphicsState,
        target: *Bitmap,
    ) void,
    render_image_ctx: ?*anyopaque,

    pub fn init(allocator: std.mem.Allocator) Interpreter {
        var interp = Interpreter{
            .allocator = allocator,
            .operand_stack = .empty,
            .state_stack = GraphicsStateStack.init(allocator),
            .path = PathBuilder.init(allocator),
            .rasterizer = Rasterizer.init(allocator),
            .target = null,
            .resources = null,
            .font_manager = FontManager.init(allocator),
            .text_renderer = null,
            .render_text_callback = null,
            .render_text_ctx = null,
            .render_image_callback = null,
            .render_image_ctx = null,
        };
        interp.text_renderer = PdfTextRenderer.init(allocator);
        return interp;
    }

    pub fn deinit(self: *Interpreter) void {
        if (self.text_renderer) |*tr| {
            tr.deinit();
        }
        self.font_manager.deinit();
        self.operand_stack.deinit(self.allocator);
        self.state_stack.deinit();
        self.path.deinit();
        self.rasterizer.deinit();
    }

    /// Set target bitmap for rendering
    pub fn setTarget(self: *Interpreter, bitmap: *Bitmap) void {
        self.target = bitmap;
    }

    /// Set resource provider
    pub fn setResources(self: *Interpreter, resources: ResourceProvider) void {
        self.resources = resources;
    }

    /// Initialize page transformation
    pub fn initPage(self: *Interpreter, width: f32, height: f32, dpi: f32) void {
        self.state_stack.reset();
        self.state_stack.initPageTransform(width, height, dpi);
        self.path.clear();
        self.operand_stack.clearRetainingCapacity();
    }

    /// Execute a content stream
    pub fn execute(self: *Interpreter, content: []const u8) !void {
        var pos: usize = 0;

        while (pos < content.len) {
            // Skip whitespace
            while (pos < content.len and isWhitespace(content[pos])) {
                pos += 1;
            }
            if (pos >= content.len) break;

            // Parse next token
            const token_result = try self.parseToken(content, pos);
            pos = token_result.next_pos;

            switch (token_result.token) {
                .operand => |op| {
                    try self.operand_stack.append(self.allocator, op);
                },
                .operator => |op_str| {
                    try self.executeOperator(op_str);
                },
                .comment => {}, // Ignore comments
            }
        }
    }

    const Token = union(enum) {
        operand: Operand,
        operator: []const u8,
        comment,
    };

    const TokenResult = struct {
        token: Token,
        next_pos: usize,
    };

    fn parseToken(self: *Interpreter, content: []const u8, start: usize) !TokenResult {
        _ = self;
        var pos = start;

        const c = content[pos];

        // Comment
        if (c == '%') {
            while (pos < content.len and content[pos] != '\n' and content[pos] != '\r') {
                pos += 1;
            }
            return .{ .token = .comment, .next_pos = pos };
        }

        // String literal (...)
        if (c == '(') {
            return parseStringLiteral(content, pos);
        }

        // Hex string <...>
        if (c == '<') {
            if (pos + 1 < content.len and content[pos + 1] == '<') {
                return .{ .token = .{ .operand = .dict_start }, .next_pos = pos + 2 };
            }
            return parseHexString(content, pos);
        }

        if (c == '>') {
            if (pos + 1 < content.len and content[pos + 1] == '>') {
                return .{ .token = .{ .operand = .dict_end }, .next_pos = pos + 2 };
            }
            return error.UnexpectedToken;
        }

        // Array markers
        if (c == '[') {
            return .{ .token = .{ .operand = .array_start }, .next_pos = pos + 1 };
        }
        if (c == ']') {
            return .{ .token = .{ .operand = .array_end }, .next_pos = pos + 1 };
        }

        // Name /...
        if (c == '/') {
            pos += 1;
            const name_start = pos;
            while (pos < content.len and !isDelimiter(content[pos]) and !isWhitespace(content[pos])) {
                pos += 1;
            }
            return .{
                .token = .{ .operand = .{ .name = content[name_start..pos] } },
                .next_pos = pos,
            };
        }

        // Number or operator
        if (c == '-' or c == '+' or c == '.' or (c >= '0' and c <= '9')) {
            return parseNumber(content, pos);
        }

        // Must be an operator (keyword)
        const op_start = pos;
        while (pos < content.len and !isDelimiter(content[pos]) and !isWhitespace(content[pos])) {
            pos += 1;
        }

        const op_str = content[op_start..pos];

        // Check for boolean
        if (std.mem.eql(u8, op_str, "true")) {
            return .{ .token = .{ .operand = .{ .boolean = true } }, .next_pos = pos };
        }
        if (std.mem.eql(u8, op_str, "false")) {
            return .{ .token = .{ .operand = .{ .boolean = false } }, .next_pos = pos };
        }

        return .{ .token = .{ .operator = op_str }, .next_pos = pos };
    }

    fn parseStringLiteral(content: []const u8, start: usize) !TokenResult {
        var pos = start + 1; // Skip '('
        var depth: u32 = 1;
        const str_start = pos;

        while (pos < content.len and depth > 0) {
            const c = content[pos];
            if (c == '\\' and pos + 1 < content.len) {
                pos += 2; // Skip escape sequence
            } else if (c == '(') {
                depth += 1;
                pos += 1;
            } else if (c == ')') {
                depth -= 1;
                if (depth > 0) pos += 1;
            } else {
                pos += 1;
            }
        }

        return .{
            .token = .{ .operand = .{ .string = content[str_start .. pos - 1] } },
            .next_pos = pos + 1,
        };
    }

    fn parseHexString(content: []const u8, start: usize) !TokenResult {
        var pos = start + 1; // Skip '<'
        const str_start = pos;

        while (pos < content.len and content[pos] != '>') {
            pos += 1;
        }

        return .{
            .token = .{ .operand = .{ .string = content[str_start..pos] } },
            .next_pos = pos + 1,
        };
    }

    fn parseNumber(content: []const u8, start: usize) !TokenResult {
        var pos = start;
        var has_dot = false;

        if (content[pos] == '-' or content[pos] == '+') pos += 1;

        while (pos < content.len) {
            const c = content[pos];
            if (c >= '0' and c <= '9') {
                pos += 1;
            } else if (c == '.' and !has_dot) {
                has_dot = true;
                pos += 1;
            } else {
                break;
            }
        }

        const num_str = content[start..pos];

        if (has_dot) {
            const val = std.fmt.parseFloat(f64, num_str) catch 0;
            return .{ .token = .{ .operand = .{ .real = val } }, .next_pos = pos };
        } else {
            const val = std.fmt.parseInt(i64, num_str, 10) catch 0;
            return .{ .token = .{ .operand = .{ .integer = val } }, .next_pos = pos };
        }
    }

    /// Execute a PDF operator
    fn executeOperator(self: *Interpreter, op_str: []const u8) !void {
        const op = Operator.fromString(op_str);
        const state = &self.state_stack.current;

        switch (op) {
            // === Graphics State ===
            .SaveState => try self.state_stack.save(),
            .RestoreState => self.state_stack.restore(),

            .ConcatMatrix => {
                const f_val = self.popFloat() orelse return;
                const e = self.popFloat() orelse return;
                const d = self.popFloat() orelse return;
                const c = self.popFloat() orelse return;
                const b = self.popFloat() orelse return;
                const a = self.popFloat() orelse return;

                state.concatMatrix(.{ .a = a, .b = b, .c = c, .d = d, .e = e, .f = f_val });
            },

            // === Path Construction ===
            .MoveTo => {
                const y = self.popFloat() orelse return;
                const x = self.popFloat() orelse return;
                try self.path.moveTo(x, y);
            },

            .LineTo => {
                const y = self.popFloat() orelse return;
                const x = self.popFloat() orelse return;
                try self.path.lineTo(x, y);
            },

            .CurveTo => {
                const y3 = self.popFloat() orelse return;
                const x3 = self.popFloat() orelse return;
                const y2 = self.popFloat() orelse return;
                const x2 = self.popFloat() orelse return;
                const y1 = self.popFloat() orelse return;
                const x1 = self.popFloat() orelse return;
                try self.path.curveTo(x1, y1, x2, y2, x3, y3);
            },

            .CurveToV => {
                const y3 = self.popFloat() orelse return;
                const x3 = self.popFloat() orelse return;
                const y2 = self.popFloat() orelse return;
                const x2 = self.popFloat() orelse return;
                try self.path.curveToV(x2, y2, x3, y3);
            },

            .CurveToY => {
                const y3 = self.popFloat() orelse return;
                const x3 = self.popFloat() orelse return;
                const y1 = self.popFloat() orelse return;
                const x1 = self.popFloat() orelse return;
                try self.path.curveToY(x1, y1, x3, y3);
            },

            .ClosePath => try self.path.closePath(),

            .Rectangle => {
                const h = self.popFloat() orelse return;
                const w = self.popFloat() orelse return;
                const y = self.popFloat() orelse return;
                const x = self.popFloat() orelse return;
                try self.path.rectangle(x, y, w, h);
            },

            // === Path Painting ===
            .Fill, .FillEvenOdd => {
                if (self.target) |target| {
                    const rule: FillRule = if (op == .FillEvenOdd) .EvenOdd else .NonZero;
                    try self.rasterizer.fill(target, &self.path, state.getFillColor(), rule, state.ctm);
                }
                self.path.clear();
            },

            .Stroke => {
                if (self.target) |target| {
                    try self.rasterizer.stroke(target, &self.path, state.getStrokeColor(), state.line_width, state.ctm);
                }
                self.path.clear();
            },

            .CloseStroke => {
                try self.path.closePath();
                if (self.target) |target| {
                    try self.rasterizer.stroke(target, &self.path, state.getStrokeColor(), state.line_width, state.ctm);
                }
                self.path.clear();
            },

            .FillStroke => {
                if (self.target) |target| {
                    try self.rasterizer.fill(target, &self.path, state.getFillColor(), .NonZero, state.ctm);
                    try self.rasterizer.stroke(target, &self.path, state.getStrokeColor(), state.line_width, state.ctm);
                }
                self.path.clear();
            },

            .CloseFillStroke => {
                try self.path.closePath();
                if (self.target) |target| {
                    try self.rasterizer.fill(target, &self.path, state.getFillColor(), .NonZero, state.ctm);
                    try self.rasterizer.stroke(target, &self.path, state.getStrokeColor(), state.line_width, state.ctm);
                }
                self.path.clear();
            },

            .EndPath => {
                self.path.clear();
            },

            // === Clipping ===
            .Clip, .ClipEvenOdd => {
                // Clipping path: the current path becomes the clipping region
                // The path is saved but not stroked or filled
                // Subsequent operations are clipped to this path
                // Note: Full clipping region management would require maintaining a clip stack
                // For now, we preserve the path for use in clipping subsequent operations
                // The path is not cleared until the graphics state is restored
            },

            // === Color ===
            .SetFillGray => {
                const g = self.popFloat() orelse return;
                state.setFillGray(g);
            },

            .SetStrokeGray => {
                const g = self.popFloat() orelse return;
                state.setStrokeGray(g);
            },

            .SetFillRGB => {
                const b = self.popFloat() orelse return;
                const g = self.popFloat() orelse return;
                const r = self.popFloat() orelse return;
                state.setFillRGB(r, g, b);
            },

            .SetStrokeRGB => {
                const b = self.popFloat() orelse return;
                const g = self.popFloat() orelse return;
                const r = self.popFloat() orelse return;
                state.setStrokeRGB(r, g, b);
            },

            .SetFillCMYK => {
                const k = self.popFloat() orelse return;
                const y = self.popFloat() orelse return;
                const m = self.popFloat() orelse return;
                const c = self.popFloat() orelse return;
                state.setFillCMYK(c, m, y, k);
            },

            .SetStrokeCMYK => {
                const k = self.popFloat() orelse return;
                const y = self.popFloat() orelse return;
                const m = self.popFloat() orelse return;
                const c = self.popFloat() orelse return;
                state.setStrokeCMYK(c, m, y, k);
            },

            .SetFillColorSpace, .SetStrokeColorSpace => {
                if (self.popName()) |cs_name| {
                    // Look up color space from resources or use standard name
                    if (self.resources) |res| {
                        if (res.getColorSpace(cs_name)) |cs_info| {
                            // Update the current color space
                            if (op == .SetFillColorSpace) {
                                state.fill_color.space = cs_info.family;
                            } else {
                                state.stroke_color.space = cs_info.family;
                            }
                        }
                    } else {
                        // Use standard color space names
                        const space = if (std.mem.eql(u8, cs_name, "DeviceGray"))
                            gs_mod.ColorSpace.DeviceGray
                        else if (std.mem.eql(u8, cs_name, "DeviceRGB"))
                            gs_mod.ColorSpace.DeviceRGB
                        else if (std.mem.eql(u8, cs_name, "DeviceCMYK"))
                            gs_mod.ColorSpace.DeviceCMYK
                        else
                            gs_mod.ColorSpace.DeviceGray; // Default fallback

                        if (op == .SetFillColorSpace) {
                            state.fill_color.space = space;
                        } else {
                            state.stroke_color.space = space;
                        }
                    }
                }
            },

            .SetFillColor, .SetFillColorN, .SetStrokeColor, .SetStrokeColorN => {
                // Pop color components based on current color space
                // For now, assume RGB
                const b = self.popFloat() orelse return;
                const g = self.popFloat() orelse return;
                const r = self.popFloat() orelse return;

                if (op == .SetFillColor or op == .SetFillColorN) {
                    state.setFillRGB(r, g, b);
                } else {
                    state.setStrokeRGB(r, g, b);
                }
            },

            // === Text ===
            .BeginText => {
                state.text.text_matrix = Matrix.identity;
                state.text.line_matrix = Matrix.identity;
            },

            .EndText => {},

            .MoveText => {
                const ty = self.popFloat() orelse return;
                const tx = self.popFloat() orelse return;
                state.textMove(tx, ty);
            },

            .MoveTextSetLeading => {
                const ty = self.popFloat() orelse return;
                const tx = self.popFloat() orelse return;
                state.text.leading = -ty;
                state.textMove(tx, ty);
            },

            .SetTextMatrix => {
                const f_val = self.popFloat() orelse return;
                const e = self.popFloat() orelse return;
                const d = self.popFloat() orelse return;
                const c = self.popFloat() orelse return;
                const b = self.popFloat() orelse return;
                const a = self.popFloat() orelse return;
                state.setTextMatrix(a, b, c, d, e, f_val);
            },

            .MoveToNextLine => state.textNewLine(),

            .SetCharSpacing => {
                state.text.char_spacing = self.popFloat() orelse return;
            },

            .SetWordSpacing => {
                state.text.word_spacing = self.popFloat() orelse return;
            },

            .SetHorizScale => {
                state.text.horiz_scale = self.popFloat() orelse return;
            },

            .SetTextLeading => {
                state.text.leading = self.popFloat() orelse return;
            },

            .SetFontSize => {
                const size = self.popFloat() orelse return;
                const name = self.popName() orelse return;
                state.text.font_name = name;
                state.text.font_size = size;
            },

            .SetTextRender => {
                const mode = self.popInt() orelse return;
                state.text.render_mode = @enumFromInt(@as(u8, @intCast(@mod(mode, 8))));
            },

            .SetTextRise => {
                state.text.rise = self.popFloat() orelse return;
            },

            .ShowText => {
                const text = self.popString() orelse return;
                self.renderText(text);
            },

            .ShowTextNextLine => {
                state.textNewLine();
                const text = self.popString() orelse return;
                self.renderText(text);
            },

            .ShowTextSpacing => {
                const text = self.popString() orelse return;
                const char_space = self.popFloat() orelse return;
                const word_space = self.popFloat() orelse return;
                state.text.word_spacing = word_space;
                state.text.char_spacing = char_space;
                state.textNewLine();
                self.renderText(text);
            },

            .ShowTextArray => {
                // TJ operator - array of strings and positioning adjustments
                self.handleShowTextArray();
            },

            // === XObjects ===
            .DoXObject => {
                const name = self.popName() orelse return;
                self.handleXObject(name);
            },

            // === Line properties ===
            else => {
                // Handle line width, dash pattern, etc.
                if (std.mem.eql(u8, op_str, "w")) {
                    state.line_width = self.popFloat() orelse return;
                } else if (std.mem.eql(u8, op_str, "J")) {
                    const cap = self.popInt() orelse return;
                    state.line_cap = @enumFromInt(@as(u8, @intCast(@mod(cap, 3))));
                } else if (std.mem.eql(u8, op_str, "j")) {
                    const join = self.popInt() orelse return;
                    state.line_join = @enumFromInt(@as(u8, @intCast(@mod(join, 3))));
                } else if (std.mem.eql(u8, op_str, "M")) {
                    state.miter_limit = self.popFloat() orelse return;
                } else if (std.mem.eql(u8, op_str, "d")) {
                    // Dash pattern: [array] phase (note: order is reversed on stack)
                    // Phase comes first when popped from stack
                    if (self.popFloat()) |phase| {
                        state.dash_pattern.phase = phase;
                        // Next item should be array - but we need to parse it from operand stack
                        // Array items were pushed but we'd need to collect them back
                        // For now, we handle the phase - full array parsing would require refactoring
                        // to handle array operands properly
                    }
                } else if (std.mem.eql(u8, op_str, "gs")) {
                    // Set graphics state from ExtGState dict
                    const gs_name = self.popName() orelse return;
                    self.applyExtGState(gs_name);
                }
                // Ignore unknown operators
            },
        }
    }

    fn renderText(self: *Interpreter, text: []const u8) void {
        if (self.render_text_callback) |callback| {
            if (self.target) |target| {
                callback(self.render_text_ctx.?, text, &self.state_stack.current, target);
            }
        } else {
            // Fallback: render text as simple rectangles
            self.renderTextFallback(text);
        }
    }

    /// Text renderer - uses font system when available, falls back to rectangles
    fn renderTextFallback(self: *Interpreter, text: []const u8) void {
        const target = self.target orelse return;
        const state = &self.state_stack.current;

        // Get text rendering color (use fill color for default render mode)
        const color = state.getFillColor();

        // Font size in points
        const font_size = state.text.font_size;
        if (font_size < 1) return;

        // Calculate text position: text_matrix is in user space, needs CTM transform
        const tm = state.text.text_matrix;
        const text_pos = tm.transformPoint(0, 0);
        const device_pos = state.ctm.transformPoint(text_pos.x, text_pos.y);

        // Calculate size in device pixels
        const scale_vec = state.ctm.transformVector(font_size, font_size);
        const size_px = @abs(scale_vec.y);

        // Ensure current font is registered
        const font_name = state.text.font_name orelse "_default";
        if (self.font_manager.getFont(font_name) == null) {
            // Register font based on resources
            self.registerFontFromResources(font_name);
        }

        // Try to use the text renderer
        if (self.text_renderer) |*tr| {
            tr.renderText(
                &self.font_manager,
                target,
                text,
                font_name,
                size_px,
                @as(i32, @intFromFloat(device_pos.x)),
                @as(i32, @intFromFloat(device_pos.y)),
                color,
            ) catch {
                // Fall back to rectangle rendering
                self.renderTextAsRectangles(text, font_size, state, target, color);
            };
        } else {
            self.renderTextAsRectangles(text, font_size, state, target, color);
        }

        // Update text matrix to advance past rendered text
        const char_count = self.estimateCharCount(text);
        const char_width = self.getAverageCharWidth(font_name, font_size);
        const total_width = @as(f32, @floatFromInt(char_count)) * (char_width + state.text.char_spacing);
        self.state_stack.current.text.text_matrix = Matrix.translation(total_width, 0).concat(tm);
    }

    /// Register a font from the resource provider
    fn registerFontFromResources(self: *Interpreter, font_name: []const u8) void {
        if (self.resources) |res| {
            if (res.getFont(font_name)) |info| {
                _ = self.font_manager.registerFont(
                    font_name,
                    info.base_font,
                    if (std.mem.eql(u8, info.subtype, "TrueType")) .TrueType else .Type1,
                    info.font_data,
                ) catch {};
            }
        } else {
            // No resources - register a default font
            _ = self.font_manager.registerFont(font_name, "Helvetica", .Type1, null) catch {};
        }
    }

    /// Get average character width for a font
    fn getAverageCharWidth(self: *Interpreter, font_name: []const u8, font_size: f32) f32 {
        if (self.font_manager.getFont(font_name)) |font| {
            // Get width of 'x' or use default
            const width_units = font.getCharWidth('x');
            return @as(f32, @floatFromInt(width_units)) * font_size / @as(f32, @floatFromInt(font.units_per_em));
        }
        return font_size * 0.5; // Default 50% of em
    }

    /// Estimate character count from text data
    fn estimateCharCount(self: *const Interpreter, text: []const u8) usize {
        _ = self;
        if (text.len == 0) return 0;

        // Check if hex-encoded (CID fonts)
        var is_hex = true;
        if (text.len >= 2 and text.len % 2 == 0) {
            for (text) |c| {
                if (!((c >= '0' and c <= '9') or (c >= 'A' and c <= 'F') or (c >= 'a' and c <= 'f'))) {
                    is_hex = false;
                    break;
                }
            }
        } else {
            is_hex = false;
        }

        if (is_hex) {
            // Hex string: assume 2-byte CID encoding
            const char_count = text.len / 4;
            return if (char_count == 0) text.len / 2 else char_count;
        }

        return text.len;
    }

    /// Fallback: render text as simple rectangles
    fn renderTextAsRectangles(
        self: *const Interpreter,
        text: []const u8,
        font_size: f32,
        state: *const GraphicsState,
        target: *Bitmap,
        color: Color,
    ) void {
        _ = self;

        const char_width = font_size * 0.6;
        const char_height = font_size * 0.8;
        const tm = state.text.text_matrix;

        // Estimate character count
        var char_count: usize = text.len;
        if (text.len >= 2 and text.len % 2 == 0) {
            var is_hex = true;
            for (text) |c| {
                if (!((c >= '0' and c <= '9') or (c >= 'A' and c <= 'F') or (c >= 'a' and c <= 'f'))) {
                    is_hex = false;
                    break;
                }
            }
            if (is_hex) {
                char_count = text.len / 4;
                if (char_count == 0) char_count = text.len / 2;
            }
        }

        var x_offset: f32 = 0;
        var i: usize = 0;
        while (i < char_count) : (i += 1) {
            const text_pos = tm.transformPoint(x_offset, 0);
            const device_pos = state.ctm.transformPoint(text_pos.x, text_pos.y);
            const size_vec = state.ctm.transformVector(char_width, char_height);
            const dev_width = @abs(size_vec.x);
            const dev_height = @abs(size_vec.y);

            const x_int = @as(i32, @intFromFloat(device_pos.x));
            const y_int = @as(i32, @intFromFloat(device_pos.y - dev_height));

            var y: i32 = y_int;
            while (y < y_int + @as(i32, @intFromFloat(dev_height))) : (y += 1) {
                if (y >= 0 and y < @as(i32, @intCast(target.height))) {
                    target.fillSpan(y, x_int, x_int + @as(i32, @intFromFloat(dev_width)) - 1, color);
                }
            }

            x_offset += char_width;
        }
    }

    fn handleShowTextArray(self: *Interpreter) void {
        // Find array bounds in operand stack
        var end_idx: ?usize = null;
        var i: usize = self.operand_stack.items.len;
        while (i > 0) {
            i -= 1;
            switch (self.operand_stack.items[i]) {
                .array_start => {
                    // Process array
                    var j = i + 1;
                    while (j < (end_idx orelse self.operand_stack.items.len)) : (j += 1) {
                        const item = self.operand_stack.items[j];
                        switch (item) {
                            .string => |s| self.renderText(s),
                            .integer, .real => {
                                // Text position adjustment (in thousandths of em)
                                const adj = item.asFloat() orelse 0;
                                // Adjust text position: convert from thousandths of em to user space
                                // Negative values move right, positive move left (in user space)
                                const adjustment = -adj / 1000.0 * self.state_stack.current.text.font_size;
                                self.state_stack.current.text.text_matrix = Matrix.translation(adjustment, 0).concat(self.state_stack.current.text.text_matrix);
                            },
                            else => {},
                        }
                    }
                    // Remove processed items
                    self.operand_stack.shrinkRetainingCapacity(i);
                    return;
                },
                .array_end => end_idx = i,
                else => {},
            }
        }
    }

    fn handleXObject(self: *Interpreter, name: []const u8) void {
        if (self.resources) |res| {
            if (res.getXObject(name)) |info| {
                switch (info.subtype) {
                    .Image => {
                        self.renderImage(info);
                    },
                    .Form => {
                        self.executeFormXObject(info);
                    },
                    .PS => {}, // PostScript - ignore
                }
            }
        }
    }

    /// Execute a Form XObject (nested content stream)
    fn executeFormXObject(self: *Interpreter, info: XObjectInfo) void {
        if (info.data.len == 0) return;

        // Save graphics state
        self.state_stack.save() catch return;

        // Apply Form's transformation matrix if present
        if (info.matrix) |m| {
            const form_matrix = Matrix{
                .a = m[0],
                .b = m[1],
                .c = m[2],
                .d = m[3],
                .e = m[4],
                .f = m[5],
            };
            // Concatenate form matrix with current CTM
            self.state_stack.current.ctm = form_matrix.concat(self.state_stack.current.ctm);
        }

        // Apply clipping from BBox if present
        // Form XObject has a bounding box that should act as a clipping region
        // For now we note this would need proper clipping support:
        // if (info.bbox) |bbox| {
        //     // Save current clipping region
        //     // Set new clipping region to intersection of current and bbox
        //     // Execute form content
        //     // Restore previous clipping region
        // }

        // Execute the form's content stream
        self.execute(info.data) catch {};

        // Restore graphics state
        self.state_stack.restore();
    }

    /// Render an image XObject
    fn renderImage(self: *Interpreter, info: XObjectInfo) void {
        const target = self.target orelse return;
        const state = &self.state_stack.current;

        // If there's a callback, use it
        if (self.render_image_callback) |callback| {
            callback(self.render_image_ctx.?, info, state, target);
            return;
        }

        // Default image rendering: decode and blit
        const width = info.width orelse return;
        const height = info.height orelse return;
        if (width == 0 or height == 0) return;

        // Get device coordinates for image placement
        // Image is placed in a 1x1 unit square, transformed by CTM
        const p0 = state.ctm.transformPoint(0, 0);
        const p1 = state.ctm.transformPoint(1, 0);
        const p2 = state.ctm.transformPoint(0, 1);

        // Calculate device dimensions
        const dev_width = @sqrt((p1.x - p0.x) * (p1.x - p0.x) + (p1.y - p0.y) * (p1.y - p0.y));
        const dev_height = @sqrt((p2.x - p0.x) * (p2.x - p0.x) + (p2.y - p0.y) * (p2.y - p0.y));

        // For now, render a placeholder rectangle
        const x_int = @as(i32, @intFromFloat(p0.x));
        const y_int = @as(i32, @intFromFloat(@min(p0.y, p0.y - dev_height)));
        const w_int = @as(i32, @intFromFloat(dev_width));
        const h_int = @as(i32, @intFromFloat(dev_height));

        // Draw gray placeholder for image
        const gray = Color.rgb(200, 200, 200);
        var y: i32 = y_int;
        while (y < y_int + h_int) : (y += 1) {
            if (y >= 0 and y < @as(i32, @intCast(target.height))) {
                target.fillSpan(y, x_int, x_int + w_int - 1, gray);
            }
        }
    }

    fn applyExtGState(self: *Interpreter, name: []const u8) void {
        if (self.resources) |res| {
            if (res.getExtGState(name)) |gs_info| {
                if (gs_info.stroke_alpha) |a| {
                    self.state_stack.current.stroke_alpha = a;
                }
                if (gs_info.fill_alpha) |a| {
                    self.state_stack.current.fill_alpha = a;
                }
                if (gs_info.blend_mode) |bm| {
                    self.state_stack.current.blend_mode = bm;
                }
            }
        }
    }

    // === Stack operations ===

    fn popFloat(self: *Interpreter) ?f32 {
        if (self.operand_stack.items.len > 0) {
            const op = self.operand_stack.pop().?;
            return op.asFloat();
        }
        return null;
    }

    fn popInt(self: *Interpreter) ?i64 {
        if (self.operand_stack.items.len > 0) {
            const op = self.operand_stack.pop().?;
            return op.asInt();
        }
        return null;
    }

    fn popName(self: *Interpreter) ?[]const u8 {
        if (self.operand_stack.items.len > 0) {
            const op = self.operand_stack.pop().?;
            return switch (op) {
                .name => |n| n,
                else => null,
            };
        }
        return null;
    }

    fn popString(self: *Interpreter) ?[]const u8 {
        if (self.operand_stack.items.len > 0) {
            const op = self.operand_stack.pop().?;
            return switch (op) {
                .string => |s| s,
                else => null,
            };
        }
        return null;
    }

    fn isWhitespace(c: u8) bool {
        return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0 or c == 12;
    }

    fn isDelimiter(c: u8) bool {
        return c == '(' or c == ')' or c == '<' or c == '>' or
            c == '[' or c == ']' or c == '{' or c == '}' or
            c == '/' or c == '%';
    }
};

// =============================================================================
// Tests
// =============================================================================

test "interpreter basic parsing" {
    var interp = Interpreter.init(std.testing.allocator);
    defer interp.deinit();

    var bmp = try Bitmap.init(std.testing.allocator, 100, 100);
    defer bmp.deinit();
    bmp.clear(Color.white);

    interp.setTarget(&bmp);
    interp.initPage(100, 100, 72);

    // Simple content stream: draw a black rectangle
    const content = "0 0 0 rg 10 10 80 80 re f";
    try interp.execute(content);

    // Check that rectangle was filled
    try std.testing.expectEqual(Color.black, bmp.getPixel(50, 50).?);
}

test "interpreter number parsing" {
    var interp = Interpreter.init(std.testing.allocator);
    defer interp.deinit();

    const content = "123 -45.67 0.5";
    try interp.execute(content);

    try std.testing.expectEqual(@as(usize, 3), interp.operand_stack.items.len);

    const op3 = interp.operand_stack.pop().?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), op3.asFloat().?, 0.001);

    const op2 = interp.operand_stack.pop().?;
    try std.testing.expectApproxEqAbs(@as(f32, -45.67), op2.asFloat().?, 0.01);

    const op1 = interp.operand_stack.pop().?;
    try std.testing.expectEqual(@as(i64, 123), op1.asInt().?);
}
