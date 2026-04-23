// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! Letter Quote Renderer — premium Word-document-style quote.
//!
//! Centred hero title in letter-spaced navy, thin gold hairline separators,
//! letter-spaced labels ("CLIENTE:", "FECHA:", "TOTAL"), and a two-page flow:
//! page 1 is a project-description letter, page 2 is the itemised estimate.
//!
//! JSON schema (see templates/reformas_sample.json for a full example):
//!
//!   {
//!     "company":  { "name": "...", "phone": "...", "email": "..." },
//!     "client":   "MARI CRUZ",
//!     "date":     "17/11/2025",
//!     "style":    {
//!         "primary_color":   "#1a2a5e",   // navy title / labels
//!         "accent_color":    "#e8a83d",   // gold hairlines / TOTAL
//!         "watermark_image": ""           // optional raw-RGB path (unused for MVP)
//!     },
//!     "pages": [
//!       {
//!         "type": "description",
//!         "blocks": [
//!           { "type": "heading",   "text": "Proyecto reforma ..." },
//!           { "type": "paragraph", "text": "Realizaremos **una reforma**..." },
//!           { "type": "bullets",   "items": ["40% al inicio", "30% semana 5"] }
//!         ]
//!       },
//!       {
//!         "type": "itemized",
//!         "subtitle":            "PRESUPUESTO ESTIMADO",
//!         "project_label":       "DESCRIPCIÓN DE PROYECTO",
//!         "project_description": "REFORMA INTEGRAL DE PISO",
//!         "sections": [
//!           { "heading": "CUARTO DE BAÑO",
//!             "items": ["RETIRADA DE ...", "DEMOLICIÓN ... **(GESTIÓN ...)**"] }
//!         ],
//!         "currency":     "€",
//!         "subtotal":     20310,
//!         "tax_rate":     0.21,
//!         "total":        24575.10,
//!         "subtotal_text": "€20.310",       // optional pre-formatted override
//!         "tax_text":      "€4.265,10",
//!         "total_text":    "€24.575,10"
//!       }
//!     ]
//!   }
//!
//! Inline `**bold**` markers are honoured inside paragraph text and item text.

const std = @import("std");
const document = @import("document.zig");
const image_lib = @import("image.zig");

// =============================================================================
// Defaults
// =============================================================================

const DEFAULT_PRIMARY = document.Color{ .r = 0.102, .g = 0.165, .b = 0.369 }; // #1a2a5e navy
const DEFAULT_ACCENT  = document.Color{ .r = 0.910, .g = 0.659, .b = 0.239 }; // #e8a83d gold
const INK = document.Color{ .r = 0.102, .g = 0.102, .b = 0.102 }; // #1a1a1a

// Tracking ratios — tuned to match the Reformas reference. Expressed as a
// fraction of font size so they scale with the headline.
const TITLE_TRACK: f32 = 0.35;   // big centred company name
const SUBTITLE_TRACK: f32 = 0.20; // phone / email
const LABEL_TRACK: f32 = 0.25;   // "CLIENTE:", "FECHA:", "TOTAL"

// =============================================================================
// Data types
// =============================================================================

pub const PageType = enum { description, itemized };

pub const BlockType = enum { heading, paragraph, bullets };

pub const DescriptionBlock = struct {
    block_type: BlockType = .paragraph,
    text: []const u8 = "",
    items: []const []const u8 = &.{},
};

pub const DescriptionPage = struct {
    blocks: []const DescriptionBlock = &.{},
};

pub const ItemizedSection = struct {
    heading: []const u8 = "",
    items: []const []const u8 = &.{},
};

pub const ItemizedPage = struct {
    subtitle: []const u8 = "",
    project_label: []const u8 = "",
    project_description: []const u8 = "",
    sections: []const ItemizedSection = &.{},
    currency: []const u8 = "",
    subtotal: f64 = 0,
    tax_rate: f64 = 0,
    total: f64 = 0,
    subtotal_text: []const u8 = "",
    tax_text: []const u8 = "",
    total_text: []const u8 = "",
};

