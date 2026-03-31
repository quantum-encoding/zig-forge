//! Proposal Document Renderer
//!
//! Generates branded proposals (solar installations, heat pumps, batteries, etc.)
//! with auto-layout, mixed section types, and page break management.
//!
//! Section types:
//! - text: Heading + body text with word wrap and bullet support
//! - metrics: Horizontal row of colored callout cards (label + value)
//! - table: Itemized table with header, alternating rows, totals, optional notes
//!
//! Architecture follows contract.zig (auto-layout with checkPageBreak) but
//! with richer section types and CRG Direct branding support.
//!
//! Supports property_image_base64 for satellite/solar API imagery.

const std = @import("std");
const document = @import("document.zig");
const image = @import("image.zig");
const qrcode = @import("qrcode.zig");

// =============================================================================
// UTF-8 to WinAnsiEncoding
// =============================================================================

/// PDF standard fonts use WinAnsiEncoding, not UTF-8.
/// This converts common multi-byte UTF-8 sequences to their WinAnsi single-byte equivalents.
/// Without this, £ appears as Â£, bullet as garbage, etc.
fn utf8ToWinAnsi(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < text.len) {
        if (i + 1 < text.len and text[i] == 0xC2) {
            // 2-byte sequences starting with 0xC2 (U+0080..U+00FF)
            // These map directly: WinAnsi byte = second byte
            const b2 = text[i + 1];
            if (b2 >= 0xA0) {
                // U+00A0..U+00FF — most map 1:1 in WinAnsi
                // £ (U+00A3) = 0xA3, © (U+00A9) = 0xA9, etc.
                try result.append(allocator, b2);
                i += 2;
                continue;
            }
        }
        if (i + 2 < text.len and text[i] == 0xE2) {
            // 3-byte sequences starting with 0xE2 (common symbols)
            const b2 = text[i + 1];
            const b3 = text[i + 2];
            if (b2 == 0x80) {
                const mapped: ?u8 = switch (b3) {
                    0x93 => 0x96, // – (en dash)
                    0x94 => 0x97, // — (em dash)
                    0x98 => 0x91, // ' (left single quote)
                    0x99 => 0x92, // ' (right single quote)
                    0x9C => 0x93, // " (left double quote)
                    0x9D => 0x94, // " (right double quote)
                    0xA2 => 0x95, // • (bullet)
                    0xA6 => 0x85, // … (ellipsis)
                    else => null,
                };
                if (mapped) |m| {
                    try result.append(allocator, m);
                    i += 3;
                    continue;
                }
            }
            if (b2 == 0x82 and b3 == 0xAC) {
                // € (euro sign) = 0x80 in WinAnsi
                try result.append(allocator, 0x80);
                i += 3;
                continue;
            }
        }
        // Pass through ASCII and anything else unchanged
        try result.append(allocator, text[i]);
        i += 1;
    }

    return result.toOwnedSlice(allocator);
}

// =============================================================================
// Data Structures
// =============================================================================

pub const MetricItem = struct {
    label: []const u8 = "",
    value: []const u8 = "",
};

pub const TableItem = struct {
    description: []const u8 = "",
    quantity: f64 = 0,
    unit_price: f64 = 0,
    total: f64 = 0,
};

pub const FooterInfo = struct {
    phone: []const u8 = "",
    email: []const u8 = "",
    website: []const u8 = "",
    dashboard_text: []const u8 = "",
    /// URL encoded into a QR code on the proposal (e.g. dashboard link for this quote)
    dashboard_url: []const u8 = "",
};

pub const SectionType = enum {
    text,
    metrics,
    table,
    chart,
};

/// Chart segment for pie/donut charts in PDF sections
pub const ChartSegment = struct {
    label: []const u8 = "",
    value: f64 = 0,
    color: ?[]const u8 = null, // hex color
};

/// Chart bar for bar charts in PDF sections
pub const ChartBarSeries = struct {
    name: []const u8 = "",
    values: []const f64 = &[_]f64{},
};

/// Embedded chart configuration for proposal sections
pub const ChartSpec = struct {
    chart_type: []const u8 = "pie", // pie, donut, bar, progress
    segments: []const ChartSegment = &[_]ChartSegment{},
    categories: []const []const u8 = &[_][]const u8{},
    series: []const ChartBarSeries = &[_]ChartBarSeries{},
    width: f64 = 500,
    height: f64 = 250,
};

pub const ProposalSection = struct {
    section_type: SectionType = .text,
    heading: []const u8 = "",
    // text fields
    content: []const u8 = "",
    // metrics fields
    metric_items: []const MetricItem = &[_]MetricItem{},
    // table fields
    table_items: []const TableItem = &[_]TableItem{},
    subtotal: f64 = 0,
    tax_rate: f64 = 0,
    total: f64 = 0,
    notes: ?[]const u8 = null,
    // chart fields
    chart_spec: ?ChartSpec = null,
};

pub const ProposalData = struct {
    company_name: []const u8 = "",
    company_address: []const u8 = "",
    company_logo_base64: ?[]const u8 = null,
    client_name: []const u8 = "",
    client_address: []const u8 = "",
    reference: []const u8 = "",
    date: []const u8 = "",
    valid_until: []const u8 = "",
    primary_color: []const u8 = "#16a34a",
    secondary_color: []const u8 = "#1e3a2f",
    sections: []const ProposalSection = &[_]ProposalSection{},
    footer: FooterInfo = .{},
    /// Base64-encoded property image (e.g. from solar API satellite view)
    property_image_base64: ?[]const u8 = null,
};

// =============================================================================
// Proposal Renderer
// =============================================================================

