//! Presentation/Canvas Document Renderer
//!
//! Generates freeform documents like pitch decks, presentations, and
//! canvas-style layouts where elements are positioned absolutely.
//!
//! Features:
//! - Multiple pages with custom backgrounds
//! - Positioned text elements with font, size, color, alignment
//! - Tables with headers, styling, borders
//! - Images with positioning and sizing
//! - Shapes (rectangles, circles, lines)
//! - Bullet lists
//!
//! JSON Schema:
//! {
//!   "page_size": { "width": 1920, "height": 1080 },
//!   "pages": [
//!     {
//!       "background_color": "#1a1a2e",
//!       "elements": [
//!         { "type": "text", "content": "Title", "x": 100, "y": 100, ... },
//!         { "type": "table", "x": 100, "y": 200, "columns": [...], "rows": [...] },
//!         { "type": "image", "base64": "...", "x": 500, "y": 100, ... },
//!         { "type": "shape", "shape": "rectangle", "x": 50, "y": 50, ... }
//!       ]
//!     }
//!   ]
//! }

const std = @import("std");
const document = @import("document.zig");
const image_mod = @import("image.zig");

// =============================================================================
// Data Structures
// =============================================================================

pub const PageSize = struct {
    width: f32 = 1920, // Default to 1080p landscape
    height: f32 = 1080,

    pub const hd_landscape = PageSize{ .width = 1920, .height = 1080 };
    pub const hd_portrait = PageSize{ .width = 1080, .height = 1920 };
    pub const a4_landscape = PageSize{ .width = document.A4_HEIGHT, .height = document.A4_WIDTH };
    pub const a4_portrait = PageSize{ .width = document.A4_WIDTH, .height = document.A4_HEIGHT };
    pub const letter_landscape = PageSize{ .width = document.LETTER_HEIGHT, .height = document.LETTER_WIDTH };
    pub const letter_portrait = PageSize{ .width = document.LETTER_WIDTH, .height = document.LETTER_HEIGHT };
};

pub const TextAlign = enum {
    left,
    center,
    right,
};

pub const FontWeight = enum {
    normal,
    bold,
};

pub const FontStyle = enum {
    normal,
    italic,
};

pub const TextElement = struct {
    content: []const u8 = "",
    x: f32 = 0,
    y: f32 = 0,
    font_size: f32 = 24,
    font_weight: FontWeight = .normal,
    font_style: FontStyle = .normal,
    color: []const u8 = "#000000",
    text_align: TextAlign = .left,
    max_width: ?f32 = null, // For text wrapping
    line_height: f32 = 1.4,
};

pub const BulletList = struct {
    items: []const []const u8 = &[_][]const u8{},
    x: f32 = 0,
    y: f32 = 0,
    font_size: f32 = 18,
    color: []const u8 = "#000000",
    bullet_color: []const u8 = "#2563eb",
    line_spacing: f32 = 8,
    indent: f32 = 20,
};

pub const TableCell = struct {
    content: []const u8 = "",
    text_align: TextAlign = .left,
    color: ?[]const u8 = null, // Override cell color
    bg_color: ?[]const u8 = null, // Cell background
};

pub const TableElement = struct {
    x: f32 = 0,
    y: f32 = 0,
    columns: []const []const u8 = &[_][]const u8{}, // Column headers
    rows: []const []const TableCell = &[_][]const TableCell{}, // Row data
    column_widths: ?[]const f32 = null, // Optional fixed widths
    header_bg_color: []const u8 = "#2563eb",
    header_text_color: []const u8 = "#ffffff",
    row_bg_color: []const u8 = "#ffffff",
    alt_row_bg_color: ?[]const u8 = "#f8f9fa",
    text_color: []const u8 = "#000000",
    border_color: []const u8 = "#e0e0e0",
    border_width: f32 = 1,
    font_size: f32 = 14,
    header_font_size: f32 = 14,
    padding: f32 = 10,
    row_height: f32 = 36,
    header_height: f32 = 40,
};

pub const ImageElement = struct {
    base64: []const u8 = "",
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 100,
    height: f32 = 100,
    // If only one dimension specified, maintain aspect ratio
    maintain_aspect: bool = true,
};

