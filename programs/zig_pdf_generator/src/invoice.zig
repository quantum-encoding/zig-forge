//! Invoice/Quote Template Renderer
//!
//! Generates professional PDF invoices from structured data.
//! Supports multiple template styles and customization options.
//!
//! Features:
//! - Company logo embedding
//! - QR code embedding (VeriFactu compliance)
//! - Multiple display modes (itemized, blackbox)
//! - Color customization
//! - Multi-page support for long item lists

const std = @import("std");
const document = @import("document.zig");
const image = @import("image.zig");
const qrcode = @import("qrcode.zig");
const identicon = @import("identicon.zig");
const crypto_receipt = @import("crypto_receipt.zig");
const types = @import("types.zig");

// =============================================================================
// Invoice Data Model
// =============================================================================

pub const LineItem = struct {
    description: []const u8,
    quantity: f64,
    unit_price: f64,
    total: f64,
};

pub const DisplayMode = enum {
    itemized, // Show full item details
    blackbox, // Show single summary line
};

pub const TemplateStyle = enum {
    professional,
    modern,
    classic,
    creative,
};

/// Visual treatment of the line-item table area. Independent of TemplateStyle.
pub const TableStyle = enum {
    bands, // alternating row fill (#f5f5f5) — the original look, default
    boxes, // bordered header + a border around every row (Spanish-invoice grid)
    minimal, // no fills; a single thin rule under the header
};

/// Whole-document visual theme. `classic` is the original layout, untouched.
/// `squircle` is the rounded-card look modelled on the best supplier invoice
/// in a 157-template corpus survey (HDM Solar): From/Bill-To as rounded cards
/// with a 1pt light border (the client card emphasised in the accent colour),
/// the items table inside a rounded container with a rounded accent header
/// band, hairline row separators, and a rounded TOTAL chip. When set, it
/// overrides table_style row treatment (separators) but keeps every other
/// field working as before.
/// `glass` is the "Liquid Glass" material treatment layered on squircle's
/// geometry: a soft vertical wash of the primary colour behind the page, and
/// every rounded container rendered as a translucent panel over that wash with
/// a hairline border and a bright top-edge sheen (an axial gradient). It reuses
/// all of squircle's layout metrics and page-break machinery — only the
/// materials differ. Panels are composited beneath the text on each page so the
/// wash and sheens always sit behind the content.
pub const Theme = enum {
    classic,
    squircle,
    glass,
};

/// One call-to-action payment button. Multiple can be shown side-by-stacked
/// (e.g. "Pay by Card" via Stripe + "PayPal"). Each renders as a real clickable
/// PDF link annotation.
pub const PaymentButton = struct {
    label: []const u8 = "Pay Now",
    url: []const u8 = "",
    color: []const u8 = "#635BFF", // button background (Stripe purple default)
    text_color: []const u8 = "#FFFFFF",
};

pub const QrCodeMode = enum {
    none, // No QR code displayed
    verifactu, // Spanish VeriFactu compliance
    payment_link, // Stripe/GoCardless payment URL
    bank_details, // UK Faster Payments format
    verification, // Hosted invoice verification link
    crypto, // Cryptocurrency payment (BTC, ETH, etc.)
};

/// Fixed drawn labels for the invoice/quote template. Every field defaults to
/// the classic English string so existing payloads render byte-identically;
/// a `labels` object in the JSON overrides any subset for other languages
/// (e.g. "Facturar a", "Descripción", "IVA"). The big title and the number
/// label are handled by InvoiceData.custom_title / number_label instead.
pub const Labels = struct {
    // Invoice meta rows (right column)
    date: []const u8 = "Date:",
    due_date: []const u8 = "Due Date:",
    // Party blocks — classic layout heading, and the rounded-card variants
    bill_to: []const u8 = "Bill To:",
    from_card: []const u8 = "FROM",
    bill_to_card: []const u8 = "BILL TO",
    // "VAT: <number>" identity lines (company + client)
    vat_prefix: []const u8 = "VAT",
    // Items-table column headers
    description: []const u8 = "Description",
    quantity: []const u8 = "Qty",
    unit_price: []const u8 = "Unit Price",
    line_total: []const u8 = "Total",
    // Totals block
    subtotal: []const u8 = "Subtotal:",
    tax_prefix: []const u8 = "Tax", // rendered as "Tax (21%):"
    total: []const u8 = "TOTAL:",
    // Footer sections
    notes: []const u8 = "Notes:",
    payment_terms: []const u8 = "Payment Terms:",
    click_to_pay: []const u8 = "Click to Pay Online",
    // QR captions by mode (qr_label still overrides these when set)
    scan_to_pay: []const u8 = "Scan to Pay",
    bank_details: []const u8 = "Bank Details",
    verify_invoice: []const u8 = "Verify Invoice",
    // Footer strap-lines by QR mode
    footer_scan_to_pay: []const u8 = "Scan QR to Pay Online",
    footer_bank_details: []const u8 = "Bank Transfer Details Above",
    footer_verify: []const u8 = "Scan to Verify Invoice",
    footer_verifactu: []const u8 = "VeriFactu Compliant Invoice",
    thank_you: []const u8 = "Thank you for your business",
};

pub const InvoiceData = struct {
    // Document type
    document_type: []const u8 = "invoice", // "invoice" or "quote"

    // Optional overrides for the big title and the number label — lets this
    // one template serve statements, credit notes, purchase orders etc.
    // (JSON "title" / "number_label"). Null keeps the classic three.
    custom_title: ?[]const u8 = null,
    number_label: ?[]const u8 = null,

    // Company info
    company_name: []const u8 = "",
    company_address: []const u8 = "",
    company_vat: []const u8 = "",
    company_logo_base64: ?[]const u8 = null,

    // Client info
    client_name: []const u8 = "",
    client_address: []const u8 = "",
    client_vat: []const u8 = "",

    // Document details
    invoice_number: []const u8 = "",
    invoice_date: []const u8 = "",
    due_date: []const u8 = "",

    // Items
    display_mode: DisplayMode = .itemized,
    items: []const LineItem = &[_]LineItem{},
    blackbox_description: []const u8 = "",

    // Totals
    subtotal: f64 = 0,
    tax_rate: f64 = 0.21,
    tax_amount: f64 = 0,
    total: f64 = 0,

    // Currency symbol prepended to every money figure (e.g. "£", "€"). Empty by
    // default so existing callers keep rendering bare numbers unchanged.
    currency_symbol: []const u8 = "",

    // VAT/tax toggle. When false, the Subtotal and Tax rows are suppressed and
    // only the TOTAL is shown — used for receipts from businesses that are not
    // (yet) VAT-registered, where breaking out a "Tax (0%)" line is misleading.
    // Defaults true so every existing invoice consumer is unchanged.
    show_tax: bool = true,

    // Fixed drawn labels (language-neutral rendering). Defaults are the
    // classic English strings, so omitting `labels` changes nothing.
    labels: Labels = .{},

    // Optional
    qr_base64: ?[]const u8 = null, // QR code image (base64 PNG)
    qr_mode: QrCodeMode = .none, // QR code purpose/label
    qr_label: ?[]const u8 = null, // Custom label for QR code (overrides default)
    verifactu_qr_base64: ?[]const u8 = null, // Legacy: maps to qr_base64 + verifactu mode
    notes: []const u8 = "",
    payment_terms: []const u8 = "",

    // VeriFactu compliance fields (Spanish e-invoicing)
    verifactu_hash: ?[]const u8 = null, // Hash signature (huella) to display on invoice
    verifactu_series: ?[]const u8 = null, // Invoice series (A, B, etc.)
    verifactu_nif: ?[]const u8 = null, // Tax ID (NIF) for verification
    verifactu_timestamp: ?[]const u8 = null, // Timestamp of hash chain registration

    // Crypto payment fields
    crypto_payment: ?types.CryptoPaymentBlock = null, // Nested crypto payment block
    crypto_wallet: ?[]const u8 = null, // Recipient wallet address for payment
    crypto_network: crypto_receipt.Network = .bitcoin, // Blockchain network
    crypto_amount: ?f64 = null, // Optional: exact crypto amount to request
    crypto_sender_wallet: ?[]const u8 = null, // Optional: sender wallet for receipt/confirmation
    show_crypto_identicons: bool = false, // Show blockie identicons for wallet addresses
    crypto_custom_symbol: ?[]const u8 = null, // Custom token symbol (overrides network default)

    // Styling
    primary_color: []const u8 = "#b39a7d",
    secondary_color: []const u8 = "#2c3e50",
    title_color: []const u8 = "#b39a7d",
    company_name_color: []const u8 = "#1a1a1a",
    font_family: []const u8 = "Helvetica",
    template_style: TemplateStyle = .professional,

    // Layout adjustments (in points)
    logo_x: f32 = 40,
    logo_y: f32 = 750,
    logo_width: f32 = 80,
    logo_height: f32 = 50,

    // When true, the logo is drawn as a square lockup immediately left of the
    // company name (the name + address block indents past it), using
    // logo_width as the square size — instead of at the absolute logo_x/logo_y.
    // Default false keeps existing layouts unchanged.
    logo_inline: bool = false,
    // Banner mode: the logo IS the identity block — drawn at its natural
    // aspect (logo_width x logo_height) at the top-left, and the company-name
    // text is suppressed (the banner usually contains it). Wins over inline.
    logo_banner: bool = false,
    // Clickable logo: a PDF link annotation over the drawn logo bounds.
    logo_link_url: ?[]const u8 = null,

    // Branding
    show_branding: bool = true, // Show "Generated by Quantify" with link
    branding_url: []const u8 = "https://quantifyinvoice.com",

    // Table-area visual style (bands | boxes | minimal). Defaults to the
    // original alternating-row "bands" look, so existing invoices are unchanged.
    table_style: TableStyle = .bands,

    // Whole-document theme (classic | squircle). Defaults to the original
    // layout so every existing payload renders byte-identically.
    theme: Theme = .classic,

    // IRPF retention (Spanish freelancer invoices): a percentage withheld and
    // subtracted from the total. Shown as a negative "IRPF (x%)" row beneath the
    // tax row. Both default 0, which hides the row entirely.
    irpf_rate: f64 = 0, // e.g. 0.15 for -15%
    irpf_amount: f64 = 0, // absolute amount withheld (already computed by caller)

    // Payment Button (clickable link in PDF). Single-button back-compat fields:
    payment_button_url: ?[]const u8 = null, // e.g., "https://checkout.stripe.com/pay/cs_live_abc123"
    payment_button_label: []const u8 = "Pay Now", // Button text
    payment_button_color: []const u8 = "#635BFF", // Stripe purple default
    payment_button_text_color: []const u8 = "#FFFFFF", // White text default

    // Multiple payment buttons (e.g. Stripe + PayPal). When non-empty this takes
    // precedence over the single payment_button_* fields above. When empty and
    // payment_button_url is set, the renderer synthesizes one button from the
    // single fields, so existing callers are unchanged.
    payment_buttons: []const PaymentButton = &[_]PaymentButton{},

    // Encryption (AES-256 /V5 /R6). When `password` is non-empty the invoice PDF
    // is password-encrypted; `owner_password` falls back to `password` if blank.
    // `seed` is the 32 bytes of random material the file key / salts / IVs derive
    // from: null => sourced from the OS CSPRNG (native). The WASM host-seeded
    // export sets it explicitly, since WASM has no in-module CSPRNG. An all-zero
    // seed is refused by the engine (see PdfDocument.enableEncryption).
    password: []const u8 = "",
    owner_password: []const u8 = "",
    seed: ?[32]u8 = null,
};