pub const PageData = struct {
    page_type: PageType = .description,
    description: ?DescriptionPage = null,
    itemized: ?ItemizedPage = null,
};

pub const LetterQuoteData = struct {
    company_name: []const u8 = "",
    company_phone: []const u8 = "",
    company_email: []const u8 = "",
    client: []const u8 = "",
    date: []const u8 = "",
    primary_color: []const u8 = "",
    accent_color: []const u8 = "",
    /// Watermark image: either a filesystem path (PNG or JPEG) or a
    /// `data:image/png;base64,...` data URL. Drawn faint behind content on
    /// every page. Empty = no watermark.
    watermark_image: []const u8 = "",
    /// 0.0–1.0; default 0.08 (very faint). Non-zero values override default.
    watermark_opacity: f64 = 0,
    /// Fraction of page width to scale the watermark to; default 0.60.
    watermark_scale: f64 = 0,
    /// "helvetica" (default) or "montserrat". Other values fall back to helvetica.
    font_family: []const u8 = "",
    pages: []const PageData = &.{},
};

// =============================================================================
// Renderer
// =============================================================================

pub const LetterQuoteRenderer = struct {
    allocator: std.mem.Allocator,
    doc: document.PdfDocument,
    data: LetterQuoteData,

    font_regular: []const u8 = "F0",
    font_bold: []const u8 = "F1",
    // Matching Font enums so measurement calls (measureText / measureTracked)
    // use the same metrics as the PDF viewer will.
    font_sans: document.Font = .helvetica,
    font_sans_bold: document.Font = .helvetica_bold,

    current_y: f32 = 0,
    page_width: f32 = document.A4_WIDTH,
    page_height: f32 = document.A4_HEIGHT,
    margin_left: f32 = 60,
    margin_right: f32 = 60,
    margin_top: f32 = 60,
    margin_bottom: f32 = 60,
    usable_width: f32 = 0,

    primary: document.Color = DEFAULT_PRIMARY,
    accent: document.Color = DEFAULT_ACCENT,

    // Watermark state — resolved once before rendering so every page can
    // reference the same XObject + ExtGState.
    watermark_id: ?[]const u8 = null,
    watermark_gs_id: ?[]const u8 = null,
    watermark_w: f32 = 0,
    watermark_h: f32 = 0,
    watermark_owned_bytes: ?[]u8 = null,

    pages: std.ArrayListUnmanaged(document.ContentStream),

    pub fn init(allocator: std.mem.Allocator, data: LetterQuoteData) LetterQuoteRenderer {
        var r = LetterQuoteRenderer{
            .allocator = allocator,
            .doc = document.PdfDocument.init(allocator),
            .data = data,
            .pages = .empty,
        };
        r.usable_width = r.page_width - r.margin_left - r.margin_right;

        // Font selection. Currently "montserrat" is the only non-default —
        // other values (or empty) fall back to Helvetica so existing callers
        // keep the old look unchanged.
        if (std.ascii.eqlIgnoreCase(data.font_family, "montserrat")) {
            r.font_sans = .montserrat_regular;
            r.font_sans_bold = .montserrat_bold;
        }
        r.font_regular = r.doc.getFontId(r.font_sans);
        r.font_bold = r.doc.getFontId(r.font_sans_bold);

        if (data.primary_color.len > 0) r.primary = document.Color.fromHex(data.primary_color);
        if (data.accent_color.len > 0) r.accent = document.Color.fromHex(data.accent_color);
        return r;
    }

    pub fn deinit(self: *LetterQuoteRenderer) void {
        if (self.watermark_owned_bytes) |b| self.allocator.free(b);
        for (self.pages.items) |*p| p.deinit();
        self.pages.deinit(self.allocator);
        self.doc.deinit();
    }

    // ─── Layout helpers ─────────────────────────────────────────

    fn ruleY(self: *LetterQuoteRenderer, content: *document.ContentStream, y: f32) !void {
        try content.drawLine(self.margin_left, y, self.page_width - self.margin_right, y, self.accent, 0.7);
    }

    fn drawRule(self: *LetterQuoteRenderer, content: *document.ContentStream) !void {
        try self.ruleY(content, self.current_y);
        self.current_y -= 14;
    }

    fn drawCenteredTracked(
        self: *LetterQuoteRenderer,
        content: *document.ContentStream,
        text: []const u8,
        font: document.Font,
        font_id: []const u8,
        size: f32,
        track_ratio: f32,
        color: document.Color,
        y: f32,
    ) !void {
        const tracking = size * track_ratio;
        const w = font.measureTracked(text, size, tracking);
        const x = self.margin_left + (self.usable_width - w) / 2;
        try content.drawTrackedText(text, x, y, font_id, size, tracking, color);
    }

    /// Load the watermark image (once) from path or data URL, register it
    /// with the PDF document, and pre-compute the draw size so each page
    /// renderer can just blit. No-op if `data.watermark_image` is empty.
    fn resolveWatermark(self: *LetterQuoteRenderer) !void {
        const src = self.data.watermark_image;
        if (src.len == 0) return;

        const raw = try loadWatermarkBytes(self.allocator, src);
        // Keep the bytes alive for the duration of the render — the Image
        // struct we pass to the doc holds a slice into them for JPEGs.
        self.watermark_owned_bytes = raw;

        const img = image_lib.loadImage(self.allocator, raw) catch {
            // If the image can't be decoded, skip silently so the document
            // still renders. Callers see no watermark but a valid PDF.
            self.allocator.free(raw);
            self.watermark_owned_bytes = null;
            return;
        };

        self.watermark_id = try self.doc.addImage(img);

        const opacity: f32 = if (self.data.watermark_opacity > 0)
            @as(f32, @floatCast(self.data.watermark_opacity))
        else
            0.08;
        self.watermark_gs_id = self.doc.getOpacityExtGStateId(opacity);

        const scale: f32 = if (self.data.watermark_scale > 0)
            @as(f32, @floatCast(self.data.watermark_scale))
        else
            0.60;
        const target_w = self.page_width * scale;
        const aspect = @as(f32, @floatFromInt(img.height)) / @as(f32, @floatFromInt(img.width));
        self.watermark_w = target_w;
        self.watermark_h = target_w * aspect;
    }

    fn drawWatermark(self: *LetterQuoteRenderer, content: *document.ContentStream) !void {
        const img_id = self.watermark_id orelse return;
        const gs_id = self.watermark_gs_id orelse return;
        const x = (self.page_width - self.watermark_w) / 2;
        const y = (self.page_height - self.watermark_h) / 2;
        try content.drawImageWithOpacity(img_id, gs_id, x, y, self.watermark_w, self.watermark_h);
    }

    // ─── Shared header (company title + contact + rule) ─────────

    fn drawCompanyHeader(self: *LetterQuoteRenderer, content: *document.ContentStream) !void {
        const title_size: f32 = 28;
        const sub_size: f32 = 11;
        const top = self.page_height - self.margin_top;

        if (self.data.company_name.len > 0) {
            try self.drawCenteredTracked(content, self.data.company_name, self.font_sans_bold, self.font_bold, title_size, TITLE_TRACK, self.primary, top - title_size);
        }
        self.current_y = top - title_size - 12;

        if (self.data.company_phone.len > 0 or self.data.company_email.len > 0) {
            var line: std.ArrayListUnmanaged(u8) = .empty;
            defer line.deinit(self.allocator);
            if (self.data.company_phone.len > 0) try line.appendSlice(self.allocator, self.data.company_phone);
            if (self.data.company_phone.len > 0 and self.data.company_email.len > 0) try line.appendSlice(self.allocator, "  |  ");
            if (self.data.company_email.len > 0) try line.appendSlice(self.allocator, self.data.company_email);
            try self.drawCenteredTracked(content, line.items, self.font_sans, self.font_regular, sub_size, SUBTITLE_TRACK, self.primary, self.current_y - sub_size);
            self.current_y -= sub_size + 14;
        }

        try self.drawRule(content);
    }

    // ─── CLIENTE / FECHA label rows ─────────────────────────────

    fn drawClientDateRows(self: *LetterQuoteRenderer, content: *document.ContentStream) !void {
        const label_size: f32 = 12;
        const line_gap: f32 = 18;

        if (self.data.client.len > 0) {
            try self.drawLabelValueRow(content, "CLIENTE:", self.data.client, label_size);
            self.current_y -= line_gap;
        }
        if (self.data.date.len > 0) {
            try self.drawLabelValueRow(content, "FECHA:", self.data.date, label_size);
            self.current_y -= line_gap;
        }
        self.current_y += 4; // tighten slightly before the rule
    }

    fn drawLabelValueRow(
        self: *LetterQuoteRenderer,
        content: *document.ContentStream,
        label: []const u8,
        value: []const u8,
        size: f32,
    ) !void {
        const tracking = size * LABEL_TRACK;
        try content.drawTrackedText(label, self.margin_left, self.current_y, self.font_regular, size, tracking, self.primary);
        const label_w = self.font_sans.measureTracked(label, size, tracking);
        try content.drawTrackedText(value, self.margin_left + label_w + 8, self.current_y, self.font_bold, size, tracking, self.primary);
    }

    // ─── Inline bold-run drawer (**text** → bold segments) ──────

    /// Draw a single wrapped line that may contain **bold** runs, left-aligned
    /// at `x`, baseline `y`. Returns nothing — caller handles line advance.
    fn drawMixedLine(
        self: *LetterQuoteRenderer,
        content: *document.ContentStream,
        line: []const u8,
        x: f32,
        y: f32,
        size: f32,
        color: document.Color,
    ) !void {
        var cur_x = x;
        var bold = false;
        var i: usize = 0;
        while (i < line.len) {
            if (i + 1 < line.len and line[i] == '*' and line[i + 1] == '*') {
                bold = !bold;
                i += 2;
                continue;
            }
            // find run up to next ** or end
            const start = i;
            while (i < line.len) : (i += 1) {
                if (i + 1 < line.len and line[i] == '*' and line[i + 1] == '*') break;
            }
            const run = line[start..i];
            const font_id = if (bold) self.font_bold else self.font_regular;
            try content.drawText(run, cur_x, y, font_id, size, color);
            const run_font: document.Font = if (bold) self.font_sans_bold else self.font_sans;
            cur_x += run_font.measureText(run, size);
        }
    }

    /// Strip `**` markers and return a clean copy for width measurement / wrapping.
    fn stripMarkers(self: *LetterQuoteRenderer, text: []const u8) ![]u8 {
        var out = try self.allocator.alloc(u8, text.len);
        var n: usize = 0;
        var i: usize = 0;
        while (i < text.len) {
            if (i + 1 < text.len and text[i] == '*' and text[i + 1] == '*') {
                i += 2;
                continue;
            }
            out[n] = text[i];
            n += 1;
            i += 1;
        }
        return out[0..n];
    }

    /// Wrap a `**bold**`-aware line to `max_width`. The wrapper works on the
    /// stripped text and then re-projects the break points back onto the
    /// original marker-bearing string so bold runs survive wrapping intact.
    fn wrapMixed(self: *LetterQuoteRenderer, text: []const u8, max_width: f32, size: f32) ![][]const u8 {
        // Build a projection: index-in-stripped → index-in-original
        var map = try self.allocator.alloc(usize, text.len + 1);
        defer self.allocator.free(map);
        var stripped: std.ArrayListUnmanaged(u8) = .empty;
        defer stripped.deinit(self.allocator);
        var i: usize = 0;
        while (i < text.len) {
            if (i + 1 < text.len and text[i] == '*' and text[i + 1] == '*') {
                i += 2;
                continue;
            }
            map[stripped.items.len] = i;
            try stripped.append(self.allocator, text[i]);
            i += 1;
        }
        map[stripped.items.len] = text.len;

        // Simple word wrap on the stripped text, measured with regular weight.
        // Bold runs in the original may measure slightly wider — we bias the
        // max_width down a touch to compensate.
        const measure_width = max_width * 0.97;
        var lines: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer lines.deinit(self.allocator);

        const src = stripped.items;
        var line_start: usize = 0;
        // orig_line_start keeps leading ** markers attached to their line so
        // the bold state is re-established correctly at render time. For the
        // very first line that means starting at byte 0, not at map[0].
        var orig_line_start: usize = 0;
        var last_space: usize = 0;
        var cur: usize = 0;
        while (cur < src.len) : (cur += 1) {
            if (src[cur] == ' ') last_space = cur;
            const w = self.font_sans.measureText(src[line_start..cur], size);
            if (w > measure_width and last_space > line_start) {
                const orig_end = map[last_space];
                try lines.append(self.allocator, text[orig_line_start..orig_end]);
                line_start = last_space + 1;
                orig_line_start = map[line_start];
                last_space = line_start;
            }
        }
        if (line_start < src.len) {
            try lines.append(self.allocator, text[orig_line_start..text.len]);
        }
        return try lines.toOwnedSlice(self.allocator);
    }

    fn drawMixedParagraph(
        self: *LetterQuoteRenderer,
        content: *document.ContentStream,
        text: []const u8,
        x: f32,
        max_width: f32,
        size: f32,
        line_height: f32,
        color: document.Color,
    ) !void {
        if (text.len == 0) return;
        const lines = try self.wrapMixed(text, max_width, size);
        defer self.allocator.free(lines);
        for (lines) |line| {
            try self.drawMixedLine(content, line, x, self.current_y, size, color);
            self.current_y -= line_height;
        }
    }

    // ─── Description page ───────────────────────────────────────

    fn drawDescriptionPage(self: *LetterQuoteRenderer, content: *document.ContentStream, page: DescriptionPage) !void {
        try self.drawWatermark(content);
        try self.drawCompanyHeader(content);
        try self.drawClientDateRows(content);
        try self.drawRule(content);

        const body_size: f32 = 11;
        const body_lh: f32 = 16;

        for (page.blocks) |block| {
            switch (block.block_type) {
                .heading => {
                    self.current_y -= 6;
                    // Headings are always bold. Strip any inline ** markers
                    // defensively so we never see them in output.
                    const clean = try self.stripMarkers(block.text);
                    defer self.allocator.free(clean);
                    try content.drawText(clean, self.margin_left, self.current_y, self.font_bold, body_size, INK);
                    self.current_y -= body_lh + 2;
                },
                .paragraph => {
                    try self.drawMixedParagraph(content, block.text, self.margin_left, self.usable_width, body_size, body_lh, INK);
                    self.current_y -= 10;
                },
                .bullets => {
                    for (block.items) |item| {
                        try content.drawCircle(self.margin_left + 4, self.current_y + 4, 1.6, INK, null);
                        const indent: f32 = 16;
                        try self.drawMixedParagraph(content, item, self.margin_left + indent, self.usable_width - indent, body_size, body_lh, INK);
                        self.current_y -= 2;
                    }
                    self.current_y -= 6;
                },
            }
        }

        // Bottom rule sits just above margin_bottom
        try self.ruleY(content, self.margin_bottom);
    }

    // ─── Itemized page ──────────────────────────────────────────

    fn drawItemizedPage(self: *LetterQuoteRenderer, content: *document.ContentStream, page: ItemizedPage) !void {
        try self.drawWatermark(content);
        try self.drawCompanyHeader(content);

        // Subtitle ("PRESUPUESTO ESTIMADO"), centred tracked navy bold
        if (page.subtitle.len > 0) {
            const sub_size: f32 = 16;
            try self.drawCenteredTracked(content, page.subtitle, self.font_sans_bold, self.font_bold, sub_size, LABEL_TRACK, self.primary, self.current_y - sub_size);
            self.current_y -= sub_size + 10;
            try self.drawRule(content);
        }

        try self.drawClientDateRows(content);
        try self.drawRule(content);

        // Project-description row: "LABEL:  VALUE" — all letter-spaced, value bold
        if (page.project_label.len > 0 or page.project_description.len > 0) {
            const ps: f32 = 12;
            const tracking = ps * LABEL_TRACK;
            var cur_x = self.margin_left;
            if (page.project_label.len > 0) {
                const label_with_colon = try std.fmt.allocPrint(self.allocator, "{s}:", .{page.project_label});
                defer self.allocator.free(label_with_colon);
                try content.drawTrackedText(label_with_colon, cur_x, self.current_y, self.font_regular, ps, tracking, self.primary);
                cur_x += self.font_sans.measureTracked(label_with_colon, ps, tracking) + 10;
            }
            if (page.project_description.len > 0) {
                try content.drawTrackedText(page.project_description, cur_x, self.current_y, self.font_bold, ps, tracking, self.primary);
            }
            self.current_y -= 18;
            try self.drawRule(content);
        }

        // Sections
        const item_size: f32 = 10.5;
        const item_lh: f32 = 14;
        for (page.sections, 0..) |sec, idx| {
            if (idx > 0) self.current_y -= 8;
            if (sec.heading.len > 0) {
                try content.drawText(sec.heading, self.margin_left, self.current_y, self.font_bold, item_size + 0.5, self.primary);
                self.current_y -= 18;
            }
            for (sec.items) |raw_item| {
                try self.drawMixedParagraph(content, raw_item, self.margin_left, self.usable_width, item_size, item_lh, INK);
            }
        }

        // Totals block — right-aligned, with a rule above
        self.current_y -= 16;
        try self.ruleY(content, self.current_y);
        self.current_y -= 18;

        try self.drawTotalsRow(content, "SUBTOTAL", page.subtotal_text, page.subtotal, page.currency, 13, self.primary, self.primary, self.font_bold, self.font_regular);
        self.current_y -= 20;

        const tax_label = try std.fmt.allocPrint(self.allocator, "IVA {d:.0}%", .{page.tax_rate * 100.0});
        defer self.allocator.free(tax_label);
        const tax_amount = page.subtotal * page.tax_rate;
        try self.drawTotalsRow(content, tax_label, page.tax_text, tax_amount, page.currency, 13, self.primary, self.primary, self.font_bold, self.font_regular);
        self.current_y -= 20;

        try self.drawTotalsRow(content, "TOTAL", page.total_text, page.total, page.currency, 15, self.accent, self.accent, self.font_bold, self.font_bold);
        self.current_y -= 24;

        // Bottom rule at fixed position above margin_bottom
        try self.ruleY(content, self.margin_bottom);
    }

    fn drawTotalsRow(
        self: *LetterQuoteRenderer,
        content: *document.ContentStream,
        label: []const u8,
        override: []const u8,
        amount: f64,
        currency: []const u8,
        size: f32,
        label_color: document.Color,
        value_color: document.Color,
        label_font_id: []const u8,
        value_font_id: []const u8,
    ) !void {
        const right_x = self.page_width - self.margin_right;
        const tracking = size * LABEL_TRACK;

        // Value
        var value_buf: [64]u8 = undefined;
        const value_str = if (override.len > 0)
            override
        else blk: {
            const s = try std.fmt.bufPrint(&value_buf, "{s}{d:.2}", .{ currency, amount });
            break :blk s;
        };

        const value_font: document.Font = if (std.mem.eql(u8, value_font_id, self.font_bold)) self.font_sans_bold else self.font_sans;
        const value_w = value_font.measureTracked(value_str, size, tracking);
        try content.drawTrackedText(value_str, right_x - value_w, self.current_y, value_font_id, size, tracking, value_color);

        // Label — sits left of the value with a gap
        const label_font: document.Font = if (std.mem.eql(u8, label_font_id, self.font_bold)) self.font_sans_bold else self.font_sans;
        const label_w = label_font.measureTracked(label, size, tracking);
        const label_x = right_x - value_w - 30 - label_w;
        try content.drawTrackedText(label, label_x, self.current_y, label_font_id, size, tracking, label_color);
    }

    // ─── Render entry ───────────────────────────────────────────

    pub fn render(self: *LetterQuoteRenderer) ![]const u8 {
        try self.resolveWatermark();
        for (self.data.pages) |page| {
            var content = document.ContentStream.init(self.allocator);
            errdefer content.deinit();
            switch (page.page_type) {
                .description => if (page.description) |d| try self.drawDescriptionPage(&content, d),
                .itemized    => if (page.itemized)    |it| try self.drawItemizedPage(&content, it),
            }
            try self.pages.append(self.allocator, content);
        }

        for (self.pages.items) |*p| {
            try self.doc.addPage(p);
        }

        return try self.doc.build();
    }
};