pub const ProposalRenderer = struct {
    allocator: std.mem.Allocator,
    doc: document.PdfDocument,
    data: ProposalData,

    // Fonts
    font_regular: []const u8 = "F0",
    font_bold: []const u8 = "F1",
    font_oblique: []const u8 = "F2",

    // Layout state
    current_y: f32 = 0,
    page_number: u32 = 1,
    total_pages: u32 = 1,

    // Page dimensions
    margin_left: f32 = 50,
    margin_right: f32 = 50,
    margin_top: f32 = 50,
    margin_bottom: f32 = 65,
    page_width: f32 = document.A4_WIDTH,
    page_height: f32 = document.A4_HEIGHT,
    usable_width: f32 = 0,

    // Decoded images
    logo_decoded: ?[]u8 = null,
    logo_pixels: ?[]u8 = null,
    logo_id: ?[]const u8 = null,
    property_decoded: ?[]u8 = null,
    property_pixels: ?[]u8 = null,
    property_id: ?[]const u8 = null,
    qr_pixels: ?[]u8 = null,
    qr_id: ?[]const u8 = null,
    qr_size: u32 = 0,

    // Content pages
    pages: std.ArrayListUnmanaged(document.ContentStream),

    pub fn init(allocator: std.mem.Allocator, data: ProposalData) ProposalRenderer {
        var renderer = ProposalRenderer{
            .allocator = allocator,
            .doc = document.PdfDocument.init(allocator),
            .data = data,
            .pages = .empty,
        };

        renderer.usable_width = renderer.page_width - renderer.margin_left - renderer.margin_right;

        renderer.font_regular = renderer.doc.getFontId(.helvetica);
        renderer.font_bold = renderer.doc.getFontId(.helvetica_bold);
        renderer.font_oblique = renderer.doc.getFontId(.helvetica_oblique);

        renderer.current_y = renderer.page_height - renderer.margin_top;

        return renderer;
    }

    pub fn deinit(self: *ProposalRenderer) void {
        if (self.logo_decoded) |d| self.allocator.free(d);
        if (self.property_decoded) |d| self.allocator.free(d);
        if (self.qr_pixels) |d| self.allocator.free(d);

        for (self.pages.items) |*page| {
            page.deinit();
        }
        self.pages.deinit(self.allocator);
        self.doc.deinit();
    }

    /// Draw text with UTF-8 to WinAnsi conversion
    fn drawTextConverted(self: *ProposalRenderer, content: *document.ContentStream, text: []const u8, x: f32, y: f32, font_id: []const u8, size: f32, color: document.Color) !void {
        const converted = try utf8ToWinAnsi(self.allocator, text);
        defer self.allocator.free(converted);
        try content.drawText(converted, x, y, font_id, size, color);
    }

    // ─── Page Management ─────────────────────────────────────────────────

    fn checkPageBreak(self: *ProposalRenderer, content: *document.ContentStream, needed_height: f32) !void {
        if (self.current_y - needed_height < self.margin_bottom) {
            try self.pages.append(self.allocator, content.*);
            content.* = document.ContentStream.init(self.allocator);
            self.page_number += 1;
            self.current_y = self.page_height - self.margin_top;
        }
    }

    // ─── Header (First Page) ─────────────────────────────────────────────

    fn drawFirstPageHeader(self: *ProposalRenderer, content: *document.ContentStream) !void {
        const primary = document.Color.fromHex(self.data.primary_color);
        const secondary = document.Color.fromHex(self.data.secondary_color);

        // Accent bar at top
        try content.drawRect(0, self.page_height - 8, self.page_width, 8, primary, null);

        // Company name
        var name_x: f32 = self.margin_left;
        if (self.logo_id) |lid| {
            try content.drawImage(lid, self.margin_left, self.page_height - 70, 50, 50);
            name_x = self.margin_left + 60;
        }

        try content.drawText(self.data.company_name, name_x, self.page_height - 40, self.font_bold, 18, secondary);

        if (self.data.company_address.len > 0) {
            try content.drawText(self.data.company_address, name_x, self.page_height - 55, self.font_regular, 9, document.Color.fromHex("#666666"));
        }

        // "PROPOSAL" label right-aligned
        const label = "PROPOSAL";
        const label_width = document.Font.helvetica_bold.measureText(label, 20);
        try content.drawText(label, self.page_width - self.margin_right - label_width, self.page_height - 40, self.font_bold, 20, primary);

        self.current_y = self.page_height - 80;

        // Separator line
        try content.drawLine(self.margin_left, self.current_y, self.page_width - self.margin_right, self.current_y, primary, 1.0);
        self.current_y -= 20;

        // Client info block (left) + Reference info (right)
        const info_start_y = self.current_y;

        // Left: Client
        try content.drawText("Prepared for:", self.margin_left, self.current_y, self.font_regular, 9, document.Color.fromHex("#888888"));
        self.current_y -= 14;
        try content.drawText(self.data.client_name, self.margin_left, self.current_y, self.font_bold, 12, document.Color.black);
        self.current_y -= 16;

        if (self.data.client_address.len > 0) {
            var lines = std.mem.splitScalar(u8, self.data.client_address, '\n');
            while (lines.next()) |line| {
                try content.drawText(line, self.margin_left, self.current_y, self.font_regular, 10, document.Color.black);
                self.current_y -= 14;
            }
        }

        // Right: Reference info boxes
        const right_x = self.page_width - self.margin_right - 160;
        var right_y = info_start_y;

        if (self.data.reference.len > 0) {
            try content.drawText("Reference:", right_x, right_y, self.font_regular, 9, document.Color.fromHex("#888888"));
            right_y -= 14;
            try content.drawText(self.data.reference, right_x, right_y, self.font_bold, 10, document.Color.black);
            right_y -= 18;
        }

        if (self.data.date.len > 0) {
            try content.drawText("Date:", right_x, right_y, self.font_regular, 9, document.Color.fromHex("#888888"));
            right_y -= 14;
            try content.drawText(self.data.date, right_x, right_y, self.font_regular, 10, document.Color.black);
            right_y -= 18;
        }

        if (self.data.valid_until.len > 0) {
            try content.drawText("Valid until:", right_x, right_y, self.font_regular, 9, document.Color.fromHex("#888888"));
            right_y -= 14;
            try content.drawText(self.data.valid_until, right_x, right_y, self.font_regular, 10, document.Color.black);
        }

        // Take the lower of the two columns
        self.current_y = @min(self.current_y, right_y) - 20;

        // Property image (satellite/solar API view) — if provided
        if (self.property_id) |pid| {
            try self.checkPageBreak(content, 180);
            // Centered, with a light border
            const img_width: f32 = 280;
            const img_height: f32 = 160;
            const img_x = self.margin_left + (self.usable_width - img_width) / 2;
            const img_y = self.current_y - img_height;

            // Light gray border around image
            try content.drawRect(img_x - 2, img_y - 2, img_width + 4, img_height + 4, null, document.Color.fromHex("#cccccc"));
            try content.drawImage(pid, img_x, img_y, img_width, img_height);

            // Caption below image
            const caption = "Your property - satellite view";
            const caption_font = document.Font.helvetica_oblique;
            const caption_w = caption_font.measureText(caption, 8);
            try content.drawText(caption, img_x + (img_width - caption_w) / 2, img_y - 12, self.font_oblique, 8, document.Color.fromHex("#888888"));

            self.current_y = img_y - 25;
        } else {
            self.current_y -= 5;
        }
    }

    // ─── Text Section ────────────────────────────────────────────────────

    fn drawTextSection(self: *ProposalRenderer, content: *document.ContentStream, section: ProposalSection) !void {
        const primary = document.Color.fromHex(self.data.primary_color);
        const font = document.Font.helvetica;

        // Heading
        if (section.heading.len > 0) {
            try self.checkPageBreak(content, 30);
            try self.drawTextConverted(content, section.heading, self.margin_left, self.current_y, self.font_bold, 14, primary);
            self.current_y -= 21;
        }

        // Content with word wrap and bullet support
        if (section.content.len > 0) {
            const converted = try utf8ToWinAnsi(self.allocator, section.content);
            defer self.allocator.free(converted);

            var paragraphs = std.mem.splitScalar(u8, converted, '\n');
            while (paragraphs.next()) |paragraph| {
                if (paragraph.len == 0) {
                    self.current_y -= 5;
                    continue;
                }

                const is_bullet = paragraph.len > 2 and paragraph[0] == '-' and paragraph[1] == ' ';
                const text_content = if (is_bullet) paragraph[2..] else paragraph;
                const indent: f32 = if (is_bullet) 15 else 0;

                var wrapped = try document.wrapText(self.allocator, text_content, font, 10.5, self.usable_width - indent);
                defer wrapped.deinit();

                for (wrapped.lines, 0..) |line, line_idx| {
                    try self.checkPageBreak(content, 15);

                    if (is_bullet and line_idx == 0) {
                        // WinAnsi bullet = 0x95
                        try content.drawText(&[_]u8{0x95}, self.margin_left, self.current_y, self.font_regular, 10, document.Color.black);
                    }

                    try content.drawText(line, self.margin_left + indent, self.current_y, self.font_regular, 10.5, document.Color.black);
                    self.current_y -= 15;
                }
            }

            self.current_y -= 10;
        }
    }

    // ─── Metrics Section (Callout Cards) ─────────────────────────────────

    fn drawMetricsSection(self: *ProposalRenderer, content: *document.ContentStream, section: ProposalSection) !void {
        const primary = document.Color.fromHex(self.data.primary_color);
        const n = section.metric_items.len;
        if (n == 0) return;

        // Heading
        if (section.heading.len > 0) {
            try self.checkPageBreak(content, 110);
            try self.drawTextConverted(content, section.heading, self.margin_left, self.current_y, self.font_bold, 14, primary);
            self.current_y -= 22;
        } else {
            try self.checkPageBreak(content, 90);
        }

        // Card layout
        const gap: f32 = 10;
        const n_f: f32 = @floatFromInt(n);
        const card_width = (self.usable_width - gap * (n_f - 1)) / n_f;
        const card_height: f32 = 75;

        var card_x = self.margin_left;
        const card_y = self.current_y - card_height;

        for (section.metric_items, 0..) |item, i| {
            // Shade: darken progressively for visual distinction
            const shade: f32 = 1.0 - @as(f32, @floatFromInt(i)) * 0.08;
            const card_color = document.Color{
                .r = primary.r * shade,
                .g = primary.g * shade,
                .b = primary.b * shade,
            };

            // Draw rounded rect card
            try content.drawRoundedRect(card_x, card_y, card_width, card_height, 6, card_color);

            // Label (small, near top of card)
            try self.drawTextConverted(content, item.label, card_x + 12, card_y + card_height - 22, self.font_regular, 9, document.Color.white);

            // Value (large, lower in card) — auto-scale if text is too wide
            const max_text_width = card_width - 24;
            const value_font = document.Font.helvetica_bold;
            var value_size: f32 = 20;
            const converted_val = try utf8ToWinAnsi(self.allocator, item.value);
            defer self.allocator.free(converted_val);
            // Scale down if needed to fit the card
            while (value_size > 12) {
                const w = value_font.measureText(converted_val, value_size);
                if (w <= max_text_width) break;
                value_size -= 1;
            }
            try content.drawText(converted_val, card_x + 12, card_y + 16, self.font_bold, value_size, document.Color.white);

            card_x += card_width + gap;
        }

        self.current_y = card_y - 16;
    }

    // ─── Table Section ───────────────────────────────────────────────────

    fn drawTableSection(self: *ProposalRenderer, content: *document.ContentStream, section: ProposalSection) !void {
        const primary = document.Color.fromHex(self.data.primary_color);
        const secondary = document.Color.fromHex(self.data.secondary_color);

        const row_height: f32 = 24;

        // Estimate FULL table height so we don't split it across pages
        const heading_h: f32 = if (section.heading.len > 0) 21 else 0;
        const header_row_h = row_height;
        const data_rows_h = @as(f32, @floatFromInt(section.table_items.len)) * row_height;
        const totals_h: f32 = 12 + // separator
            (if (section.subtotal > 0) @as(f32, 20) else 0) +
            (if (section.tax_rate > 0) @as(f32, 20) else 0) +
            (if (section.total > 0) @as(f32, 34) else 0) +
            (if (section.notes != null) @as(f32, 16) else 0);
        const full_table_h = heading_h + header_row_h + data_rows_h + totals_h + 20;

        // If the whole table fits on the current page, keep it together.
        // If it doesn't fit on a fresh page either (very large table), just
        // start it here and let individual rows break normally.
        const space_left = self.current_y - self.margin_bottom;
        const fresh_page_space = self.page_height - self.margin_top - self.margin_bottom;
        if (full_table_h <= fresh_page_space and full_table_h > space_left) {
            // Table fits on a page but not THIS page — force page break
            try self.checkPageBreak(content, fresh_page_space + 1);
        }

        // Heading
        if (section.heading.len > 0) {
            try self.checkPageBreak(content, 60);
            try self.drawTextConverted(content, section.heading, self.margin_left, self.current_y, self.font_bold, 14, primary);
            self.current_y -= 21;
        } else {
            try self.checkPageBreak(content, 40);
        }

        // Column layout: Description (flex) | Qty | Unit Price | Total
        const col_qty_w: f32 = 50;
        const col_price_w: f32 = 85;
        const col_total_w: f32 = 85;
        const col_desc_w = self.usable_width - col_qty_w - col_price_w - col_total_w;
        const padding: f32 = 8;

        const col_desc_x = self.margin_left;
        const col_qty_x = col_desc_x + col_desc_w;
        const col_price_x = col_qty_x + col_qty_w;
        const col_total_x = col_price_x + col_price_w;

        // Header row
        try content.drawRect(self.margin_left, self.current_y - row_height, self.usable_width, row_height, secondary, null);
        const header_text_y = self.current_y - row_height + 7;
        try content.drawText("Description", col_desc_x + padding, header_text_y, self.font_bold, 9, document.Color.white);
        try content.drawText("Qty", col_qty_x + padding, header_text_y, self.font_bold, 9, document.Color.white);
        try content.drawText("Unit Price", col_price_x + padding, header_text_y, self.font_bold, 9, document.Color.white);
        try content.drawText("Total", col_total_x + padding, header_text_y, self.font_bold, 9, document.Color.white);
        self.current_y -= row_height;

        // Data rows
        const alt_bg = document.Color.fromHex("#f5f5f5");
        for (section.table_items, 0..) |item, i| {
            try self.checkPageBreak(content, row_height);

            if (i % 2 == 0) {
                try content.drawRect(self.margin_left, self.current_y - row_height, self.usable_width, row_height, alt_bg, null);
            }

            const text_y = self.current_y - row_height + 7;

            // Description
            const desc_display = if (item.description.len > 50) item.description[0..50] else item.description;
            try self.drawTextConverted(content, desc_display, col_desc_x + padding, text_y, self.font_regular, 9, document.Color.black);

            // Quantity
            var qty_buf: [32]u8 = undefined;
            const qty_str = std.fmt.bufPrint(&qty_buf, "{d:.0}", .{item.quantity}) catch "0";
            try content.drawText(qty_str, col_qty_x + padding, text_y, self.font_regular, 9, document.Color.black);

            // Unit price — WinAnsi £
            var price_buf: [32]u8 = undefined;
            const price_str = formatCurrency(&price_buf, item.unit_price);
            try content.drawText(price_str, col_price_x + padding, text_y, self.font_regular, 9, document.Color.black);

            // Total — WinAnsi £
            var total_buf: [32]u8 = undefined;
            const total_str = formatCurrency(&total_buf, item.total);
            try content.drawText(total_str, col_total_x + padding, text_y, self.font_regular, 9, document.Color.black);

            self.current_y -= row_height;
        }

        // Separator line below table rows
        try content.drawLine(self.margin_left, self.current_y, self.page_width - self.margin_right, self.current_y, document.Color.fromHex("#cccccc"), 0.5);
        self.current_y -= 12;

        // Totals block (right-aligned) — with proper spacing
        const totals_x = col_price_x;
        const totals_val_x = col_total_x + padding;

        // Subtotal
        if (section.subtotal > 0) {
            try self.checkPageBreak(content, 20);
            try content.drawText("Subtotal:", totals_x, self.current_y, self.font_regular, 10, document.Color.black);
            var sub_buf: [32]u8 = undefined;
            const sub_str = formatCurrency(&sub_buf, section.subtotal);
            try content.drawText(sub_str, totals_val_x, self.current_y, self.font_regular, 10, document.Color.black);
            self.current_y -= 20;
        }

        // Tax
        if (section.tax_rate > 0) {
            try self.checkPageBreak(content, 20);
            var tax_label_buf: [48]u8 = undefined;
            const tax_label = std.fmt.bufPrint(&tax_label_buf, "VAT ({d:.0}%):", .{section.tax_rate * 100}) catch "VAT:";
            try content.drawText(tax_label, totals_x, self.current_y, self.font_regular, 10, document.Color.black);
            var tax_buf: [32]u8 = undefined;
            const tax_amount = section.subtotal * section.tax_rate;
            const tax_str = formatCurrency(&tax_buf, tax_amount);
            try content.drawText(tax_str, totals_val_x, self.current_y, self.font_regular, 10, document.Color.black);
            self.current_y -= 20;
        }

        // Total line with separator
        if (section.total > 0) {
            try self.checkPageBreak(content, 30);
            try content.drawLine(totals_x, self.current_y + 2, self.page_width - self.margin_right, self.current_y + 2, document.Color.black, 0.5);
            self.current_y -= 12;
            // Shift total label and value slightly left to align £ with column above
            try content.drawText("Total:", totals_x - 3, self.current_y, self.font_bold, 12, document.Color.black);
            var tot_buf: [32]u8 = undefined;
            const tot_str = formatCurrency(&tot_buf, section.total);
            try content.drawText(tot_str, totals_val_x - 3, self.current_y, self.font_bold, 12, primary);
            self.current_y -= 22;
        }

        // Notes (optional, small gray italic text below totals)
        if (section.notes) |notes| {
            if (notes.len > 0) {
                try self.checkPageBreak(content, 16);
                self.current_y -= 2;
                try self.drawTextConverted(content, notes, self.margin_left, self.current_y, self.font_oblique, 8, document.Color.fromHex("#888888"));
                self.current_y -= 14;
            }
        }

        self.current_y -= 10;
    }

    // ─── Chart Section ──────────────────────────────────────────────────

    /// Default palette for charts (matching zig_charts) — RGB values to avoid comptime branch limit
    const chart_palette = [_]document.Color{
        .{ .r = 0.231, .g = 0.510, .b = 0.965 }, // #3B82F6 blue
        .{ .r = 0.937, .g = 0.267, .b = 0.267 }, // #EF4444 red
        .{ .r = 0.063, .g = 0.725, .b = 0.506 }, // #10B981 green
        .{ .r = 0.961, .g = 0.620, .b = 0.043 }, // #F59E0B amber
        .{ .r = 0.545, .g = 0.361, .b = 0.965 }, // #8B5CF6 violet
        .{ .r = 0.925, .g = 0.286, .b = 0.600 }, // #EC4899 pink
        .{ .r = 0.024, .g = 0.714, .b = 0.831 }, // #06B6D4 cyan
        .{ .r = 0.976, .g = 0.451, .b = 0.086 }, // #F97316 orange
    };

    fn drawChartSection(self: *ProposalRenderer, content: *document.ContentStream, section: ProposalSection) !void {
        const primary = document.Color.fromHex(self.data.primary_color);
        const spec = section.chart_spec orelse return;

        // Estimate full section height so heading + chart stay together
        const heading_h: f32 = if (section.heading.len > 0) 21 else 0;
        const chart_type = spec.chart_type;
        const pie_legend_h: f32 = @as(f32, @floatFromInt(spec.segments.len)) * 16 + 10;
        const chart_body_h: f32 = if (std.mem.eql(u8, chart_type, "pie") or std.mem.eql(u8, chart_type, "donut"))
            80 * 2 + pie_legend_h + 30 // radius*2 + legend + margins
        else if (std.mem.eql(u8, chart_type, "bar"))
            @as(f32, @floatCast(spec.height)) + 80 // extra room for negative bars + legend
        else if (std.mem.eql(u8, chart_type, "progress"))
            @as(f32, @floatFromInt(spec.segments.len)) * 22 + 30
        else
            200;
        const full_section_h = heading_h + chart_body_h;

        // Keep heading + chart together: if it fits on a fresh page but not
        // this one, force a page break before drawing anything.
        const space_left = self.current_y - self.margin_bottom;
        const fresh_page_space = self.page_height - self.margin_top - self.margin_bottom;
        if (full_section_h <= fresh_page_space and full_section_h > space_left) {
            try self.checkPageBreak(content, fresh_page_space + 1);
        }

        // Heading
        if (section.heading.len > 0) {
            try self.checkPageBreak(content, 40);
            try self.drawTextConverted(content, section.heading, self.margin_left, self.current_y, self.font_bold, 14, primary);
            self.current_y -= 21;
        }

        if (std.mem.eql(u8, chart_type, "pie") or std.mem.eql(u8, chart_type, "donut")) {
            try self.drawPieChart(content, spec);
        } else if (std.mem.eql(u8, chart_type, "bar")) {
            try self.drawBarChart(content, spec);
        } else if (std.mem.eql(u8, chart_type, "progress")) {
            try self.drawProgressChart(content, spec);
        }

        self.current_y -= 10;
    }

    fn drawPieChart(self: *ProposalRenderer, content: *document.ContentStream, spec: ChartSpec) !void {
        const segments = spec.segments;
        if (segments.len == 0) return;

        // Calculate total
        var total: f64 = 0;
        for (segments) |seg| total += seg.value;
        if (total == 0) return;

        const radius: f32 = 80;
        const legend_h: f32 = @as(f32, @floatFromInt(segments.len)) * 16 + 10;
        const chart_h: f32 = radius * 2 + legend_h + 20;
        try self.checkPageBreak(content, chart_h);

        // Pie dimensions — center offset down by radius so pie sits below current_y
        const is_donut = std.mem.eql(u8, spec.chart_type, "donut");
        const cx = self.margin_left + 130;
        const cy = self.current_y - radius - 10;
        const inner_r: f32 = if (is_donut) radius * 0.5 else 0;
        _ = inner_r; // TODO: donut path

        // Draw pie segments
        var current_angle: f32 = -std.math.pi / 2.0; // Start from top
        for (segments, 0..) |seg, i| {
            const sweep: f32 = @floatCast((seg.value / total) * 2.0 * std.math.pi);
            const color = if (seg.color) |hex| document.Color.fromHex(hex) else chart_palette[i % chart_palette.len];

            // Draw pie segment using line approximation
            try content.setFillColor(color);
            try content.moveTo(cx, cy);

            const steps: u32 = 24;
            const step_angle = sweep / @as(f32, @floatFromInt(steps));
            var angle = current_angle;
            const sx = cx + @cos(angle) * radius;
            const sy = cy + @sin(angle) * radius;
            try content.lineTo(sx, sy);

            var s: u32 = 0;
            while (s <= steps) : (s += 1) {
                angle += step_angle;
                try content.lineTo(cx + @cos(angle) * radius, cy + @sin(angle) * radius);
            }

            try content.closePath();
            try content.fill();

            current_angle += sweep;
        }

        // White segment borders
        current_angle = -std.math.pi / 2.0;
        try content.setStrokeColor(.{ .r = 1, .g = 1, .b = 1 });
        try content.setLineWidth(1.5);
        for (segments) |seg| {
            const sweep: f32 = @floatCast((seg.value / total) * 2.0 * std.math.pi);
            try content.moveTo(cx, cy);
            try content.lineTo(cx + @cos(current_angle) * radius, cy + @sin(current_angle) * radius);
            try content.stroke();
            current_angle += sweep;
        }

        // Legend table (right side of pie, vertically centered)
        const legend_x = cx + radius + 30;
        const legend_total_h = @as(f32, @floatFromInt(segments.len)) * 16;
        var legend_y = cy + legend_total_h / 2 - 8; // Center legend vertically with pie
        const gray = document.Color{ .r = 0.25, .g = 0.25, .b = 0.25 };

        for (segments, 0..) |seg, i| {
            const color = if (seg.color) |hex| document.Color.fromHex(hex) else chart_palette[i % chart_palette.len];
            const pct: f32 = @floatCast((seg.value / total) * 100.0);

            // Color dot
            try content.drawRect(legend_x, legend_y - 7, 8, 8, color, null);

            // Label + percentage
            var label_buf: [128]u8 = undefined;
            const label = std.fmt.bufPrint(&label_buf, "{s}  {d:.1}%", .{ seg.label, pct }) catch seg.label;
            try content.drawText(label, legend_x + 14, legend_y, self.font_regular, 9, gray);

            legend_y -= 16;
        }

        // Advance Y past the pie + legend
        self.current_y = cy - radius - 20;
    }

    fn drawBarChart(self: *ProposalRenderer, content: *document.ContentStream, spec: ChartSpec) !void {
        const categories = spec.categories;
        const series_list = spec.series;
        if (categories.len == 0 or series_list.len == 0) return;

        const chart_h: f32 = @floatCast(spec.height);

        // Find max and min values across all series
        var max_val: f64 = 0;
        var min_val: f64 = 0;
        for (series_list) |s| {
            for (s.values) |v| {
                if (v > max_val) max_val = v;
                if (v < min_val) min_val = v;
            }
        }
        if (max_val == 0) max_val = 1;
        const has_negative = min_val < 0;
        const range = max_val - min_val;

        // Allocate vertical space: positive bars above baseline, negative below
        // Baseline position is proportional to how much of the range is positive
        const pos_ratio: f32 = @floatCast(max_val / range);
        const neg_ratio: f32 = @floatCast(@abs(min_val) / range);
        const draw_h = chart_h - 50; // Space for bars (excluding labels/legend)
        const pos_h = if (has_negative) draw_h * pos_ratio else draw_h;
        const neg_h = if (has_negative) draw_h * neg_ratio else 0;

        // Extra space needed for negative bars + labels below
        const extra_neg_space: f32 = if (has_negative) neg_h + 10 else 0;
        try self.checkPageBreak(content, chart_h + extra_neg_space + 50);

        const chart_left = self.margin_left + 40;
        const chart_right = self.page_width - self.margin_right;
        const chart_w = chart_right - chart_left;
        const chart_top = self.current_y - 5;

        // Baseline Y: sits below the positive bar area
        const baseline_y = chart_top - pos_h - 5;

        // Draw bars
        const num_cats: f32 = @floatFromInt(categories.len);
        const num_series: f32 = @floatFromInt(series_list.len);
        const group_w = chart_w / num_cats;
        const bar_w = (group_w * 0.7) / num_series;
        const gap = group_w * 0.15;

        const gray = document.Color{ .r = 0.25, .g = 0.25, .b = 0.25 };
        const light_gray = document.Color{ .r = 0.85, .g = 0.85, .b = 0.85 };

        // Baseline
        try content.drawLine(chart_left, baseline_y, chart_right, baseline_y, light_gray, if (has_negative) @as(f32, 1.0) else 0.5);

        for (categories, 0..) |cat, ci| {
            const cat_x = chart_left + @as(f32, @floatFromInt(ci)) * group_w;

            // Category label — below negative bars (or below baseline if no negatives)
            const label_y = baseline_y - neg_h - 14;
            try content.drawText(cat, cat_x + group_w / 2 - 10, label_y, self.font_regular, 8, gray);

            for (series_list, 0..) |s, si| {
                if (ci >= s.values.len) continue;
                const val = s.values[ci];
                const color = chart_palette[si % chart_palette.len];
                const bx = cat_x + gap + @as(f32, @floatFromInt(si)) * bar_w;

                if (val > 0) {
                    const bar_h: f32 = @floatCast((val / max_val) * pos_h);
                    try content.drawRect(bx, baseline_y, bar_w - 1, bar_h, color, null);
                } else if (val < 0) {
                    const bar_h: f32 = @floatCast((@abs(val) / @abs(min_val)) * neg_h);
                    try content.drawRect(bx, baseline_y - bar_h, bar_w - 1, bar_h, color, null);
                }
            }
        }

        // Legend below everything
        var lx = chart_left;
        const ly = baseline_y - neg_h - 30;
        for (series_list, 0..) |s, si| {
            const color = chart_palette[si % chart_palette.len];
            try content.drawRect(lx, ly - 7, 8, 8, color, null);
            try content.drawText(s.name, lx + 14, ly, self.font_regular, 9, gray);
            lx += 100;
        }

        self.current_y = ly - 20;
    }

    fn drawProgressChart(self: *ProposalRenderer, content: *document.ContentStream, spec: ChartSpec) !void {
        const segments = spec.segments;
        if (segments.len == 0) return;

        try self.checkPageBreak(content, @as(f32, @floatFromInt(segments.len)) * 24 + 20);

        const bar_left = self.margin_left + 120;
        const bar_right = self.page_width - self.margin_right - 40;
        const bar_w = bar_right - bar_left;
        const gray = document.Color{ .r = 0.25, .g = 0.25, .b = 0.25 };
        const bg = document.Color{ .r = 0.93, .g = 0.93, .b = 0.93 };

        for (segments, 0..) |seg, i| {
            const y = self.current_y - @as(f32, @floatFromInt(i)) * 22;
            const pct: f32 = @floatCast(@min(seg.value / 100.0, 1.0));
            const color = if (seg.color) |hex| document.Color.fromHex(hex) else chart_palette[i % chart_palette.len];

            // Label
            try content.drawText(seg.label, self.margin_left, y, self.font_regular, 9, gray);

            // Background bar
            try content.drawRect(bar_left, y - 8, bar_w, 12, bg, null);

            // Filled bar
            if (pct > 0) {
                try content.drawRect(bar_left, y - 8, bar_w * pct, 12, color, null);
            }

            // Percentage text
            var pct_buf: [16]u8 = undefined;
            const pct_str = std.fmt.bufPrint(&pct_buf, "{d:.0}%", .{seg.value}) catch "";
            try content.drawText(pct_str, bar_right + 6, y, self.font_regular, 9, gray);
        }

        self.current_y -= @as(f32, @floatFromInt(segments.len)) * 22 + 10;
    }

    // ─── Footer ──────────────────────────────────────────────────────────

    fn drawFooter(self: *ProposalRenderer, content: *document.ContentStream) !void {
        const primary = document.Color.fromHex(self.data.primary_color);
        const footer = self.data.footer;

        // Colored bar at bottom
        try content.drawRect(0, 0, self.page_width, 30, primary, null);

        // Footer text centered in bar
        var buf: [256]u8 = undefined;
        const footer_text = std.fmt.bufPrint(&buf, "{s}  |  {s}  |  {s}", .{
            footer.phone,
            footer.email,
            footer.website,
        }) catch "";

        if (footer_text.len > 0) {
            const font = document.Font.helvetica;
            const text_width = font.measureText(footer_text, 8);
            const text_x = (self.page_width - text_width) / 2;
            try content.drawText(footer_text, text_x, 10, self.font_regular, 8, document.Color.white);
        }

        // QR code + dashboard text area (above footer bar)
        const has_qr = self.qr_id != null;
        const qr_display_size: f32 = 55;

        if (has_qr and footer.dashboard_text.len > 0) {
            // QR code on the right, dashboard text on the left
            const qr_x = self.page_width - self.margin_right - qr_display_size;
            const qr_y: f32 = 33;
            try content.drawImage(self.qr_id.?, qr_x, qr_y, qr_display_size, qr_display_size);

            // "Scan to view your quote" label under QR
            const scan_label = "Scan to view your quote";
            const scan_font = document.Font.helvetica;
            const scan_w = scan_font.measureText(scan_label, 6);
            try content.drawText(scan_label, qr_x + (qr_display_size - scan_w) / 2, qr_y - 8, self.font_regular, 6, document.Color.fromHex("#888888"));

            // Dashboard text to the left of QR
            const converted = try utf8ToWinAnsi(self.allocator, footer.dashboard_text);
            defer self.allocator.free(converted);
            const text_area_width = qr_x - self.margin_left - 15;
            var wrapped = try document.wrapText(self.allocator, converted, document.Font.helvetica_oblique, 7.5, text_area_width);
            defer wrapped.deinit();
            var text_y: f32 = 62;
            for (wrapped.lines) |line| {
                try content.drawText(line, self.margin_left, text_y, self.font_oblique, 7.5, document.Color.fromHex("#666666"));
                text_y -= 10;
            }
        } else if (has_qr) {
            // QR code only, centered above footer
            const qr_x = (self.page_width - qr_display_size) / 2;
            const qr_y: f32 = 35;
            try content.drawImage(self.qr_id.?, qr_x, qr_y, qr_display_size, qr_display_size);

            const scan_label = "Scan to view your quote";
            const scan_font = document.Font.helvetica;
            const scan_w = scan_font.measureText(scan_label, 6);
            try content.drawText(scan_label, qr_x + (qr_display_size - scan_w) / 2, qr_y - 8, self.font_regular, 6, document.Color.fromHex("#888888"));
        } else if (footer.dashboard_text.len > 0) {
            // Dashboard text only, centered
            const dash_font = document.Font.helvetica_oblique;
            const converted = try utf8ToWinAnsi(self.allocator, footer.dashboard_text);
            defer self.allocator.free(converted);
            const dash_width = dash_font.measureText(converted, 7);
            const dash_x = (self.page_width - dash_width) / 2;
            try content.drawText(converted, dash_x, 35, self.font_oblique, 7, document.Color.fromHex("#888888"));
        }

        // Page number (right-aligned above QR/dashboard area)
        var page_buf: [32]u8 = undefined;
        const page_text = std.fmt.bufPrint(&page_buf, "Page {d} of {d}", .{ self.page_number, self.total_pages }) catch "";
        const page_font = document.Font.helvetica;
        const page_width = page_font.measureText(page_text, 7);
        const page_y: f32 = if (has_qr) 92 else 46;
        try content.drawText(page_text, self.page_width - self.margin_right - page_width, page_y, self.font_regular, 7, document.Color.fromHex("#999999"));
    }

    // ─── Render ──────────────────────────────────────────────────────────

    pub fn render(self: *ProposalRenderer) ![]const u8 {
        var content = document.ContentStream.init(self.allocator);
        errdefer content.deinit();

        // Load logo if provided
        if (self.data.company_logo_base64) |logo_b64| {
            if (logo_b64.len > 0) {
                const result = image.loadImageFromBase64(self.allocator, logo_b64) catch null;
                if (result) |r| {
                    self.logo_decoded = r.decoded_bytes;
                    if (r.image.format != .jpeg) {
                        self.logo_pixels = @constCast(r.image.data);
                    }
                    self.logo_id = self.doc.addImage(r.image) catch null;
                }
            }
        }

        // Load property image if provided
        if (self.data.property_image_base64) |prop_b64| {
            if (prop_b64.len > 0) {
                const result = image.loadImageFromBase64(self.allocator, prop_b64) catch null;
                if (result) |r| {
                    self.property_decoded = r.decoded_bytes;
                    if (r.image.format != .jpeg) {
                        self.property_pixels = @constCast(r.image.data);
                    }
                    self.property_id = self.doc.addImage(r.image) catch null;
                }
            }
        }

        // Generate QR code for dashboard URL
        if (self.data.footer.dashboard_url.len > 0) {
            var qr_img = qrcode.encodeAndRender(self.allocator, self.data.footer.dashboard_url, 4, .{ .ec_level = .M, .quiet_zone = 2 }) catch null;
            if (qr_img) |*qi| {
                self.qr_pixels = qi.pixels;
                self.qr_size = qi.width;
                const qr_image = document.Image{
                    .width = qi.width,
                    .height = qi.height,
                    .format = .raw_rgb,
                    .data = qi.pixels,
                };
                self.qr_id = self.doc.addImage(qr_image) catch null;
                // Increase bottom margin to accommodate QR code + label above footer bar
                self.margin_bottom = 100;
            }
        }

        // First page header
        try self.drawFirstPageHeader(&content);

        // Render sections
        for (self.data.sections, 0..) |section, i| {
            // Inter-section spacing — visual breathing room between components
            if (i > 0) {
                self.current_y -= 28;
            }

            switch (section.section_type) {
                .text => try self.drawTextSection(&content, section),
                .metrics => try self.drawMetricsSection(&content, section),
                .table => try self.drawTableSection(&content, section),
                .chart => try self.drawChartSection(&content, section),
            }
        }

        // Save final page — ownership transfers to pages array
        try self.pages.append(self.allocator, content);
        content.buffer = .empty;

        // Update total pages
        self.total_pages = @intCast(self.pages.items.len);

        // Render footers and add all pages
        for (self.pages.items, 0..) |*page, page_idx| {
            self.page_number = @intCast(page_idx + 1);
            try self.drawFooter(page);
            try self.doc.addPage(page);
        }

        return self.doc.build();
    }
};

