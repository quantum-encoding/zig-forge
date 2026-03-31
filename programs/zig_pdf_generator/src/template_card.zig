//! Template Card Renderer
//!
//! Generates visually appealing template cards for the Quantum Encoding
//! image generation template system. Each card serves dual purpose:
//!
//! 1. **Visual** — Branded dark-theme A4 card suitable for sharing on
//!    social media or printing. Shows template name, description, example
//!    image, style prefix/suffix, tags, and author info.
//!
//! 2. **Machine-readable** — Embeds the full template JSON payload both
//!    as a QR code (for camera-based import) and in PDF /Info metadata
//!    under the /QE_TPL key (for programmatic extraction).
//!
//! Architecture follows proposal.zig (auto-layout renderer with branded styling).

const std = @import("std");
const document = @import("document.zig");
const image = @import("image.zig");
const qrcode = @import("qrcode.zig");

// =============================================================================
// Base64 Encoder (for QR payload and metadata)
// =============================================================================

const b64_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

fn base64Encode(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    if (data.len == 0) return try allocator.alloc(u8, 0);

    const out_len = ((data.len + 2) / 3) * 4;
    var output = try allocator.alloc(u8, out_len);
    var o: usize = 0;
    var i: usize = 0;

    while (i + 3 <= data.len) : (i += 3) {
        const b0: u32 = data[i];
        const b1: u32 = data[i + 1];
        const b2: u32 = data[i + 2];
        const triple = (b0 << 16) | (b1 << 8) | b2;
        output[o] = b64_alphabet[@as(u6, @truncate(triple >> 18))];
        output[o + 1] = b64_alphabet[@as(u6, @truncate(triple >> 12))];
        output[o + 2] = b64_alphabet[@as(u6, @truncate(triple >> 6))];
        output[o + 3] = b64_alphabet[@as(u6, @truncate(triple))];
        o += 4;
    }

    const remaining = data.len - i;
    if (remaining == 1) {
        const b0: u32 = data[i];
        const triple = b0 << 16;
        output[o] = b64_alphabet[@as(u6, @truncate(triple >> 18))];
        output[o + 1] = b64_alphabet[@as(u6, @truncate(triple >> 12))];
        output[o + 2] = '=';
        output[o + 3] = '=';
    } else if (remaining == 2) {
        const b0: u32 = data[i];
        const b1: u32 = data[i + 1];
        const triple = (b0 << 16) | (b1 << 8);
        output[o] = b64_alphabet[@as(u6, @truncate(triple >> 18))];
        output[o + 1] = b64_alphabet[@as(u6, @truncate(triple >> 12))];
        output[o + 2] = b64_alphabet[@as(u6, @truncate(triple >> 6))];
        output[o + 3] = '=';
    }

    return output;
}

// =============================================================================
// Data Structures
// =============================================================================

pub const TemplateCardData = struct {
    // Template payload (embedded in QR + metadata)
    format: []const u8 = "QE-TPL-V1",
    template_name: []const u8 = "",
    template_description: []const u8 = "",
    template_prefix: []const u8 = "",
    template_suffix: []const u8 = "",
    template_author: []const u8 = "",
    template_tags: []const []const u8 = &[_][]const u8{},
    template_example_prompt: []const u8 = "",

    // Rendering-only fields (not embedded in QR/metadata)
    example_image_base64: ?[]const u8 = null,
    primary_color: []const u8 = "#00BCD4",
    secondary_color: []const u8 = "#1a1a2e",
    created_at: []const u8 = "",
};

// =============================================================================
// Template Card Renderer
// =============================================================================