// =============================================================================
// Public API
// =============================================================================

pub fn generateLetterQuote(allocator: std.mem.Allocator, data: LetterQuoteData) ![]u8 {
    var r = LetterQuoteRenderer.init(allocator, data);
    defer r.deinit();
    const bytes = try r.render();
    return try allocator.dupe(u8, bytes);
}

pub fn generateLetterQuoteFromJson(allocator: std.mem.Allocator, json_str: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const data = try parseLetterQuoteJson(aa, json_str);
    var r = LetterQuoteRenderer.init(aa, data);
    defer r.deinit();
    const pdf = try r.render();
    return try allocator.dupe(u8, pdf);
}

// =============================================================================
// JSON parsing
// =============================================================================

/// Resolve a watermark source (filesystem path OR `data:...;base64,...` URL)
/// into raw image bytes. Caller owns the returned buffer.
fn loadWatermarkBytes(a: std.mem.Allocator, src: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, src, "data:")) {
        // Data URL: strip header up to and including the comma.
        const comma = std.mem.indexOfScalar(u8, src, ',') orelse return error.InvalidDataUrl;
        const header = src[0..comma];
        const payload = src[comma + 1 ..];
        if (std.mem.indexOf(u8, header, "base64") == null) {
            // Plain (URL-escaped) data URL — just dupe it as-is. Uncommon for images.
            return try a.dupe(u8, payload);
        }
        return try image_lib.decodeBase64(a, payload);
    }
    // Filesystem path. Use the shared single-threaded IO handle so this
    // works identically from the CLI and FFI entry points.
    const io = std.Io.Threaded.global_single_threaded.io();
    return try std.Io.Dir.cwd().readFileAlloc(io, src, a, .limited(32 * 1024 * 1024));
}