pub const ShapeType = enum {
    rectangle,
    rounded_rectangle,
    circle,
    ellipse,
    line,
};

pub const ShapeElement = struct {
    shape: ShapeType = .rectangle,
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 100,
    height: f32 = 100,
    // For circles: x,y is center, width is radius
    // For lines: x,y is start, width,height is end point offset
    fill_color: ?[]const u8 = null,
    stroke_color: ?[]const u8 = "#000000",
    stroke_width: f32 = 1,
    corner_radius: f32 = 0, // For rounded_rectangle
    opacity: f32 = 1.0,
};

pub const ElementType = enum {
    text,
    bullet_list,
    table,
    image,
    shape,
};

pub const Element = union(ElementType) {
    text: TextElement,
    bullet_list: BulletList,
    table: TableElement,
    image: ImageElement,
    shape: ShapeElement,
};

pub const Page = struct {
    background_color: ?[]const u8 = null,
    elements: []const Element = &[_]Element{},
};

pub const PresentationData = struct {
    page_size: PageSize = .{},
    pages: []const Page = &[_]Page{},
    // Global styling defaults
    default_font_size: f32 = 24,
    default_text_color: []const u8 = "#000000",
    default_background: []const u8 = "#ffffff",
};

// =============================================================================
// Presentation Renderer
// =============================================================================