/// 32 bytes of random material for the encryption seed. Native: from the OS
/// CSPRNG. WASM has no CSPRNG here, so it returns zeros — and the engine
/// refuses an all-zero seed, so a WASM caller must use the host-seeded export.
const osSeed = @import("pdf_crypt.zig").osSeed;

// =============================================================================
// Invoice Renderer
// =============================================================================

/// Address blocks may arrive newline-separated (one component per line, the
/// natural form — "Street\nCity, Postcode\nCountry") or, for older callers,
/// comma-space separated. Prefer the newline form when present so a real
/// address with commas inside a line (e.g. "Coalville, LE67 3GS") stays on one
/// line instead of being split at every comma.
fn addressDelimiter(addr: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, addr, '\n') != null) "\n" else ", ";
}

pub const InvoiceRenderer = struct {
    allocator: std.mem.Allocator,
    doc: document.PdfDocument,
    data: InvoiceData,

    // Decoded images (need to track for cleanup)
    logo_decoded: ?[]u8 = null,
    qr_decoded: ?[]u8 = null,
    logo_pixels: ?[]u8 = null,
    qr_pixels: ?[]u8 = null,

    // Crypto-generated images (native QR and identicons)
    crypto_qr_pixels: ?[]u8 = null,
    recipient_identicon_pixels: ?[]u8 = null,
    sender_identicon_pixels: ?[]u8 = null,

    // Page state
    current_y: f32 = 0,
    /// Squircle/glass theme: y of the top of the rounded table container on the
    /// current page (set by drawTableHeader, consumed by closeTableContainer).
    table_top: f32 = 0,
    /// Glass theme: the background layer (wash + translucent panels + sheens)
    /// for the current page. Composited beneath the foreground content stream at
    /// each page flush so panels always sit behind text. Points at a stack local
    /// in `render`; null for non-glass themes (which never draw to it).
    bg: ?*document.ContentStream = null,
    margin_left: f32 = 40,
    margin_right: f32 = 40,
    margin_top: f32 = 40,
    margin_bottom: f32 = 60,
    page_width: f32 = document.A4_WIDTH,
    page_height: f32 = document.A4_HEIGHT,

    // Font IDs (will be assigned during init)
    font_regular: []const u8 = "F0",
    font_bold: []const u8 = "F1",

    pub fn init(allocator: std.mem.Allocator, data: InvoiceData) InvoiceRenderer {
        var renderer = InvoiceRenderer{
            .allocator = allocator,
            .doc = document.PdfDocument.init(allocator),
            .data = data,
        };

        // Add fonts based on font_family
        if (std.mem.eql(u8, data.font_family, "Times-Roman") or std.mem.eql(u8, data.font_family, "Times")) {
            renderer.font_regular = renderer.doc.getFontId(.times_roman);
            renderer.font_bold = renderer.doc.getFontId(.times_bold);
        } else if (std.mem.eql(u8, data.font_family, "Courier")) {
            renderer.font_regular = renderer.doc.getFontId(.courier);
            renderer.font_bold = renderer.doc.getFontId(.courier_bold);
        } else {
            // Default to Helvetica
            renderer.font_regular = renderer.doc.getFontId(.helvetica);
            renderer.font_bold = renderer.doc.getFontId(.helvetica_bold);
        }

        renderer.current_y = renderer.page_height - renderer.margin_top;

        return renderer;
    }

    pub fn deinit(self: *InvoiceRenderer) void {
        // For JPEG: decoded_bytes contains the raw JPEG, pixels is null
        // For PNG: decoded_bytes contains the pixel data (same as image.data), pixels is null
        // So we only free decoded_bytes, never pixels (they're the same pointer for PNG)
        if (self.logo_decoded) |d| self.allocator.free(d);
        if (self.qr_decoded) |d| self.allocator.free(d);
        // Note: logo_pixels and qr_pixels are NOT freed - they point to same memory as decoded

        // Free crypto-generated images (these are owned by us, not decoded from base64)
        if (self.crypto_qr_pixels) |p| self.allocator.free(p);
        if (self.recipient_identicon_pixels) |p| self.allocator.free(p);
        if (self.sender_identicon_pixels) |p| self.allocator.free(p);

        self.doc.deinit();
    }

    /// The base (regular) font family in use, as a measurable Font enum.
    fn fontEnumRegular(self: *const InvoiceRenderer) document.Font {
        if (std.mem.eql(u8, self.data.font_family, "Times-Roman") or std.mem.eql(u8, self.data.font_family, "Times"))
            return .times_roman;
        if (std.mem.eql(u8, self.data.font_family, "Courier")) return .courier;
        return .helvetica;
    }

    /// The bold counterpart of the family, for measuring bold (right-aligned) text.
    fn fontEnumBold(self: *const InvoiceRenderer) document.Font {
        return switch (self.fontEnumRegular()) {
            .times_roman => .times_bold,
            .courier => .courier_bold,
            else => .helvetica_bold,
        };
    }

    /// Draw `text` ending at `right_x` (grows leftward), shrinking the font just
    /// enough to fit within `max_width` so a long value neither runs off the
    /// right edge nor collides with the label to its left. Down to a 6pt floor.
    fn drawRightFit(self: *const InvoiceRenderer, content: *document.ContentStream, text: []const u8, right_x: f32, max_width: f32, y: f32, font_id: []const u8, font: document.Font, base_size: f32, color: document.Color) !void {
        _ = self;
        var size = base_size;
        const w = font.measureText(text, base_size);
        if (w > max_width and w > 0 and max_width > 0) {
            size = @max(6.0, base_size * max_width / w);
        }
        try content.drawTextRightAligned(text, right_x, y, font_id, font, size, color);
    }

    // -------------------------------------------------------------------------
    // Liquid Glass materials
    // -------------------------------------------------------------------------

    /// Themes that use squircle's rounded-card geometry (cards, rounded table
    /// container, accent header band, rounded totals chip). Glass reuses all of
    /// it and only swaps the materials, so every layout branch keys off this.
    fn roundedLayout(self: *const InvoiceRenderer) bool {
        return self.data.theme == .squircle or self.data.theme == .glass;
    }

    /// Linear blend from `a` to `b` by `t` in [0,1] (t=0 → a, t=1 → b).
    fn mixColor(a: document.Color, b: document.Color, t: f32) document.Color {
        return .{
            .r = a.r + (b.r - a.r) * t,
            .g = a.g + (b.g - a.g) * t,
            .b = a.b + (b.b - a.b) * t,
        };
    }

    /// Paint the page "environment": a soft vertical wash from a light tint of
    /// the primary colour at the top fading to white by the lower third. Drawn
    /// first into the background layer of every glass page.
    fn drawGlassWash(self: *InvoiceRenderer, bg: *document.ContentStream) !void {
        const primary = document.Color.fromHex(self.data.primary_color);
        const wash_top = mixColor(document.Color.white, primary, 0.10); // ~10% tint
        const top_y = self.page_height;
        const fade_y = self.page_height * 0.34; // white by the lower third
        const sh = self.doc.getAxialShadingId(wash_top, document.Color.white, 0, top_y, 0, fade_y);
        try bg.saveState();
        try bg.clipRect(0, 0, self.page_width, self.page_height);
        try bg.paintShading(sh);
        try bg.restoreState();
    }

    /// Draw one glass panel into the background layer: a translucent rounded
    /// fill over the wash, a bright top-edge sheen (an axial gradient confined
    /// to the top band), and an optional hairline border. Because the whole
    /// background layer is composited beneath the page text, panels never
    /// obscure the content drawn over them — including dynamic-height panels
    /// (the items-table container) closed after their rows are laid down.
    fn drawGlassPanel(
        self: *InvoiceRenderer,
        bg: *document.ContentStream,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        radius: f32,
        base: document.Color,
        base_alpha: f32,
        sheen_end: document.Color,
        sheen_alpha: f32,
        border: ?document.Color,
        border_w: f32,
    ) !void {
        // Translucent base fill — the wash shows through.
        try bg.saveState();
        try bg.setExtGState(self.doc.getOpacityExtGStateId(base_alpha));
        try bg.drawRoundedRectEx(x, y, w, h, radius, base, null, 1.0);
        try bg.restoreState();

        // Top-edge sheen: white at the very top fading to `sheen_end`, clipped
        // to the panel silhouette AND the top band so it reads as a highlight.
        // Full-height fade: a band-clipped sheen left a hard tint seam where
        // the band ended (field report: it sliced through the QUOTE wordmark
        // and read as the panel's edge). Fading across the whole panel has no
        // seam — the gradient's end IS the panel's bottom border.
        if (h > 1.0) {
            const sh = self.doc.getAxialShadingId(document.Color.white, sheen_end, x, y + h, x, y);
            try bg.saveState();
            try bg.setExtGState(self.doc.getOpacityExtGStateId(sheen_alpha));
            try bg.clipRoundedRect(x, y, w, h, radius);
            try bg.paintShading(sh);
            try bg.restoreState();
        }

        // Hairline border — opaque, drawn last so the edge stays crisp.
        if (border) |bc| {
            try bg.drawRoundedRectEx(x, y, w, h, radius, null, bc, border_w);
        }
    }

    /// Flush the current page: composite the background layer (wash + glass
    /// panels) beneath the foreground content, commit the page, and reset both
    /// buffers for the next page. For non-glass themes the background layer is
    /// empty, so the composed bytes equal the content bytes exactly.
    fn flushPage(self: *InvoiceRenderer, content: *document.ContentStream) !void {
        const bg = self.bg.?;
        try bg.buffer.appendSlice(self.allocator, content.getContent());
        try self.doc.addPage(bg);
        content.deinit();
        content.* = document.ContentStream.init(self.allocator);
        bg.deinit();
        bg.* = document.ContentStream.init(self.allocator);
    }

    /// Draw the items-table header (column titles + bar/rule per table_style) at
    /// the current y and advance below it. Redrawn at the top of every page so a
    /// paginated item list keeps its headers. In the squircle theme the header
    /// is a rounded accent band and the top of the rounded table container is
    /// recorded so the container can be closed when the rows end (per page).
    fn drawTableHeader(self: *InvoiceRenderer, content: *document.ContentStream) !void {
        const primary = document.Color.fromHex(self.data.primary_color);
        const secondary = document.Color.fromHex(self.data.secondary_color);
        const usable_width = self.page_width - self.margin_left - self.margin_right;
        const table_style = self.data.table_style;
        const box_border = document.Color.fromHex("#d0d0d0");
        // Glass: the header band ends up WASHED (the white table container
        // composites over it), so white titles die — dark ink carries the
        // contrast, same rule as the totals chip (field report).
        const header_text_color = if (self.data.theme == .glass)
            document.Color.fromHex(self.data.secondary_color)
        else if (table_style == .minimal and !self.roundedLayout()) primary else document.Color.white;
        if (self.data.theme == .glass) {
            try self.drawGlassPanel(self.bg.?, self.margin_left, self.current_y - 5, usable_width, 22, 7, primary, 0.90, primary, 0.50, null, 0);
            self.table_top = self.current_y + 17 + 8;
        } else if (self.data.theme == .squircle) {
            try content.drawRoundedRectEx(self.margin_left, self.current_y - 5, usable_width, 22, 7, primary, null, 1.0);
            self.table_top = self.current_y + 17 + 8; // band top + container breathing room
        } else if (table_style != .minimal) {
            const header_border: ?document.Color = if (table_style == .boxes) box_border else null;
            try content.drawRect(self.margin_left, self.current_y - 5, usable_width, 22, primary, header_border);
        }
        const col_desc = self.margin_left + 5;
        const col_qty = self.margin_left + 280;
        const col_price = self.margin_left + 350;
        const col_total = self.margin_left + 450;
        try content.drawText(self.data.labels.description, col_desc, self.current_y, self.font_bold, 10, header_text_color);
        try content.drawText(self.data.labels.quantity, col_qty, self.current_y, self.font_bold, 10, header_text_color);
        try content.drawText(self.data.labels.unit_price, col_price, self.current_y, self.font_bold, 10, header_text_color);
        try content.drawText(self.data.labels.line_total, col_total, self.current_y, self.font_bold, 10, header_text_color);
        if (table_style == .minimal and !self.roundedLayout()) {
            try content.drawLine(self.margin_left, self.current_y - 6, self.margin_left + usable_width, self.current_y - 6, secondary, 0.75);
        }
        self.current_y -= 28;
    }

    /// Squircle theme: close the rounded container around the items table —
    /// a 1pt light stroke from the recorded table_top down to `bottom_y`.
    /// Called when the rows end and, for paginated lists, before each page
    /// break (each page gets its own container). No-op on other themes.
    fn closeTableContainer(self: *InvoiceRenderer, content: *document.ContentStream, bottom_y: f32) !void {
        if (!self.roundedLayout()) return;
        const usable_width = self.page_width - self.margin_left - self.margin_right;
        const x = self.margin_left - 8;
        const w = usable_width + 16;
        const h = self.table_top - bottom_y;
        if (self.data.theme == .glass) {
            // Translucent container over the wash + a hairline border. Drawn into
            // the bg layer, so although it is emitted after the rows its fill and
            // sheen still sit behind the already-drawn row text.
            const primary = document.Color.fromHex(self.data.primary_color);
            const panel_border = mixColor(document.Color.white, primary, 0.14);
            const sheen_end = mixColor(document.Color.white, primary, 0.22);
            try self.drawGlassPanel(self.bg.?, x, bottom_y, w, h, 10, document.Color.white, 0.70, sheen_end, 0.55, panel_border, 1.0);
        } else {
            const border = document.Color.fromHex("#E5E7EB");
            try content.drawRoundedRectEx(x, bottom_y, w, h, 10, null, border, 1.0);
        }
    }

    /// Commit the current page and start a fresh one at the top. `redraw_header`
    /// re-draws the items-table header (for paginated rows); pass false for a
    /// fresh page that just holds the totals block. Intermediate content buffers
    /// are freed here; the final one is freed by render's `defer`.
    fn startNewPage(self: *InvoiceRenderer, content: *document.ContentStream, redraw_header: bool) !void {
        try self.flushPage(content);
        self.current_y = self.page_height - self.margin_top;
        if (self.data.theme == .glass) try self.drawGlassWash(self.bg.?);
        if (redraw_header) try self.drawTableHeader(content);
    }

    /// Generate the complete invoice PDF
    pub fn render(self: *InvoiceRenderer) ![]const u8 {
        // Resolve crypto payment block or legacy fields
        const crypto_block = self.data.crypto_payment;
        const wallet_val = if (crypto_block) |cb| (if (cb.to_address.len > 0) cb.to_address else null) else self.data.crypto_wallet;
        const network_val = if (crypto_block) |cb| cb.getNetwork() else self.data.crypto_network;
        const sender_val = if (crypto_block) |cb| (if (cb.from_address.len > 0) cb.from_address else null) else self.data.crypto_sender_wallet;
        const symbol_val = if (crypto_block) |cb| (if (cb.currency.len > 0) cb.currency else cb.getNetwork().symbol()) else (self.data.crypto_custom_symbol orelse self.data.crypto_network.symbol());
        const amount_str = if (crypto_block) |cb| (if (cb.amount.len > 0) cb.amount else null) else null;

        var content = document.ContentStream.init(self.allocator);
        defer content.deinit();

        // Glass theme: a background layer (wash + translucent panels + sheens)
        // composited beneath the foreground at every page flush. Empty for other
        // themes, so their composed output is byte-identical to before.
        var page_bg = document.ContentStream.init(self.allocator);
        defer page_bg.deinit();
        self.bg = &page_bg;
        if (self.data.theme == .glass) try self.drawGlassWash(&page_bg);

        // Load images if provided
        var logo_id: ?[]const u8 = null;
        var qr_id: ?[]const u8 = null;

        if (self.data.company_logo_base64) |logo_b64| {
            if (logo_b64.len > 0) {
                const result = image.loadImageFlexible(self.allocator, logo_b64) catch null;
                if (result) |r| {
                    self.logo_decoded = r.decoded_bytes;
                    if (r.image.format != .jpeg) {
                        self.logo_pixels = @constCast(r.image.data);
                    }
                    logo_id = self.doc.addImage(r.image) catch null;
                }
            }
        }

        // Load QR code - check new field first, fall back to legacy verifactu field
        const qr_b64_data = self.data.qr_base64 orelse self.data.verifactu_qr_base64;
        // Determine effective QR mode
        var effective_qr_mode = self.data.qr_mode;
        if (effective_qr_mode == .none) {
            // Legacy field implies verifactu mode (only if non-empty)
            if (self.data.verifactu_qr_base64) |legacy_qr| {
                if (legacy_qr.len > 0) {
                    effective_qr_mode = .verifactu;
                }
            }
        }

        if (qr_b64_data) |qr_b64| {
            if (qr_b64.len > 0 and effective_qr_mode != .none) {
                const result = image.loadImageFlexible(self.allocator, qr_b64) catch null;
                if (result) |r| {
                    self.qr_decoded = r.decoded_bytes;
                    if (r.image.format != .jpeg) {
                        self.qr_pixels = @constCast(r.image.data);
                    }
                    qr_id = self.doc.addImage(r.image) catch null;
                }
            }
        }

        // Native crypto QR generation (when crypto_wallet/crypto_payment is set and mode is crypto)
        var crypto_qr_id: ?[]const u8 = null;
        var recipient_identicon_id: ?[]const u8 = null;
        var sender_identicon_id: ?[]const u8 = null;

        if (wallet_val) |wallet| {
            if (wallet.len > 0 and (effective_qr_mode == .crypto or self.data.qr_mode == .crypto)) {
                // Set effective mode to crypto if not already
                effective_qr_mode = .crypto;

                // Build crypto payment URI
                const uri = try self.buildCryptoUri(wallet, network_val, symbol_val, amount_str);
                defer self.allocator.free(uri);

                // Generate native QR code
                const qr_config = qrcode.QrConfig{
                    .ec_level = .M,
                    .min_version = 1,
                    .max_version = 10,
                };

                if (qrcode.encodeAndRender(self.allocator, uri, 4, qr_config)) |qr_img| {
                    self.crypto_qr_pixels = qr_img.pixels;
                    const img = document.Image{
                        .width = qr_img.width,
                        .height = qr_img.height,
                        .data = qr_img.pixels,
                        .format = .raw_rgb,
                    };
                    crypto_qr_id = self.doc.addImage(img) catch null;
                    // Use crypto QR if no base64 QR was provided
                    if (qr_id == null) {
                        qr_id = crypto_qr_id;
                    }
                } else |_| {}

                // Generate recipient identicon
                if (self.data.show_crypto_identicons) {
                    if (identicon.generate(self.allocator, wallet, .{ .size = 8, .scale = 8 })) |icon| {
                        self.recipient_identicon_pixels = icon.pixels;
                        const img = document.Image{
                            .width = icon.width,
                            .height = icon.height,
                            .data = icon.pixels,
                            .format = .raw_rgb,
                        };
                        recipient_identicon_id = self.doc.addImage(img) catch null;
                    } else |_| {}
                }
            }
        }

        // Generate sender identicon if address provided and identicons enabled
        if (sender_val) |sender| {
            if (sender.len > 0 and self.data.show_crypto_identicons) {
                if (identicon.generate(self.allocator, sender, .{ .size = 8, .scale = 8 })) |icon| {
                    self.sender_identicon_pixels = icon.pixels;
                    const img = document.Image{
                        .width = icon.width,
                        .height = icon.height,
                        .data = icon.pixels,
                        .format = .raw_rgb,
                    };
                    sender_identicon_id = self.doc.addImage(img) catch null;
                } else |_| {}
            }
        }

        const primary = document.Color.fromHex(self.data.primary_color);
        const secondary = document.Color.fromHex(self.data.secondary_color);
        const title_color = document.Color.fromHex(self.data.title_color);
        const company_color = document.Color.fromHex(self.data.company_name_color);

        // Usable width
        const usable_width = self.page_width - self.margin_left - self.margin_right;

        // Glass theme reusable material tokens (translucent white panels + a
        // faintly accent-tinted sheen and hairline border).
        const glass_panel_border = mixColor(document.Color.white, primary, 0.14);
        const glass_sheen_end = mixColor(document.Color.white, primary, 0.22);

        // =====================================================================
        // Header Section
        // =====================================================================

        // Glass theme: a translucent panel behind the title / company / meta
        // block at the top of the page (the "masthead" pane), drawn into the bg
        // layer so the header text sits on top of it. The rounded layout keeps
        // the company address in the From card below, so this block is compact.
        if (self.data.theme == .glass) {
            const mh_bottom = self.page_height - self.margin_top - 88;
            const mh_top = self.page_height - self.margin_top + 18;
            try self.drawGlassPanel(&page_bg, self.margin_left - 8, mh_bottom, usable_width + 16, mh_top - mh_bottom, 12, document.Color.white, 0.72, glass_sheen_end, 0.50, glass_panel_border, 1.0);
        }

        // Logo (absolute-positioned). The inline-lockup variant is drawn beside
        // the company name below instead.
        if (logo_id) |lid| {
            if (!self.data.logo_inline and !self.data.logo_banner) {
                try content.drawImage(lid, self.data.logo_x, self.data.logo_y, self.data.logo_width, self.data.logo_height);
                if (self.data.logo_link_url) |u| {
                    if (u.len > 0) try self.doc.addLinkAnnotation(self.data.logo_x, self.data.logo_y, self.data.logo_x + self.data.logo_width, self.data.logo_y + self.data.logo_height, u);
                }
            }
        }

        // Document title (INVOICE / QUOTE / RECEIPT — or a custom override
        // like STATEMENT / CREDIT NOTE). Right-aligned by estimated width so
        // long titles don't run off the page; very long ones also shrink.
        const is_quote = std.mem.eql(u8, self.data.document_type, "quote");
        const is_receipt = std.mem.eql(u8, self.data.document_type, "receipt");
        const doc_title = self.data.custom_title orelse (if (is_quote) "QUOTE" else if (is_receipt) "RECEIPT" else "INVOICE");
        const title_size: f32 = if (doc_title.len > 12) 20 else 28;
        const title_est_w = @as(f32, @floatFromInt(doc_title.len)) * title_size * 0.72;
        const title_inset: f32 = if (self.roundedLayout()) 10 else 0;
        const title_x = @max(self.page_width - self.margin_right - title_inset - title_est_w, self.margin_left + 180);
        // Glass: the wordmark lives INSIDE the masthead panel (its ascenders
        // overflowed the rounded edge when drawn on the margin line).
        const title_y = if (self.data.theme == .glass)
            self.page_height - self.margin_top - 10
        else
            self.page_height - self.margin_top;
        try content.drawText(doc_title, title_x, title_y, self.font_bold, title_size, title_color);

        self.current_y = self.page_height - self.margin_top - 50;

        // Company name — with an optional inline logo lockup to its left. When
        // present the logo square sits at the left margin, top-aligned with the
        // name, and the whole name+address block indents past it.
        var block_x = self.margin_left;
        if (logo_id) |lid| {
            if (self.data.logo_banner) {
                // Banner: natural-aspect image replaces the company-name text.
                const bw = self.data.logo_width;
                const bh = self.data.logo_height;
                const by = self.current_y + 12 - bh;
                try content.drawImage(lid, self.margin_left, by, bw, bh);
                if (self.data.logo_link_url) |u| {
                    if (u.len > 0) try self.doc.addLinkAnnotation(self.margin_left, by, self.margin_left + bw, by + bh, u);
                }
                self.current_y = by - 18;
            } else if (self.data.logo_inline) {
                // Natural aspect — never squash a non-square mark into a box.
                const lw = self.data.logo_width;
                const lh = if (self.data.logo_height > 0) self.data.logo_height else self.data.logo_width;
                // Top-align with the 16pt name (cap top ~12pt above baseline).
                try content.drawImage(lid, self.margin_left, self.current_y + 12 - lh, lw, lh);
                if (self.data.logo_link_url) |u| {
                    if (u.len > 0) try self.doc.addLinkAnnotation(self.margin_left, self.current_y + 12 - lh, self.margin_left + lw, self.current_y + 12, u);
                }
                block_x = self.margin_left + lw + 10;
            }
        }
        if (!self.data.logo_banner or logo_id == null) {
            try content.drawText(self.data.company_name, block_x, self.current_y, self.font_bold, 16, company_color);
            self.current_y -= 18;
        }

        // Company address (multi-line) — in the rounded-card themes the address
        // moves into the "From" card below instead.
        if (!self.roundedLayout() and self.data.company_address.len > 0) {
            var line_iter = std.mem.splitSequence(u8, self.data.company_address, addressDelimiter(self.data.company_address));
            while (line_iter.next()) |line| {
                try content.drawText(line, block_x, self.current_y, self.font_regular, 10, document.Color.black);
                self.current_y -= 13;
            }
        }

        // Company VAT
        if (!self.roundedLayout() and self.data.company_vat.len > 0) {
            var vat_buf: [128]u8 = undefined;
            const vat_line = std.fmt.bufPrint(&vat_buf, "{s}: {s}", .{ self.data.labels.vat_prefix, self.data.company_vat }) catch self.data.company_vat;
            try content.drawText(vat_line, self.margin_left, self.current_y, self.font_regular, 10, document.Color.black);
            self.current_y -= 18;
        }

        // =====================================================================
        // Invoice Details (right side)
        // =====================================================================

        // Values are anchored to the right margin and grow leftward, so a long
        // invoice number or date can never run off the right edge.
        // Rounded themes inset the wordmark 10pt; the meta values share that
        // right edge so QTE number/date align under the E (field report).
        const details_right = self.page_width - self.margin_right - (if (self.roundedLayout()) @as(f32, 10) else 0);
        const reg = self.fontEnumRegular();
        // The block is 180pt wide by default (64pt of label + the value), but a
        // long document number — shop order refs run to 25+ characters — would
        // be shrunk to fit. Widen the block leftward instead, up to 300pt, so
        // the number stays at full size; the wordmark on the left has room.
        const widest_value = @max(
            reg.measureText(self.data.invoice_number, 10),
            @max(reg.measureText(self.data.invoice_date, 10), reg.measureText(self.data.due_date, 10)),
        );
        const block_width = @min(@as(f32, 300), @max(@as(f32, 180), 64 + widest_value + 4));
        const details_x = details_right - block_width;
        // Values fit within the space to the right of the (max-width) labels.
        const meta_value_width = details_right - (details_x + 64);
        var details_y = self.page_height - self.margin_top - 50;

        // Document number (label tracks the document type)
        const num_label = self.data.number_label orelse (if (is_quote) "Quote #:" else if (is_receipt) "Receipt #:" else "Invoice #:");
        try content.drawText(num_label, details_x, details_y, self.font_bold, 10, document.Color.black);
        try self.drawRightFit(&content, self.data.invoice_number, details_right, meta_value_width, details_y, self.font_regular, reg, 10, document.Color.black);
        details_y -= 15;

        // Date
        try content.drawText(self.data.labels.date, details_x, details_y, self.font_bold, 10, document.Color.black);
        try self.drawRightFit(&content, self.data.invoice_date, details_right, meta_value_width, details_y, self.font_regular, reg, 10, document.Color.black);
        details_y -= 15;

        // Due date
        if (self.data.due_date.len > 0) {
            try content.drawText(self.data.labels.due_date, details_x, details_y, self.font_bold, 10, document.Color.black);
            try self.drawRightFit(&content, self.data.due_date, details_right, meta_value_width, details_y, self.font_regular, reg, 10, document.Color.black);
        }

        // =====================================================================
        // Client Section
        // =====================================================================

        if (self.roundedLayout()) {
            // Rounded-card themes: From + Bill To as side-by-side cards; the
            // client card carries an accent treatment — the emphasis from the
            // HDM benchmark. Squircle uses bordered cards; glass uses
            // translucent panels with a sheen over the wash.
            const card_border = document.Color.fromHex("#E5E7EB");
            const muted = document.Color.fromHex("#6B7280");
            // Clear BOTH columns above: the company block (left, current_y)
            // and the invoice-meta block (right, details_y ends at the Due
            // Date baseline) — plus a full line of air before the cards.
            self.current_y = @min(self.current_y - 16, details_y - 26);
            const gap: f32 = 14;
            // Cards share the table container's exact span (margin−8 … +8) —
            // field report: edges a hair inside the table read as misaligned.
            const row_x = self.margin_left - 8;
            const row_w = usable_width + 16;
            const card_w = (row_w - gap) / 2;
            const pad: f32 = 12;

            // Count lines to size both cards identically (label + name + lines).
            var from_lines: f32 = 1; // company name
            if (self.data.company_address.len > 0) {
                var it = std.mem.splitSequence(u8, self.data.company_address, addressDelimiter(self.data.company_address));
                while (it.next()) |_| from_lines += 1;
            }
            if (self.data.company_vat.len > 0) from_lines += 1;
            var to_lines: f32 = 1; // client name
            if (self.data.client_address.len > 0) {
                var it = std.mem.splitSequence(u8, self.data.client_address, addressDelimiter(self.data.client_address));
                while (it.next()) |_| to_lines += 1;
            }
            if (self.data.client_vat.len > 0) to_lines += 1;
            const n_lines = @max(from_lines, to_lines);
            const card_h = 26 + n_lines * 13 + pad; // label row (+4 gap) + lines + padding

            const card_top = self.current_y;
            const from_x = row_x;
            const to_x = row_x + card_w + gap;
            if (self.data.theme == .glass) {
                // From: neutral translucent panel. Bill To: same glass with a
                // SOFT accent — the faded material everywhere (field report:
                // the saturated hairline/sheen read louder than the rest).
                try self.drawGlassPanel(&page_bg, from_x, card_top - card_h, card_w, card_h, 10, document.Color.white, 0.72, glass_sheen_end, 0.50, glass_panel_border, 1.0);
                const to_border = mixColor(document.Color.white, primary, 0.45);
                try self.drawGlassPanel(&page_bg, to_x, card_top - card_h, card_w, card_h, 10, document.Color.white, 0.74, glass_sheen_end, 0.55, to_border, 1.1);
            } else {
                try content.drawRoundedRectEx(from_x, card_top - card_h, card_w, card_h, 10, null, card_border, 1.0);
                try content.drawRoundedRectEx(to_x, card_top - card_h, card_w, card_h, 10, null, primary, 1.5);
            }

            // From card content — label and name share the exact left edge;
            // the extra 4pt under the label keeps them reading as two rows
            // rather than a cramped lockup (field report).
            var fy = card_top - pad - 6;
            try content.drawText(self.data.labels.from_card, from_x + pad, fy, self.font_bold, 8, muted);
            fy -= 19;
            try content.drawText(self.data.company_name, from_x + pad, fy, self.font_bold, 10, document.Color.black);
            fy -= 13;
            if (self.data.company_address.len > 0) {
                var it = std.mem.splitSequence(u8, self.data.company_address, addressDelimiter(self.data.company_address));
                while (it.next()) |line| {
                    try content.drawText(line, from_x + pad, fy, self.font_regular, 9, document.Color.black);
                    fy -= 13;
                }
            }
            if (self.data.company_vat.len > 0) {
                var vat_buf: [128]u8 = undefined;
                const vat_line = std.fmt.bufPrint(&vat_buf, "{s}: {s}", .{ self.data.labels.vat_prefix, self.data.company_vat }) catch self.data.company_vat;
                try content.drawText(vat_line, from_x + pad, fy, self.font_regular, 9, muted);
            }

            // Bill To card content
            var ty = card_top - pad - 6;
            try content.drawText(self.data.labels.bill_to_card, to_x + pad, ty, self.font_bold, 8, primary);
            ty -= 19;
            try content.drawText(self.data.client_name, to_x + pad, ty, self.font_bold, 10, document.Color.black);
            ty -= 13;
            if (self.data.client_address.len > 0) {
                var it = std.mem.splitSequence(u8, self.data.client_address, addressDelimiter(self.data.client_address));
                while (it.next()) |line| {
                    try content.drawText(line, to_x + pad, ty, self.font_regular, 9, document.Color.black);
                    ty -= 13;
                }
            }
            if (self.data.client_vat.len > 0) {
                var cvat_buf: [128]u8 = undefined;
                const cvat_line = std.fmt.bufPrint(&cvat_buf, "{s}: {s}", .{ self.data.labels.vat_prefix, self.data.client_vat }) catch self.data.client_vat;
                try content.drawText(cvat_line, to_x + pad, ty, self.font_regular, 9, muted);
            }

            self.current_y = card_top - card_h - 8;
        } else {
            self.current_y -= 30;

            // "Bill To" header
            try content.drawText(self.data.labels.bill_to, self.margin_left, self.current_y, self.font_bold, 12, primary);
            self.current_y -= 18;

            // Client name
            try content.drawText(self.data.client_name, self.margin_left, self.current_y, self.font_bold, 11, document.Color.black);
            self.current_y -= 14;

            // Client address
            if (self.data.client_address.len > 0) {
                var addr_iter = std.mem.splitSequence(u8, self.data.client_address, addressDelimiter(self.data.client_address));
                while (addr_iter.next()) |line| {
                    try content.drawText(line, self.margin_left, self.current_y, self.font_regular, 10, document.Color.black);
                    self.current_y -= 13;
                }
            }

            // Client VAT
            if (self.data.client_vat.len > 0) {
                var cvat_buf: [128]u8 = undefined;
                const cvat_line = std.fmt.bufPrint(&cvat_buf, "{s}: {s}", .{ self.data.labels.vat_prefix, self.data.client_vat }) catch self.data.client_vat;
                try content.drawText(cvat_line, self.margin_left, self.current_y, self.font_regular, 10, document.Color.black);
                self.current_y -= 18;
            }
        }

        // =====================================================================
        // Items Table
        // =====================================================================

        self.current_y -= 20;

        // Items table. The header is a helper so it can be redrawn at the top of
        // each continuation page when a long item list paginates.
        const table_style = self.data.table_style;
        const box_border = document.Color.fromHex("#d0d0d0");
        const col_desc = self.margin_left + 5;
        const col_qty = self.margin_left + 280;
        const col_price = self.margin_left + 350;
        const col_total = self.margin_left + 450;

        try self.drawTableHeader(&content);

        // Table rows - with text wrapping for descriptions
        const desc_col_width = col_qty - col_desc - 10; // Description column width with padding
        const line_height: f32 = 12; // Height per line of text
        const row_padding: f32 = 6; // Padding above/below text in row

        // Get font enum for text measurement
        const font_enum = self.fontEnumRegular();

        if (self.data.display_mode == .itemized) {
            for (self.data.items, 0..) |item, i| {
                // Wrap description text to fit column width
                var wrapped = try document.wrapText(self.allocator, item.description, font_enum, 9, desc_col_width);
                defer wrapped.deinit();

                const num_lines = @max(1, wrapped.lines.len);
                const row_height = @as(f32, @floatFromInt(num_lines)) * line_height + row_padding;

                // Paginate: if this row won't fit, close this page's rounded
                // container (squircle), then start a new page and redraw the
                // table header before drawing it.
                if (self.current_y - row_height < self.margin_bottom + 40) {
                    try self.closeTableContainer(&content, self.current_y + 2);
                    try self.startNewPage(&content, true);
                }

                // Row background — squircle draws a hairline separator under
                // each row; otherwise it depends on table_style:
                //   bands   -> alternating #f5f5f5 fill on even rows (original)
                //   boxes   -> a light border around every row, no fill
                //   minimal -> nothing (clean rows)
                const row_y = self.current_y - row_height + line_height;
                if (self.roundedLayout()) {
                    if (i + 1 < self.data.items.len) {
                        const sep = if (self.data.theme == .glass) document.Color.fromHex("#EDF0F3") else document.Color.fromHex("#E5E7EB");
                        try content.drawLine(self.margin_left + 2, row_y - 4, self.margin_left + usable_width - 2, row_y - 4, sep, 0.5);
                    }
                } else switch (table_style) {
                    .bands => if (i % 2 == 0) {
                        try content.drawRect(self.margin_left, row_y, usable_width, row_height, document.Color.fromHex("#f5f5f5"), null);
                    },
                    .boxes => try content.drawRect(self.margin_left, row_y, usable_width, row_height, null, box_border),
                    .minimal => {},
                }

                // Draw wrapped description lines
                var desc_y = self.current_y;
                for (wrapped.lines) |line| {
                    try content.drawText(line, col_desc, desc_y, self.font_regular, 9, document.Color.black);
                    desc_y -= line_height;
                }

                // Draw qty/price/total on first line (aligned with top of description)
                var qty_buf: [16]u8 = undefined;
                const qty_str = std.fmt.bufPrint(&qty_buf, "{d:.0}", .{item.quantity}) catch "0";
                try content.drawText(qty_str, col_qty, self.current_y, self.font_regular, 9, document.Color.black);

                var price_buf: [24]u8 = undefined;
                const price_str = std.fmt.bufPrint(&price_buf, "{s}{d:.2}", .{ self.data.currency_symbol, item.unit_price }) catch "0.00";
                try content.drawText(price_str, col_price, self.current_y, self.font_regular, 9, document.Color.black);

                var total_buf: [24]u8 = undefined;
                const total_str = std.fmt.bufPrint(&total_buf, "{s}{d:.2}", .{ self.data.currency_symbol, item.total }) catch "0.00";
                try content.drawText(total_str, col_total, self.current_y, self.font_regular, 9, document.Color.black);

                self.current_y -= row_height + 2; // Move down by row height plus small gap
            }
        } else {
            // Blackbox mode - wrap description text
            var wrapped = try document.wrapText(self.allocator, self.data.blackbox_description, font_enum, 9, desc_col_width);
            defer wrapped.deinit();

            const num_lines = @max(1, wrapped.lines.len);
            const row_height = @as(f32, @floatFromInt(num_lines)) * line_height + row_padding;

            const bb_y = self.current_y - row_height + line_height;
            if (self.roundedLayout()) {
                // container + header band carry the look; no row fill
            } else switch (table_style) {
                .bands => try content.drawRect(self.margin_left, bb_y, usable_width, row_height, document.Color.fromHex("#f5f5f5"), null),
                .boxes => try content.drawRect(self.margin_left, bb_y, usable_width, row_height, null, box_border),
                .minimal => {},
            }

            // Draw wrapped description lines
            var desc_y = self.current_y;
            for (wrapped.lines) |line| {
                try content.drawText(line, col_desc, desc_y, self.font_regular, 9, document.Color.black);
                desc_y -= line_height;
            }

            var total_buf: [24]u8 = undefined;
            const total_str = std.fmt.bufPrint(&total_buf, "{s}{d:.2}", .{ self.data.currency_symbol, self.data.subtotal }) catch "0.00";
            try content.drawText(total_str, col_total, self.current_y, self.font_regular, 9, document.Color.black);

            self.current_y -= row_height + 2;
        }

        // =====================================================================
        // Totals Section
        // =====================================================================

        // Squircle: the rows are done — close the rounded table container.
        try self.closeTableContainer(&content, self.current_y + 2);

        // Keep the whole totals block together: if it won't fit under the last
        // row, move it to a fresh page (no table header needed there).
        if (self.current_y < self.margin_bottom + 160) {
            try self.startNewPage(&content, false);
        }

        self.current_y -= 20;

        // Separator line
        try content.drawLine(col_price - 20, self.current_y + 15, self.page_width - self.margin_right, self.current_y + 15, secondary, 0.5);

        // Amount values are right-anchored so large figures grow leftward and
        // never overrun the table's right edge.
        const amt_right = self.margin_left + usable_width - 6;
        const reg_t = self.fontEnumRegular();
        const amt_width = amt_right - (col_price + 70); // space right of the widest label

        // Subtotal + Tax — only when VAT/tax is being shown. For a non-tax
        // receipt these rows are suppressed entirely (subtotal == total, and a
        // "Tax (0%)" line would be misleading); only the TOTAL bar is rendered.
        if (self.data.show_tax) {
            // Subtotal
            try content.drawText(self.data.labels.subtotal, col_price, self.current_y, self.font_regular, 10, document.Color.black);
            var subtotal_buf: [24]u8 = undefined;
            const subtotal_str = std.fmt.bufPrint(&subtotal_buf, "{s}{d:.2}", .{ self.data.currency_symbol, self.data.subtotal }) catch "0.00";
            try self.drawRightFit(&content, subtotal_str, amt_right, amt_width, self.current_y, self.font_regular, reg_t, 10, document.Color.black);
            self.current_y -= 16;

            // Tax
            var tax_label_buf: [64]u8 = undefined;
            const tax_pct = self.data.tax_rate * 100;
            const tax_label = std.fmt.bufPrint(&tax_label_buf, "{s} ({d:.0}%):", .{ self.data.labels.tax_prefix, tax_pct }) catch self.data.labels.tax_prefix;
            try content.drawText(tax_label, col_price, self.current_y, self.font_regular, 10, document.Color.black);
            var tax_buf: [24]u8 = undefined;
            const tax_str = std.fmt.bufPrint(&tax_buf, "{s}{d:.2}", .{ self.data.currency_symbol, self.data.tax_amount }) catch "0.00";
            try self.drawRightFit(&content, tax_str, amt_right, amt_width, self.current_y, self.font_regular, reg_t, 10, document.Color.black);
            self.current_y -= 16;

            // IRPF retention (Spanish freelancer invoices) — a negative row.
            // Shown only when a rate or amount is set; otherwise the row is hidden.
            if (self.data.irpf_rate != 0 or self.data.irpf_amount != 0) {
                var irpf_label_buf: [32]u8 = undefined;
                const irpf_pct = self.data.irpf_rate * 100;
                const irpf_label = std.fmt.bufPrint(&irpf_label_buf, "IRPF ({d:.0}%):", .{irpf_pct}) catch "IRPF:";
                try content.drawText(irpf_label, col_price, self.current_y, self.font_regular, 10, document.Color.black);
                var irpf_buf: [24]u8 = undefined;
                const irpf_str = std.fmt.bufPrint(&irpf_buf, "-{s}{d:.2}", .{ self.data.currency_symbol, @abs(self.data.irpf_amount) }) catch "0.00";
                try self.drawRightFit(&content, irpf_str, amt_right, amt_width, self.current_y, self.font_regular, reg_t, 10, document.Color.black);
                self.current_y -= 16;
            }

            self.current_y -= 12; // Extra spacing before TOTAL row
        } else {
            self.current_y -= 12; // Modest gap between separator and TOTAL bar
        }

        // Total (highlighted) - width calculated to align with table right edge
        const total_bar_x = col_price - 10;
        const table_right_edge = self.margin_left + usable_width;
        const total_bar_width = table_right_edge - total_bar_x;
        if (self.data.theme == .glass) {
            // Emphasis chip in the SAME faded material as the (container-
            // washed) header band — glass accents whisper, they don't shout
            // (field report). Dark text carries the contrast instead.
            const chip_fill = mixColor(document.Color.white, primary, 0.30);
            try self.drawGlassPanel(&page_bg, total_bar_x, self.current_y - 5, total_bar_width, 22, 7, chip_fill, 0.85, glass_sheen_end, 0.50, glass_panel_border, 1.0);
        } else if (self.data.theme == .squircle) {
            try content.drawRoundedRectEx(total_bar_x, self.current_y - 5, total_bar_width, 22, 7, primary, null, 1.0);
        } else {
            try content.drawRect(total_bar_x, self.current_y - 5, total_bar_width, 22, primary, null);
        }
        // Faded glass chip needs dark ink; solid chips keep white.
        const total_text_color = if (self.data.theme == .glass) secondary else document.Color.white;
        try content.drawText(self.data.labels.total, col_price, self.current_y, self.font_bold, 12, total_text_color);
        var grand_total_buf: [24]u8 = undefined;
        const grand_total_str = std.fmt.bufPrint(&grand_total_buf, "{s}{d:.2}", .{ self.data.currency_symbol, self.data.total }) catch "0.00";
        try self.drawRightFit(&content, grand_total_str, table_right_edge - 10, (table_right_edge - 10) - (col_price + 64), self.current_y, self.font_bold, self.fontEnumBold(), 12, total_text_color);

        // =====================================================================
        // Footer Section - Notes/Payment Terms then QR Code below
        // =====================================================================

        self.current_y -= 30;

        // Notes (full width with text wrapping)
        const notes_max_width = usable_width - 10; // Full width minus small padding

        if (self.data.notes.len > 0) {
            try content.drawText(self.data.labels.notes, self.margin_left, self.current_y, self.font_bold, 10, secondary);
            self.current_y -= 14;

            // Wrap notes text
            var notes_wrapped = try document.wrapText(self.allocator, self.data.notes, font_enum, 9, notes_max_width);
            defer notes_wrapped.deinit();

            for (notes_wrapped.lines) |line| {
                try content.drawText(line, self.margin_left, self.current_y, self.font_regular, 9, document.Color.black);
                self.current_y -= 12;
            }
            self.current_y -= 6; // Extra spacing after notes
        }

        // Payment terms (full width with text wrapping)
        if (self.data.payment_terms.len > 0) {
            try content.drawText(self.data.labels.payment_terms, self.margin_left, self.current_y, self.font_bold, 10, secondary);
            self.current_y -= 14;

            // Wrap payment terms text
            var terms_wrapped = try document.wrapText(self.allocator, self.data.payment_terms, font_enum, 9, notes_max_width);
            defer terms_wrapped.deinit();

            for (terms_wrapped.lines) |line| {
                try content.drawText(line, self.margin_left, self.current_y, self.font_regular, 9, document.Color.black);
                self.current_y -= 12;
            }
            self.current_y -= 8; // Extra spacing after payment terms
        }

        // =====================================================================
        // Crypto Payment Section (with optional identicons)
        // =====================================================================
        if (wallet_val) |wallet| {
            if (wallet.len > 0) {
                self.current_y -= 10;

                // Section header with network color
                const network_color = document.Color.fromHex(network_val.color());
                const network_name = network_val.displayName();

                var header_buf: [64]u8 = undefined;
                const header_text = std.fmt.bufPrint(&header_buf, "Pay with {s} ({s})", .{ network_name, symbol_val }) catch "Crypto Payment";
                try content.drawText(header_text, self.margin_left, self.current_y, self.font_bold, 11, network_color);
                self.current_y -= 18;

                // Recipient wallet address with optional identicon
                const identicon_size: f32 = 24;
                const addr_x = if (recipient_identicon_id != null) self.margin_left + identicon_size + 8 else self.margin_left;

                if (recipient_identicon_id) |icon_id| {
                    try content.drawImage(icon_id, self.margin_left, self.current_y - identicon_size + 10, identicon_size, identicon_size);
                }

                try content.drawText("To:", addr_x, self.current_y, self.font_bold, 9, secondary);
                self.current_y -= 12;

                // Show truncated address
                const truncated = truncateAddress(wallet, 10, 8);
                try content.drawText(&truncated, addr_x, self.current_y, self.font_regular, 9, document.Color.black);
                self.current_y -= 14;

                // Full address in smaller font (for verification)
                try content.drawText(wallet, addr_x, self.current_y, self.font_regular, 7, document.Color.fromHex("#666666"));
                self.current_y -= 16;

                // Sender wallet (if provided) with optional identicon
                if (sender_val) |sender| {
                    if (sender.len > 0) {
                        const sender_x = if (sender_identicon_id != null) self.margin_left + identicon_size + 8 else self.margin_left;

                        if (sender_identicon_id) |icon_id| {
                            try content.drawImage(icon_id, self.margin_left, self.current_y - identicon_size + 10, identicon_size, identicon_size);
                        }

                        try content.drawText("From:", sender_x, self.current_y, self.font_bold, 9, secondary);
                        self.current_y -= 12;

                        const sender_truncated = truncateAddress(sender, 10, 8);
                        try content.drawText(&sender_truncated, sender_x, self.current_y, self.font_regular, 9, document.Color.black);
                        self.current_y -= 18;
                    }
                }

                // Crypto amount if specified
                if (amount_str) |amt_s| {
                    if (amt_s.len > 0) {
                        var amount_buf: [128]u8 = undefined;
                        const amount_text = std.fmt.bufPrint(&amount_buf, "Amount: {s} {s}", .{ amt_s, symbol_val }) catch "Amount: [error]";
                        try content.drawText(amount_text, self.margin_left, self.current_y, self.font_bold, 10, network_color);
                        self.current_y -= 20;
                    }
                } else if (self.data.crypto_amount) |amount| {
                    var amount_buf: [64]u8 = undefined;
                    const amount_text = std.fmt.bufPrint(&amount_buf, "Amount: {d:.8} {s}", .{ amount, symbol_val }) catch "Amount: [error]";
                    try content.drawText(amount_text, self.margin_left, self.current_y, self.font_bold, 10, network_color);
                    self.current_y -= 20;
                }
            }
        }

        // Resolve the effective payment buttons: an explicit payment_buttons
        // array wins; otherwise synthesize a single button from the legacy
        // payment_button_* fields so existing callers are unchanged.
        var single_buf: [1]PaymentButton = undefined;
        const pay_btns: []const PaymentButton = blk: {
            if (self.data.payment_buttons.len > 0) break :blk self.data.payment_buttons;
            if (self.data.payment_button_url) |url| {
                single_buf[0] = .{
                    .label = self.data.payment_button_label,
                    .url = url,
                    .color = self.data.payment_button_color,
                    .text_color = self.data.payment_button_text_color,
                };
                break :blk single_buf[0..1];
            }
            break :blk &[_]PaymentButton{};
        };

        // QR Code - positioned below notes, right-aligned with table
        if (qr_id) |qid| {
            const qr_size: f32 = 80; // ~28mm for good scannability
            const qr_padding: f32 = 15;

            // Right edge aligns with table right edge
            const qr_x = table_right_edge - qr_size;
            const qr_y = self.current_y - qr_size - qr_padding;

            try content.drawImage(qid, qr_x, qr_y, qr_size, qr_size);

            // Label below QR code - use custom label if provided, otherwise default by mode
            const qr_label: []const u8 = if (self.data.qr_label) |custom_label|
                if (custom_label.len > 0) custom_label else switch (effective_qr_mode) {
                    .verifactu => "VeriFactu",
                    .payment_link => self.data.labels.scan_to_pay,
                    .bank_details => self.data.labels.bank_details,
                    .verification => self.data.labels.verify_invoice,
                    .crypto => "Crypto Payment",
                    .none => "",
                }
            else switch (effective_qr_mode) {
                .verifactu => "VeriFactu",
                .payment_link => self.data.labels.scan_to_pay,
                .bank_details => self.data.labels.bank_details,
                .verification => self.data.labels.verify_invoice,
                .crypto => "Crypto Payment",
                .none => "",
            };

            if (qr_label.len > 0) {
                // Center label under QR (approximate centering based on label length)
                const label_width: f32 = @as(f32, @floatFromInt(qr_label.len)) * 4.5;
                const label_x = qr_x + (qr_size / 2) - (label_width / 2);
                try content.drawText(qr_label, label_x, qr_y - 10, self.font_bold, 9, primary);
            }

            // Payment button(s) stacked to the left of the QR code.
            if (pay_btns.len > 0) {
                const btn_width: f32 = 100;
                const btn_height: f32 = 28;
                const gap: f32 = 6;
                const n: f32 = @floatFromInt(pay_btns.len);
                const stack_h = n * btn_height + (n - 1) * gap;
                const btn_x = qr_x - btn_width - 15; // Left of QR with spacing
                var btn_y = qr_y + (qr_size + stack_h) / 2 - btn_height; // stack centered on QR
                for (pay_btns) |b| {
                    const bg = document.Color.fromHex(b.color);
                    const tc = document.Color.fromHex(b.text_color);
                    const bounds = try content.drawButton(b.label, btn_x, btn_y, btn_width, btn_height, self.font_bold, 11, bg, tc, 6);
                    try self.doc.addLinkAnnotation(bounds.x1, bounds.y1, bounds.x2, bounds.y2, b.url);
                    btn_y -= btn_height + gap;
                }
            }

            // Update current_y to account for QR placement
            self.current_y = qr_y - 25;
        } else if (pay_btns.len > 0) {
            // No QR code — stack the payment button(s) standalone, right-aligned.
            const btn_width: f32 = 140;
            const btn_height: f32 = 34;
            const gap: f32 = 8;
            const btn_x = table_right_edge - btn_width;
            var btn_y = self.current_y - btn_height - 15;
            for (pay_btns) |b| {
                const bg = document.Color.fromHex(b.color);
                const tc = document.Color.fromHex(b.text_color);
                const bounds = try content.drawButton(b.label, btn_x, btn_y, btn_width, btn_height, self.font_bold, 12, bg, tc, 6);
                try self.doc.addLinkAnnotation(bounds.x1, bounds.y1, bounds.x2, bounds.y2, b.url);
                btn_y -= btn_height + gap;
            }

            // "Click to Pay" hint below a single button.
            if (pay_btns.len == 1) {
                const label_text = self.data.labels.click_to_pay;
                const lbl_width: f32 = @as(f32, @floatFromInt(label_text.len)) * 4.0;
                const lbl_x = btn_x + (btn_width - lbl_width) / 2;
                try content.drawText(label_text, lbl_x, btn_y + gap - 12, self.font_regular, 8, secondary);
            }

            self.current_y = btn_y - 20;
        }

        // Footer line - fixed position near bottom
        try content.drawLine(self.margin_left, self.margin_bottom - 10, self.page_width - self.margin_right, self.margin_bottom - 10, secondary, 0.5);

        // Footer text - varies by QR mode
        if (qr_id != null) {
            const footer_label: []const u8 = switch (effective_qr_mode) {
                .verifactu => self.data.labels.footer_verifactu,
                .payment_link => self.data.labels.footer_scan_to_pay,
                .bank_details => self.data.labels.footer_bank_details,
                .verification => self.data.labels.footer_verify,
                .crypto => "Cryptocurrency Payment Accepted",
                .none => "",
            };
            if (footer_label.len > 0) {
                try content.drawText(footer_label, self.margin_left, self.margin_bottom - 25, self.font_regular, 8, secondary);
            }

            // VeriFactu: Display hash signature (huella) in footer
            if (effective_qr_mode == .verifactu) {
                if (self.data.verifactu_hash) |hash| {
                    if (hash.len > 0) {
                        // Show truncated hash (first 16 chars as per VeriFactu QR standard)
                        const hash_display = if (hash.len > 16) hash[0..16] else hash;
                        // Format: "Huella: XXXXXXXXXXXXXXXX"
                        var hash_buf: [32]u8 = undefined;
                        const hash_text = std.fmt.bufPrint(&hash_buf, "Huella: {s}...", .{hash_display}) catch "Huella: [error]";
                        try content.drawText(hash_text, self.margin_left, self.margin_bottom - 38, self.font_regular, 7, secondary);
                    }
                }

                // Display series and NIF if available
                if (self.data.verifactu_series) |series| {
                    if (series.len > 0) {
                        var series_buf: [32]u8 = undefined;
                        const series_text = std.fmt.bufPrint(&series_buf, "Serie: {s}", .{series}) catch "Serie: [error]";
                        try content.drawText(series_text, self.margin_left + 180, self.margin_bottom - 38, self.font_regular, 7, secondary);
                    }
                }

                if (self.data.verifactu_nif) |nif| {
                    if (nif.len > 0) {
                        var nif_buf: [32]u8 = undefined;
                        const nif_text = std.fmt.bufPrint(&nif_buf, "NIF: {s}", .{nif}) catch "NIF: [error]";
                        try content.drawText(nif_text, self.margin_left + 250, self.margin_bottom - 38, self.font_regular, 7, secondary);
                    }
                }
            }

            try content.drawText(self.data.labels.thank_you, self.page_width - self.margin_right - 130, self.margin_bottom - 25, self.font_regular, 9, secondary);
        } else {
            try content.drawText(self.data.labels.thank_you, self.page_width / 2 - 60, self.margin_bottom - 25, self.font_regular, 9, secondary);
        }

        // Branding footer with clickable link
        if (self.data.show_branding) {
            const branding_text = "Generated by Quantify";
            const branding_font_size: f32 = 7;
            const branding_y = self.margin_bottom - 45;

            // Calculate text width for link annotation (approx 4.2 points per char at size 7)
            const text_width: f32 = @as(f32, @floatFromInt(branding_text.len)) * 4.2;

            // Draw centered branding text in subtle gray
            const branding_x = (self.page_width - text_width) / 2;
            const branding_color = document.Color{ .r = 0.6, .g = 0.6, .b = 0.6 }; // Light gray
            try content.drawText(branding_text, branding_x, branding_y, self.font_regular, branding_font_size, branding_color);

            // Add clickable link annotation (PDF coordinates: x1, y1, x2, y2)
            try self.doc.addLinkAnnotation(
                branding_x,
                branding_y - 2, // Slight padding below text
                branding_x + text_width,
                branding_y + branding_font_size + 2, // Slight padding above text
                self.data.branding_url,
            );
        }

        // Add page to document — composite the glass background beneath the
        // foreground (a no-op for other themes, whose bg layer is empty).
        try self.flushPage(&content);

        // Password-protect the document (AES-256) when a password is set. Must
        // be configured before build() so every stream/string is encrypted.
        if (self.data.password.len > 0) {
            const owner = if (self.data.owner_password.len > 0) self.data.owner_password else self.data.password;
            try self.doc.enableEncryption(self.data.password, owner, document.DEFAULT_PERMS, self.data.seed orelse osSeed());
        }

        // Build and return PDF
        return try self.doc.build();
    }

    /// Build cryptocurrency payment URI for QR code
    /// Supports BIP21 (Bitcoin), EIP681 (Ethereum/ERC20), and other chain-specific formats
    fn buildCryptoUri(self: *InvoiceRenderer, wallet: []const u8, network: crypto_receipt.Network, symbol: []const u8, amount_str: ?[]const u8) ![]u8 {
        // Buffer for URI construction
        var uri_buf: [512]u8 = undefined;

        // Determine URI scheme based on network
        const uri_str: []const u8 = switch (network) {
            .bitcoin => blk: {
                // BIP21: bitcoin:<address>?amount=<amount>&label=<label>
                if (amount_str) |amt| {
                    if (amt.len > 0) break :blk std.fmt.bufPrint(&uri_buf, "bitcoin:{s}?amount={s}", .{ wallet, amt }) catch "bitcoin:error";
                }
                if (self.data.crypto_amount) |amount| {
                    break :blk std.fmt.bufPrint(&uri_buf, "bitcoin:{s}?amount={d:.8}", .{ wallet, amount }) catch "bitcoin:error";
                }
                break :blk std.fmt.bufPrint(&uri_buf, "bitcoin:{s}", .{wallet}) catch "bitcoin:error";
            },
            .ethereum, .polygon, .bnb => blk: {
                // EIP681: ethereum:<address>[@chainId]?value=<wei>
                const chain_id: u32 = switch (network) {
                    .ethereum => 1,
                    .polygon => 137,
                    .bnb => 56,
                    else => 1,
                };
                var opt_amount: ?f64 = null;
                if (amount_str) |amt| {
                    if (amt.len > 0) opt_amount = std.fmt.parseFloat(f64, amt) catch 0.0;
                } else if (self.data.crypto_amount) |amt| {
                    opt_amount = amt;
                }
                if (opt_amount) |amount| {
                    // Convert to wei (1 ETH = 10^18 wei)
                    const wei: u64 = @intFromFloat(amount * 1e18);
                    break :blk std.fmt.bufPrint(&uri_buf, "ethereum:{s}@{d}?value={d}", .{ wallet, chain_id, wei }) catch "ethereum:error";
                } else {
                    break :blk std.fmt.bufPrint(&uri_buf, "ethereum:{s}@{d}", .{ wallet, chain_id }) catch "ethereum:error";
                }
            },
            .litecoin => blk: {
                if (amount_str) |amt| {
                    if (amt.len > 0) break :blk std.fmt.bufPrint(&uri_buf, "litecoin:{s}?amount={s}", .{ wallet, amt }) catch "litecoin:error";
                }
                if (self.data.crypto_amount) |amount| {
                    break :blk std.fmt.bufPrint(&uri_buf, "litecoin:{s}?amount={d:.8}", .{ wallet, amount }) catch "litecoin:error";
                }
                break :blk std.fmt.bufPrint(&uri_buf, "litecoin:{s}", .{wallet}) catch "litecoin:error";
            },
            .dogecoin => blk: {
                if (amount_str) |amt| {
                    if (amt.len > 0) break :blk std.fmt.bufPrint(&uri_buf, "dogecoin:{s}?amount={s}", .{ wallet, amt }) catch "dogecoin:error";
                }
                if (self.data.crypto_amount) |amount| {
                    break :blk std.fmt.bufPrint(&uri_buf, "dogecoin:{s}?amount={d:.8}", .{ wallet, amount }) catch "dogecoin:error";
                }
                break :blk std.fmt.bufPrint(&uri_buf, "dogecoin:{s}", .{wallet}) catch "dogecoin:error";
            },
            .bitcoin_cash => blk: {
                if (amount_str) |amt| {
                    if (amt.len > 0) break :blk std.fmt.bufPrint(&uri_buf, "bitcoincash:{s}?amount={s}", .{ wallet, amt }) catch "bitcoincash:error";
                }
                if (self.data.crypto_amount) |amount| {
                    break :blk std.fmt.bufPrint(&uri_buf, "bitcoincash:{s}?amount={d:.8}", .{ wallet, amount }) catch "bitcoincash:error";
                }
                break :blk std.fmt.bufPrint(&uri_buf, "bitcoincash:{s}", .{wallet}) catch "bitcoincash:error";
            },
            .solana => blk: {
                if (amount_str) |amt| {
                    if (amt.len > 0) break :blk std.fmt.bufPrint(&uri_buf, "solana:{s}?amount={s}", .{ wallet, amt }) catch "solana:error";
                }
                if (self.data.crypto_amount) |amount| {
                    break :blk std.fmt.bufPrint(&uri_buf, "solana:{s}?amount={d:.9}", .{ wallet, amount }) catch "solana:error";
                }
                break :blk std.fmt.bufPrint(&uri_buf, "solana:{s}", .{wallet}) catch "solana:error";
            },
            .tron => blk: {
                if (amount_str) |amt| {
                    if (amt.len > 0) break :blk std.fmt.bufPrint(&uri_buf, "tron:{s}?amount={s}", .{ wallet, amt }) catch "tron:error";
                }
                if (self.data.crypto_amount) |amount| {
                    break :blk std.fmt.bufPrint(&uri_buf, "tron:{s}?amount={d:.6}", .{ wallet, amount }) catch "tron:error";
                }
                break :blk std.fmt.bufPrint(&uri_buf, "tron:{s}", .{wallet}) catch "tron:error";
            },
            .xrp => blk: {
                if (amount_str) |amt| {
                    if (amt.len > 0) break :blk std.fmt.bufPrint(&uri_buf, "xrpl:{s}?amount={s}", .{ wallet, amt }) catch "xrpl:error";
                }
                if (self.data.crypto_amount) |amount| {
                    break :blk std.fmt.bufPrint(&uri_buf, "xrpl:{s}?amount={d:.6}", .{ wallet, amount }) catch "xrpl:error";
                }
                break :blk std.fmt.bufPrint(&uri_buf, "xrpl:{s}", .{wallet}) catch "xrpl:error";
            },
            .cardano => blk: {
                if (amount_str) |amt| {
                    if (amt.len > 0) break :blk std.fmt.bufPrint(&uri_buf, "web+cardano:{s}?amount={s}", .{ wallet, amt }) catch "cardano:error";
                }
                if (self.data.crypto_amount) |amount| {
                    break :blk std.fmt.bufPrint(&uri_buf, "web+cardano:{s}?amount={d:.6}", .{ wallet, amount }) catch "cardano:error";
                }
                break :blk std.fmt.bufPrint(&uri_buf, "web+cardano:{s}", .{wallet}) catch "cardano:error";
            },
            .usdt, .usdc => blk: {
                break :blk std.fmt.bufPrint(&uri_buf, "ethereum:{s}?token={s}", .{ wallet, symbol }) catch "ethereum:error";
            },
            .lightning => blk: {
                break :blk std.fmt.bufPrint(&uri_buf, "lightning:{s}", .{wallet}) catch "lightning:error";
            },
            .custom => blk: {
                if (amount_str) |amt| {
                    if (amt.len > 0) break :blk std.fmt.bufPrint(&uri_buf, "{s}:{s}?amount={s}", .{ symbol, wallet, amt }) catch "custom:error";
                }
                if (self.data.crypto_amount) |amount| {
                    break :blk std.fmt.bufPrint(&uri_buf, "{s}:{s}?amount={d:.8}", .{ symbol, wallet, amount }) catch "custom:error";
                }
                break :blk std.fmt.bufPrint(&uri_buf, "{s}:{s}", .{ symbol, wallet }) catch "custom:error";
            },
        };

        return try self.allocator.dupe(u8, uri_str);
    }

    /// Truncate wallet address for display (show first and last N chars)
    fn truncateAddress(address: []const u8, comptime prefix_len: usize, comptime suffix_len: usize) [prefix_len + 3 + suffix_len]u8 {
        var result: [prefix_len + 3 + suffix_len]u8 = undefined;
        if (address.len <= prefix_len + suffix_len + 3) {
            // Address is short enough, pad with spaces
            @memset(&result, ' ');
            @memcpy(result[0..@min(address.len, result.len)], address[0..@min(address.len, result.len)]);
        } else {
            @memcpy(result[0..prefix_len], address[0..prefix_len]);
            result[prefix_len] = '.';
            result[prefix_len + 1] = '.';
            result[prefix_len + 2] = '.';
            @memcpy(result[prefix_len + 3 ..], address[address.len - suffix_len ..]);
        }
        return result;
    }
};