fn dupeStr(a: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8, def: []const u8) ![]const u8 {
    if (obj.get(key)) |v| if (v == .string) return try a.dupe(u8, v.string);
    return try a.dupe(u8, def);
}

fn getFloat(obj: std.json.ObjectMap, key: []const u8) f64 {
    if (obj.get(key)) |v| return switch (v) {
        .float => v.float,
        .integer => @floatFromInt(v.integer),
        else => 0,
    };
    return 0;
}

fn parseBlock(a: std.mem.Allocator, obj: std.json.ObjectMap) !DescriptionBlock {
    const type_str = try dupeStr(a, obj, "type", "paragraph");
    const bt: BlockType = if (std.mem.eql(u8, type_str, "heading")) .heading
        else if (std.mem.eql(u8, type_str, "bullets")) .bullets
        else .paragraph;

    var block = DescriptionBlock{
        .block_type = bt,
        .text = try dupeStr(a, obj, "text", ""),
    };

    if (bt == .bullets) {
        if (obj.get("items")) |v| if (v == .array) {
            const arr = v.array.items;
            const buf = try a.alloc([]const u8, arr.len);
            for (arr, 0..) |iv, i| {
                buf[i] = if (iv == .string) try a.dupe(u8, iv.string) else "";
            }
            block.items = buf;
        };
    }
    return block;
}