pub const PresentationRenderer = struct {
    allocator: std.mem.Allocator,
    doc: document.PdfDocument,
    data: PresentationData,
    content: ?*document.ContentStream = null,

    // Coordinate system: y=0 is top of page (we convert to PDF coordinates internally)
    page_height: f32 = 1080,

    pub fn init(allocator: std.mem.Allocator, data: PresentationData) PresentationRenderer {
        const doc = document.PdfDocument.init(allocator);

        return PresentationRenderer{
            .allocator = allocator,
            .doc = doc,
            .data = data,
            .page_height = data.page_size.height,
        };
    }

    pub fn deinit(self: *PresentationRenderer) void {
        // Free all allocated data from JSON parsing
        for (self.data.pages) |page| {
            for (page.elements) |elem| {
                switch (elem) {
                    .table => |table| {
                        if (table.columns.len > 0) {
                            self.allocator.free(@constCast(table.columns));
                        }
                        if (table.column_widths) |widths| {
                            if (widths.len > 0) {
                                self.allocator.free(@constCast(widths));
                            }
                        }
                        for (table.rows) |row| {
                            if (row.len > 0) {
                                self.allocator.free(@constCast(row));
                            }
                        }
                        if (table.rows.len > 0) {
                            self.allocator.free(@constCast(table.rows));
                        }
                    },
                    .bullet_list => |list| {
                        if (list.items.len > 0) {
                            self.allocator.free(@constCast(list.items));
                        }
                    },
                    else => {},
                }
            }
            if (page.elements.len > 0) {
                self.allocator.free(@constCast(page.elements));
            }
        }
        if (self.data.pages.len > 0) {
            self.allocator.free(@constCast(self.data.pages));
        }

        self.doc.deinit();
    }

    /// Convert from top-down Y coordinate to PDF bottom-up coordinate
    fn toPdfY(self: *PresentationRenderer, y: f32) f32 {
        return self.page_height - y;
    }

    /// Render the presentation and return PDF bytes
    pub fn render(self: *PresentationRenderer) ![]const u8 {
        self.doc.setPageSize(.{
            .width = self.data.page_size.width,
            .height = self.data.page_size.height,
        });

        for (self.data.pages) |page| {
            try self.renderPage(page);
        }

        return try self.doc.build();
    }

    fn renderPage(self: *PresentationRenderer, page: Page) !void {
        var content = document.ContentStream.init(self.allocator);
        defer content.deinit();

        // Draw background
        const bg_color = page.background_color orelse self.data.default_background;
        const color = document.Color.fromHex(bg_color);
        try content.drawRect(0, 0, self.data.page_size.width, self.data.page_size.height, color, null);

        // Get font IDs we'll need
        const font_regular = self.doc.getFontId(.helvetica);
        const font_bold = self.doc.getFontId(.helvetica_bold);
        const font_italic = self.doc.getFontId(.helvetica_oblique);
        const font_bold_italic = self.doc.getFontId(.helvetica_bold_oblique);

        // Render elements in order (later elements draw on top)
        for (page.elements) |element| {
            switch (element) {
                .text => |text| try self.renderText(&content, text, font_regular, font_bold, font_italic, font_bold_italic),
                .bullet_list => |list| try self.renderBulletList(&content, list, font_regular),
                .table => |table| try self.renderTable(&content, table, font_regular, font_bold),
                .image => |img| try self.renderImage(&content, img),
                .shape => |shape| try self.renderShape(&content, shape),
            }
        }

        try self.doc.addPage(&content);
    }

    fn renderText(
        self: *PresentationRenderer,
        content: *document.ContentStream,
        text: TextElement,
        font_regular: []const u8,
        font_bold: []const u8,
        font_italic: []const u8,
        font_bold_italic: []const u8,
    ) !void {
        const color = document.Color.fromHex(text.color);

        const font_id = switch (text.font_weight) {
            .bold => switch (text.font_style) {
                .italic => font_bold_italic,
                .normal => font_bold,
            },
            .normal => switch (text.font_style) {
                .italic => font_italic,
                .normal => font_regular,
            },
        };

        const font_enum: document.Font = switch (text.font_weight) {
            .bold => switch (text.font_style) {
                .italic => .helvetica_bold_oblique,
                .normal => .helvetica_bold,
            },
            .normal => switch (text.font_style) {
                .italic => .helvetica_oblique,
                .normal => .helvetica,
            },
        };

        // Y coordinate represents the text baseline position
        // (decorative lines placed below Y will appear below the text)
        const pdf_y = self.toPdfY(text.y);

        if (text.max_width) |max_w| {
            // Word-wrapped text
            try self.renderWrappedText(content, text.content, text.x, pdf_y, max_w, text.font_size, text.line_height, text.text_align, font_enum, font_id, color);
        } else {
            // Single line - handle alignment
            var x = text.x;
            if (text.text_align != .left) {
                const width = self.measureTextWidth(text.content, font_enum, text.font_size);
                switch (text.text_align) {
                    .center => x = text.x - width / 2,
                    .right => x = text.x - width,
                    .left => {},
                }
            }
            try content.drawText(text.content, x, pdf_y, font_id, text.font_size, color);
        }
    }

    fn renderWrappedText(
        self: *PresentationRenderer,
        stream: *document.ContentStream,
        text_content: []const u8,
        x: f32,
        start_y: f32,
        max_width: f32,
        font_size: f32,
        line_height: f32,
        text_align_param: TextAlign,
        font: document.Font,
        font_id: []const u8,
        color: document.Color,
    ) !void {
        var y = start_y;
        const line_spacing = font_size * line_height;

        // Simple word wrapping
        var line_start: usize = 0;
        var last_space: usize = 0;
        var current_width: f32 = 0;

        for (text_content, 0..) |char, i| {
            if (char == ' ') {
                last_space = i;
            }
            if (char == '\n') {
                // Explicit line break
                const line = text_content[line_start..i];
                try self.drawAlignedLine(stream, line, x, y, max_width, text_align_param, font, font_id, font_size, color);
                y -= line_spacing;
                line_start = i + 1;
                current_width = 0;
                continue;
            }

            current_width += @as(f32, @floatFromInt(font.charWidth(char))) * font_size / 1000.0;

            if (current_width > max_width and last_space > line_start) {
                // Wrap at last space
                const line = text_content[line_start..last_space];
                try self.drawAlignedLine(stream, line, x, y, max_width, text_align_param, font, font_id, font_size, color);
                y -= line_spacing;
                line_start = last_space + 1;
                current_width = self.measureTextWidth(text_content[line_start .. i + 1], font, font_size);
            }
        }

        // Draw remaining text
        if (line_start < text_content.len) {
            const line = text_content[line_start..];
            try self.drawAlignedLine(stream, line, x, y, max_width, text_align_param, font, font_id, font_size, color);
        }
    }

    fn drawAlignedLine(
        self: *PresentationRenderer,
        stream: *document.ContentStream,
        line: []const u8,
        x: f32,
        y: f32,
        max_width: f32,
        text_align_param: TextAlign,
        font: document.Font,
        font_id: []const u8,
        font_size: f32,
        color: document.Color,
    ) !void {
        const width = self.measureTextWidth(line, font, font_size);
        const draw_x = switch (text_align_param) {
            .left => x,
            .center => x + (max_width - width) / 2,
            .right => x + max_width - width,
        };
        try stream.drawText(line, draw_x, y, font_id, font_size, color);
    }

    fn measureTextWidth(self: *PresentationRenderer, text: []const u8, font: document.Font, size: f32) f32 {
        _ = self;
        var width: f32 = 0;
        for (text) |char| {
            width += @as(f32, @floatFromInt(font.charWidth(char))) * size / 1000.0;
        }
        return width;
    }

    fn renderBulletList(
        self: *PresentationRenderer,
        stream: *document.ContentStream,
        list: BulletList,
        font_id: []const u8,
    ) !void {
        // Y is baseline position for first item
        var y = self.toPdfY(list.y);

        for (list.items) |item| {
            // Draw bullet
            const bullet_color = document.Color.fromHex(list.bullet_color);
            try stream.drawText("\xe2\x80\xa2", list.x, y, font_id, list.font_size, bullet_color); // UTF-8 bullet

            // Draw text
            const text_color = document.Color.fromHex(list.color);
            try stream.drawText(item, list.x + list.indent, y, font_id, list.font_size, text_color);

            y -= list.font_size + list.line_spacing;
        }
    }

    fn renderTable(
        self: *PresentationRenderer,
        stream: *document.ContentStream,
        table: TableElement,
        font_regular: []const u8,
        font_bold: []const u8,
    ) !void {
        const num_cols = table.columns.len;
        if (num_cols == 0) return;

        // Calculate column widths
        var col_widths: [32]f32 = undefined;
        var total_width: f32 = 0;

        if (table.column_widths) |widths| {
            for (widths, 0..) |w, i| {
                if (i >= num_cols) break;
                col_widths[i] = w;
                total_width += w;
            }
        } else {
            // Auto-calculate equal widths (default 150 per column)
            const default_width: f32 = 150;
            for (0..num_cols) |i| {
                col_widths[i] = default_width;
                total_width += default_width;
            }
        }

        var y = self.toPdfY(table.y);

        // Draw header row
        try self.renderTableRow(
            stream,
            table,
            table.columns,
            col_widths[0..num_cols],
            table.x,
            y,
            table.header_height,
            table.header_bg_color,
            table.header_text_color,
            table.header_font_size,
            font_bold,
        );
        y -= table.header_height;

        // Draw data rows
        for (table.rows, 0..) |row, row_idx| {
            const bg_color = if (table.alt_row_bg_color) |alt| blk: {
                break :blk if (row_idx % 2 == 1) alt else table.row_bg_color;
            } else table.row_bg_color;

            // Extract cell contents
            var contents: [32][]const u8 = undefined;
            for (row, 0..) |cell, i| {
                if (i >= num_cols) break;
                contents[i] = cell.content;
            }

            try self.renderTableRow(
                stream,
                table,
                contents[0..@min(row.len, num_cols)],
                col_widths[0..num_cols],
                table.x,
                y,
                table.row_height,
                bg_color,
                table.text_color,
                table.font_size,
                font_regular,
            );
            y -= table.row_height;
        }

        // Draw outer border
        const border_color = document.Color.fromHex(table.border_color);
        const table_height = table.header_height + @as(f32, @floatFromInt(table.rows.len)) * table.row_height;
        try stream.drawRect(table.x, self.toPdfY(table.y) - table_height, total_width, table_height, null, border_color);
    }

    fn renderTableRow(
        self: *PresentationRenderer,
        stream: *document.ContentStream,
        table: TableElement,
        cells: []const []const u8,
        col_widths: []const f32,
        x: f32,
        y: f32,
        height: f32,
        bg_color: []const u8,
        text_color: []const u8,
        font_size: f32,
        font_id: []const u8,
    ) !void {
        _ = self;
        var cell_x = x;

        for (cells, 0..) |cell_content, i| {
            const width = col_widths[i];

            // Draw cell background
            const bg = document.Color.fromHex(bg_color);
            try stream.drawRect(cell_x, y - height, width, height, bg, null);

            // Draw cell border
            const border = document.Color.fromHex(table.border_color);
            try stream.drawRect(cell_x, y - height, width, height, null, border);

            // Draw cell text
            const text_c = document.Color.fromHex(text_color);
            const text_y = y - height / 2 - font_size / 3;
            try stream.drawText(cell_content, cell_x + table.padding, text_y, font_id, font_size, text_c);

            cell_x += width;
        }
    }

    fn renderImage(
        self: *PresentationRenderer,
        stream: *document.ContentStream,
        img: ImageElement,
    ) !void {
        if (img.base64.len == 0) return;

        // Decode base64 and load image
        const result = image_mod.loadImageFromBase64(self.allocator, img.base64) catch return;
        defer self.allocator.free(result.decoded_bytes);

        // Add image to document and get ID
        const image_id = self.doc.addImage(result.image) catch return;

        const pdf_y = self.toPdfY(img.y) - img.height;
        try stream.drawImage(image_id, img.x, pdf_y, img.width, img.height);
    }

    fn renderShape(
        self: *PresentationRenderer,
        stream: *document.ContentStream,
        shape: ShapeElement,
    ) !void {
        const fill_color: ?document.Color = if (shape.fill_color) |fill| document.Color.fromHex(fill) else null;
        const stroke_color: ?document.Color = if (shape.stroke_color) |stroke| document.Color.fromHex(stroke) else null;

        const pdf_y = self.toPdfY(shape.y);

        switch (shape.shape) {
            .rectangle, .rounded_rectangle => {
                // Draw rectangle (rounded corners not yet implemented)
                try stream.drawRect(shape.x, pdf_y - shape.height, shape.width, shape.height, fill_color, stroke_color);
            },
            .circle => {
                // x,y is center, width is diameter
                const radius = shape.width / 2;
                try stream.drawCircle(shape.x, pdf_y, radius, fill_color, stroke_color);
            },
            .ellipse => {
                // Approximate ellipse with rectangle for now
                try stream.drawRect(shape.x, pdf_y - shape.height, shape.width, shape.height, fill_color, stroke_color);
            },
            .line => {
                // x,y is start, width/height is end offset
                if (stroke_color) |sc| {
                    try stream.drawLine(shape.x, pdf_y, shape.x + shape.width, pdf_y - shape.height, sc, shape.stroke_width);
                }
            },
        }
    }
};