// =============================================================================
// Currency Formatting
// =============================================================================

fn formatCurrency(buf: *[32]u8, amount: f64) []const u8 {
    // WinAnsiEncoding: £ = single byte 0xA3
    const abs_amount = @abs(amount);
    const pounds: u64 = @intFromFloat(abs_amount);
    const pence: u64 = @intFromFloat((abs_amount - @as(f64, @floatFromInt(pounds))) * 100 + 0.5);

    if (pounds >= 1_000_000) {
        return std.fmt.bufPrint(buf, "\xa3{d},{d:0>3},{d:0>3}.{d:0>2}", .{
            pounds / 1_000_000,
            (pounds / 1000) % 1000,
            pounds % 1000,
            pence,
        }) catch "0.00";
    } else if (pounds >= 1000) {
        return std.fmt.bufPrint(buf, "\xa3{d},{d:0>3}.{d:0>2}", .{
            pounds / 1000,
            pounds % 1000,
            pence,
        }) catch "0.00";
    } else {
        return std.fmt.bufPrint(buf, "\xa3{d}.{d:0>2}", .{ pounds, pence }) catch "0.00";
    }
}

// =============================================================================
// JSON Parser
// =============================================================================

fn dupeJsonString(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) !?[]const u8 {
    if (obj.get(key)) |v| {
        return switch (v) {
            .string => |s| try allocator.dupe(u8, s),
            else => null,
        };
    }
    return null;
}