fn parseDescriptionPage(a: std.mem.Allocator, obj: std.json.ObjectMap) !DescriptionPage {
    var page = DescriptionPage{};
    if (obj.get("blocks")) |v| if (v == .array) {
        const arr = v.array.items;
        const buf = try a.alloc(DescriptionBlock, arr.len);
        for (arr, 0..) |bv, i| {
            buf[i] = if (bv == .object) try parseBlock(a, bv.object) else .{};
        }
        page.blocks = buf;
    };
    return page;
}

fn parseItemizedPage(a: std.mem.Allocator, obj: std.json.ObjectMap) !ItemizedPage {
    var page = ItemizedPage{
        .subtitle            = try dupeStr(a, obj, "subtitle", ""),
        .project_label       = try dupeStr(a, obj, "project_label", ""),
        .project_description = try dupeStr(a, obj, "project_description", ""),
        .currency            = try dupeStr(a, obj, "currency", ""),
        .subtotal            = getFloat(obj, "subtotal"),
        .tax_rate            = getFloat(obj, "tax_rate"),
        .total               = getFloat(obj, "total"),
        .subtotal_text       = try dupeStr(a, obj, "subtotal_text", ""),
        .tax_text            = try dupeStr(a, obj, "tax_text", ""),
        .total_text          = try dupeStr(a, obj, "total_text", ""),
    };
    if (obj.get("sections")) |v| if (v == .array) {
        const arr = v.array.items;
        const buf = try a.alloc(ItemizedSection, arr.len);
        for (arr, 0..) |sv, i| {
            if (sv != .object) { buf[i] = .{}; continue; }
            const so = sv.object;
            var sec = ItemizedSection{ .heading = try dupeStr(a, so, "heading", "") };
            if (so.get("items")) |iv| if (iv == .array) {
                const iarr = iv.array.items;
                const ibuf = try a.alloc([]const u8, iarr.len);
                for (iarr, 0..) |it, j| {
                    ibuf[j] = if (it == .string) try a.dupe(u8, it.string) else "";
                }
                sec.items = ibuf;
            };
            buf[i] = sec;
        }
        page.sections = buf;
    };
    return page;
}