// =============================================================================
// Convenience Function
// =============================================================================

/// Generate invoice PDF from InvoiceData struct
/// Returns an allocator-owned slice that must be freed by the caller.
pub fn generateInvoice(allocator: std.mem.Allocator, data: InvoiceData) ![]u8 {
    var renderer = InvoiceRenderer.init(allocator, data);
    defer renderer.deinit();

    const pdf_output = try renderer.render();

    // Make a copy since the original is owned by renderer.doc
    const result = try allocator.dupe(u8, pdf_output);
    return result;
}

// =============================================================================
// Tests
// =============================================================================

test "generate simple invoice" {
    const allocator = std.testing.allocator;

    const items = [_]LineItem{
        .{ .description = "Web Development", .quantity = 40, .unit_price = 100, .total = 4000 },
        .{ .description = "Consulting", .quantity = 10, .unit_price = 150, .total = 1500 },
    };

    const data = InvoiceData{
        .document_type = "invoice",
        .company_name = "Acme Corp",
        .company_address = "123 Business St, Tech City",
        .company_vat = "ESB12345678",
        .client_name = "Client LLC",
        .client_address = "456 Client Ave",
        .client_vat = "ESB87654321",
        .invoice_number = "INV-2025-001",
        .invoice_date = "2025-11-29",
        .due_date = "2025-12-29",
        .items = &items,
        .subtotal = 5500,
        .tax_rate = 0.21,
        .tax_amount = 1155,
        .total = 6655,
        .notes = "Thank you for your business!",
        .payment_terms = "Payment due within 30 days",
    };

    const pdf_bytes = try generateInvoice(allocator, data);
    defer allocator.free(pdf_bytes);

    try std.testing.expect(pdf_bytes.len > 500);
    try std.testing.expect(std.mem.startsWith(u8, pdf_bytes, "%PDF-1.4"));
}