pub const TemplateCardRenderer = struct {
    allocator: std.mem.Allocator,
    doc: document.PdfDocument,
    data: TemplateCardData,

    // Fonts
    font_regular: []const u8 = "F0",
    font_bold: []const u8 = "F1",
    font_courier: []const u8 = "F4",

    // Layout
    current_y: f32 = 0,
    margin_left: f32 = 40,
    margin_right: f32 = 40,
    page_width: f32 = document.A4_WIDTH,
    page_height: f32 = document.A4_HEIGHT,
    usable_width: f32 = 0,

    // Decoded resources
    example_decoded: ?[]u8 = null,
    example_pixels: ?[]u8 = null,
    example_id: ?[]const u8 = null,
    qr_pixels: ?[]u8 = null,
    qr_id: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, data: TemplateCardData) TemplateCardRenderer {
        var renderer = TemplateCardRenderer{
            .allocator = allocator,
            .doc = document.PdfDocument.init(allocator),
            .data = data,
        };

        renderer.usable_width = renderer.page_width - renderer.margin_left - renderer.margin_right;
        renderer.font_regular = renderer.doc.getFontId(.helvetica);
        renderer.font_bold = renderer.doc.getFontId(.helvetica_bold);
        renderer.font_courier = renderer.doc.getFontId(.courier);
        renderer.current_y = renderer.page_height - renderer.margin_left;

        return renderer;
    }

    pub fn deinit(self: *TemplateCardRenderer) void {
        if (self.example_decoded) |d| self.allocator.free(d);
        if (self.qr_pixels) |d| self.allocator.free(d);
        self.doc.deinit();
    }

    // ─── Colors ─────────────────────────────────────────────────────────

    fn primaryColor(self: *const TemplateCardRenderer) document.Color {
        return document.Color.fromHex(self.data.primary_color);
    }

    fn bgColor(self: *const TemplateCardRenderer) document.Color {
        return document.Color.fromHex(self.data.secondary_color);
    }

    const text_white = document.Color{ .r = 0.93, .g = 0.93, .b = 0.93 };
    const text_gray = document.Color{ .r = 0.65, .g = 0.65, .b = 0.7 };
    const text_dark_gray = document.Color{ .r = 0.45, .g = 0.45, .b = 0.5 };
    const label_cyan = document.Color.fromHex("#00BCD4");

    // ─── Header Bar ─────────────────────────────────────────────────────

    fn renderHeaderBar(self: *TemplateCardRenderer, content: *document.ContentStream) !void {
        const primary = self.primaryColor();
        const bar_height: f32 = 36;
        const bar_y = self.page_height - bar_height;

        // Colored header bar
        try content.drawRect(0, bar_y, self.page_width, bar_height, primary, null);

        // Header text
        const header_text = "QUANTUM ENCODING TEMPLATE LIBRARY";
        const font = document.Font.helvetica_bold;
        const text_width = font.measureText(header_text, 10);
        const text_x = (self.page_width - text_width) / 2;
        try content.drawText(header_text, text_x, bar_y + 13, self.font_bold, 10, document.Color.white);

        self.current_y = bar_y - 30;
    }

    // ─── Template Name + Description ────────────────────────────────────

    fn renderTemplateName(self: *TemplateCardRenderer, content: *document.ContentStream) !void {
        const primary = self.primaryColor();

        // Template name (large, centered)
        if (self.data.template_name.len > 0) {
            const name_font = document.Font.helvetica_bold;
            const name_width = name_font.measureText(self.data.template_name, 22);
            const name_x = (self.page_width - name_width) / 2;
            try content.drawText(self.data.template_name, name_x, self.current_y, self.font_bold, 22, primary);
            self.current_y -= 12;
        }

        // Thin accent line
        const line_width: f32 = 200;
        const line_x = (self.page_width - line_width) / 2;
        try content.drawLine(line_x, self.current_y, line_x + line_width, self.current_y, primary, 0.5);
        self.current_y -= 16;

        // Description (centered, light gray)
        if (self.data.template_description.len > 0) {
            const desc_font = document.Font.helvetica;
            var wrapped = try document.wrapText(self.allocator, self.data.template_description, desc_font, 11, self.usable_width - 40);
            defer wrapped.deinit();

            for (wrapped.lines) |line| {
                const line_w = desc_font.measureText(line, 11);
                const lx = (self.page_width - line_w) / 2;
                try content.drawText(line, lx, self.current_y, self.font_regular, 11, text_gray);
                self.current_y -= 15;
            }
        }

        self.current_y -= 10;
    }

    // ─── Example Image ──────────────────────────────────────────────────

    fn renderExampleImage(self: *TemplateCardRenderer, content: *document.ContentStream) !void {
        if (self.example_id) |eid| {
            const max_img_width: f32 = 400;
            const max_img_height: f32 = 280;

            // Center the image
            const img_x = (self.page_width - max_img_width) / 2;
            const img_y = self.current_y - max_img_height;

            // Subtle border
            const border_color = document.Color{ .r = 0.3, .g = 0.3, .b = 0.35 };
            try content.drawRect(img_x - 1, img_y - 1, max_img_width + 2, max_img_height + 2, null, border_color);

            try content.drawImage(eid, img_x, img_y, max_img_width, max_img_height);
            self.current_y = img_y - 18;
        }
    }

    // ─── Style Text (Prefix / Suffix / Example) ─────────────────────────

    fn renderStyleSection(self: *TemplateCardRenderer, content: *document.ContentStream, label: []const u8, text: []const u8) !void {
        if (text.len == 0) return;

        // Label (small cyan)
        try content.drawText(label, self.margin_left, self.current_y, self.font_bold, 9, label_cyan);
        self.current_y -= 14;

        // Value (courier, wrapped)
        const courier_font = document.Font.courier;
        // Truncate display to reasonable length
        const display_text = if (text.len > 300) text[0..300] else text;
        var wrapped = try document.wrapText(self.allocator, display_text, courier_font, 9.5, self.usable_width - 20);
        defer wrapped.deinit();

        for (wrapped.lines) |line| {
            try content.drawText(line, self.margin_left + 10, self.current_y, self.font_courier, 9.5, text_white);
            self.current_y -= 13;
        }

        self.current_y -= 8;
    }

    fn renderStyleText(self: *TemplateCardRenderer, content: *document.ContentStream) !void {
        try self.renderStyleSection(content, "STYLE PREFIX", self.data.template_prefix);
        try self.renderStyleSection(content, "STYLE MODIFIERS", self.data.template_suffix);

        // Example usage
        if (self.data.template_example_prompt.len > 0) {
            try content.drawText("EXAMPLE USAGE", self.margin_left, self.current_y, self.font_bold, 9, label_cyan);
            self.current_y -= 14;

            var buf: [512]u8 = undefined;
            const example_text = std.fmt.bufPrint(&buf, "Subject: \"{s}\"", .{self.data.template_example_prompt}) catch self.data.template_example_prompt;

            const courier_font = document.Font.courier;
            var wrapped = try document.wrapText(self.allocator, example_text, courier_font, 9.5, self.usable_width - 20);
            defer wrapped.deinit();

            for (wrapped.lines) |line| {
                try content.drawText(line, self.margin_left + 10, self.current_y, self.font_courier, 9.5, text_white);
                self.current_y -= 13;
            }
            self.current_y -= 8;
        }
    }

    // ─── QR Code + Metadata Panel ───────────────────────────────────────

    fn renderQrAndMeta(self: *TemplateCardRenderer, content: *document.ContentStream) !void {
        const qr_display_size: f32 = 130;
        const qr_x = self.margin_left;
        const qr_y = self.current_y - qr_display_size;

        // QR code
        if (self.qr_id) |qid| {
            try content.drawImage(qid, qr_x, qr_y, qr_display_size, qr_display_size);
        }

        // Metadata text to the right of QR
        const meta_x = qr_x + qr_display_size + 20;
        var meta_y = self.current_y - 4;

        // Tags
        if (self.data.template_tags.len > 0) {
            var tag_buf: [512]u8 = undefined;
            var tag_pos: usize = 0;

            for (self.data.template_tags) |tag| {
                if (tag_pos + tag.len + 2 > tag_buf.len) break;
                tag_buf[tag_pos] = '#';
                tag_pos += 1;
                @memcpy(tag_buf[tag_pos .. tag_pos + tag.len], tag);
                tag_pos += tag.len;
                tag_buf[tag_pos] = ' ';
                tag_pos += 1;
            }

            if (tag_pos > 0) {
                try content.drawText("Tags:", meta_x, meta_y, self.font_bold, 9, text_dark_gray);
                try content.drawText(tag_buf[0..tag_pos], meta_x + 35, meta_y, self.font_regular, 9, text_gray);
                meta_y -= 16;
            }
        }

        // Author
        if (self.data.template_author.len > 0) {
            try content.drawText("Author:", meta_x, meta_y, self.font_bold, 9, text_dark_gray);
            try content.drawText(self.data.template_author, meta_x + 45, meta_y, self.font_regular, 9, text_gray);
            meta_y -= 16;
        }

        // Created date
        if (self.data.created_at.len > 0) {
            try content.drawText("Created:", meta_x, meta_y, self.font_bold, 9, text_dark_gray);
            try content.drawText(self.data.created_at, meta_x + 50, meta_y, self.font_regular, 9, text_gray);
            meta_y -= 16;
        }

        // Format
        try content.drawText("Format:", meta_x, meta_y, self.font_bold, 9, text_dark_gray);
        try content.drawText(self.data.format, meta_x + 45, meta_y, self.font_regular, 9, text_gray);
        meta_y -= 20;

        // Scan instruction
        if (self.qr_id != null) {
            try content.drawText("Scan QR to import template", meta_x, meta_y, self.font_regular, 8, text_dark_gray);
        }

        self.current_y = qr_y - 15;
    }

    // ─── Footer ─────────────────────────────────────────────────────────

    fn renderFooter(self: *TemplateCardRenderer, content: *document.ContentStream) !void {
        const primary = self.primaryColor();

        // Separator line
        try content.drawLine(self.margin_left, self.current_y, self.page_width - self.margin_right, self.current_y, primary, 0.5);
        self.current_y -= 14;

        // URL centered
        const url = "quantumencoding.co.uk/templates";
        const font = document.Font.helvetica;
        const url_width = font.measureText(url, 8);
        const url_x = (self.page_width - url_width) / 2;
        try content.drawText(url, url_x, self.current_y, self.font_regular, 8, text_dark_gray);
    }

    // ─── Build Template Payload JSON ────────────────────────────────────

    fn buildPayloadJson(self: *TemplateCardRenderer) ![]u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(self.allocator);

        try buf.appendSlice(self.allocator, "{\"format\":\"");
        try appendJsonEscaped(&buf, self.allocator, self.data.format);
        try buf.appendSlice(self.allocator, "\",\"template\":{\"name\":\"");
        try appendJsonEscaped(&buf, self.allocator, self.data.template_name);
        try buf.appendSlice(self.allocator, "\",\"description\":\"");
        try appendJsonEscaped(&buf, self.allocator, self.data.template_description);
        try buf.appendSlice(self.allocator, "\",\"prefix\":\"");
        try appendJsonEscaped(&buf, self.allocator, self.data.template_prefix);
        try buf.appendSlice(self.allocator, "\",\"suffix\":\"");
        try appendJsonEscaped(&buf, self.allocator, self.data.template_suffix);
        try buf.appendSlice(self.allocator, "\",\"author\":\"");
        try appendJsonEscaped(&buf, self.allocator, self.data.template_author);
        try buf.appendSlice(self.allocator, "\",\"tags\":[");

        for (self.data.template_tags, 0..) |tag, i| {
            if (i > 0) try buf.append(self.allocator, ',');
            try buf.append(self.allocator, '"');
            try appendJsonEscaped(&buf, self.allocator, tag);
            try buf.append(self.allocator, '"');
        }

        try buf.appendSlice(self.allocator, "],\"examplePrompt\":\"");
        try appendJsonEscaped(&buf, self.allocator, self.data.template_example_prompt);
        try buf.appendSlice(self.allocator, "\"}}");

        return buf.toOwnedSlice(self.allocator);
    }

    // ─── Render ─────────────────────────────────────────────────────────

    pub fn render(self: *TemplateCardRenderer) ![]const u8 {
        var content = document.ContentStream.init(self.allocator);
        errdefer content.deinit();

        // Full-page dark background
        const bg = self.bgColor();
        try content.drawRect(0, 0, self.page_width, self.page_height, bg, null);

        // Load example image if provided
        if (self.data.example_image_base64) |img_b64| {
            if (img_b64.len > 0) {
                const result = image.loadImageFromBase64(self.allocator, img_b64) catch null;
                if (result) |r| {
                    self.example_decoded = r.decoded_bytes;
                    if (r.image.format != .jpeg) {
                        self.example_pixels = @constCast(r.image.data);
                    }
                    self.example_id = self.doc.addImage(r.image) catch null;
                }
            }
        }

        // Build template payload JSON
        const payload_json = try self.buildPayloadJson();
        defer self.allocator.free(payload_json);

        // Base64 encode for QR and metadata
        const payload_b64 = try base64Encode(self.allocator, payload_json);
        defer self.allocator.free(payload_b64);

        // Generate QR code from base64 payload
        var qr_img = qrcode.encodeAndRender(self.allocator, payload_b64, 3, .{
            .ec_level = .L,
            .max_version = 25,
            .quiet_zone = 2,
        }) catch null;
        if (qr_img) |*qi| {
            self.qr_pixels = qi.pixels;
            const qr_image = document.Image{
                .width = qi.width,
                .height = qi.height,
                .format = .raw_rgb,
                .data = qi.pixels,
            };
            self.qr_id = self.doc.addImage(qr_image) catch null;
        }

        // Set PDF metadata
        var info = document.PdfInfo{
            .title = self.data.template_name,
            .author = self.data.template_author,
            .subject = self.data.template_description,
            .creator = "zigpdf Template Card Generator",
            .producer = "zigpdf 1.0.0",
        };
        info.addCustom("QE_TPL", payload_b64);
        self.doc.setInfo(info);

        // Render all sections
        try self.renderHeaderBar(&content);
        try self.renderTemplateName(&content);
        try self.renderExampleImage(&content);
        try self.renderStyleText(&content);
        try self.renderQrAndMeta(&content);
        try self.renderFooter(&content);

        // Add page
        try self.doc.addPage(&content);

        return self.doc.build();
    }
};

