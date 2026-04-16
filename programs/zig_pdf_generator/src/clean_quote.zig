// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! Clean Quote Document Renderer — Minimalist consultant-style template.
//!
//! A premium white-paper layout with a single accent colour used sparingly.
//! Document type (QUOTE/INVOICE/HANDOVER/INSPECTION) is derived from the
//! reference prefix (QTE/INV/HND/INS).
//!
//! Shared JSON schema with proposal.zig so TS callers can swap between
//! brand-heavy and minimalist templates by changing the FFI function name.
//!
//! Colour palette:
//!   Ink black       #0a0a0a  — body text
//!   Muted grey      #52525b  — secondary labels
//!   Subtle grey     #71717a  — tertiary text
//!   Border          #e4e4e7  — hairlines, table rules
//!   Card background #f5f5f4  — metrics card fill
//!   Accent red      #DC2626  — document type word, hairline, bullet dots

const std = @import("std");
const document = @import("document.zig");
const proposal = @import("proposal.zig");

// Reuse types from proposal.zig — same JSON contract
pub const MetricItem = proposal.MetricItem;
pub const TableItem = proposal.TableItem;
pub const FooterInfo = proposal.FooterInfo;
pub const ProposalSection = proposal.ProposalSection;
pub const ProposalData = proposal.ProposalData;

// =============================================================================
// Colour Palette
// =============================================================================

const INK_BLACK = document.Color{ .r = 0.039, .g = 0.039, .b = 0.039 }; // #0a0a0a
const MUTED_GREY = document.Color{ .r = 0.322, .g = 0.322, .b = 0.357 }; // #52525b
const SUBTLE_GREY = document.Color{ .r = 0.443, .g = 0.443, .b = 0.478 }; // #71717a
const BORDER_GREY = document.Color{ .r = 0.894, .g = 0.894, .b = 0.906 }; // #e4e4e7
const CARD_BG = document.Color{ .r = 0.961, .g = 0.961, .b = 0.949 }; // #f5f5f4
const ACCENT_RED = document.Color{ .r = 0.863, .g = 0.149, .b = 0.149 }; // #DC2626
const WHITE = document.Color{ .r = 1.0, .g = 1.0, .b = 1.0 };

// =============================================================================
// UTF-8 → WinAnsiEncoding (shared helper)
// =============================================================================

fn utf8ToWinAnsi(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < text.len) {
        if (i + 1 < text.len and text[i] == 0xC2) {
            const b2 = text[i + 1];
            if (b2 >= 0xA0) {
                try result.append(allocator, b2);
                i += 2;
                continue;
            }
        }
        if (i + 2 < text.len and text[i] == 0xE2) {
            const b2 = text[i + 1];
            const b3 = text[i + 2];
            if (b2 == 0x80) {
                const mapped: ?u8 = switch (b3) {
                    0x93 => 0x96, // –
                    0x94 => 0x97, // —
                    0x98 => 0x91, // ‘
                    0x99 => 0x92, // ’
                    0x9C => 0x93, // “
                    0x9D => 0x94, // ”
                    0xA2 => 0x95, // •
                    0xA6 => 0x85, // …
                    else => null,
                };
                if (mapped) |m| {
                    try result.append(allocator, m);
                    i += 3;
                    continue;
                }
            }
            if (b2 == 0x82 and b3 == 0xAC) {
                try result.append(allocator, 0x80); // €
                i += 3;
                continue;
            }
        }
        try result.append(allocator, text[i]);
        i += 1;
    }
    return result.toOwnedSlice(allocator);
}

// =============================================================================
// Document Type Derivation
// =============================================================================

/// Map reference prefix to document type word.
///   QTE-... → "QUOTE"
///   INV-... → "INVOICE"
///   HND-... → "HANDOVER"
///   INS-... → "INSPECTION"
///   anything else → "QUOTE"
fn deriveDocTypeWord(reference: []const u8) []const u8 {
    if (reference.len >= 3) {
        const p = reference[0..3];
        if (std.ascii.eqlIgnoreCase(p, "QTE")) return "QUOTE";
        if (std.ascii.eqlIgnoreCase(p, "INV")) return "INVOICE";
        if (std.ascii.eqlIgnoreCase(p, "HND")) return "HANDOVER";
        if (std.ascii.eqlIgnoreCase(p, "INS")) return "INSPECTION";
    }
    return "QUOTE";
}