test "receipt with tax disabled omits tax rows" {
    const allocator = std.testing.allocator;

    const items = [_]LineItem{
        .{ .description = "Hot tub hire", .quantity = 1, .unit_price = 250, .total = 250 },
    };

    const data = InvoiceData{
        .document_type = "receipt",
        .company_name = "Lutuno Ltd",
        .client_name = "A. Customer",
        .invoice_number = "RCT-2026-001",
        .invoice_date = "2026-06-02",
        .items = &items,
        .subtotal = 250,
        .total = 250,
        .show_tax = false, // non-VAT-registered business
    };

    const pdf_bytes = try generateInvoice(allocator, data);
    defer allocator.free(pdf_bytes);

    try std.testing.expect(std.mem.startsWith(u8, pdf_bytes, "%PDF-1.4"));
    // Title reflects the document type
    try std.testing.expect(std.mem.indexOf(u8, pdf_bytes, "RECEIPT") != null);
    // No Subtotal / Tax breakdown is drawn when show_tax is false
    try std.testing.expect(std.mem.indexOf(u8, pdf_bytes, "Subtotal") == null);
    try std.testing.expect(std.mem.indexOf(u8, pdf_bytes, "Tax (") == null);
    // The TOTAL bar is still present
    try std.testing.expect(std.mem.indexOf(u8, pdf_bytes, "TOTAL") != null);
}