// =============================================================================
// JSON Escaping Helper
// =============================================================================

fn appendJsonEscaped(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => {
                if (c < 0x20) {
                    // Control character — skip
                } else {
                    try buf.append(allocator, c);
                }
            },
        }
    }
}

// =============================================================================
// JSON Parser
// =============================================================================

fn dupeJsonString(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    if (obj.get(key)) |v| {
        return switch (v) {
            .string => |s| allocator.dupe(u8, s) catch null,
            else => null,
        };
    }
    return null;
}

fn dupeJsonStringDefault(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8, default: []const u8) []const u8 {
    return dupeJsonString(allocator, obj, key) orelse (allocator.dupe(u8, default) catch default);
}

const ParsedTemplateCard = struct {
    data: TemplateCardData,
    tags_buf: [][]const u8,

    pub fn deinit(self: ParsedTemplateCard, allocator: std.mem.Allocator) void {
        allocator.free(self.tags_buf);
    }
};

fn parseTemplateCardJson(allocator: std.mem.Allocator, json_str: []const u8) !ParsedTemplateCard {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const root = parsed.value.object;

    var data = TemplateCardData{};

    data.format = dupeJsonStringDefault(allocator, root, "format", "QE-TPL-V1");
    data.primary_color = dupeJsonStringDefault(allocator, root, "primary_color", "#00BCD4");
    data.secondary_color = dupeJsonStringDefault(allocator, root, "secondary_color", "#1a1a2e");
    data.example_image_base64 = dupeJsonString(allocator, root, "example_image_base64");
    data.created_at = dupeJsonStringDefault(allocator, root, "created_at", "");

    // Parse nested template object
    if (root.get("template")) |t| {
        if (t == .object) {
            const tpl = t.object;
            data.template_name = dupeJsonStringDefault(allocator, tpl, "name", "");
            data.template_description = dupeJsonStringDefault(allocator, tpl, "description", "");
            data.template_prefix = dupeJsonStringDefault(allocator, tpl, "prefix", "");
            data.template_suffix = dupeJsonStringDefault(allocator, tpl, "suffix", "");
            data.template_author = dupeJsonStringDefault(allocator, tpl, "author", "");
            data.template_example_prompt = dupeJsonStringDefault(allocator, tpl, "examplePrompt", "");

            // Tags array
            var tags_buf: [][]const u8 = &[_][]const u8{};
            if (tpl.get("tags")) |tags_val| {
                if (tags_val == .array) {
                    const arr = tags_val.array.items;
                    var tags = try allocator.alloc([]const u8, arr.len);
                    var count: usize = 0;
                    for (arr) |item| {
                        if (item == .string) {
                            tags[count] = try allocator.dupe(u8, item.string);
                            count += 1;
                        }
                    }
                    tags_buf = tags[0..count];
                    data.template_tags = tags_buf;
                }
            }

            return .{
                .data = data,
                .tags_buf = tags_buf,
            };
        }
    }

    return .{
        .data = data,
        .tags_buf = &[_][]const u8{},
    };
}