// =============================================================================
// JSON Parsing
// =============================================================================

pub fn generatePresentationFromJson(allocator: std.mem.Allocator, json_str: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const root = parsed.value;
    const obj = root.object;

    // Parse page size
    var page_size = PageSize{};
    if (obj.get("page_size")) |ps| {
        if (ps.object.get("width")) |w| page_size.width = @floatCast(getNumber(w));
        if (ps.object.get("height")) |h| page_size.height = @floatCast(getNumber(h));
    }

    // Parse pages
    var pages: std.ArrayListUnmanaged(Page) = .empty;
    defer pages.deinit(allocator);

    if (obj.get("pages")) |pages_arr| {
        for (pages_arr.array.items) |page_val| {
            const page = try parsePage(allocator, page_val);
            try pages.append(allocator, page);
        }
    }

    const data = PresentationData{
        .page_size = page_size,
        .pages = try pages.toOwnedSlice(allocator),
    };

    var renderer = PresentationRenderer.init(allocator, data);
    defer renderer.deinit();

    const pdf_bytes = try renderer.render();
    // Duplicate the bytes before renderer.deinit() frees the internal buffer
    return try allocator.dupe(u8, pdf_bytes);
}

fn parsePage(allocator: std.mem.Allocator, page_val: std.json.Value) !Page {
    const page_obj = page_val.object;

    var background_color: ?[]const u8 = null;
    if (page_obj.get("background_color")) |bg| {
        background_color = bg.string;
    }

    var elements: std.ArrayListUnmanaged(Element) = .empty;
    defer elements.deinit(allocator);

    if (page_obj.get("elements")) |elem_arr| {
        for (elem_arr.array.items) |elem_val| {
            if (try parseElement(allocator, elem_val)) |elem| {
                try elements.append(allocator, elem);
            }
        }
    }

    return Page{
        .background_color = background_color,
        .elements = try elements.toOwnedSlice(allocator),
    };
}