test "invoice with tax enabled still renders tax rows" {
    const allocator = std.testing.allocator;

    const items = [_]LineItem{
        .{ .description = "Consulting", .quantity = 1, .unit_price = 1000, .total = 1000 },
    };

    const data = InvoiceData{
        .document_type = "invoice",
        .company_name = "VAT Co",
        .invoice_number = "INV-1",
        .invoice_date = "2026-06-02",
        .items = &items,
        .subtotal = 1000,
        .tax_rate = 0.20,
        .tax_amount = 200,
        .total = 1200,
        // show_tax defaults to true
    };

    const pdf_bytes = try generateInvoice(allocator, data);
    defer allocator.free(pdf_bytes);

    // Note: PDF escapes literal parens in text strings ("(" -> "\("), so the
    // rate label appears as "Tax \(20%\)" in the byte stream — match the prefix.
    try std.testing.expect(std.mem.indexOf(u8, pdf_bytes, "Subtotal") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf_bytes, "Tax ") != null);
}

test "encrypted invoice: password + fixed seed produces an /Encrypt-protected PDF" {
    const allocator = std.testing.allocator;

    const items = [_]LineItem{
        .{ .description = "Consulting", .quantity = 1, .unit_price = 1000, .total = 1000 },
    };

    const data = InvoiceData{
        .document_type = "invoice",
        .company_name = "Secure Co",
        .invoice_number = "ENC-1",
        .invoice_date = "2026-06-19",
        .items = &items,
        .subtotal = 1000,
        .total = 1000,
        .password = "open-sesame",
        .seed = [_]u8{0x11} ** 32, // fixed (non-zero) seed => reproducible file
    };

    const pdf_bytes = try generateInvoice(allocator, data);
    defer allocator.free(pdf_bytes);

    try std.testing.expect(std.mem.startsWith(u8, pdf_bytes, "%PDF-1.4"));
    // The encrypt dict and a document /ID must be present once encryption is on.
    try std.testing.expect(std.mem.indexOf(u8, pdf_bytes, "/Encrypt") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf_bytes, "/AESV3") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf_bytes, "/ID") != null);
}