// =============================================================================
// Public API
// =============================================================================

pub fn generateTemplateCardFromJson(allocator: std.mem.Allocator, json_str: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const parsed = try parseTemplateCardJson(arena_alloc, json_str);

    var renderer = TemplateCardRenderer.init(arena_alloc, parsed.data);
    defer renderer.deinit();

    const pdf_output = try renderer.render();
    return try allocator.dupe(u8, pdf_output);
}

pub fn generateDemoTemplateCard(allocator: std.mem.Allocator) ![]u8 {
    const demo_json =
        \\{
        \\  "format": "QE-TPL-V1",
        \\  "template": {
        \\    "name": "Cosmic Duck",
        \\    "description": "Rubber ducks in sacred geometry tech style with cosmic backgrounds",
        \\    "prefix": "COSMIC DUCK WISDOM:",
        \\    "suffix": "Rubber duck characters, sacred geometry background, cosmic nebula lighting, digital art style, cinematic composition",
        \\    "author": "Rich @ Quantum Encoding",
        \\    "tags": ["duck", "mystical", "tech", "comedy"],
        \\    "examplePrompt": "group of ducks in a board meeting"
        \\  },
        \\  "primary_color": "#00BCD4",
        \\  "secondary_color": "#1a1a2e",
        \\  "created_at": "2026-02-20"
        \\}
    ;

    return generateTemplateCardFromJson(allocator, demo_json);
}

// =============================================================================
// Tests
// =============================================================================

test "base64 encode" {
    const allocator = std.testing.allocator;
    const result = try base64Encode(allocator, "Hello, World!");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("SGVsbG8sIFdvcmxkIQ==", result);
}

test "base64 encode empty" {
    const allocator = std.testing.allocator;
    const result = try base64Encode(allocator, "");
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "generate demo template card" {
    const allocator = std.testing.allocator;
    const pdf = try generateDemoTemplateCard(allocator);
    defer allocator.free(pdf);

    // Should produce valid PDF
    try std.testing.expect(pdf.len > 100);
    try std.testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4"));
}

test "json round-trip payload" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tags = [_][]const u8{ "duck", "tech" };
    const data = TemplateCardData{
        .template_name = "Test",
        .template_prefix = "PREFIX:",
        .template_suffix = "suffix text",
        .template_tags = &tags,
    };

    var renderer = TemplateCardRenderer.init(a, data);
    defer renderer.deinit();

    const json = try renderer.buildPayloadJson();
    defer a.free(json);

    // Should contain the template data
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"Test\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"duck\"") != null);
}