// =============================================================================
// Clean Quote Renderer
// =============================================================================

pub const CleanQuoteRenderer = struct {
    allocator: std.mem.Allocator,
    doc: document.PdfDocument,
    data: ProposalData,

    font_regular: []const u8 = "F0",
    font_bold: []const u8 = "F1",
    font_oblique: []const u8 = "F2",

    current_y: f32 = 0,
    page_number: u32 = 1,
    total_pages: u32 = 1,

    margin_left: f32 = 50,
    margin_right: f32 = 50,
    margin_top: f32 = 50,
    margin_bottom: f32 = 55,
    page_width: f32 = document.A4_WIDTH,
    page_height: f32 = document.A4_HEIGHT,
    usable_width: f32 = 0,

    pages: std.ArrayListUnmanaged(document.ContentStream),

    pub fn init(allocator: std.mem.Allocator, data: ProposalData) CleanQuoteRenderer {
        var r = CleanQuoteRenderer{
            .allocator = allocator,
            .doc = document.PdfDocument.init(allocator),
            .data = data,
            .pages = .empty,
        };
        r.usable_width = r.page_width - r.margin_left - r.margin_right;
        r.font_regular = r.doc.getFontId(.helvetica);
        r.font_bold = r.doc.getFontId(.helvetica_bold);
        r.font_oblique = r.doc.getFontId(.helvetica_oblique);
        r.current_y = r.page_height - r.margin_top;
        return r;
    }

    pub fn deinit(self: *CleanQuoteRenderer) void {
        for (self.pages.items) |*page| page.deinit();
        self.pages.deinit(self.allocator);
        self.doc.deinit();
    }

    // ─── Text helper (auto UTF-8 conversion) ─────────────────────

    fn drawTextConverted(self: *CleanQuoteRenderer, content: *document.ContentStream, text: []const u8, x: f32, y: f32, font_id: []const u8, size: f32, color: document.Color) !void {
        const converted = try utf8ToWinAnsi(self.allocator, text);
        defer self.allocator.free(converted);
        try content.drawText(converted, x, y, font_id, size, color);
    }

    fn measureText(_: *CleanQuoteRenderer, text: []const u8, font: document.Font, font_size: f32) f32 {
        // Approximate — for exact measurement use font.measureText directly
        return font.measureText(text, font_size);
    }

    // ─── Page management ────────────────────────────────────────

    fn checkPageBreak(self: *CleanQuoteRenderer, content: *document.ContentStream, needed_height: f32) !void {
        if (self.current_y - needed_height >= self.margin_bottom) return;
        // Save current page and start new one
        try self.pages.append(self.allocator, content.*);
        content.* = document.ContentStream.init(self.allocator);
        self.current_y = self.page_height - self.margin_top;
    }

    // ─── Header ─────────────────────────────────────────────────

    fn drawHeader(self: *CleanQuoteRenderer, content: *document.ContentStream) !void {
        const top_y = self.current_y;

        // Company name — bold black, top-left, 20pt
        const company = if (self.data.company_name.len > 0) self.data.company_name else "COMPANY";
        try self.drawTextConverted(content, company, self.margin_left, top_y - 16, self.font_bold, 20, INK_BLACK);

        // Company tagline / address line beneath, small uppercase grey
        if (self.data.company_address.len > 0) {
            // Take just the first line as a tagline if multi-line
            var tagline_end: usize = self.data.company_address.len;
            for (self.data.company_address, 0..) |c, i| {
                if (c == '\n' or c == ',') { tagline_end = i; break; }
            }
            const tagline = self.data.company_address[0..tagline_end];
            const upper = try std.ascii.allocUpperString(self.allocator, tagline);
            defer self.allocator.free(upper);
            try self.drawTextConverted(content, upper, self.margin_left, top_y - 30, self.font_regular, 8.5, SUBTLE_GREY);
        }

        // Document type word — right side, large, accent red
        const doc_type = deriveDocTypeWord(self.data.reference);
        const doc_type_size: f32 = 28;
        const doc_type_width = document.Font.helvetica_bold.measureText(doc_type, doc_type_size);
        const right_x = self.page_width - self.margin_right;
        try self.drawTextConverted(content, doc_type, right_x - doc_type_width, top_y - 22, self.font_bold, doc_type_size, ACCENT_RED);

        // Reference number beneath doc type — small grey
        if (self.data.reference.len > 0) {
            const ref_width = document.Font.helvetica.measureText(self.data.reference, 10);
            try self.drawTextConverted(content, self.data.reference, right_x - ref_width, top_y - 38, self.font_regular, 10, MUTED_GREY);
        }

        self.current_y = top_y - 50;

        // Contact row — grey, single row (phone · email left, website right)
        const have_contact = self.data.footer.phone.len > 0 or self.data.footer.email.len > 0 or self.data.footer.website.len > 0;
        if (have_contact) {
            var contact_left: std.ArrayListUnmanaged(u8) = .empty;
            defer contact_left.deinit(self.allocator);
            if (self.data.footer.phone.len > 0) {
                try contact_left.appendSlice(self.allocator, self.data.footer.phone);
            }
            if (self.data.footer.email.len > 0) {
                if (contact_left.items.len > 0) try contact_left.appendSlice(self.allocator, "  \u{00B7}  ");
                try contact_left.appendSlice(self.allocator, self.data.footer.email);
            }
            if (contact_left.items.len > 0) {
                try self.drawTextConverted(content, contact_left.items, self.margin_left, self.current_y, self.font_regular, 10, MUTED_GREY);
            }
            if (self.data.footer.website.len > 0) {
                const www_width = document.Font.helvetica.measureText(self.data.footer.website, 10);
                try self.drawTextConverted(content, self.data.footer.website, right_x - www_width, self.current_y, self.font_regular, 10, MUTED_GREY);
            }
            self.current_y -= 18;
        }

        // Red hairline separator
        try content.drawLine(self.margin_left, self.current_y, self.page_width - self.margin_right, self.current_y, ACCENT_RED, 0.5);
        self.current_y -= 22;

        // Prepared-for / dates two-column block
        try self.drawPreparedForDates(content);
    }

    fn drawPreparedForDates(self: *CleanQuoteRenderer, content: *document.ContentStream) !void {
        const col_right_x = self.margin_left + self.usable_width / 2 + 40;
        const top_y = self.current_y;

        // Left: PREPARED FOR
        try self.drawUppercaseLabel(content, "PREPARED FOR", self.margin_left, top_y);
        if (self.data.client_name.len > 0) {
            try self.drawTextConverted(content, self.data.client_name, self.margin_left, top_y - 16, self.font_bold, 13, INK_BLACK);
        }
        if (self.data.client_address.len > 0) {
            // Use only first line / first segment as email/contact info
            var addr_end: usize = self.data.client_address.len;
            for (self.data.client_address, 0..) |c, i| {
                if (c == '\n') { addr_end = i; break; }
            }
            const addr = self.data.client_address[0..addr_end];
            try self.drawTextConverted(content, addr, self.margin_left, top_y - 30, self.font_regular, 10.5, MUTED_GREY);
        }

        // Right: DATE + VALID UNTIL
        if (self.data.date.len > 0) {
            try self.drawUppercaseLabel(content, "DATE", col_right_x, top_y);
            try self.drawTextConverted(content, self.data.date, col_right_x, top_y - 16, self.font_regular, 11, INK_BLACK);
        }
        if (self.data.valid_until.len > 0) {
            try self.drawUppercaseLabel(content, "VALID UNTIL", col_right_x + 140, top_y);
            try self.drawTextConverted(content, self.data.valid_until, col_right_x + 140, top_y - 16, self.font_regular, 11, INK_BLACK);
        }

        self.current_y = top_y - 48;
    }

    fn drawUppercaseLabel(self: *CleanQuoteRenderer, content: *document.ContentStream, label: []const u8, x: f32, y: f32) !void {
        try self.drawTextConverted(content, label, x, y, self.font_bold, 8.5, SUBTLE_GREY);
    }

    // ─── Footer (minimal, single grey line) ─────────────────────

    fn drawFooter(self: *CleanQuoteRenderer, content: *document.ContentStream) !void {
        const y = self.margin_bottom - 20;

        // Build single footer line: COMPANY · COMPANY NO · WEBSITE
        var line: std.ArrayListUnmanaged(u8) = .empty;
        defer line.deinit(self.allocator);

        if (self.data.company_name.len > 0) {
            const upper = try std.ascii.allocUpperString(self.allocator, self.data.company_name);
            defer self.allocator.free(upper);
            try line.appendSlice(self.allocator, upper);
        }

        // Extract company number if present in address (look for pattern "No. XXXXX" or "CO. NO. XXX")
        // For now, keep it simple — caller can put it in the website or add a future field

        if (self.data.footer.website.len > 0) {
            if (line.items.len > 0) try line.appendSlice(self.allocator, "  \u{00B7}  ");
            const upper_web = try std.ascii.allocUpperString(self.allocator, self.data.footer.website);
            defer self.allocator.free(upper_web);
            try line.appendSlice(self.allocator, upper_web);
        }

        if (line.items.len > 0) {
            const line_width = document.Font.helvetica.measureText(line.items, 9);
            const x = (self.page_width - line_width) / 2;
            try self.drawTextConverted(content, line.items, x, y, self.font_regular, 9, SUBTLE_GREY);
        }

        // Page number (only if multi-page)
        if (self.total_pages > 1) {
            var buf: [32]u8 = undefined;
            const pg = try std.fmt.bufPrint(&buf, "{d} / {d}", .{ self.page_number, self.total_pages });
            const pg_width = document.Font.helvetica.measureText(pg, 9);
            try self.drawTextConverted(content, pg, self.page_width - self.margin_right - pg_width, y, self.font_regular, 9, SUBTLE_GREY);
        }
    }

    // ─── Sections ───────────────────────────────────────────────

    fn drawSections(self: *CleanQuoteRenderer, content: *document.ContentStream) !void {
        for (self.data.sections, 0..) |section, idx| {
            if (idx > 0) self.current_y -= 20;
            switch (section.section_type) {
                .text => try self.drawTextSection(content, section),
                .metrics => try self.drawMetricsSection(content, section),
                .table => try self.drawTableSection(content, section),
                .chart => try self.drawTextSection(content, section), // degrade chart to text
            }
        }
    }

    // Text section — plain prose, optional tiny uppercase label instead of heading.
    // Detects "What's Included" / "Next Steps" for special treatment.
    fn drawTextSection(self: *CleanQuoteRenderer, content: *document.ContentStream, section: ProposalSection) !void {
        try self.checkPageBreak(content, 40);

        const is_whats_included = isWhatsIncluded(section.heading);
        const is_next_steps = isNextSteps(section.heading);

        if (is_whats_included) {
            // WHAT'S INCLUDED — tiny uppercase grey label, bullets with red dots
            try self.drawUppercaseLabel(content, "WHAT'S INCLUDED", self.margin_left, self.current_y);
            self.current_y -= 18;
            try self.drawBulletList(content, section.content);
        } else if (is_next_steps) {
            // NEXT STEPS — uppercase label then prose
            const upper = try std.ascii.allocUpperString(self.allocator, section.heading);
            defer self.allocator.free(upper);
            try self.drawUppercaseLabel(content, upper, self.margin_left, self.current_y);
            self.current_y -= 18;
            try self.drawProse(content, section.content, self.margin_left, self.usable_width);
        } else if (section.heading.len > 0) {
            // Intro / other — small bold heading (not a giant banner)
            try self.drawTextConverted(content, section.heading, self.margin_left, self.current_y, self.font_bold, 13, INK_BLACK);
            self.current_y -= 20;
            try self.drawProse(content, section.content, self.margin_left, self.usable_width);
        } else {
            // No heading — just prose
            try self.drawProse(content, section.content, self.margin_left, self.usable_width);
        }
    }

    fn isWhatsIncluded(heading: []const u8) bool {
        var buf: [64]u8 = undefined;
        const n = @min(heading.len, buf.len);
        for (heading[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
        const lower = buf[0..n];
        return std.mem.indexOf(u8, lower, "included") != null or
            std.mem.indexOf(u8, lower, "includes") != null;
    }

    fn isNextSteps(heading: []const u8) bool {
        var buf: [64]u8 = undefined;
        const n = @min(heading.len, buf.len);
        for (heading[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
        const lower = buf[0..n];
        return std.mem.indexOf(u8, lower, "next step") != null or
            std.mem.indexOf(u8, lower, "notes") != null or
            std.mem.indexOf(u8, lower, "terms") != null;
    }

    fn drawProse(self: *CleanQuoteRenderer, content: *document.ContentStream, text: []const u8, x: f32, max_width: f32) !void {
        if (text.len == 0) return;
        // Split on newlines, wrap each paragraph
        var lines_iter = std.mem.splitScalar(u8, text, '\n');
        while (lines_iter.next()) |para_raw| {
            const para = std.mem.trim(u8, para_raw, " \t\r");
            if (para.len == 0) {
                self.current_y -= 6; // blank line spacing
                continue;
            }
            const wrapped = try document.wrapText(self.allocator, para, .helvetica, 11.5, max_width);
            defer self.allocator.free(wrapped.lines);
            for (wrapped.lines) |line| {
                try self.checkPageBreak(content, 16);
                try self.drawTextConverted(content, line, x, self.current_y, self.font_regular, 11.5, INK_BLACK);
                self.current_y -= 15;
            }
            self.current_y -= 4; // paragraph gap
        }
    }

    fn drawBulletList(self: *CleanQuoteRenderer, content: *document.ContentStream, text: []const u8) !void {
        var lines_iter = std.mem.splitScalar(u8, text, '\n');
        while (lines_iter.next()) |line_raw| {
            var line = std.mem.trim(u8, line_raw, " \t\r");
            if (line.len == 0) continue;
            // Strip markdown-style bullet prefix
            if (std.mem.startsWith(u8, line, "- ")) line = line[2..];
            if (std.mem.startsWith(u8, line, "* ")) line = line[2..];
            if (line.len > 0 and line[0] == 0xE2) {
                // Skip UTF-8 bullet prefix if present (• = E2 80 A2)
                if (line.len > 3) line = std.mem.trimStart(u8, line[3..], " \t");
            }

            try self.checkPageBreak(content, 18);

            // Red dot bullet
            const bullet_x = self.margin_left + 4;
            const bullet_y = self.current_y + 4;
            try content.drawCircle(bullet_x, bullet_y, 1.6, ACCENT_RED, null);

            // Wrap text after indent
            const text_x = self.margin_left + 16;
            const text_w = self.usable_width - 16;
            const wrapped = try document.wrapText(self.allocator, line, .helvetica, 11, text_w);
            defer self.allocator.free(wrapped.lines);

            for (wrapped.lines, 0..) |wline, i| {
                if (i > 0) {
                    try self.checkPageBreak(content, 16);
                }
                try self.drawTextConverted(content, wline, text_x, self.current_y, self.font_regular, 11, INK_BLACK);
                self.current_y -= 15;
            }
            self.current_y -= 2;
        }
    }

    // Metrics section — single rounded grey card with 2-col key-value list.
    fn drawMetricsSection(self: *CleanQuoteRenderer, content: *document.ContentStream, section: ProposalSection) !void {
        if (section.metric_items.len == 0) return;

        // Label
        if (section.heading.len > 0) {
            const upper = try std.ascii.allocUpperString(self.allocator, section.heading);
            defer self.allocator.free(upper);
            try self.drawUppercaseLabel(content, upper, self.margin_left, self.current_y);
            self.current_y -= 16;
        }

        // Compute card dimensions
        const item_h: f32 = 22;
        const card_padding: f32 = 14;
        const card_h: f32 = @as(f32, @floatFromInt(section.metric_items.len)) * item_h + card_padding * 2 - 6;

        try self.checkPageBreak(content, card_h + 10);

        const card_x = self.margin_left;
        const card_w = self.usable_width;
        const card_top_y = self.current_y;
        const card_bottom_y = card_top_y - card_h;

        // Card background — light grey with border
        try content.drawRoundedRect(card_x, card_bottom_y, card_w, card_h, 8, CARD_BG);
        // Border hairline on rounded rect (approx — draw a rounded outline not trivial,
        // use thin strokes along each edge for minimal look)
        try content.drawLine(card_x, card_top_y, card_x + card_w, card_top_y, BORDER_GREY, 0.5);
        try content.drawLine(card_x, card_bottom_y, card_x + card_w, card_bottom_y, BORDER_GREY, 0.5);

        // Items — label left (grey), value right-aligned (black)
        var y = card_top_y - card_padding;
        for (section.metric_items) |item| {
            try self.drawTextConverted(content, item.label, card_x + card_padding, y - 10, self.font_regular, 10.5, MUTED_GREY);
            const val_width = document.Font.helvetica_bold.measureText(item.value, 11);
            try self.drawTextConverted(content, item.value, card_x + card_w - card_padding - val_width, y - 10, self.font_bold, 11, INK_BLACK);
            y -= item_h;
        }

        self.current_y = card_bottom_y - 8;
    }

    // Table section — hairline-separated pricing table, no fills, total in bold black.
    fn drawTableSection(self: *CleanQuoteRenderer, content: *document.ContentStream, section: ProposalSection) !void {
        try self.checkPageBreak(content, 80);

        // Section label
        if (section.heading.len > 0) {
            const upper = try std.ascii.allocUpperString(self.allocator, section.heading);
            defer self.allocator.free(upper);
            try self.drawUppercaseLabel(content, upper, self.margin_left, self.current_y);
            self.current_y -= 20;
        }

        // Column header — bold text with grey underline
        const desc_x = self.margin_left;
        const amount_x = self.page_width - self.margin_right;
        try self.drawTextConverted(content, "Description", desc_x, self.current_y, self.font_bold, 10, INK_BLACK);
        const amt_hdr_width = document.Font.helvetica_bold.measureText("Amount", 10);
        try self.drawTextConverted(content, "Amount", amount_x - amt_hdr_width, self.current_y, self.font_bold, 10, INK_BLACK);
        self.current_y -= 6;
        try content.drawLine(desc_x, self.current_y, amount_x, self.current_y, BORDER_GREY, 0.5);
        self.current_y -= 12;

        // Items — each with 1px hairline separator beneath
        for (section.table_items) |item| {
            try self.checkPageBreak(content, 30);

            // Wrap description if too long
            const desc_max_w = self.usable_width - 100;
            const wrapped = try document.wrapText(self.allocator, item.description, .helvetica, 11, desc_max_w);
            defer self.allocator.free(wrapped.lines);

            const row_top = self.current_y;
            for (wrapped.lines, 0..) |line, i| {
                try self.drawTextConverted(content, line, desc_x, self.current_y - @as(f32, @floatFromInt(i)) * 14, self.font_regular, 11, INK_BLACK);
            }

            // Amount right-aligned on first row
            var amt_buf: [32]u8 = undefined;
            const amt_str = try std.fmt.bufPrint(&amt_buf, "\u{00A3}{d:.2}", .{item.total});
            const amt_conv = try utf8ToWinAnsi(self.allocator, amt_str);
            defer self.allocator.free(amt_conv);
            const amt_w = document.Font.helvetica.measureText(amt_conv, 11);
            try content.drawText(amt_conv, amount_x - amt_w, row_top, self.font_regular, 11, INK_BLACK);

            const row_height: f32 = @as(f32, @floatFromInt(wrapped.lines.len)) * 14 + 6;
            self.current_y = row_top - row_height;

            // Hairline separator
            try content.drawLine(desc_x, self.current_y, amount_x, self.current_y, BORDER_GREY, 0.4);
            self.current_y -= 10;
        }

        // Subtotal / Tax / Total
        const label_x = self.page_width - self.margin_right - 160;

        if (section.subtotal > 0 or section.tax_rate > 0) {
            try self.drawTextConverted(content, "Subtotal", label_x, self.current_y, self.font_regular, 11, MUTED_GREY);
            var sub_buf: [32]u8 = undefined;
            const sub_str = try std.fmt.bufPrint(&sub_buf, "\u{00A3}{d:.2}", .{section.subtotal});
            const sub_conv = try utf8ToWinAnsi(self.allocator, sub_str);
            defer self.allocator.free(sub_conv);
            const sub_w = document.Font.helvetica.measureText(sub_conv, 11);
            try content.drawText(sub_conv, amount_x - sub_w, self.current_y, self.font_regular, 11, MUTED_GREY);
            self.current_y -= 16;

            if (section.tax_rate > 0) {
                var vat_lbl_buf: [32]u8 = undefined;
                const vat_pct = section.tax_rate * 100.0;
                const vat_lbl = try std.fmt.bufPrint(&vat_lbl_buf, "VAT ({d:.0}%)", .{vat_pct});
                try self.drawTextConverted(content, vat_lbl, label_x, self.current_y, self.font_regular, 11, MUTED_GREY);
                const vat_amount = section.subtotal * section.tax_rate;
                var vat_buf: [32]u8 = undefined;
                const vat_str = try std.fmt.bufPrint(&vat_buf, "\u{00A3}{d:.2}", .{vat_amount});
                const vat_conv = try utf8ToWinAnsi(self.allocator, vat_str);
                defer self.allocator.free(vat_conv);
                const vat_w = document.Font.helvetica.measureText(vat_conv, 11);
                try content.drawText(vat_conv, amount_x - vat_w, self.current_y, self.font_regular, 11, MUTED_GREY);
                self.current_y -= 16;
            }

            // Hairline above total
            try content.drawLine(label_x, self.current_y + 4, amount_x, self.current_y + 4, BORDER_GREY, 0.6);
            self.current_y -= 4;
        }

        if (section.total > 0) {
            try self.drawTextConverted(content, "Total", label_x, self.current_y, self.font_bold, 12, INK_BLACK);
            var tot_buf: [32]u8 = undefined;
            const tot_str = try std.fmt.bufPrint(&tot_buf, "\u{00A3}{d:.2}", .{section.total});
            const tot_conv = try utf8ToWinAnsi(self.allocator, tot_str);
            defer self.allocator.free(tot_conv);
            const tot_w = document.Font.helvetica_bold.measureText(tot_conv, 12);
            try content.drawText(tot_conv, amount_x - tot_w, self.current_y, self.font_bold, 12, INK_BLACK);
            self.current_y -= 20;
        }

        // Notes prose
        if (section.notes) |notes| {
            if (notes.len > 0) {
                self.current_y -= 6;
                try self.drawProse(content, notes, self.margin_left, self.usable_width);
            }
        }
    }

    // ─── Render entrypoint ──────────────────────────────────────

    pub fn render(self: *CleanQuoteRenderer) ![]const u8 {
        var content = document.ContentStream.init(self.allocator);
        errdefer content.deinit();

        try self.drawHeader(&content);
        try self.drawSections(&content);

        // Save final page
        try self.pages.append(self.allocator, content);
        content.buffer = .empty;

        self.total_pages = @intCast(self.pages.items.len);

        // Render footers and add to document
        for (self.pages.items, 0..) |*page, idx| {
            self.page_number = @intCast(idx + 1);
            try self.drawFooter(page);
            try self.doc.addPage(page);
        }

        return try self.doc.build();
    }
};

// =============================================================================
// Public API
// =============================================================================

/// Generate a clean quote PDF from pre-parsed data.
/// Returns a buffer owned by `allocator` (caller must free).
pub fn generateCleanQuote(allocator: std.mem.Allocator, data: ProposalData) ![]u8 {
    var renderer = CleanQuoteRenderer.init(allocator, data);
    defer renderer.deinit();
    const bytes = try renderer.render();
    return try allocator.dupe(u8, bytes);
}

/// Generate a clean quote PDF from JSON input. Same schema as proposal.
pub fn generateCleanQuoteFromJson(allocator: std.mem.Allocator, json_str: []const u8) ![]u8 {
    // Use an arena for all the transient JSON-derived allocations — the renderer
    // copies what it needs into the PDF output buffer, then we return a single
    // allocation owned by the caller's allocator.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const data = try parseProposalJsonLocal(arena_alloc, json_str);
    var renderer = CleanQuoteRenderer.init(arena_alloc, data);
    defer renderer.deinit();

    const pdf = try renderer.render();
    return try allocator.dupe(u8, pdf);
}

// Local JSON parser — mirrors proposal.zig's parseProposalJson but stays
// self-contained so this module has no dependency on proposal internals.
fn parseProposalJsonLocal(allocator: std.mem.Allocator, json_str: []const u8) !ProposalData {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidJson;
    const root = parsed.value.object;

    var data = ProposalData{};

    data.company_name = try dupeStr(allocator, root, "company_name", "");
    data.company_address = try dupeStr(allocator, root, "company_address", "");
    data.client_name = try dupeStr(allocator, root, "client_name", "");
    data.client_address = try dupeStr(allocator, root, "client_address", "");
    data.reference = try dupeStr(allocator, root, "reference", "");
    data.date = try dupeStr(allocator, root, "date", "");
    data.valid_until = try dupeStr(allocator, root, "valid_until", "");

    // Footer
    if (root.get("footer")) |f| {
        if (f == .object) {
            data.footer = .{
                .phone = try dupeStr(allocator, f.object, "phone", ""),
                .email = try dupeStr(allocator, f.object, "email", ""),
                .website = try dupeStr(allocator, f.object, "website", ""),
                .dashboard_text = try dupeStr(allocator, f.object, "dashboard_text", ""),
                .dashboard_url = try dupeStr(allocator, f.object, "dashboard_url", ""),
            };
        }
    }

    // Sections
    if (root.get("sections")) |s| {
        if (s == .array) {
            const arr = s.array.items;
            const sections_buf = try allocator.alloc(ProposalSection, arr.len);

            for (arr, 0..) |sec_val, i| {
                if (sec_val != .object) {
                    sections_buf[i] = .{};
                    continue;
                }
                const obj = sec_val.object;

                const type_str = try dupeStr(allocator, obj, "type", "text");
                const sec_type: proposal.SectionType = if (std.mem.eql(u8, type_str, "metrics"))
                    .metrics
                else if (std.mem.eql(u8, type_str, "table"))
                    .table
                else if (std.mem.eql(u8, type_str, "chart"))
                    .chart
                else
                    .text;

                var section = ProposalSection{
                    .section_type = sec_type,
                    .heading = try dupeStr(allocator, obj, "heading", ""),
                    .content = try dupeStr(allocator, obj, "content", ""),
                    .subtotal = getFloat(obj, "subtotal"),
                    .tax_rate = getFloat(obj, "tax_rate"),
                    .total = getFloat(obj, "total"),
                    .notes = dupeOptStr(allocator, obj, "notes") catch null,
                };

                // metric_items
                if (obj.get("metric_items")) |mi| {
                    if (mi == .array) {
                        const marr = mi.array.items;
                        const mbuf = try allocator.alloc(MetricItem, marr.len);
                        for (marr, 0..) |mv, j| {
                            if (mv == .object) {
                                mbuf[j] = .{
                                    .label = try dupeStr(allocator, mv.object, "label", ""),
                                    .value = try dupeStr(allocator, mv.object, "value", ""),
                                };
                            } else mbuf[j] = .{};
                        }
                        section.metric_items = mbuf;
                    }
                }

                // table_items
                if (obj.get("table_items")) |ti| {
                    if (ti == .array) {
                        const tarr = ti.array.items;
                        const tbuf = try allocator.alloc(TableItem, tarr.len);
                        for (tarr, 0..) |tv, j| {
                            if (tv == .object) {
                                tbuf[j] = .{
                                    .description = try dupeStr(allocator, tv.object, "description", ""),
                                    .quantity = getFloat(tv.object, "quantity"),
                                    .unit_price = getFloat(tv.object, "unit_price"),
                                    .total = getFloat(tv.object, "total"),
                                };
                            } else tbuf[j] = .{};
                        }
                        section.table_items = tbuf;
                    }
                }

                sections_buf[i] = section;
            }
            data.sections = sections_buf;
        }
    }

    return data;
}

fn dupeStr(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8, default: []const u8) ![]const u8 {
    if (obj.get(key)) |v| {
        if (v == .string) return try allocator.dupe(u8, v.string);
    }
    return try allocator.dupe(u8, default);
}

fn dupeOptStr(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) !?[]const u8 {
    if (obj.get(key)) |v| {
        if (v == .string and v.string.len > 0) return try allocator.dupe(u8, v.string);
    }
    return null;
}

fn getFloat(obj: std.json.ObjectMap, key: []const u8) f64 {
    if (obj.get(key)) |v| {
        return switch (v) {
            .float => v.float,
            .integer => @floatFromInt(v.integer),
            else => 0,
        };
    }
    return 0;
}