fn parseLetterQuoteJson(a: std.mem.Allocator, json_str: []const u8) !LetterQuoteData {
    var parsed = try std.json.parseFromSlice(std.json.Value, a, json_str, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidJson;
    const root = parsed.value.object;

    var data = LetterQuoteData{};

    if (root.get("company")) |c| if (c == .object) {
        data.company_name  = try dupeStr(a, c.object, "name", "");
        data.company_phone = try dupeStr(a, c.object, "phone", "");
        data.company_email = try dupeStr(a, c.object, "email", "");
    };
    data.client = try dupeStr(a, root, "client", "");
    data.date   = try dupeStr(a, root, "date", "");

    if (root.get("style")) |s| if (s == .object) {
        data.primary_color     = try dupeStr(a, s.object, "primary_color", "");
        data.accent_color      = try dupeStr(a, s.object, "accent_color", "");
        data.watermark_image   = try dupeStr(a, s.object, "watermark_image", "");
        data.watermark_opacity = getFloat(s.object, "watermark_opacity");
        data.watermark_scale   = getFloat(s.object, "watermark_scale");
        data.font_family       = try dupeStr(a, s.object, "font_family", "");
    };

    if (root.get("pages")) |p| if (p == .array) {
        const arr = p.array.items;
        const buf = try a.alloc(PageData, arr.len);
        for (arr, 0..) |pv, i| {
            if (pv != .object) { buf[i] = .{}; continue; }
            const po = pv.object;
            const type_str = try dupeStr(a, po, "type", "description");
            const pt: PageType = if (std.mem.eql(u8, type_str, "itemized")) .itemized else .description;

            var page = PageData{ .page_type = pt };
            if (pt == .description) {
                const dp = try parseDescriptionPage(a, po);
                const slot = try a.create(DescriptionPage);
                slot.* = dp;
                page.description = slot.*;
            } else {
                const ip = try parseItemizedPage(a, po);
                const slot = try a.create(ItemizedPage);
                slot.* = ip;
                page.itemized = slot.*;
            }
            buf[i] = page;
        }
        data.pages = buf;
    };

    return data;
}