fn parseElement(allocator: std.mem.Allocator, elem_val: std.json.Value) !?Element {
    const obj = elem_val.object;

    const elem_type = obj.get("type") orelse return null;
    const type_str = elem_type.string;

    if (std.mem.eql(u8, type_str, "text")) {
        return Element{ .text = try parseTextElement(obj) };
    } else if (std.mem.eql(u8, type_str, "bullet_list")) {
        return Element{ .bullet_list = try parseBulletList(allocator, obj) };
    } else if (std.mem.eql(u8, type_str, "table")) {
        return Element{ .table = try parseTableElement(allocator, obj) };
    } else if (std.mem.eql(u8, type_str, "image")) {
        return Element{ .image = try parseImageElement(obj) };
    } else if (std.mem.eql(u8, type_str, "shape")) {
        return Element{ .shape = try parseShapeElement(obj) };
    }

    return null;
}

fn parseTextElement(obj: std.json.ObjectMap) !TextElement {
    var text = TextElement{};

    if (obj.get("content")) |c| text.content = c.string;
    if (obj.get("x")) |x| text.x = @floatCast(getNumber(x));
    if (obj.get("y")) |y| text.y = @floatCast(getNumber(y));
    if (obj.get("font_size")) |fs| text.font_size = @floatCast(getNumber(fs));
    if (obj.get("color")) |c| text.color = c.string;
    if (obj.get("max_width")) |mw| text.max_width = @floatCast(getNumber(mw));
    if (obj.get("line_height")) |lh| text.line_height = @floatCast(getNumber(lh));

    if (obj.get("font_weight")) |fw| {
        if (std.mem.eql(u8, fw.string, "bold")) text.font_weight = .bold;
    }
    if (obj.get("font_style")) |fs| {
        if (std.mem.eql(u8, fs.string, "italic")) text.font_style = .italic;
    }
    if (obj.get("align")) |a| {
        if (std.mem.eql(u8, a.string, "center")) text.text_align = .center;
        if (std.mem.eql(u8, a.string, "right")) text.text_align = .right;
    }

    return text;
}