test "encrypted invoice: an all-zero seed is refused" {
    const allocator = std.testing.allocator;

    const items = [_]LineItem{
        .{ .description = "X", .quantity = 1, .unit_price = 1, .total = 1 },
    };
    const data = InvoiceData{
        .company_name = "Co",
        .invoice_number = "Z-1",
        .invoice_date = "2026-06-19",
        .items = &items,
        .subtotal = 1,
        .total = 1,
        .password = "pw",
        .seed = [_]u8{0} ** 32, // all-zero => predictable key => must be rejected
    };
    try std.testing.expectError(error.InsecureSeed, generateInvoice(allocator, data));
}

test "generate crypto payment invoice with identicons" {
    const allocator = std.testing.allocator;

    const items = [_]LineItem{
        .{ .description = "Software Development", .quantity = 1, .unit_price = 5000, .total = 5000 },
    };

    const data = InvoiceData{
        .document_type = "invoice",
        .company_name = "Quantum Labs",
        .company_address = "789 Blockchain Ave, Crypto City",
        .client_name = "DeFi Protocol Inc",
        .client_address = "123 Smart Contract Blvd",
        .invoice_number = "CRYPTO-2026-001",
        .invoice_date = "2026-01-04",
        .due_date = "2026-01-14",
        .items = &items,
        .subtotal = 5000,
        .tax_rate = 0,
        .tax_amount = 0,
        .total = 5000,
        .notes = "Payment accepted in cryptocurrency",
        .payment_terms = "Payment due within 10 days",

        // Crypto payment options
        .qr_mode = .crypto,
        .crypto_wallet = "0x742d35Cc6634C0532925a3b844Bc9e7595f7ABCD",
        .crypto_network = .ethereum,
        .crypto_amount = 2.5,
        .crypto_sender_wallet = "0x8ba1f109551bD432803012645Ac136ddd64DBA72",
        .show_crypto_identicons = true,
        .primary_color = "#627eea", // Ethereum blue
    };

    const pdf_bytes = try generateInvoice(allocator, data);
    defer allocator.free(pdf_bytes);

    // Verify PDF structure
    try std.testing.expect(pdf_bytes.len > 5000); // Should be larger due to embedded images
    try std.testing.expect(std.mem.startsWith(u8, pdf_bytes, "%PDF-1.4"));
    try std.testing.expect(std.mem.endsWith(u8, pdf_bytes, "%%EOF\n"));

    // Verify crypto-related content
    try std.testing.expect(std.mem.indexOf(u8, pdf_bytes, "Ethereum") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf_bytes, "0x742d35Cc") != null);
}