fn dupeJsonStringDefault(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8, default: []const u8) ![]const u8 {
    return try dupeJsonString(allocator, obj, key) orelse try allocator.dupe(u8, default);
}

fn getJsonFloat(v: std.json.Value) f64 {
    return switch (v) {
        .float => v.float,
        .integer => @floatFromInt(v.integer),
        else => 0,
    };
}

const ParsedProposal = struct {
    data: ProposalData,
    sections_buf: []ProposalSection,
    metric_bufs: [][]MetricItem,
    table_bufs: [][]TableItem,

    pub fn deinit(self: ParsedProposal, allocator: std.mem.Allocator) void {
        for (self.metric_bufs) |buf| allocator.free(buf);
        for (self.table_bufs) |buf| allocator.free(buf);
        allocator.free(self.metric_bufs);
        allocator.free(self.table_bufs);
        allocator.free(self.sections_buf);
    }
};

fn parseProposalJson(allocator: std.mem.Allocator, json_str: []const u8) !ParsedProposal {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const root = parsed.value.object;

    var data = ProposalData{};

    data.company_name = try dupeJsonStringDefault(allocator, root, "company_name", "");
    data.company_address = try dupeJsonStringDefault(allocator, root, "company_address", "");
    data.company_logo_base64 = try dupeJsonString(allocator, root, "company_logo_base64");
    data.property_image_base64 = try dupeJsonString(allocator, root, "property_image_base64");
    data.client_name = try dupeJsonStringDefault(allocator, root, "client_name", "");
    data.client_address = try dupeJsonStringDefault(allocator, root, "client_address", "");
    data.reference = try dupeJsonStringDefault(allocator, root, "reference", "");
    data.date = try dupeJsonStringDefault(allocator, root, "date", "");
    data.valid_until = try dupeJsonStringDefault(allocator, root, "valid_until", "");
    data.primary_color = try dupeJsonStringDefault(allocator, root, "primary_color", "#16a34a");
    data.secondary_color = try dupeJsonStringDefault(allocator, root, "secondary_color", "#1e3a2f");

    // Footer
    if (root.get("footer")) |f| {
        if (f == .object) {
            data.footer = .{
                .phone = try dupeJsonStringDefault(allocator, f.object, "phone", ""),
                .email = try dupeJsonStringDefault(allocator, f.object, "email", ""),
                .website = try dupeJsonStringDefault(allocator, f.object, "website", ""),
                .dashboard_text = try dupeJsonStringDefault(allocator, f.object, "dashboard_text", ""),
                .dashboard_url = try dupeJsonStringDefault(allocator, f.object, "dashboard_url", ""),
            };
        }
    }

    // Sections
    var sections_buf: []ProposalSection = &[_]ProposalSection{};
    var metric_bufs: std.ArrayListUnmanaged([]MetricItem) = .empty;
    var table_bufs: std.ArrayListUnmanaged([]TableItem) = .empty;

    if (root.get("sections")) |s| {
        if (s == .array) {
            const arr = s.array.items;
            sections_buf = try allocator.alloc(ProposalSection, arr.len);

            for (arr, 0..) |sec_val, i| {
                if (sec_val != .object) {
                    sections_buf[i] = .{};
                    continue;
                }
                const obj = sec_val.object;

                const type_str = try dupeJsonStringDefault(allocator, obj, "type", "text");
                defer allocator.free(type_str);
                const sec_type: SectionType = if (std.mem.eql(u8, type_str, "metrics"))
                    .metrics
                else if (std.mem.eql(u8, type_str, "table"))
                    .table
                else if (std.mem.eql(u8, type_str, "chart"))
                    .chart
                else
                    .text;

                sections_buf[i] = .{
                    .section_type = sec_type,
                    .heading = try dupeJsonStringDefault(allocator, obj, "heading", ""),
                    .content = try dupeJsonStringDefault(allocator, obj, "content", ""),
                };

                if (obj.get("metric_items")) |mi| {
                    if (mi == .array) {
                        const m_arr = mi.array.items;
                        const items = try allocator.alloc(MetricItem, m_arr.len);
                        for (m_arr, 0..) |m_val, j| {
                            if (m_val == .object) {
                                items[j] = .{
                                    .label = try dupeJsonStringDefault(allocator, m_val.object, "label", ""),
                                    .value = try dupeJsonStringDefault(allocator, m_val.object, "value", ""),
                                };
                            } else {
                                items[j] = .{};
                            }
                        }
                        sections_buf[i].metric_items = items;
                        try metric_bufs.append(allocator, items);
                    }
                }

                if (obj.get("table_items")) |ti| {
                    if (ti == .array) {
                        const t_arr = ti.array.items;
                        const items = try allocator.alloc(TableItem, t_arr.len);
                        for (t_arr, 0..) |t_val, j| {
                            if (t_val == .object) {
                                items[j] = .{
                                    .description = try dupeJsonStringDefault(allocator, t_val.object, "description", ""),
                                    .quantity = if (t_val.object.get("quantity")) |q| getJsonFloat(q) else 0,
                                    .unit_price = if (t_val.object.get("unit_price")) |p| getJsonFloat(p) else 0,
                                    .total = if (t_val.object.get("total")) |t| getJsonFloat(t) else 0,
                                };
                            } else {
                                items[j] = .{};
                            }
                        }
                        sections_buf[i].table_items = items;
                        try table_bufs.append(allocator, items);
                    }
                }

                if (obj.get("subtotal")) |v| sections_buf[i].subtotal = getJsonFloat(v);
                if (obj.get("tax_rate")) |v| sections_buf[i].tax_rate = getJsonFloat(v);
                if (obj.get("total")) |v| sections_buf[i].total = getJsonFloat(v);
                sections_buf[i].notes = try dupeJsonString(allocator, obj, "notes");

                // Parse chart_spec for chart sections
                if (obj.get("chart_spec")) |cs| {
                    if (cs == .object) {
                        var chart = ChartSpec{};
                        if (cs.object.get("chart_type")) |ct| if (ct == .string) { chart.chart_type = ct.string; };
                        if (cs.object.get("width")) |w| chart.width = getJsonFloat(w);
                        if (cs.object.get("height")) |h| chart.height = getJsonFloat(h);

                        // Parse segments (pie, donut, progress)
                        if (cs.object.get("segments")) |segs| {
                            if (segs == .array) {
                                const seg_arr = segs.array.items;
                                const chart_segs = try allocator.alloc(ChartSegment, seg_arr.len);
                                for (seg_arr, 0..) |sv, si| {
                                    if (sv == .object) {
                                        chart_segs[si] = .{
                                            .label = try dupeJsonStringDefault(allocator, sv.object, "label", ""),
                                            .value = if (sv.object.get("value")) |v| getJsonFloat(v) else 0,
                                            .color = try dupeJsonString(allocator, sv.object, "color"),
                                        };
                                    } else {
                                        chart_segs[si] = .{};
                                    }
                                }
                                chart.segments = chart_segs;
                            }
                        }

                        // Parse categories (bar charts)
                        if (cs.object.get("categories")) |cats| {
                            if (cats == .array) {
                                const cat_arr = cats.array.items;
                                const cat_strs = try allocator.alloc([]const u8, cat_arr.len);
                                for (cat_arr, 0..) |cv, ci| {
                                    cat_strs[ci] = if (cv == .string) try allocator.dupe(u8, cv.string) else "";
                                }
                                chart.categories = cat_strs;
                            }
                        }

                        // Parse series (bar charts)
                        if (cs.object.get("series")) |ser| {
                            if (ser == .array) {
                                const ser_arr = ser.array.items;
                                const chart_series = try allocator.alloc(ChartBarSeries, ser_arr.len);
                                for (ser_arr, 0..) |sv, si| {
                                    if (sv == .object) {
                                        chart_series[si] = .{
                                            .name = try dupeJsonStringDefault(allocator, sv.object, "name", ""),
                                        };
                                        if (sv.object.get("values")) |vals| {
                                            if (vals == .array) {
                                                const v_arr = vals.array.items;
                                                const floats = try allocator.alloc(f64, v_arr.len);
                                                for (v_arr, 0..) |fv, fi| {
                                                    floats[fi] = switch (fv) {
                                                        .integer => |n| @floatFromInt(n),
                                                        .float => |f| f,
                                                        else => 0,
                                                    };
                                                }
                                                chart_series[si].values = floats;
                                            }
                                        }
                                    } else {
                                        chart_series[si] = .{};
                                    }
                                }
                                chart.series = chart_series;
                            }
                        }

                        sections_buf[i].chart_spec = chart;
                    }
                }
            }
            data.sections = sections_buf;
        }
    }

    return .{
        .data = data,
        .sections_buf = sections_buf,
        .metric_bufs = try metric_bufs.toOwnedSlice(allocator),
        .table_bufs = try table_bufs.toOwnedSlice(allocator),
    };
}