fn parseBulletList(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !BulletList {
    var list = BulletList{};

    if (obj.get("x")) |x| list.x = @floatCast(getNumber(x));
    if (obj.get("y")) |y| list.y = @floatCast(getNumber(y));
    if (obj.get("font_size")) |fs| list.font_size = @floatCast(getNumber(fs));
    if (obj.get("color")) |c| list.color = c.string;
    if (obj.get("bullet_color")) |bc| list.bullet_color = bc.string;
    if (obj.get("line_spacing")) |ls| list.line_spacing = @floatCast(getNumber(ls));
    if (obj.get("indent")) |i| list.indent = @floatCast(getNumber(i));

    if (obj.get("items")) |items_arr| {
        var items: std.ArrayListUnmanaged([]const u8) = .empty;
        for (items_arr.array.items) |item| {
            try items.append(allocator, item.string);
        }
        list.items = try items.toOwnedSlice(allocator);
    }

    return list;
}

fn parseTableElement(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !TableElement {
    var table = TableElement{};

    if (obj.get("x")) |x| table.x = @floatCast(getNumber(x));
    if (obj.get("y")) |y| table.y = @floatCast(getNumber(y));
    if (obj.get("font_size")) |fs| table.font_size = @floatCast(getNumber(fs));
    if (obj.get("header_font_size")) |hfs| table.header_font_size = @floatCast(getNumber(hfs));
    if (obj.get("header_bg_color")) |c| table.header_bg_color = c.string;
    if (obj.get("header_text_color")) |c| table.header_text_color = c.string;
    if (obj.get("row_bg_color")) |c| table.row_bg_color = c.string;
    if (obj.get("text_color")) |c| table.text_color = c.string;
    if (obj.get("border_color")) |c| table.border_color = c.string;
    if (obj.get("border_width")) |bw| table.border_width = @floatCast(getNumber(bw));
    if (obj.get("padding")) |p| table.padding = @floatCast(getNumber(p));
    if (obj.get("row_height")) |rh| table.row_height = @floatCast(getNumber(rh));
    if (obj.get("header_height")) |hh| table.header_height = @floatCast(getNumber(hh));

    if (obj.get("alt_row_bg_color")) |c| {
        table.alt_row_bg_color = c.string;
    }

    // Parse columns
    if (obj.get("columns")) |cols_arr| {
        var cols: std.ArrayListUnmanaged([]const u8) = .empty;
        for (cols_arr.array.items) |col| {
            try cols.append(allocator, col.string);
        }
        table.columns = try cols.toOwnedSlice(allocator);
    }

    // Parse column widths
    if (obj.get("column_widths")) |widths_arr| {
        var widths: std.ArrayListUnmanaged(f32) = .empty;
        for (widths_arr.array.items) |w| {
            try widths.append(allocator, @floatCast(getNumber(w)));
        }
        table.column_widths = try widths.toOwnedSlice(allocator);
    }

    // Parse rows
    if (obj.get("rows")) |rows_arr| {
        var rows: std.ArrayListUnmanaged([]const TableCell) = .empty;
        for (rows_arr.array.items) |row_val| {
            var cells: std.ArrayListUnmanaged(TableCell) = .empty;
            for (row_val.array.items) |cell_val| {
                // Cell can be a string or an object
                switch (cell_val) {
                    .string => |s| try cells.append(allocator, TableCell{ .content = s }),
                    .object => |cell_obj| {
                        var cell = TableCell{};
                        if (cell_obj.get("content")) |c| cell.content = c.string;
                        if (cell_obj.get("color")) |c| cell.color = c.string;
                        if (cell_obj.get("bg_color")) |c| cell.bg_color = c.string;
                        if (cell_obj.get("align")) |a| {
                            if (std.mem.eql(u8, a.string, "center")) cell.text_align = .center;
                            if (std.mem.eql(u8, a.string, "right")) cell.text_align = .right;
                        }
                        try cells.append(allocator, cell);
                    },
                    else => {},
                }
            }
            try rows.append(allocator, try cells.toOwnedSlice(allocator));
        }
        table.rows = try rows.toOwnedSlice(allocator);
    }

    return table;
}

fn parseImageElement(obj: std.json.ObjectMap) !ImageElement {
    var img = ImageElement{};

    if (obj.get("base64")) |b| img.base64 = b.string;
    if (obj.get("x")) |x| img.x = @floatCast(getNumber(x));
    if (obj.get("y")) |y| img.y = @floatCast(getNumber(y));
    if (obj.get("width")) |w| img.width = @floatCast(getNumber(w));
    if (obj.get("height")) |h| img.height = @floatCast(getNumber(h));

    return img;
}

fn parseShapeElement(obj: std.json.ObjectMap) !ShapeElement {
    var shape = ShapeElement{};

    if (obj.get("x")) |x| shape.x = @floatCast(getNumber(x));
    if (obj.get("y")) |y| shape.y = @floatCast(getNumber(y));
    if (obj.get("width")) |w| shape.width = @floatCast(getNumber(w));
    if (obj.get("height")) |h| shape.height = @floatCast(getNumber(h));
    if (obj.get("fill_color")) |c| shape.fill_color = c.string;
    if (obj.get("stroke_color")) |c| shape.stroke_color = c.string;
    if (obj.get("stroke_width")) |sw| shape.stroke_width = @floatCast(getNumber(sw));
    if (obj.get("corner_radius")) |cr| shape.corner_radius = @floatCast(getNumber(cr));
    if (obj.get("opacity")) |o| shape.opacity = @floatCast(getNumber(o));

    if (obj.get("shape")) |s| {
        if (std.mem.eql(u8, s.string, "rectangle")) shape.shape = .rectangle;
        if (std.mem.eql(u8, s.string, "rounded_rectangle")) shape.shape = .rounded_rectangle;
        if (std.mem.eql(u8, s.string, "circle")) shape.shape = .circle;
        if (std.mem.eql(u8, s.string, "ellipse")) shape.shape = .ellipse;
        if (std.mem.eql(u8, s.string, "line")) shape.shape = .line;
    }

    return shape;
}

fn getNumber(val: std.json.Value) f64 {
    return switch (val) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => 0,
    };
}