test "generate bitcoin invoice with QR" {
    const allocator = std.testing.allocator;

    const items = [_]LineItem{
        .{ .description = "Consulting Services", .quantity = 10, .unit_price = 100, .total = 1000 },
    };

    const data = InvoiceData{
        .document_type = "invoice",
        .company_name = "BTC Consulting",
        .company_address = "Satoshi Street 21",
        .client_name = "Hodler LLC",
        .invoice_number = "BTC-001",
        .invoice_date = "2026-01-04",
        .items = &items,
        .subtotal = 1000,
        .total = 1000,

        // Bitcoin payment
        .qr_mode = .crypto,
        .crypto_wallet = "bc1qxy2kgdygjrsqtzq2n0yrf2493p83kkfjhx0wlh",
        .crypto_network = .bitcoin,
        .crypto_amount = 0.015,
        .show_crypto_identicons = false,
        .primary_color = "#f7931a", // Bitcoin orange
    };

    const pdf_bytes = try generateInvoice(allocator, data);
    defer allocator.free(pdf_bytes);

    try std.testing.expect(pdf_bytes.len > 2000);
    try std.testing.expect(std.mem.startsWith(u8, pdf_bytes, "%PDF-1.4"));
    try std.testing.expect(std.mem.indexOf(u8, pdf_bytes, "Bitcoin") != null);
}

test "generate multi-chain invoice - Solana" {
    const allocator = std.testing.allocator;

    const items = [_]LineItem{
        .{ .description = "NFT Minting", .quantity = 100, .unit_price = 5, .total = 500 },
    };

    const data = InvoiceData{
        .document_type = "invoice",
        .company_name = "Solana NFT Studio",
        .client_name = "NFT Collector",
        .invoice_number = "SOL-001",
        .invoice_date = "2026-01-04",
        .items = &items,
        .subtotal = 500,
        .total = 500,
        .qr_mode = .crypto,
        .crypto_wallet = "7EcDhSYGxXyscszYEp35KHN8vvw3svAuLKTzXwCFLtV",
        .crypto_network = .solana,
        .crypto_amount = 2.5,
        .primary_color = "#9945ff", // Solana purple
    };

    const pdf_bytes = try generateInvoice(allocator, data);
    defer allocator.free(pdf_bytes);

    try std.testing.expect(pdf_bytes.len > 2000);
    try std.testing.expect(std.mem.indexOf(u8, pdf_bytes, "Solana") != null);
}