// =============================================================================
// Public API
// =============================================================================

pub fn generateProposalFromJson(allocator: std.mem.Allocator, json_str: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const parsed = try parseProposalJson(arena_alloc, json_str);

    var renderer = ProposalRenderer.init(arena_alloc, parsed.data);
    defer renderer.deinit();

    const pdf_output = try renderer.render();
    return try allocator.dupe(u8, pdf_output);
}

/// Generate a demo proposal PDF — online quote context (no survey assumed)
pub fn generateDemoProposal(allocator: std.mem.Allocator) ![]u8 {
    const demo_json =
        \\{
        \\  "company_name": "CRG Direct",
        \\  "company_address": "Unit 7 Solent Business Park, Fareham, Hampshire PO15 7FH",
        \\  "client_name": "Mr & Mrs Johnson",
        \\  "client_address": "42 Oak Lane\nSouthampton\nSO16 3QR",
        \\  "reference": "CRG-2026-00123",
        \\  "date": "8 February 2026",
        \\  "valid_until": "10 March 2026",
        \\  "primary_color": "#16a34a",
        \\  "secondary_color": "#1e3a2f",
        \\  "footer": {
        \\    "phone": "01329 800 123",
        \\    "email": "info@crgdirect.co.uk",
        \\    "website": "www.crgdirect.co.uk",
        \\    "dashboard_text": "Sign in to your CRG Direct dashboard at dashboard.crgdirect.co.uk to view your quote, track progress and manage your installation.",
        \\    "dashboard_url": "https://dashboard.crgdirect.co.uk/quotes/CRG-2026-00123"
        \\  },
        \\  "sections": [
        \\    {
        \\      "type": "text",
        \\      "heading": "Your Personalised Quote",
        \\      "content": "Thank you for your interest in solar energy. Based on your property details and energy usage, we have prepared this personalised quote for a solar PV system tailored to your home.\n\nThis quote covers everything you need for a complete solar installation, from panels and inverter through to full electrical commissioning and ongoing monitoring. All prices are fully inclusive with no hidden extras."
        \\    },
        \\    {
        \\      "type": "metrics",
        \\      "heading": "Estimated System Performance",
        \\      "metric_items": [
        \\        { "label": "System Size", "value": "4.2 kWp" },
        \\        { "label": "Annual Generation", "value": "3,800 kWh" },
        \\        { "label": "Est. Annual Savings", "value": "\u00a31,140/yr" },
        \\        { "label": "CO2 Offset", "value": "0.88 tonnes" }
        \\      ]
        \\    },
        \\    {
        \\      "type": "table",
        \\      "heading": "System Pricing",
        \\      "table_items": [
        \\        { "description": "JA Solar 420W All-Black Mono PERC Panels", "quantity": 10, "unit_price": 185.00, "total": 1850.00 },
        \\        { "description": "GivEnergy 5.2kWh All-in-One Battery System", "quantity": 1, "unit_price": 2895.00, "total": 2895.00 },
        \\        { "description": "Full Electrical Installation & Commissioning", "quantity": 1, "unit_price": 1450.00, "total": 1450.00 },
        \\        { "description": "Scaffolding & Access Equipment", "quantity": 1, "unit_price": 385.00, "total": 385.00 }
        \\      ],
        \\      "subtotal": 6580.00,
        \\      "tax_rate": 0.0,
        \\      "total": 6580.00,
        \\      "notes": "Includes: MCS certification, 10-year workmanship warranty, system monitoring setup, DNO notification and G99 compliance"
        \\    },
        \\    {
        \\      "type": "text",
        \\      "heading": "About Your Solar Panels",
        \\      "content": "The JA Solar 420W All-Black panels specified in this quote are tier-1 rated modules with industry-leading efficiency of 21.3%. Key features:\n\n- Half-cut cell technology for improved shade tolerance and higher yield\n- All-black aesthetic design that blends with your roof\n- 25-year product warranty and 30-year linear performance guarantee\n- Rated for wind loads up to 2400Pa and snow loads up to 5400Pa\n- Anti-PID (Potential Induced Degradation) certified\n\nThese panels are manufactured by JA Solar, one of the world's largest and most trusted solar manufacturers, with over 100GW shipped globally."
        \\    },
        \\    {
        \\      "type": "text",
        \\      "heading": "About Your Battery Storage",
        \\      "content": "The GivEnergy 5.2kWh All-in-One system combines a hybrid inverter and battery in a single compact unit. This is what makes a real difference to your energy bills:\n\n- Store excess solar generation during the day for use in the evening peak hours\n- Intelligent time-of-use tariff support \u2014 charge overnight at cheap rates, use during expensive peak periods\n- Emergency Power Supply (EPS) \u2014 keeps essential circuits running during power cuts\n- Remote monitoring and control via the GivEnergy app on your phone\n- Expandable \u2014 add a second battery later to increase storage to 10.4kWh\n\nBased on typical usage, the battery increases your self-consumption rate from approximately 35% to 75%, meaning you use far more of the energy your panels generate rather than exporting it."
        \\    },
        \\    {
        \\      "type": "text",
        \\      "heading": "Why Choose CRG Direct?",
        \\      "content": "CRG Direct has been installing solar and renewable energy systems across Hampshire and the South Coast since 2018. Every installation is completed by MCS-certified engineers to the highest industry standards.\n\n- Over 1,200 residential solar installations completed\n- Average customer saves 65% on electricity bills in year one\n- All systems remotely monitored with proactive maintenance alerts\n- 10-year workmanship warranty backed by insurance-backed guarantee\n- Finance options available from 0% APR (subject to status)\n- Rated 4.9/5 on Trustpilot with over 400 verified reviews\n\nRecent case study: A 4-bedroom detached property in Eastleigh with a similar 4.2kWp system achieved 4,100 kWh generation in its first year, exceeding projected output by 8%. The homeowner reported electricity bills reduced from \u00a3180/month to \u00a362/month."
        \\    },
        \\    {
        \\      "type": "text",
        \\      "heading": "What Happens Next",
        \\      "content": "Getting started with your solar installation is simple:\n\n- Review this quote and choose your preferred system configuration\n- Accept your quote online via your CRG Direct dashboard\n- We arrange a technical site survey to confirm system design (free of charge)\n- We handle all DNO applications and approvals on your behalf (typically 4-6 weeks)\n- Installation completed in 1-2 days with minimal disruption to your home\n- Full commissioning, testing and handover including monitoring app setup\n\nYour quote is saved to your CRG Direct dashboard where you can review it at any time, ask questions, and track the progress of your installation once you proceed.\n\nQuestions? Call us on 01329 800 123 or email info@crgdirect.co.uk. We are always happy to help."
        \\    }
        \\  ]
        \\}
    ;

    return generateProposalFromJson(allocator, demo_json);
}
