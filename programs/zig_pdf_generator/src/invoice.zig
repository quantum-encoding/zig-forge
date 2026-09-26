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
    /// Unit of measure printed after the quantity ("hrs", "m²", "days").
    unit: []const u8 = "",
    /// Line discount in percent (10 = 10% off). Shown in its own column when
    /// any item has one; the JSON parser applies it when it derives `total`.
    discount: f64 = 0,
};

/// One extra row between Subtotal and Tax (e.g. Shipping +12.50, Deposit
/// -200.00). Part of the taxable base when the engine derives the totals.
pub const Adjustment = struct {
    label: []const u8 = "",
    amount: f64 = 0,
};

/// Structured bank-transfer details, drawn as a text block. Independent of
/// the image-only `qr_mode = bank_details` QR caption.
pub const BankDetails = struct {
    account_name: []const u8 = "",
    bank_name: []const u8 = "",
    sort_code: []const u8 = "",
    account_number: []const u8 = "",
    iban: []const u8 = "",
    bic: []const u8 = "",
    reference: []const u8 = "",

    pub fn isEmpty(self: BankDetails) bool {
        return self.account_name.len == 0 and self.bank_name.len == 0 and
            self.sort_code.len == 0 and self.account_number.len == 0 and
            self.iban.len == 0 and self.bic.len == 0 and self.reference.len == 0;
    }
};

/// Round to whole cents (half away from zero).
pub fn roundCents(x: f64) f64 {
    return @round(x * 100.0) / 100.0;
}

/// Line total the engine derives when the caller omits one:
/// quantity x unit_price, less `discount_pct` percent, rounded to cents.
pub fn lineTotal(quantity: f64, unit_price: f64, discount_pct: f64) f64 {
    const d = std.math.clamp(discount_pct, 0, 100);
    return roundCents(quantity * unit_price * (1.0 - d / 100.0));
}

pub const Totals = struct {
    subtotal: f64,
    adjustments: f64,
    tax: f64,
    total: f64,
};

/// Derive document totals from the line items. The taxable base is the
/// subtotal plus every adjustment; tax is `tax_rate` of that base (0 when tax
/// is not shown); IRPF is withheld from the result.
pub fn computeTotals(items: []const LineItem, adjustments: []const Adjustment, tax_rate: f64, show_tax: bool, irpf_amount: f64) Totals {
    var subtotal: f64 = 0;
    for (items) |it| subtotal += it.total;
    var adj: f64 = 0;
    for (adjustments) |a| adj += a.amount;
    subtotal = roundCents(subtotal);
    adj = roundCents(adj);
    const tax = if (show_tax) roundCents((subtotal + adj) * tax_rate) else 0;
    return .{
        .subtotal = subtotal,
        .adjustments = adj,
        .tax = tax,
        .total = roundCents(subtotal + adj + tax - @abs(irpf_amount)),
    };
}

/// Amount still owed after `amount_paid`, never negative.
pub fn balanceDue(total: f64, amount_paid: f64) f64 {
    return @max(0, roundCents(total - amount_paid));
}

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
/// `minimal` is typography-led: no filled bands or cards, hairline rules,
/// right-aligned figures, generous whitespace and a single accent taken from
/// primary_color (title, TOTAL figure).
/// `letterhead` opens like a formal business letter — letterhead block over a
/// double rule, recipient address and date/reference block, the document
/// title and an optional subject line — followed by a compact item table and
/// a double-ruled total.
pub const Theme = enum {
    classic,
    squircle,
    glass,
    minimal,
    letterhead,
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
    // Due-date meta label used for quotes when `due_date_label` is unset
    valid_until: []const u8 = "Valid Until:",
    // Amount column header when the Qty/Unit Price columns are hidden
    amount: []const u8 = "Amount",
    // Line-discount column header
    discount: []const u8 = "Disc.",
    // Payment rows under the TOTAL
    amount_paid: []const u8 = "Amount Paid:",
    balance_due: []const u8 = "Balance Due:",
    paid_in_full: []const u8 = "PAID IN FULL",
    // Structured bank-details rows (the block heading is `bank_details`)
    account_name: []const u8 = "Account name",
    bank_name: []const u8 = "Bank",
    sort_code: []const u8 = "Sort code",
    account_number: []const u8 = "Account no.",
    iban: []const u8 = "IBAN",
    bic: []const u8 = "BIC / SWIFT",
    payment_reference: []const u8 = "Reference",
    // Signature block heading
    signature: []const u8 = "Authorised signature",
    // Letterhead subject prefix ("Re: <subject>")
    subject_prefix: []const u8 = "Re:",
    // Minimal/letterhead page footer: "Page 2 of 3"
    page: []const u8 = "Page",
    page_of: []const u8 = "of",
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

    // Whole-document theme (classic | squircle | glass | minimal |
    // letterhead). Defaults to the original layout.
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

    // ---- Block toggles and document-system fields --------------------------

    // Buyer block. When false — or when client_name, client_address and
    // client_vat are all empty — no Bill To block is drawn (the rounded
    // themes' FROM card then spans the row).
    show_client: bool = true,

    // Due-date meta label. Null: "Valid Until:" (labels.valid_until) for a
    // quote whose labels.due_date is untouched, otherwise labels.due_date.
    due_date_label: ?[]const u8 = null,

    // False: Description | Amount only (flat-rate / fixed-fee documents).
    show_qty_columns: bool = true,

    // Rows between Subtotal and Tax (Shipping, Deposit, ...).
    adjustments: []const Adjustment = &[_]Adjustment{},

    // Payment received. When set, "Amount Paid" and "Balance Due" rows follow
    // the TOTAL; payment_date / payment_method annotate the paid row.
    amount_paid: ?f64 = null,
    payment_date: []const u8 = "",
    payment_method: []const u8 = "",
    // PAID IN FULL mark. Null: drawn on a receipt whose balance is 0.
    paid_stamp: ?bool = null,

    // Bank-transfer text block (drawn when non-empty and show_bank_details).
    bank_details: BankDetails = .{},
    show_bank_details: bool = true,

    // Signature line block.
    show_signature: bool = false,
    signature_name: []const u8 = "",
    signature_title: []const u8 = "",
    signature_image_base64: ?[]const u8 = null,

    // Subject line under the title (minimal and letterhead themes).
    subject: []const u8 = "",
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

/// Quantity with up to two decimals, trailing zeros trimmed: 3 -> "3",
/// 2.5 -> "2.5", 0.125 -> "0.13".
pub fn fmtQty(buf: []u8, q: f64) []const u8 {
    const s = std.fmt.bufPrint(buf, "{d:.2}", .{q}) catch return "0";
    if (std.mem.indexOfScalar(u8, s, '.') == null) return s;
    var end = s.len;
    while (end > 0 and s[end - 1] == '0') end -= 1;
    if (end > 0 and s[end - 1] == '.') end -= 1;
    return s[0..end];
}

/// Money with the sign ahead of the currency symbol ("-£12.50").
fn fmtMoney(buf: []u8, symbol: []const u8, amount: f64) []const u8 {
    if (amount <= -0.005) return std.fmt.bufPrint(buf, "-{s}{d:.2}", .{ symbol, -amount }) catch "0.00";
    return std.fmt.bufPrint(buf, "{s}{d:.2}", .{ symbol, @abs(amount) }) catch "0.00";
}

/// Wrap `text` to `max_width`, honouring explicit line breaks: each
/// "\n"-separated paragraph wraps on its own and an empty paragraph yields a
/// blank line. Text without a newline wraps exactly as `wrapText` does.
fn wrapParagraphs(allocator: std.mem.Allocator, text: []const u8, font: document.Font, size: f32, max_width: f32) !document.WrappedText {
    if (std.mem.indexOfScalar(u8, text, '\n') == null) return document.wrapText(allocator, text, font, size, max_width);
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer lines.deinit(allocator);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const para = std.mem.trimEnd(u8, raw, "\r");
        if (para.len == 0) {
            try lines.append(allocator, "");
            continue;
        }
        var w = try document.wrapText(allocator, para, font, size, max_width);
        defer w.deinit();
        try lines.appendSlice(allocator, w.lines);
    }
    return .{ .lines = try lines.toOwnedSlice(allocator), .allocator = allocator };
}

/// A drawn label reduced to small-caps form: trailing colon/space removed and
/// ASCII upper-cased (non-ASCII bytes pass through), cut on a UTF-8 boundary.
fn capsLabel(buf: []u8, text: []const u8) []const u8 {
    const t = std.mem.trimEnd(u8, text, ": ");
    var n = @min(t.len, buf.len);
    while (n > 0 and n < t.len and (t[n] & 0xC0) == 0x80) n -= 1;
    for (t[0..n], 0..) |c, i| buf[i] = std.ascii.toUpper(c);
    return buf[0..n];
}

/// A drawn label with its trailing colon removed ("Subtotal:" -> "Subtotal").
fn bareLabel(text: []const u8) []const u8 {
    return std.mem.trimEnd(u8, text, ": ");
}

/// Item-table column geometry. Classic/squircle/glass use left-aligned
/// columns at fixed offsets (the original grid when no discount column is
/// needed); minimal/letterhead right-align every figure. Numeric columns hold
/// a left x (left-aligned) or a right edge (right-aligned); null = hidden.
const TableCols = struct {
    desc_x: f32,
    desc_w: f32,
    qty: ?f32,
    price: ?f32,
    disc: ?f32,
    total: f32,
    right_aligned: bool,
};

/// Everything loaded before drawing starts: image resource ids and the
/// resolved crypto/QR state.
const Assets = struct {
    logo_id: ?[]const u8 = null,
    qr_id: ?[]const u8 = null,
    sig_id: ?[]const u8 = null,
    recipient_identicon_id: ?[]const u8 = null,
    sender_identicon_id: ?[]const u8 = null,
    effective_qr_mode: QrCodeMode = .none,
    wallet: ?[]const u8 = null,
    network: crypto_receipt.Network = .bitcoin,
    sender: ?[]const u8 = null,
    symbol: []const u8 = "",
    amount_str: ?[]const u8 = null,
};

pub const InvoiceRenderer = struct {
    allocator: std.mem.Allocator,
    doc: document.PdfDocument,
    data: InvoiceData,

    // Decoded images (need to track for cleanup)
    logo_decoded: ?[]u8 = null,
    qr_decoded: ?[]u8 = null,
    sig_decoded: ?[]u8 = null,
    logo_pixels: ?[]u8 = null,
    qr_pixels: ?[]u8 = null,
    // Natural pixel sizes, for aspect-correct placement.
    logo_px_w: u32 = 0,
    logo_px_h: u32 = 0,
    sig_px_w: u32 = 0,
    sig_px_h: u32 = 0,

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
    /// Minimal/letterhead: composed page streams held until the page count is
    /// known, so every page footer can print "Page n of N".
    pending_pages: std.ArrayListUnmanaged([]u8) = .empty,
    /// Baseline of the first totals row, on the page the totals block is
    /// drawn on — the bank-details block can sit beside it on the left.
    totals_top: f32 = 0,
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

        // The typographic themes breathe: wider margins all round.
        if (data.theme == .minimal or data.theme == .letterhead) {
            renderer.margin_left = 50;
            renderer.margin_right = 50;
            renderer.margin_top = 50;
            renderer.margin_bottom = 64;
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
        if (self.sig_decoded) |d| self.allocator.free(d);
        // Note: logo_pixels and qr_pixels are NOT freed - they point to same memory as decoded

        // Free crypto-generated images (these are owned by us, not decoded from base64)
        if (self.crypto_qr_pixels) |p| self.allocator.free(p);
        if (self.recipient_identicon_pixels) |p| self.allocator.free(p);
        if (self.sender_identicon_pixels) |p| self.allocator.free(p);

        for (self.pending_pages.items) |p| self.allocator.free(p);
        self.pending_pages.deinit(self.allocator);

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
    // Document model helpers
    // -------------------------------------------------------------------------

    /// Themes that use squircle's rounded-card geometry (cards, rounded table
    /// container, accent header band, rounded totals chip). Glass reuses all of
    /// it and only swaps the materials, so every layout branch keys off this.
    fn roundedLayout(self: *const InvoiceRenderer) bool {
        return self.data.theme == .squircle or self.data.theme == .glass;
    }

    /// The typographic themes (minimal, letterhead): right-aligned figures,
    /// hairline rules, per-page footers.
    fn isModern(self: *const InvoiceRenderer) bool {
        return self.data.theme == .minimal or self.data.theme == .letterhead;
    }

    fn isQuote(self: *const InvoiceRenderer) bool {
        return std.mem.eql(u8, self.data.document_type, "quote");
    }

    fn isReceipt(self: *const InvoiceRenderer) bool {
        return std.mem.eql(u8, self.data.document_type, "receipt");
    }

    fn isCustom(self: *const InvoiceRenderer) bool {
        return std.mem.eql(u8, self.data.document_type, "custom");
    }

    /// True when a buyer block is drawn at all.
    fn hasClient(self: *const InvoiceRenderer) bool {
        return self.data.show_client and (self.data.client_name.len > 0 or
            self.data.client_address.len > 0 or self.data.client_vat.len > 0);
    }

    fn docTitle(self: *const InvoiceRenderer) []const u8 {
        return self.data.custom_title orelse
            (if (self.isQuote()) "QUOTE" else if (self.isReceipt()) "RECEIPT" else if (self.isCustom()) "DOCUMENT" else "INVOICE");
    }

    fn numberLabel(self: *const InvoiceRenderer) []const u8 {
        return self.data.number_label orelse
            (if (self.isQuote()) "Quote #:" else if (self.isReceipt()) "Receipt #:" else if (self.isCustom()) "Reference:" else "Invoice #:");
    }

    fn dueLabel(self: *const InvoiceRenderer) []const u8 {
        if (self.data.due_date_label) |l| return l;
        if (self.isQuote() and std.mem.eql(u8, self.data.labels.due_date, "Due Date:")) return self.data.labels.valid_until;
        return self.data.labels.due_date;
    }

    fn anyDiscount(self: *const InvoiceRenderer) bool {
        if (self.data.display_mode != .itemized) return false;
        for (self.data.items) |it| if (it.discount != 0) return true;
        return false;
    }

    fn amountPaid(self: *const InvoiceRenderer) ?f64 {
        return self.data.amount_paid;
    }

    fn showPaidStamp(self: *const InvoiceRenderer) bool {
        if (self.data.paid_stamp) |p| return p;
        const paid = self.data.amount_paid orelse return false;
        return self.isReceipt() and balanceDue(self.data.total, paid) < 0.005;
    }

    fn showBank(self: *const InvoiceRenderer) bool {
        return self.data.show_bank_details and !self.data.bank_details.isEmpty();
    }

    fn tableCols(self: *const InvoiceRenderer) TableCols {
        const ml = self.margin_left;
        const usable = self.page_width - self.margin_left - self.margin_right;
        const disc = self.anyDiscount();
        const qty = self.data.show_qty_columns;
        if (!self.isModern()) {
            if (qty and !disc) return .{ .desc_x = ml + 5, .desc_w = 265, .qty = ml + 280, .price = ml + 350, .disc = null, .total = ml + 450, .right_aligned = false };
            if (qty) return .{ .desc_x = ml + 5, .desc_w = 225, .qty = ml + 240, .price = ml + 300, .disc = ml + 385, .total = ml + 450, .right_aligned = false };
            if (disc) return .{ .desc_x = ml + 5, .desc_w = 370, .qty = null, .price = null, .disc = ml + 385, .total = ml + 450, .right_aligned = false };
            return .{ .desc_x = ml + 5, .desc_w = 435, .qty = null, .price = null, .disc = null, .total = ml + 450, .right_aligned = false };
        }
        const r = ml + usable;
        var left = r - 85; // total column
        var c = TableCols{ .desc_x = ml, .desc_w = 0, .qty = null, .price = null, .disc = null, .total = r, .right_aligned = true };
        if (disc) {
            c.disc = left - 10;
            left -= 55;
        }
        if (qty) {
            c.price = left - 10;
            left -= 85;
            c.qty = left - 10;
            left -= 70;
        }
        c.desc_w = left - ml - 14;
        return c;
    }

    // -------------------------------------------------------------------------
    // Liquid Glass materials
    // -------------------------------------------------------------------------

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
        // to the panel silhouette. The fade runs the full panel height, so
        // there is no seam — the gradient's end IS the panel's bottom border.
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

    // -------------------------------------------------------------------------
    // Pages
    // -------------------------------------------------------------------------

    /// Flush the current page: composite the background layer (wash + glass
    /// panels) beneath the foreground content, commit the page, and reset both
    /// buffers for the next page. For non-glass themes the background layer is
    /// empty, so the composed bytes equal the content bytes exactly. The
    /// typographic themes hold the composed page back (see pending_pages).
    fn flushPage(self: *InvoiceRenderer, content: *document.ContentStream) !void {
        const bg = self.bg.?;
        try bg.buffer.appendSlice(self.allocator, content.getContent());
        var flushed: u32 = undefined;
        if (self.isModern()) {
            const bytes = try self.allocator.dupe(u8, bg.getContent());
            errdefer self.allocator.free(bytes);
            try self.pending_pages.append(self.allocator, bytes);
            flushed = @intCast(self.pending_pages.items.len);
        } else {
            try self.doc.addPage(bg);
            flushed = self.doc.page_count;
        }
        // Link annotations recorded from here on belong to the next page.
        self.doc.setAnnotationPage(flushed);
        content.deinit();
        content.* = document.ContentStream.init(self.allocator);
        bg.deinit();
        bg.* = document.ContentStream.init(self.allocator);
    }

    /// Minimal/letterhead: add the held-back pages to the document, stamping
    /// each with the page footer (hairline, company name, "Page n of N").
    fn commitPendingPages(self: *InvoiceRenderer) !void {
        const n = self.pending_pages.items.len;
        const muted = document.Color.fromHex("#6B7280");
        const hair = document.Color.fromHex("#E5E7EB");
        const right = self.page_width - self.margin_right;
        const fy = self.margin_bottom - 24;
        for (self.pending_pages.items, 0..) |bytes, i| {
            var cs = document.ContentStream.init(self.allocator);
            defer cs.deinit();
            try cs.buffer.appendSlice(self.allocator, bytes);
            try cs.drawLine(self.margin_left, self.margin_bottom - 12, right, self.margin_bottom - 12, hair, 0.6);
            if (self.data.company_name.len > 0) {
                try cs.drawText(self.data.company_name, self.margin_left, fy, self.font_bold, 7.5, muted);
            }
            if (n > 1) {
                var buf: [64]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{s} {d} {s} {d}", .{ self.data.labels.page, i + 1, self.data.labels.page_of, n }) catch "";
                try cs.drawTextRightAligned(s, right, fy, self.font_regular, self.fontEnumRegular(), 7.5, muted);
            }
            try self.doc.addPage(&cs);
        }
    }

    /// Draw the items-table header (column titles + bar/rule per table_style) at
    /// the current y and advance below it. Redrawn at the top of every page so a
    /// paginated item list keeps its headers. In the squircle theme the header
    /// is a rounded accent band and the top of the rounded table container is
    /// recorded so the container can be closed when the rows end (per page).
    fn drawTableHeader(self: *InvoiceRenderer, content: *document.ContentStream) !void {
        if (self.isModern()) return self.drawModernTableHeader(content);
        const primary = document.Color.fromHex(self.data.primary_color);
        const secondary = document.Color.fromHex(self.data.secondary_color);
        const usable_width = self.page_width - self.margin_left - self.margin_right;
        const table_style = self.data.table_style;
        const box_border = document.Color.fromHex("#d0d0d0");
        // Glass: the header band ends up WASHED (the white table container
        // composites over it), so white titles die — dark ink carries the
        // contrast, same rule as the totals chip.
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
        const cols = self.tableCols();
        const total_label = if (self.data.show_qty_columns) self.data.labels.line_total else self.data.labels.amount;
        try content.drawText(self.data.labels.description, cols.desc_x, self.current_y, self.font_bold, 10, header_text_color);
        if (cols.qty) |x| try content.drawText(self.data.labels.quantity, x, self.current_y, self.font_bold, 10, header_text_color);
        if (cols.price) |x| try content.drawText(self.data.labels.unit_price, x, self.current_y, self.font_bold, 10, header_text_color);
        if (cols.disc) |x| try content.drawText(self.data.labels.discount, x, self.current_y, self.font_bold, 10, header_text_color);
        try content.drawText(total_label, cols.total, self.current_y, self.font_bold, 10, header_text_color);
        if (table_style == .minimal and !self.roundedLayout()) {
            try content.drawLine(self.margin_left, self.current_y - 6, self.margin_left + usable_width, self.current_y - 6, secondary, 0.75);
        }
        self.current_y -= 28;
    }

    /// Minimal: muted bold labels over a single hairline. Letterhead: labels
    /// between an accent rule above and a fine accent rule below.
    fn drawModernTableHeader(self: *InvoiceRenderer, content: *document.ContentStream) !void {
        const primary = document.Color.fromHex(self.data.primary_color);
        const secondary = document.Color.fromHex(self.data.secondary_color);
        const left = self.margin_left;
        const right = self.page_width - self.margin_right;
        const cols = self.tableCols();
        const bold = self.fontEnumBold();
        const size: f32 = 8;
        const color = if (self.data.theme == .minimal) document.Color.fromHex("#6B7280") else secondary;
        const y = self.current_y;
        if (self.data.theme == .letterhead) {
            try content.drawLine(left, y + 12, right, y + 12, primary, 1.0);
        }
        var buf: [5][64]u8 = undefined;
        const total_label = if (self.data.show_qty_columns) self.data.labels.line_total else self.data.labels.amount;
        try content.drawTrackedText(capsLabel(&buf[0], self.data.labels.description), cols.desc_x, y, self.font_bold, size, 0.6, color);
        const heads = [_]struct { x: ?f32, label: []const u8 }{
            .{ .x = cols.qty, .label = self.data.labels.quantity },
            .{ .x = cols.price, .label = self.data.labels.unit_price },
            .{ .x = cols.disc, .label = self.data.labels.discount },
            .{ .x = cols.total, .label = total_label },
        };
        for (heads, 1..) |h, i| {
            const x = h.x orelse continue;
            const t = capsLabel(&buf[i], h.label);
            const w = bold.measureTracked(t, size, 0.6);
            try content.drawTrackedText(t, x - w, y, self.font_bold, size, 0.6, color);
        }
        if (self.data.theme == .letterhead) {
            try content.drawLine(left, y - 7, right, y - 7, primary, 0.4);
        } else {
            try content.drawLine(left, y - 7, right, y - 7, document.Color.fromHex("#D1D5DB"), 0.6);
        }
        self.current_y = y - 7 - 17;
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
        if (self.isModern()) {
            // Continuation pages carry the document's identity at the top.
            var buf: [160]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "{s}  {s}", .{ self.docTitle(), self.data.invoice_number }) catch self.docTitle();
            try content.drawText(line, self.margin_left, self.current_y, self.font_bold, 8, document.Color.fromHex("#6B7280"));
            self.current_y -= 30;
        }
        if (redraw_header) try self.drawTableHeader(content);
    }

    /// Start a new page (no table header) unless `needed` points still fit
    /// above the bottom margin.
    fn ensureSpace(self: *InvoiceRenderer, content: *document.ContentStream, needed: f32) !void {
        if (self.current_y - needed < self.margin_bottom + 10) try self.startNewPage(content, false);
    }

    // -------------------------------------------------------------------------
    // Render
    // -------------------------------------------------------------------------

    /// Generate the complete invoice PDF
    pub fn render(self: *InvoiceRenderer) ![]const u8 {
        var content = document.ContentStream.init(self.allocator);
        defer content.deinit();

        // Glass theme: a background layer (wash + translucent panels + sheens)
        // composited beneath the foreground at every page flush. Empty for other
        // themes, so their composed output equals the content stream.
        var page_bg = document.ContentStream.init(self.allocator);
        defer page_bg.deinit();
        self.bg = &page_bg;
        if (self.data.theme == .glass) try self.drawGlassWash(&page_bg);

        const assets = try self.loadAssets();

        switch (self.data.theme) {
            .minimal => try self.drawMinimalHeader(&content, assets),
            .letterhead => try self.drawLetterheadHeader(&content, assets),
            .classic, .squircle, .glass => try self.drawClassicHeader(&content, assets),
        }

        try self.drawItems(&content);
        try self.drawTotals(&content);
        try self.drawClosingBlocks(&content, assets);

        if (self.isModern()) {
            try self.drawModernFooter(&content, assets);
        } else {
            try self.drawClassicFooter(&content, assets);
        }

        // Add the last page — composite the glass background beneath the
        // foreground (a no-op for other themes, whose bg layer is empty).
        try self.flushPage(&content);
        if (self.isModern()) try self.commitPendingPages();

        // Password-protect the document (AES-256) when a password is set. Must
        // be configured before build() so every stream/string is encrypted.
        if (self.data.password.len > 0) {
            const owner = if (self.data.owner_password.len > 0) self.data.owner_password else self.data.password;
            try self.doc.enableEncryption(self.data.password, owner, document.DEFAULT_PERMS, self.data.seed orelse osSeed());
        }

        // Build and return PDF
        return try self.doc.build();
    }

    /// Decode the logo, QR and signature images and build the native crypto QR
    /// and identicons. Registration order fixes the image resource names.
    fn loadAssets(self: *InvoiceRenderer) !Assets {
        var a = Assets{};

        // Resolve crypto payment block or legacy fields
        const crypto_block = self.data.crypto_payment;
        a.wallet = if (crypto_block) |cb| (if (cb.to_address.len > 0) cb.to_address else null) else self.data.crypto_wallet;
        a.network = if (crypto_block) |cb| cb.getNetwork() else self.data.crypto_network;
        a.sender = if (crypto_block) |cb| (if (cb.from_address.len > 0) cb.from_address else null) else self.data.crypto_sender_wallet;
        a.symbol = if (crypto_block) |cb| (if (cb.currency.len > 0) cb.currency else cb.getNetwork().symbol()) else (self.data.crypto_custom_symbol orelse self.data.crypto_network.symbol());
        a.amount_str = if (crypto_block) |cb| (if (cb.amount.len > 0) cb.amount else null) else null;

        if (self.data.company_logo_base64) |logo_b64| {
            if (logo_b64.len > 0) {
                const result = image.loadImageFlexible(self.allocator, logo_b64) catch null;
                if (result) |r| {
                    self.logo_decoded = r.decoded_bytes;
                    if (r.image.format != .jpeg) {
                        self.logo_pixels = @constCast(r.image.data);
                    }
                    self.logo_px_w = r.image.width;
                    self.logo_px_h = r.image.height;
                    a.logo_id = self.doc.addImage(r.image) catch null;
                }
            }
        }

        // Load QR code - check new field first, fall back to legacy verifactu field
        const qr_b64_data = self.data.qr_base64 orelse self.data.verifactu_qr_base64;
        // Determine effective QR mode
        a.effective_qr_mode = self.data.qr_mode;
        if (a.effective_qr_mode == .none) {
            // Legacy field implies verifactu mode (only if non-empty)
            if (self.data.verifactu_qr_base64) |legacy_qr| {
                if (legacy_qr.len > 0) {
                    a.effective_qr_mode = .verifactu;
                }
            }
        }

        if (qr_b64_data) |qr_b64| {
            if (qr_b64.len > 0 and a.effective_qr_mode != .none) {
                const result = image.loadImageFlexible(self.allocator, qr_b64) catch null;
                if (result) |r| {
                    self.qr_decoded = r.decoded_bytes;
                    if (r.image.format != .jpeg) {
                        self.qr_pixels = @constCast(r.image.data);
                    }
                    a.qr_id = self.doc.addImage(r.image) catch null;
                }
            }
        }

        // Native crypto QR generation (when crypto_wallet/crypto_payment is set and mode is crypto)
        if (a.wallet) |wallet| {
            if (wallet.len > 0 and (a.effective_qr_mode == .crypto or self.data.qr_mode == .crypto)) {
                a.effective_qr_mode = .crypto;

                const uri = try self.buildCryptoUri(wallet, a.network, a.symbol, a.amount_str);
                defer self.allocator.free(uri);

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
                    const crypto_qr_id = self.doc.addImage(img) catch null;
                    // Use crypto QR if no base64 QR was provided
                    if (a.qr_id == null) a.qr_id = crypto_qr_id;
                } else |_| {}

                if (self.data.show_crypto_identicons) {
                    if (identicon.generate(self.allocator, wallet, .{ .size = 8, .scale = 8 })) |icon| {
                        self.recipient_identicon_pixels = icon.pixels;
                        const img = document.Image{
                            .width = icon.width,
                            .height = icon.height,
                            .data = icon.pixels,
                            .format = .raw_rgb,
                        };
                        a.recipient_identicon_id = self.doc.addImage(img) catch null;
                    } else |_| {}
                }
            }
        }

        // Generate sender identicon if address provided and identicons enabled
        if (a.sender) |sender| {
            if (sender.len > 0 and self.data.show_crypto_identicons) {
                if (identicon.generate(self.allocator, sender, .{ .size = 8, .scale = 8 })) |icon| {
                    self.sender_identicon_pixels = icon.pixels;
                    const img = document.Image{
                        .width = icon.width,
                        .height = icon.height,
                        .data = icon.pixels,
                        .format = .raw_rgb,
                    };
                    a.sender_identicon_id = self.doc.addImage(img) catch null;
                } else |_| {}
            }
        }

        if (self.data.show_signature) {
            if (self.data.signature_image_base64) |sig_b64| {
                if (sig_b64.len > 0) {
                    const result = image.loadImageFlexible(self.allocator, sig_b64) catch null;
                    if (result) |r| {
                        self.sig_decoded = r.decoded_bytes;
                        self.sig_px_w = r.image.width;
                        self.sig_px_h = r.image.height;
                        a.sig_id = self.doc.addImage(r.image) catch null;
                    }
                }
            }
        }

        return a;
    }

    /// Fit an image of `px_w` x `px_h` pixels inside `max_w` x `max_h` points,
    /// keeping its aspect. Falls back to the box itself when the size is unknown.
    fn fitBox(px_w: u32, px_h: u32, max_w: f32, max_h: f32) [2]f32 {
        if (px_w == 0 or px_h == 0) return .{ max_w, max_h };
        const aspect = @as(f32, @floatFromInt(px_w)) / @as(f32, @floatFromInt(px_h));
        var w = max_h * aspect;
        var h = max_h;
        if (w > max_w) {
            w = max_w;
            h = max_w / aspect;
        }
        return .{ w, h };
    }

    /// Draw the logo with its bottom-left at (x, y), plus its link.
    fn drawLogoAt(self: *InvoiceRenderer, content: *document.ContentStream, id: []const u8, x: f32, y: f32, w: f32, h: f32) !void {
        try content.drawImage(id, x, y, w, h);
        if (self.data.logo_link_url) |u| {
            if (u.len > 0) try self.doc.addLinkAnnotation(x, y, x + w, y + h, u);
        }
    }

    // -------------------------------------------------------------------------
    // Header — classic / squircle / glass
    // -------------------------------------------------------------------------

    fn drawClassicHeader(self: *InvoiceRenderer, content: *document.ContentStream, assets: Assets) !void {
        const logo_id = assets.logo_id;
        const primary = document.Color.fromHex(self.data.primary_color);
        const title_color = document.Color.fromHex(self.data.title_color);
        const company_color = document.Color.fromHex(self.data.company_name_color);
        const usable_width = self.page_width - self.margin_left - self.margin_right;

        // Glass theme reusable material tokens (translucent white panels + a
        // faintly accent-tinted sheen and hairline border).
        const glass_panel_border = mixColor(document.Color.white, primary, 0.14);
        const glass_sheen_end = mixColor(document.Color.white, primary, 0.22);

        // Glass theme: a translucent panel behind the title / company / meta
        // block at the top of the page (the "masthead" pane), drawn into the bg
        // layer so the header text sits on top of it. The rounded layout keeps
        // the company address in the From card below, so this block is compact.
        if (self.data.theme == .glass) {
            const mh_bottom = self.page_height - self.margin_top - 88;
            const mh_top = self.page_height - self.margin_top + 18;
            try self.drawGlassPanel(self.bg.?, self.margin_left - 8, mh_bottom, usable_width + 16, mh_top - mh_bottom, 12, document.Color.white, 0.72, glass_sheen_end, 0.50, glass_panel_border, 1.0);
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
        const doc_title = self.docTitle();
        const title_size: f32 = if (doc_title.len > 12) 20 else 28;
        const title_est_w = @as(f32, @floatFromInt(doc_title.len)) * title_size * 0.72;
        const title_inset: f32 = if (self.roundedLayout()) 10 else 0;
        const title_x = @max(self.page_width - self.margin_right - title_inset - title_est_w, self.margin_left + 180);
        // Glass: the wordmark lives INSIDE the masthead panel (its ascenders
        // would overflow the rounded edge on the margin line).
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

        // ---- Document meta (right side) ------------------------------------

        // Values are anchored to the right margin and grow leftward, so a long
        // invoice number or date can never run off the right edge. Rounded
        // themes inset the wordmark 10pt; the meta values share that right edge.
        const details_right = self.page_width - self.margin_right - (if (self.roundedLayout()) @as(f32, 10) else 0);
        const reg = self.fontEnumRegular();
        // The block is 180pt wide by default (64pt of label + the value); a long
        // document number widens it leftward, up to 300pt, instead of shrinking.
        const widest_value = @max(
            reg.measureText(self.data.invoice_number, 10),
            @max(reg.measureText(self.data.invoice_date, 10), reg.measureText(self.data.due_date, 10)),
        );
        const block_width = @min(@as(f32, 300), @max(@as(f32, 180), 64 + widest_value + 4));
        const details_x = details_right - block_width;
        const meta_value_width = details_right - (details_x + 64);
        var details_y = self.page_height - self.margin_top - 50;

        try content.drawText(self.numberLabel(), details_x, details_y, self.font_bold, 10, document.Color.black);
        try self.drawRightFit(content, self.data.invoice_number, details_right, meta_value_width, details_y, self.font_regular, reg, 10, document.Color.black);
        details_y -= 15;

        try content.drawText(self.data.labels.date, details_x, details_y, self.font_bold, 10, document.Color.black);
        try self.drawRightFit(content, self.data.invoice_date, details_right, meta_value_width, details_y, self.font_regular, reg, 10, document.Color.black);
        details_y -= 15;

        if (self.data.due_date.len > 0) {
            try content.drawText(self.dueLabel(), details_x, details_y, self.font_bold, 10, document.Color.black);
            try self.drawRightFit(content, self.data.due_date, details_right, meta_value_width, details_y, self.font_regular, reg, 10, document.Color.black);
        }

        // ---- Parties ---------------------------------------------------------

        const has_client = self.hasClient();
        if (self.roundedLayout()) {
            // Rounded-card themes: From + Bill To as side-by-side cards; the
            // client card carries an accent treatment. Squircle uses bordered
            // cards; glass uses translucent panels with a sheen over the wash.
            // With no buyer the FROM card spans the whole row.
            const card_border = document.Color.fromHex("#E5E7EB");
            const muted = document.Color.fromHex("#6B7280");
            // Clear BOTH columns above: the company block (left, current_y)
            // and the invoice-meta block (right, details_y ends at the Due
            // Date baseline) — plus a full line of air before the cards.
            self.current_y = @min(self.current_y - 16, details_y - 26);
            const gap: f32 = 14;
            // Cards share the table container's exact span (margin−8 … +8).
            const row_x = self.margin_left - 8;
            const row_w = usable_width + 16;
            const card_w = if (has_client) (row_w - gap) / 2 else row_w;
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
            const n_lines = if (has_client) @max(from_lines, to_lines) else from_lines;
            const card_h = 26 + n_lines * 13 + pad; // label row (+4 gap) + lines + padding

            const card_top = self.current_y;
            const from_x = row_x;
            const to_x = row_x + card_w + gap;
            if (self.data.theme == .glass) {
                // From: neutral translucent panel. Bill To: same glass with a
                // soft accent border.
                try self.drawGlassPanel(self.bg.?, from_x, card_top - card_h, card_w, card_h, 10, document.Color.white, 0.72, glass_sheen_end, 0.50, glass_panel_border, 1.0);
                if (has_client) {
                    const to_border = mixColor(document.Color.white, primary, 0.45);
                    try self.drawGlassPanel(self.bg.?, to_x, card_top - card_h, card_w, card_h, 10, document.Color.white, 0.74, glass_sheen_end, 0.55, to_border, 1.1);
                }
            } else {
                try content.drawRoundedRectEx(from_x, card_top - card_h, card_w, card_h, 10, null, card_border, 1.0);
                if (has_client) try content.drawRoundedRectEx(to_x, card_top - card_h, card_w, card_h, 10, null, primary, 1.5);
            }

            // From card content — label and name share the exact left edge;
            // the extra 4pt under the label keeps them reading as two rows.
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

            if (has_client) {
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
            }

            self.current_y = card_top - card_h - 8;
        } else if (has_client) {
            self.current_y -= 30;

            try content.drawText(self.data.labels.bill_to, self.margin_left, self.current_y, self.font_bold, 12, primary);
            self.current_y -= 18;

            try content.drawText(self.data.client_name, self.margin_left, self.current_y, self.font_bold, 11, document.Color.black);
            self.current_y -= 14;

            if (self.data.client_address.len > 0) {
                var addr_iter = std.mem.splitSequence(u8, self.data.client_address, addressDelimiter(self.data.client_address));
                while (addr_iter.next()) |line| {
                    try content.drawText(line, self.margin_left, self.current_y, self.font_regular, 10, document.Color.black);
                    self.current_y -= 13;
                }
            }

            if (self.data.client_vat.len > 0) {
                var cvat_buf: [128]u8 = undefined;
                const cvat_line = std.fmt.bufPrint(&cvat_buf, "{s}: {s}", .{ self.data.labels.vat_prefix, self.data.client_vat }) catch self.data.client_vat;
                try content.drawText(cvat_line, self.margin_left, self.current_y, self.font_regular, 10, document.Color.black);
                self.current_y -= 18;
            }
        } else {
            // No buyer: clear the meta column before the table starts.
            self.current_y = @min(self.current_y, details_y) - 12;
        }

        self.current_y -= 20;
    }

    // -------------------------------------------------------------------------
    // Header — minimal
    // -------------------------------------------------------------------------

    fn drawMinimalHeader(self: *InvoiceRenderer, content: *document.ContentStream, assets: Assets) !void {
        const title_color = document.Color.fromHex(self.data.title_color);
        const company_color = document.Color.fromHex(self.data.company_name_color);
        const muted = document.Color.fromHex("#6B7280");
        const ink = document.Color.fromHex("#111827");
        const body = document.Color.fromHex("#374151");
        const left = self.margin_left;
        const right = self.page_width - self.margin_right;
        const usable = right - left;
        const reg = self.fontEnumRegular();
        const top = self.page_height - self.margin_top;

        // Identity column: logo, then name, address, VAT.
        var ly = top;
        var show_name = true;
        if (assets.logo_id) |lid| {
            const fit = fitBox(self.logo_px_w, self.logo_px_h, 150, 44);
            try self.drawLogoAt(content, lid, left, top + 6 - fit[1], fit[0], fit[1]);
            ly = top + 6 - fit[1] - 20;
            if (self.data.logo_banner) show_name = false;
        } else {
            ly = top - 4;
        }
        if (show_name and self.data.company_name.len > 0) {
            try content.drawText(self.data.company_name, left, ly, self.font_bold, 12, company_color);
            ly -= 15;
        }
        if (self.data.company_address.len > 0) {
            var it = std.mem.splitSequence(u8, self.data.company_address, addressDelimiter(self.data.company_address));
            while (it.next()) |line| {
                try content.drawText(line, left, ly, self.font_regular, 8.5, body);
                ly -= 11.5;
            }
        }
        if (self.data.company_vat.len > 0) {
            var vat_buf: [128]u8 = undefined;
            const vat_line = std.fmt.bufPrint(&vat_buf, "{s} {s}", .{ self.data.labels.vat_prefix, self.data.company_vat }) catch self.data.company_vat;
            try content.drawText(vat_line, left, ly, self.font_regular, 8.5, muted);
            ly -= 11.5;
        }

        // Title column: the document word, large and light, with its number.
        const title = self.docTitle();
        var tsize: f32 = 30;
        const tw_max: f32 = 250;
        if (reg.measureText(title, tsize) > tw_max) tsize = @max(14, tsize * tw_max / reg.measureText(title, tsize));
        try content.drawTextRightAligned(title, right, top - 20, self.font_regular, reg, tsize, title_color);
        var ry: f32 = top - 38;
        if (self.data.invoice_number.len > 0) {
            var nb: [192]u8 = undefined;
            const num = std.fmt.bufPrint(&nb, "{s}  {s}", .{ bareLabel(self.numberLabel()), self.data.invoice_number }) catch self.data.invoice_number;
            try self.drawRightFit(content, num, right, 250, ry, self.font_regular, reg, 9.5, muted);
            ry -= 12;
        }

        const rule_y = @min(ly + 4, ry) - 14;
        try content.drawLine(left, rule_y, right, rule_y, document.Color.fromHex("#E5E7EB"), 0.6);

        // Info row: [BILL TO | PAYMENT] ........ DATE ... DUE
        const label_y = rule_y - 20;
        const value_y = label_y - 15;
        var cb: [64]u8 = undefined;
        var y_end = value_y;
        const date_x = left + usable * 0.52;
        const due_x = left + usable * 0.76;
        if (self.hasClient()) {
            try content.drawTrackedText(capsLabel(&cb, self.data.labels.bill_to_card), left, label_y, self.font_bold, 7, 0.8, muted);
            var y = value_y;
            if (self.data.client_name.len > 0) {
                try content.drawText(self.data.client_name, left, y, self.font_bold, 10.5, ink);
                y -= 13.5;
            }
            if (self.data.client_address.len > 0) {
                var it = std.mem.splitSequence(u8, self.data.client_address, addressDelimiter(self.data.client_address));
                while (it.next()) |line| {
                    try content.drawText(line, left, y, self.font_regular, 9, body);
                    y -= 12;
                }
            }
            if (self.data.client_vat.len > 0) {
                var vb: [128]u8 = undefined;
                const v = std.fmt.bufPrint(&vb, "{s} {s}", .{ self.data.labels.vat_prefix, self.data.client_vat }) catch self.data.client_vat;
                try content.drawText(v, left, y, self.font_regular, 8.5, muted);
                y -= 12;
            }
            y_end = @min(y_end, y + 12);
        } else if (self.data.amount_paid != null and (self.data.payment_method.len > 0 or self.data.payment_date.len > 0)) {
            // A receipt without a buyer leads with how it was paid.
            try content.drawTrackedText(capsLabel(&cb, self.data.labels.amount_paid), left, label_y, self.font_bold, 7, 0.8, muted);
            var y = value_y;
            if (self.data.payment_method.len > 0) {
                try content.drawText(self.data.payment_method, left, y, self.font_bold, 10.5, ink);
                y -= 13.5;
            }
            if (self.data.payment_date.len > 0) {
                try content.drawText(self.data.payment_date, left, y, self.font_regular, 9, body);
                y -= 12;
            }
            y_end = @min(y_end, y + 12);
        }
        if (self.data.invoice_date.len > 0) {
            try content.drawTrackedText(capsLabel(&cb, self.data.labels.date), date_x, label_y, self.font_bold, 7, 0.8, muted);
            try content.drawText(self.data.invoice_date, date_x, value_y, self.font_regular, 10, ink);
        }
        if (self.data.due_date.len > 0) {
            try content.drawTrackedText(capsLabel(&cb, self.dueLabel()), due_x, label_y, self.font_bold, 7, 0.8, muted);
            try content.drawText(self.data.due_date, due_x, value_y, self.font_regular, 10, ink);
        }

        var y = y_end - 26;
        if (self.data.subject.len > 0) {
            var wrapped = try wrapParagraphs(self.allocator, self.data.subject, self.fontEnumBold(), 11, usable);
            defer wrapped.deinit();
            for (wrapped.lines) |line| {
                try content.drawText(line, left, y, self.font_bold, 11, ink);
                y -= 14;
            }
            y -= 12;
        }
        self.current_y = y - 8;
    }

    // -------------------------------------------------------------------------
    // Header — letterhead
    // -------------------------------------------------------------------------

    fn drawLetterheadHeader(self: *InvoiceRenderer, content: *document.ContentStream, assets: Assets) !void {
        const primary = document.Color.fromHex(self.data.primary_color);
        const title_color = document.Color.fromHex(self.data.title_color);
        const company_color = document.Color.fromHex(self.data.company_name_color);
        const muted = document.Color.fromHex("#6B7280");
        const ink = document.Color.fromHex("#111827");
        const body = document.Color.fromHex("#374151");
        const left = self.margin_left;
        const right = self.page_width - self.margin_right;
        const usable = right - left;
        const reg = self.fontEnumRegular();
        const bold = self.fontEnumBold();
        const top = self.page_height - self.margin_top;

        // Letterhead: mark (or name) on the left, sender details on the right.
        var left_bottom = top;
        var name_on_right = false;
        if (assets.logo_id) |lid| {
            const fit = fitBox(self.logo_px_w, self.logo_px_h, 180, 54);
            try self.drawLogoAt(content, lid, left, top + 8 - fit[1], fit[0], fit[1]);
            left_bottom = top + 8 - fit[1];
            name_on_right = !self.data.logo_banner;
        } else if (self.data.company_name.len > 0) {
            var size: f32 = 20;
            const max_w = usable * 0.55;
            const w = bold.measureText(self.data.company_name, size);
            if (w > max_w) size = @max(11, size * max_w / w);
            try content.drawText(self.data.company_name, left, top - 12, self.font_bold, size, company_color);
            left_bottom = top - 18;
        }
        var ry: f32 = top;
        if (name_on_right and self.data.company_name.len > 0) {
            try self.drawRightFit(content, self.data.company_name, right, usable * 0.45, ry, self.font_bold, bold, 10.5, company_color);
            ry -= 13;
        }
        if (self.data.company_address.len > 0) {
            var it = std.mem.splitSequence(u8, self.data.company_address, addressDelimiter(self.data.company_address));
            while (it.next()) |line| {
                try content.drawTextRightAligned(line, right, ry, self.font_regular, reg, 8.5, body);
                ry -= 11;
            }
        }
        if (self.data.company_vat.len > 0) {
            var vat_buf: [128]u8 = undefined;
            const vat_line = std.fmt.bufPrint(&vat_buf, "{s} {s}", .{ self.data.labels.vat_prefix, self.data.company_vat }) catch self.data.company_vat;
            try content.drawTextRightAligned(vat_line, right, ry, self.font_regular, reg, 8.5, muted);
            ry -= 11;
        }

        // Double rule under the letterhead.
        const rule_y = @min(left_bottom, ry + 4) - 12;
        try content.drawLine(left, rule_y, right, rule_y, primary, 1.4);
        try content.drawLine(left, rule_y - 3, right, rule_y - 3, primary, 0.4);

        // Recipient address block (left) and date/reference block (right).
        const block_top = rule_y - 34;
        var y = block_top;
        if (self.hasClient()) {
            if (self.data.client_name.len > 0) {
                try content.drawText(self.data.client_name, left, y, self.font_bold, 10.5, ink);
                y -= 14;
            }
            if (self.data.client_address.len > 0) {
                var it = std.mem.splitSequence(u8, self.data.client_address, addressDelimiter(self.data.client_address));
                while (it.next()) |line| {
                    try content.drawText(line, left, y, self.font_regular, 10, body);
                    y -= 13;
                }
            }
            if (self.data.client_vat.len > 0) {
                var vb: [128]u8 = undefined;
                const v = std.fmt.bufPrint(&vb, "{s} {s}", .{ self.data.labels.vat_prefix, self.data.client_vat }) catch self.data.client_vat;
                try content.drawText(v, left, y, self.font_regular, 9, muted);
                y -= 13;
            }
        }
        const meta_x = right - 200;
        var my = block_top;
        const rows = [_]struct { label: []const u8, value: []const u8 }{
            .{ .label = self.data.labels.date, .value = self.data.invoice_date },
            .{ .label = self.numberLabel(), .value = self.data.invoice_number },
            .{ .label = self.dueLabel(), .value = self.data.due_date },
        };
        for (rows) |row| {
            if (row.value.len == 0) continue;
            try content.drawText(bareLabel(row.label), meta_x, my, self.font_regular, 9, muted);
            try self.drawRightFit(content, row.value, right, 120, my, self.font_bold, bold, 9.5, ink);
            my -= 14;
        }

        // Document title and optional subject line.
        var ty = @min(y, my) - 22;
        try content.drawTrackedText(self.docTitle(), left, ty, self.font_bold, 15, 1.2, title_color);
        ty -= 8;
        if (self.data.subject.len > 0) {
            ty -= 12;
            var sb: [512]u8 = undefined;
            const subj = std.fmt.bufPrint(&sb, "{s} {s}", .{ self.data.labels.subject_prefix, self.data.subject }) catch self.data.subject;
            var wrapped = try wrapParagraphs(self.allocator, subj, bold, 10.5, usable);
            defer wrapped.deinit();
            for (wrapped.lines) |line| {
                try content.drawText(line, left, ty, self.font_bold, 10.5, ink);
                ty -= 13.5;
            }
        }
        self.current_y = ty - 28;
    }

    // -------------------------------------------------------------------------
    // Items table
    // -------------------------------------------------------------------------

    fn drawItems(self: *InvoiceRenderer, content: *document.ContentStream) !void {
        try self.drawTableHeader(content);
        if (self.isModern()) return self.drawModernRows(content);

        const usable_width = self.page_width - self.margin_left - self.margin_right;
        const table_style = self.data.table_style;
        const box_border = document.Color.fromHex("#d0d0d0");
        const cols = self.tableCols();
        const desc_col_width = cols.desc_w;
        const line_height: f32 = 12; // Height per line of text
        const row_padding: f32 = 6; // Padding above/below text in row
        const font_enum = self.fontEnumRegular();

        if (self.data.display_mode == .itemized) {
            for (self.data.items, 0..) |item, i| {
                var wrapped = try document.wrapText(self.allocator, item.description, font_enum, 9, desc_col_width);
                defer wrapped.deinit();

                const num_lines = @max(1, wrapped.lines.len);
                const row_height = @as(f32, @floatFromInt(num_lines)) * line_height + row_padding;

                // Paginate: if this row won't fit, close this page's rounded
                // container (squircle), then start a new page and redraw the
                // table header before drawing it.
                if (self.current_y - row_height < self.margin_bottom + 40) {
                    try self.closeTableContainer(content, self.current_y + 2);
                    try self.startNewPage(content, true);
                }

                // Row background — squircle draws a hairline separator under
                // each row; otherwise it depends on table_style:
                //   bands   -> alternating #f5f5f5 fill on even rows
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

                var desc_y = self.current_y;
                for (wrapped.lines) |line| {
                    try content.drawText(line, cols.desc_x, desc_y, self.font_regular, 9, document.Color.black);
                    desc_y -= line_height;
                }

                // qty/price/discount/total on the first line
                if (cols.qty) |x| {
                    var qty_buf: [48]u8 = undefined;
                    const qty_str = self.qtyText(&qty_buf, item);
                    try content.drawText(qty_str, x, self.current_y, self.font_regular, 9, document.Color.black);
                }
                if (cols.price) |x| {
                    var price_buf: [48]u8 = undefined;
                    const price_str = std.fmt.bufPrint(&price_buf, "{s}{d:.2}", .{ self.data.currency_symbol, item.unit_price }) catch "0.00";
                    try content.drawText(price_str, x, self.current_y, self.font_regular, 9, document.Color.black);
                }
                if (cols.disc) |x| {
                    if (item.discount != 0) {
                        var db: [40]u8 = undefined;
                        try content.drawText(discText(&db, item.discount), x, self.current_y, self.font_regular, 9, document.Color.black);
                    }
                }
                var total_buf: [48]u8 = undefined;
                const total_str = std.fmt.bufPrint(&total_buf, "{s}{d:.2}", .{ self.data.currency_symbol, item.total }) catch "0.00";
                try content.drawText(total_str, cols.total, self.current_y, self.font_regular, 9, document.Color.black);

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

            var desc_y = self.current_y;
            for (wrapped.lines) |line| {
                try content.drawText(line, cols.desc_x, desc_y, self.font_regular, 9, document.Color.black);
                desc_y -= line_height;
            }

            var total_buf: [48]u8 = undefined;
            const total_str = std.fmt.bufPrint(&total_buf, "{s}{d:.2}", .{ self.data.currency_symbol, self.data.subtotal }) catch "0.00";
            try content.drawText(total_str, cols.total, self.current_y, self.font_regular, 9, document.Color.black);

            self.current_y -= row_height + 2;
        }
    }

    /// "3", "2.5 hrs", "12 m²".
    fn qtyText(self: *const InvoiceRenderer, buf: []u8, item: LineItem) []const u8 {
        _ = self;
        var qb: [32]u8 = undefined;
        const q = fmtQty(&qb, item.quantity);
        if (item.unit.len == 0) {
            if (q.len > buf.len) return "0";
            @memcpy(buf[0..q.len], q);
            return buf[0..q.len];
        }
        return std.fmt.bufPrint(buf, "{s} {s}", .{ q, item.unit }) catch q;
    }

    /// "10%", "12.5%".
    fn discText(buf: []u8, pct: f64) []const u8 {
        var qb: [32]u8 = undefined;
        return std.fmt.bufPrint(buf, "{s}%", .{fmtQty(&qb, pct)}) catch "";
    }

    /// Minimal/letterhead rows: right-aligned figures, hairline separators.
    fn drawModernRows(self: *InvoiceRenderer, content: *document.ContentStream) !void {
        const primary = document.Color.fromHex(self.data.primary_color);
        const ink = document.Color.fromHex("#111827");
        const sep = document.Color.fromHex("#ECEEF1");
        const closing = if (self.data.theme == .letterhead) primary else document.Color.fromHex("#D1D5DB");
        const left = self.margin_left;
        const right = self.page_width - self.margin_right;
        const cols = self.tableCols();
        const reg = self.fontEnumRegular();
        const size: f32 = 9.5;
        const lh: f32 = 12.5;

        const Row = struct { desc: []const u8, item: ?LineItem, amount: f64 };
        const count: usize = if (self.data.display_mode == .itemized) self.data.items.len else 1;
        for (0..count) |i| {
            const row: Row = if (self.data.display_mode == .itemized)
                .{ .desc = self.data.items[i].description, .item = self.data.items[i], .amount = self.data.items[i].total }
            else
                .{ .desc = self.data.blackbox_description, .item = null, .amount = self.data.subtotal };

            var wrapped = try wrapParagraphs(self.allocator, row.desc, reg, size, cols.desc_w);
            defer wrapped.deinit();
            const n: f32 = @floatFromInt(@max(1, wrapped.lines.len));
            const block = (n - 1) * lh;
            if (self.current_y - block - 10 < self.margin_bottom + 30) {
                try self.startNewPage(content, true);
            }

            var y = self.current_y;
            for (wrapped.lines) |line| {
                try content.drawText(line, cols.desc_x, y, self.font_regular, size, ink);
                y -= lh;
            }
            if (row.item) |item| {
                if (cols.qty) |x| {
                    var qb: [48]u8 = undefined;
                    try content.drawTextRightAligned(self.qtyText(&qb, item), x, self.current_y, self.font_regular, reg, size, ink);
                }
                if (cols.price) |x| {
                    var pb: [48]u8 = undefined;
                    try content.drawTextRightAligned(fmtMoney(&pb, self.data.currency_symbol, item.unit_price), x, self.current_y, self.font_regular, reg, size, ink);
                }
                if (cols.disc) |x| {
                    if (item.discount != 0) {
                        var db: [40]u8 = undefined;
                        try content.drawTextRightAligned(discText(&db, item.discount), x, self.current_y, self.font_regular, reg, size, ink);
                    }
                }
            }
            var tb: [48]u8 = undefined;
            try content.drawTextRightAligned(fmtMoney(&tb, self.data.currency_symbol, row.amount), cols.total, self.current_y, self.font_regular, reg, size, ink);

            const sep_y = self.current_y - block - 8;
            const last = i + 1 == count;
            if (last) {
                try content.drawLine(left, sep_y, right, sep_y, closing, 0.7);
            } else {
                try content.drawLine(left, sep_y, right, sep_y, sep, 0.5);
            }
            self.current_y = sep_y - 16;
        }
    }

    // -------------------------------------------------------------------------
    // Totals
    // -------------------------------------------------------------------------

    fn drawTotals(self: *InvoiceRenderer, content: *document.ContentStream) !void {
        if (self.isModern()) return self.drawModernTotals(content);

        const primary = document.Color.fromHex(self.data.primary_color);
        const secondary = document.Color.fromHex(self.data.secondary_color);
        const usable_width = self.page_width - self.margin_left - self.margin_right;
        const col_price = self.margin_left + 350;
        const adjustments = self.data.adjustments;

        // Squircle: the rows are done — close the rounded table container.
        try self.closeTableContainer(content, self.current_y + 2);

        // Keep the whole totals block together: if it won't fit under the last
        // row, move it to a fresh page (no table header needed there).
        var extra_rows: f32 = @floatFromInt(adjustments.len);
        if (!self.data.show_tax and adjustments.len > 0) extra_rows += 1;
        if (self.data.amount_paid != null) extra_rows += 3;
        if (self.current_y < self.margin_bottom + 160 + extra_rows * 16) {
            try self.startNewPage(content, false);
        }

        self.current_y -= 20;
        self.totals_top = self.current_y;

        // Separator line
        try content.drawLine(col_price - 20, self.current_y + 15, self.page_width - self.margin_right, self.current_y + 15, secondary, 0.5);

        // Amount values are right-anchored so large figures grow leftward and
        // never overrun the table's right edge.
        const amt_right = self.margin_left + usable_width - 6;
        const reg_t = self.fontEnumRegular();
        const amt_width = amt_right - (col_price + 70); // space right of the widest label

        // Subtotal + Tax — only when VAT/tax is being shown. For a non-tax
        // receipt these rows are suppressed (subtotal == total, and a "Tax (0%)"
        // line would be misleading) unless adjustments sit between them.
        if (self.data.show_tax) {
            var subtotal_buf: [48]u8 = undefined;
            try content.drawText(self.data.labels.subtotal, col_price, self.current_y, self.font_regular, 10, document.Color.black);
            const subtotal_str = std.fmt.bufPrint(&subtotal_buf, "{s}{d:.2}", .{ self.data.currency_symbol, self.data.subtotal }) catch "0.00";
            try self.drawRightFit(content, subtotal_str, amt_right, amt_width, self.current_y, self.font_regular, reg_t, 10, document.Color.black);
            self.current_y -= 16;

            try self.drawClassicAdjustments(content, col_price, amt_right, amt_width);

            var tax_label_buf: [64]u8 = undefined;
            const tax_pct = self.data.tax_rate * 100;
            const tax_label = std.fmt.bufPrint(&tax_label_buf, "{s} ({d:.0}%):", .{ self.data.labels.tax_prefix, tax_pct }) catch self.data.labels.tax_prefix;
            try content.drawText(tax_label, col_price, self.current_y, self.font_regular, 10, document.Color.black);
            var tax_buf: [48]u8 = undefined;
            const tax_str = std.fmt.bufPrint(&tax_buf, "{s}{d:.2}", .{ self.data.currency_symbol, self.data.tax_amount }) catch "0.00";
            try self.drawRightFit(content, tax_str, amt_right, amt_width, self.current_y, self.font_regular, reg_t, 10, document.Color.black);
            self.current_y -= 16;

            // IRPF retention (Spanish freelancer invoices) — a negative row.
            if (self.data.irpf_rate != 0 or self.data.irpf_amount != 0) {
                var irpf_label_buf: [32]u8 = undefined;
                const irpf_pct = self.data.irpf_rate * 100;
                const irpf_label = std.fmt.bufPrint(&irpf_label_buf, "IRPF ({d:.0}%):", .{irpf_pct}) catch "IRPF:";
                try content.drawText(irpf_label, col_price, self.current_y, self.font_regular, 10, document.Color.black);
                var irpf_buf: [48]u8 = undefined;
                const irpf_str = std.fmt.bufPrint(&irpf_buf, "-{s}{d:.2}", .{ self.data.currency_symbol, @abs(self.data.irpf_amount) }) catch "0.00";
                try self.drawRightFit(content, irpf_str, amt_right, amt_width, self.current_y, self.font_regular, reg_t, 10, document.Color.black);
                self.current_y -= 16;
            }

            self.current_y -= 12; // Extra spacing before TOTAL row
        } else {
            if (adjustments.len > 0) {
                var subtotal_buf: [48]u8 = undefined;
                try content.drawText(self.data.labels.subtotal, col_price, self.current_y, self.font_regular, 10, document.Color.black);
                try self.drawRightFit(content, fmtMoney(&subtotal_buf, self.data.currency_symbol, self.data.subtotal), amt_right, amt_width, self.current_y, self.font_regular, reg_t, 10, document.Color.black);
                self.current_y -= 16;
                try self.drawClassicAdjustments(content, col_price, amt_right, amt_width);
            }
            self.current_y -= 12; // Modest gap between separator and TOTAL bar
        }

        // Total (highlighted) - width calculated to align with table right edge
        const total_bar_x = col_price - 10;
        const table_right_edge = self.margin_left + usable_width;
        const total_bar_width = table_right_edge - total_bar_x;
        if (self.data.theme == .glass) {
            // Emphasis chip in the same faded material as the header band —
            // dark text carries the contrast.
            const glass_panel_border = mixColor(document.Color.white, primary, 0.14);
            const glass_sheen_end = mixColor(document.Color.white, primary, 0.22);
            const chip_fill = mixColor(document.Color.white, primary, 0.30);
            try self.drawGlassPanel(self.bg.?, total_bar_x, self.current_y - 5, total_bar_width, 22, 7, chip_fill, 0.85, glass_sheen_end, 0.50, glass_panel_border, 1.0);
        } else if (self.data.theme == .squircle) {
            try content.drawRoundedRectEx(total_bar_x, self.current_y - 5, total_bar_width, 22, 7, primary, null, 1.0);
        } else {
            try content.drawRect(total_bar_x, self.current_y - 5, total_bar_width, 22, primary, null);
        }
        // Faded glass chip needs dark ink; solid chips keep white.
        const total_text_color = if (self.data.theme == .glass) secondary else document.Color.white;
        try content.drawText(self.data.labels.total, col_price, self.current_y, self.font_bold, 12, total_text_color);
        var grand_total_buf: [48]u8 = undefined;
        const grand_total_str = std.fmt.bufPrint(&grand_total_buf, "{s}{d:.2}", .{ self.data.currency_symbol, self.data.total }) catch "0.00";
        try self.drawRightFit(content, grand_total_str, table_right_edge - 10, (table_right_edge - 10) - (col_price + 64), self.current_y, self.font_bold, self.fontEnumBold(), 12, total_text_color);

        const total_y = self.current_y;

        // Payment received and what is still owed.
        if (self.data.amount_paid) |paid| {
            self.current_y -= 26;
            var pb: [48]u8 = undefined;
            try content.drawText(self.data.labels.amount_paid, col_price, self.current_y, self.font_regular, 10, document.Color.black);
            try self.drawRightFit(content, fmtMoney(&pb, self.data.currency_symbol, paid), amt_right, amt_width, self.current_y, self.font_regular, reg_t, 10, document.Color.black);
            var mb: [160]u8 = undefined;
            if (self.paymentMeta(&mb)) |meta| {
                self.current_y -= 11;
                try content.drawText(meta, col_price, self.current_y, self.font_regular, 8, document.Color.fromHex("#6B7280"));
            }
            self.current_y -= 17;
            var bb: [48]u8 = undefined;
            try content.drawText(self.data.labels.balance_due, col_price, self.current_y, self.font_bold, 10, document.Color.black);
            try self.drawRightFit(content, fmtMoney(&bb, self.data.currency_symbol, balanceDue(self.data.total, paid)), amt_right, amt_width, self.current_y, self.font_bold, self.fontEnumBold(), 10, document.Color.black);
        }

        if (self.showPaidStamp()) try self.drawPaidStamp(content, self.margin_left, total_y + 6);
    }

    fn drawClassicAdjustments(self: *InvoiceRenderer, content: *document.ContentStream, label_x: f32, amt_right: f32, amt_width: f32) !void {
        for (self.data.adjustments) |adj| {
            var ab: [48]u8 = undefined;
            try content.drawText(adj.label, label_x, self.current_y, self.font_regular, 10, document.Color.black);
            try self.drawRightFit(content, fmtMoney(&ab, self.data.currency_symbol, adj.amount), amt_right, amt_width, self.current_y, self.font_regular, self.fontEnumRegular(), 10, document.Color.black);
            self.current_y -= 16;
        }
    }

    /// "2026-09-03 · Bank transfer" from payment_date / payment_method.
    fn paymentMeta(self: *const InvoiceRenderer, buf: []u8) ?[]const u8 {
        const d = self.data.payment_date;
        const m = self.data.payment_method;
        if (d.len == 0 and m.len == 0) return null;
        if (d.len > 0 and m.len > 0) return std.fmt.bufPrint(buf, "{s} \xc2\xb7 {s}", .{ d, m }) catch d;
        return if (d.len > 0) d else m;
    }

    /// PAID IN FULL mark: a double-ruled rounded frame with tracked caps in
    /// the accent colour, vertically centred on `y_mid`.
    fn drawPaidStamp(self: *InvoiceRenderer, content: *document.ContentStream, x: f32, y_mid: f32) !void {
        const primary = document.Color.fromHex(self.data.primary_color);
        const text = self.data.labels.paid_in_full;
        const size: f32 = 11;
        const track: f32 = 1.6;
        const tw = self.fontEnumBold().measureTracked(text, size, track);
        const w = tw + 28;
        const h: f32 = 28;
        try content.drawRoundedRectEx(x, y_mid - h / 2, w, h, 6, null, primary, 1.6);
        try content.drawRoundedRectEx(x + 3, y_mid - h / 2 + 3, w - 6, h - 6, 4, null, primary, 0.5);
        try content.drawTrackedText(text, x + 14, y_mid - 4, self.font_bold, size, track, primary);
    }

    fn drawModernTotals(self: *InvoiceRenderer, content: *document.ContentStream) !void {
        const primary = document.Color.fromHex(self.data.primary_color);
        const ink = document.Color.fromHex("#111827");
        const body = document.Color.fromHex("#374151");
        const muted = document.Color.fromHex("#6B7280");
        const right = self.page_width - self.margin_right;
        const lx = right - 230;
        const reg = self.fontEnumRegular();
        const bold = self.fontEnumBold();
        const sym = self.data.currency_symbol;
        const letter = self.data.theme == .letterhead;
        const adjustments = self.data.adjustments;

        var rows: f32 = @floatFromInt(adjustments.len);
        if (self.data.show_tax) rows += 2;
        if (self.data.irpf_rate != 0 or self.data.irpf_amount != 0) rows += 1;
        if (self.data.amount_paid != null) rows += 3;
        if (self.current_y - (rows * 17 + 50) < self.margin_bottom + 10) try self.startNewPage(content, false);

        var y = self.current_y - 4;
        self.totals_top = y;
        const Line = struct { label: []const u8, amount: f64 };
        var buf: [96]u8 = undefined;
        var mb: [48]u8 = undefined;

        if (self.data.show_tax or adjustments.len > 0) {
            try content.drawText(bareLabel(self.data.labels.subtotal), lx, y, self.font_regular, 9.5, body);
            try content.drawTextRightAligned(fmtMoney(&mb, sym, self.data.subtotal), right, y, self.font_regular, reg, 9.5, ink);
            y -= 17;
        }
        for (adjustments) |adj| {
            const l = Line{ .label = adj.label, .amount = adj.amount };
            try content.drawText(l.label, lx, y, self.font_regular, 9.5, body);
            try content.drawTextRightAligned(fmtMoney(&mb, sym, l.amount), right, y, self.font_regular, reg, 9.5, ink);
            y -= 17;
        }
        if (self.data.show_tax) {
            var qb: [32]u8 = undefined;
            const tax_label = std.fmt.bufPrint(&buf, "{s} ({s}%)", .{ self.data.labels.tax_prefix, fmtQty(&qb, self.data.tax_rate * 100) }) catch self.data.labels.tax_prefix;
            try content.drawText(tax_label, lx, y, self.font_regular, 9.5, body);
            try content.drawTextRightAligned(fmtMoney(&mb, sym, self.data.tax_amount), right, y, self.font_regular, reg, 9.5, ink);
            y -= 17;
            if (self.data.irpf_rate != 0 or self.data.irpf_amount != 0) {
                var ib: [32]u8 = undefined;
                const irpf_label = std.fmt.bufPrint(&buf, "IRPF ({s}%)", .{fmtQty(&ib, self.data.irpf_rate * 100)}) catch "IRPF";
                try content.drawText(irpf_label, lx, y, self.font_regular, 9.5, body);
                try content.drawTextRightAligned(fmtMoney(&mb, sym, -@abs(self.data.irpf_amount)), right, y, self.font_regular, reg, 9.5, ink);
                y -= 17;
            }
        }

        // TOTAL row
        y -= 6;
        if (letter) {
            try content.drawLine(lx, y + 14, right, y + 14, ink, 0.6);
        } else {
            try content.drawLine(lx, y + 14, right, y + 14, primary, 1.0);
        }
        y -= 4;
        const total_y = y;
        try content.drawText(bareLabel(self.data.labels.total), lx, y, self.font_bold, 10.5, ink);
        var tb: [48]u8 = undefined;
        const total_str = fmtMoney(&tb, sym, self.data.total);
        if (letter) {
            try content.drawTextRightAligned(total_str, right, y, self.font_bold, bold, 12, ink);
            const w = bold.measureText(total_str, 12);
            try content.drawLine(right - w - 4, y - 5, right, y - 5, ink, 0.5);
            try content.drawLine(right - w - 4, y - 7.5, right, y - 7.5, ink, 0.5);
        } else {
            try content.drawTextRightAligned(total_str, right, y - 1, self.font_bold, bold, 15, primary);
        }
        y -= 24;

        if (self.data.amount_paid) |paid| {
            try content.drawText(bareLabel(self.data.labels.amount_paid), lx, y, self.font_regular, 9.5, body);
            try content.drawTextRightAligned(fmtMoney(&mb, sym, paid), right, y, self.font_regular, reg, 9.5, ink);
            var pmb: [160]u8 = undefined;
            if (self.paymentMeta(&pmb)) |meta| {
                y -= 11;
                try content.drawText(meta, lx, y, self.font_regular, 7.5, muted);
            }
            y -= 17;
            const bal_color = if (letter) ink else primary;
            try content.drawText(bareLabel(self.data.labels.balance_due), lx, y, self.font_bold, 10, ink);
            try content.drawTextRightAligned(fmtMoney(&mb, sym, balanceDue(self.data.total, paid)), right, y, self.font_bold, bold, 10, bal_color);
            y -= 17;
        }

        if (self.showPaidStamp()) try self.drawPaidStamp(content, self.margin_left, total_y + 4);
        self.current_y = y;
    }

    // -------------------------------------------------------------------------
    // Closing blocks: notes, terms, bank details, crypto, QR/buttons, signature
    // -------------------------------------------------------------------------

    /// Section heading: "Notes:" bold in the classic themes, tracked small
    /// caps in minimal/letterhead.
    fn drawSectionHeading(self: *InvoiceRenderer, content: *document.ContentStream, text: []const u8, x: f32) !void {
        if (self.isModern()) {
            var cb: [64]u8 = undefined;
            try content.drawTrackedText(capsLabel(&cb, text), x, self.current_y, self.font_bold, 7, 0.8, document.Color.fromHex("#6B7280"));
            self.current_y -= 14;
        } else {
            try content.drawText(text, x, self.current_y, self.font_bold, 10, document.Color.fromHex(self.data.secondary_color));
            self.current_y -= 14;
        }
    }

    /// A wrapped text section (notes / payment terms), paginating as needed.
    fn drawTextSection(self: *InvoiceRenderer, content: *document.ContentStream, heading: []const u8, text: []const u8, after: f32) !void {
        const usable_width = self.page_width - self.margin_left - self.margin_right;
        const color = if (self.isModern()) document.Color.fromHex("#374151") else document.Color.black;
        try self.ensureSpace(content, 40);
        try self.drawSectionHeading(content, heading, self.margin_left);
        var wrapped = try wrapParagraphs(self.allocator, text, self.fontEnumRegular(), 9, usable_width - 10);
        defer wrapped.deinit();
        for (wrapped.lines) |line| {
            if (self.current_y < self.margin_bottom + 10) try self.startNewPage(content, false);
            try content.drawText(line, self.margin_left, self.current_y, self.font_regular, 9, color);
            self.current_y -= 12;
        }
        self.current_y -= after;
    }

    /// The structured bank-details block at `x`, starting at current_y.
    fn drawBankBlock(self: *InvoiceRenderer, content: *document.ContentStream, x: f32) !void {
        const bd = self.data.bank_details;
        const l = self.data.labels;
        const modern = self.isModern();
        const label_color = if (modern) document.Color.fromHex("#6B7280") else document.Color.fromHex(self.data.secondary_color);
        const value_color = if (modern) document.Color.fromHex("#111827") else document.Color.black;
        try self.drawSectionHeading(content, l.bank_details, x);
        const rows = [_][2][]const u8{
            .{ l.account_name, bd.account_name },
            .{ l.bank_name, bd.bank_name },
            .{ l.sort_code, bd.sort_code },
            .{ l.account_number, bd.account_number },
            .{ l.iban, bd.iban },
            .{ l.bic, bd.bic },
            .{ l.payment_reference, bd.reference },
        };
        for (rows) |row| {
            if (row[1].len == 0) continue;
            try content.drawText(row[0], x, self.current_y, self.font_regular, 8.5, label_color);
            try content.drawText(row[1], x + 82, self.current_y, self.font_bold, 9, value_color);
            self.current_y -= 12.5;
        }
    }

    fn bankBlockHeight(self: *const InvoiceRenderer) f32 {
        const bd = self.data.bank_details;
        var n: f32 = 0;
        for ([_][]const u8{ bd.account_name, bd.bank_name, bd.sort_code, bd.account_number, bd.iban, bd.bic, bd.reference }) |v| {
            if (v.len > 0) n += 1;
        }
        return 14 + n * 12.5;
    }

    /// Signature line block: heading, signature image (or blank space) over a
    /// rule, then name and title beneath it.
    fn drawSignatureBlock(self: *InvoiceRenderer, content: *document.ContentStream, sig_id: ?[]const u8) !void {
        const secondary = document.Color.fromHex(self.data.secondary_color);
        const muted = document.Color.fromHex("#6B7280");
        const ink = if (self.isModern()) document.Color.fromHex("#111827") else document.Color.black;
        try self.ensureSpace(content, 92);
        self.current_y -= 10;
        try self.drawSectionHeading(content, self.data.labels.signature, self.margin_left);
        const line_y = self.current_y - 40;
        const line_w: f32 = 210;
        if (sig_id) |sid| {
            const fit = fitBox(self.sig_px_w, self.sig_px_h, 170, 40);
            try content.drawImage(sid, self.margin_left + 4, line_y + 2, fit[0], fit[1]);
        }
        try content.drawLine(self.margin_left, line_y, self.margin_left + line_w, line_y, secondary, 0.6);
        var y = line_y - 13;
        if (self.data.signature_name.len > 0) {
            try content.drawText(self.data.signature_name, self.margin_left, y, self.font_bold, 9.5, ink);
            y -= 12;
        }
        if (self.data.signature_title.len > 0) {
            try content.drawText(self.data.signature_title, self.margin_left, y, self.font_regular, 8.5, muted);
            y -= 12;
        }
        self.current_y = y - 8;
    }

    fn drawClosingBlocks(self: *InvoiceRenderer, content: *document.ContentStream, assets: Assets) !void {
        const primary = document.Color.fromHex(self.data.primary_color);
        const secondary = document.Color.fromHex(self.data.secondary_color);
        const usable_width = self.page_width - self.margin_left - self.margin_right;
        const table_right_edge = self.margin_left + usable_width;

        // Bank details beside the totals, in the empty column on the left,
        // when they fit there (and no PAID mark claims that space).
        var bank_beside = false;
        if (self.showBank() and !self.showPaidStamp() and self.totals_top - self.bankBlockHeight() > self.margin_bottom + 10) {
            const after_totals = self.current_y;
            self.current_y = self.totals_top;
            try self.drawBankBlock(content, self.margin_left);
            self.current_y = @min(after_totals, self.current_y + 4);
            bank_beside = true;
        }

        self.current_y -= if (self.isModern()) 18 else 30;

        if (self.data.notes.len > 0) try self.drawTextSection(content, self.data.labels.notes, self.data.notes, 6);
        if (self.data.payment_terms.len > 0) try self.drawTextSection(content, self.data.labels.payment_terms, self.data.payment_terms, 8);

        // Bank details sit on the left; the QR / pay buttons, when present,
        // share their top edge on the right.
        var side_top = self.current_y;
        var bank_end: ?f32 = null;
        if (self.showBank() and !bank_beside) {
            const has_side = assets.qr_id != null;
            try self.ensureSpace(content, @max(self.bankBlockHeight(), if (has_side) @as(f32, 125) else 0) + 10);
            self.current_y -= 4;
            side_top = self.current_y;
            try self.drawBankBlock(content, self.margin_left);
            bank_end = self.current_y - 6;
            self.current_y = bank_end.?;
        }

        // ---- Crypto payment section (with optional identicons) --------------
        if (assets.wallet) |wallet| {
            if (wallet.len > 0) {
                self.current_y -= 10;

                const network_color = document.Color.fromHex(assets.network.color());
                const network_name = assets.network.displayName();

                var header_buf: [64]u8 = undefined;
                const header_text = std.fmt.bufPrint(&header_buf, "Pay with {s} ({s})", .{ network_name, assets.symbol }) catch "Crypto Payment";
                try content.drawText(header_text, self.margin_left, self.current_y, self.font_bold, 11, network_color);
                self.current_y -= 18;

                const identicon_size: f32 = 24;
                const addr_x = if (assets.recipient_identicon_id != null) self.margin_left + identicon_size + 8 else self.margin_left;

                if (assets.recipient_identicon_id) |icon_id| {
                    try content.drawImage(icon_id, self.margin_left, self.current_y - identicon_size + 10, identicon_size, identicon_size);
                }

                try content.drawText("To:", addr_x, self.current_y, self.font_bold, 9, secondary);
                self.current_y -= 12;

                const truncated = truncateAddress(wallet, 10, 8);
                try content.drawText(&truncated, addr_x, self.current_y, self.font_regular, 9, document.Color.black);
                self.current_y -= 14;

                // Full address in smaller font (for verification)
                try content.drawText(wallet, addr_x, self.current_y, self.font_regular, 7, document.Color.fromHex("#666666"));
                self.current_y -= 16;

                if (assets.sender) |sender| {
                    if (sender.len > 0) {
                        const sender_x = if (assets.sender_identicon_id != null) self.margin_left + identicon_size + 8 else self.margin_left;

                        if (assets.sender_identicon_id) |icon_id| {
                            try content.drawImage(icon_id, self.margin_left, self.current_y - identicon_size + 10, identicon_size, identicon_size);
                        }

                        try content.drawText("From:", sender_x, self.current_y, self.font_bold, 9, secondary);
                        self.current_y -= 12;

                        const sender_truncated = truncateAddress(sender, 10, 8);
                        try content.drawText(&sender_truncated, sender_x, self.current_y, self.font_regular, 9, document.Color.black);
                        self.current_y -= 18;
                    }
                }

                if (assets.amount_str) |amt_s| {
                    if (amt_s.len > 0) {
                        var amount_buf: [128]u8 = undefined;
                        const amount_text = std.fmt.bufPrint(&amount_buf, "Amount: {s} {s}", .{ amt_s, assets.symbol }) catch "Amount: [error]";
                        try content.drawText(amount_text, self.margin_left, self.current_y, self.font_bold, 10, network_color);
                        self.current_y -= 20;
                    }
                } else if (self.data.crypto_amount) |amount| {
                    var amount_buf: [64]u8 = undefined;
                    const amount_text = std.fmt.bufPrint(&amount_buf, "Amount: {d:.8} {s}", .{ amount, assets.symbol }) catch "Amount: [error]";
                    try content.drawText(amount_text, self.margin_left, self.current_y, self.font_bold, 10, network_color);
                    self.current_y -= 20;
                }
            }
        }

        // Resolve the effective payment buttons: an explicit payment_buttons
        // array wins; otherwise synthesize a single button from the legacy
        // payment_button_* fields.
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

        // The QR / buttons column starts level with the bank block when there
        // is one, otherwise below everything drawn so far.
        const flow_y = self.current_y;
        if (bank_end != null) self.current_y = side_top;

        // QR Code - positioned below notes, right-aligned with table
        if (assets.qr_id) |qid| {
            const qr_size: f32 = 80; // ~28mm for good scannability
            const qr_padding: f32 = 15;

            const qr_x = table_right_edge - qr_size;
            const qr_y = self.current_y - qr_size - qr_padding;

            try content.drawImage(qid, qr_x, qr_y, qr_size, qr_size);

            // Label below QR code - custom label if provided, otherwise by mode
            const qr_label: []const u8 = if (self.data.qr_label) |custom_label|
                if (custom_label.len > 0) custom_label else self.qrModeLabel(assets.effective_qr_mode)
            else
                self.qrModeLabel(assets.effective_qr_mode);

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
                    const bgc = document.Color.fromHex(b.color);
                    const tc = document.Color.fromHex(b.text_color);
                    const bounds = try content.drawButton(b.label, btn_x, btn_y, btn_width, btn_height, self.font_bold, 11, bgc, tc, 6);
                    try self.doc.addLinkAnnotation(bounds.x1, bounds.y1, bounds.x2, bounds.y2, b.url);
                    btn_y -= btn_height + gap;
                }
            }

            self.current_y = qr_y - 25;
        } else if (pay_btns.len > 0) {
            // No QR code — stack the payment button(s) standalone, right-aligned.
            const btn_width: f32 = 140;
            const btn_height: f32 = 34;
            const gap: f32 = 8;
            const btn_x = table_right_edge - btn_width;
            var btn_y = self.current_y - btn_height - 15;
            for (pay_btns) |b| {
                const bgc = document.Color.fromHex(b.color);
                const tc = document.Color.fromHex(b.text_color);
                const bounds = try content.drawButton(b.label, btn_x, btn_y, btn_width, btn_height, self.font_bold, 12, bgc, tc, 6);
                try self.doc.addLinkAnnotation(bounds.x1, bounds.y1, bounds.x2, bounds.y2, b.url);
                btn_y -= btn_height + gap;
            }

            if (pay_btns.len == 1) {
                const label_text = self.data.labels.click_to_pay;
                const lbl_width: f32 = @as(f32, @floatFromInt(label_text.len)) * 4.0;
                const lbl_x = btn_x + (btn_width - lbl_width) / 2;
                try content.drawText(label_text, lbl_x, btn_y + gap - 12, self.font_regular, 8, secondary);
            }

            self.current_y = btn_y - 20;
        }
        if (bank_end != null) self.current_y = @min(self.current_y, flow_y);

        if (self.data.show_signature) try self.drawSignatureBlock(content, assets.sig_id);
    }

    fn qrModeLabel(self: *const InvoiceRenderer, mode: QrCodeMode) []const u8 {
        return switch (mode) {
            .verifactu => "VeriFactu",
            .payment_link => self.data.labels.scan_to_pay,
            .bank_details => self.data.labels.bank_details,
            .verification => self.data.labels.verify_invoice,
            .crypto => "Crypto Payment",
            .none => "",
        };
    }

    fn footerStrap(self: *const InvoiceRenderer, mode: QrCodeMode) []const u8 {
        return switch (mode) {
            .verifactu => self.data.labels.footer_verifactu,
            .payment_link => self.data.labels.footer_scan_to_pay,
            .bank_details => self.data.labels.footer_bank_details,
            .verification => self.data.labels.footer_verify,
            .crypto => "Cryptocurrency Payment Accepted",
            .none => "",
        };
    }

    /// VeriFactu hash (huella), series and NIF along one line at `y`.
    fn drawVerifactuLine(self: *InvoiceRenderer, content: *document.ContentStream, y: f32, color: document.Color) !void {
        if (self.data.verifactu_hash) |hash| {
            if (hash.len > 0) {
                // First 16 chars, as per the VeriFactu QR standard
                const hash_display = if (hash.len > 16) hash[0..16] else hash;
                var hash_buf: [32]u8 = undefined;
                const hash_text = std.fmt.bufPrint(&hash_buf, "Huella: {s}...", .{hash_display}) catch "Huella: [error]";
                try content.drawText(hash_text, self.margin_left, y, self.font_regular, 7, color);
            }
        }
        if (self.data.verifactu_series) |series| {
            if (series.len > 0) {
                var series_buf: [32]u8 = undefined;
                const series_text = std.fmt.bufPrint(&series_buf, "Serie: {s}", .{series}) catch "Serie: [error]";
                try content.drawText(series_text, self.margin_left + 180, y, self.font_regular, 7, color);
            }
        }
        if (self.data.verifactu_nif) |nif| {
            if (nif.len > 0) {
                var nif_buf: [32]u8 = undefined;
                const nif_text = std.fmt.bufPrint(&nif_buf, "NIF: {s}", .{nif}) catch "NIF: [error]";
                try content.drawText(nif_text, self.margin_left + 250, y, self.font_regular, 7, color);
            }
        }
    }

    // -------------------------------------------------------------------------
    // Footers
    // -------------------------------------------------------------------------

    /// Classic/squircle/glass footer on the last page: rule, QR strap-line,
    /// VeriFactu details, thank-you line and the optional branding link.
    fn drawClassicFooter(self: *InvoiceRenderer, content: *document.ContentStream, assets: Assets) !void {
        const secondary = document.Color.fromHex(self.data.secondary_color);

        try content.drawLine(self.margin_left, self.margin_bottom - 10, self.page_width - self.margin_right, self.margin_bottom - 10, secondary, 0.5);

        if (assets.qr_id != null) {
            const footer_label = self.footerStrap(assets.effective_qr_mode);
            if (footer_label.len > 0) {
                try content.drawText(footer_label, self.margin_left, self.margin_bottom - 25, self.font_regular, 8, secondary);
            }
            if (assets.effective_qr_mode == .verifactu) try self.drawVerifactuLine(content, self.margin_bottom - 38, secondary);
            try content.drawText(self.data.labels.thank_you, self.page_width - self.margin_right - 130, self.margin_bottom - 25, self.font_regular, 9, secondary);
        } else {
            try content.drawText(self.data.labels.thank_you, self.page_width / 2 - 60, self.margin_bottom - 25, self.font_regular, 9, secondary);
        }

        if (self.data.show_branding) {
            const branding_text = "Generated by Quantify";
            const branding_font_size: f32 = 7;
            const branding_y = self.margin_bottom - 45;
            const text_width: f32 = @as(f32, @floatFromInt(branding_text.len)) * 4.2;
            const branding_x = (self.page_width - text_width) / 2;
            const branding_color = document.Color{ .r = 0.6, .g = 0.6, .b = 0.6 };
            try content.drawText(branding_text, branding_x, branding_y, self.font_regular, branding_font_size, branding_color);
            try self.doc.addLinkAnnotation(branding_x, branding_y - 2, branding_x + text_width, branding_y + branding_font_size + 2, self.data.branding_url);
        }
    }

    /// Minimal/letterhead last-page footer, under the per-page line drawn by
    /// commitPendingPages: thank-you (or QR strap-line) left, branding right,
    /// VeriFactu details beneath.
    fn drawModernFooter(self: *InvoiceRenderer, content: *document.ContentStream, assets: Assets) !void {
        const muted = document.Color.fromHex("#6B7280");
        const right = self.page_width - self.margin_right;
        const y = self.margin_bottom - 35;
        const strap = if (assets.qr_id != null) self.footerStrap(assets.effective_qr_mode) else "";
        const left_text = if (strap.len > 0) strap else self.data.labels.thank_you;
        try content.drawText(left_text, self.margin_left, y, self.font_regular, 7.5, muted);
        if (assets.qr_id != null and assets.effective_qr_mode == .verifactu) try self.drawVerifactuLine(content, y - 11, muted);
        if (self.data.show_branding) {
            const branding_text = "Generated by Quantify";
            const size: f32 = 7;
            const w = self.fontEnumRegular().measureText(branding_text, size);
            const color = document.Color{ .r = 0.6, .g = 0.6, .b = 0.6 };
            try content.drawText(branding_text, right - w, y, self.font_regular, size, color);
            try self.doc.addLinkAnnotation(right - w, y - 2, right, y + size + 2, self.data.branding_url);
        }
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

// -----------------------------------------------------------------------------
// Document-system tests
// -----------------------------------------------------------------------------

test "quantity prints up to two decimals, trailing zeros trimmed" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("3", fmtQty(&buf, 3));
    try std.testing.expectEqualStrings("40", fmtQty(&buf, 40));
    try std.testing.expectEqualStrings("2.5", fmtQty(&buf, 2.5));
    try std.testing.expectEqualStrings("0.13", fmtQty(&buf, 0.125));
    try std.testing.expectEqualStrings("1.75", fmtQty(&buf, 1.75));
    try std.testing.expectEqualStrings("0", fmtQty(&buf, 0));
}

test "line totals, document totals and balance" {
    try std.testing.expectApproxEqAbs(@as(f64, 270), lineTotal(3, 100, 10), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 33.33), lineTotal(1, 33.333, 0), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0), lineTotal(1, 50, 150), 1e-9); // clamped to 100%

    const items = [_]LineItem{
        .{ .description = "a", .quantity = 1, .unit_price = 100, .total = 100 },
        .{ .description = "b", .quantity = 2, .unit_price = 50, .total = 90, .discount = 10 },
    };
    const adj = [_]Adjustment{ .{ .label = "Shipping", .amount = 10 }, .{ .label = "Deposit", .amount = -50 } };
    const t = computeTotals(&items, &adj, 0.2, true, 0);
    try std.testing.expectApproxEqAbs(@as(f64, 190), t.subtotal, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, -40), t.adjustments, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 30), t.tax, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 180), t.total, 1e-9);

    const untaxed = computeTotals(&items, &adj, 0.2, false, 15);
    try std.testing.expectApproxEqAbs(@as(f64, 0), untaxed.tax, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 135), untaxed.total, 1e-9);

    try std.testing.expectApproxEqAbs(@as(f64, 80), balanceDue(180, 100), 1e-9);
    try std.testing.expectEqual(@as(f64, 0), balanceDue(180, 200));
}

fn renderForTest(data: InvoiceData) ![]u8 {
    return generateInvoice(std.testing.allocator, data);
}

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

test "an empty buyer collapses in every style" {
    const items = [_]LineItem{.{ .description = "Item", .quantity = 1, .unit_price = 10, .total = 10 }};
    for ([_]Theme{ .classic, .squircle, .glass, .minimal, .letterhead }) |theme| {
        const pdf = try renderForTest(.{ .company_name = "Co", .items = &items, .subtotal = 10, .total = 12, .theme = theme });
        defer std.testing.allocator.free(pdf);
        try std.testing.expect(!contains(pdf, "Bill To"));
        try std.testing.expect(!contains(pdf, "BILL TO"));
        try std.testing.expect(contains(pdf, "Co"));

        // show_client:false hides a buyer that is present.
        const hidden = try renderForTest(.{ .company_name = "Co", .client_name = "Buyer Ltd", .show_client = false, .items = &items, .total = 12, .theme = theme });
        defer std.testing.allocator.free(hidden);
        try std.testing.expect(!contains(hidden, "Buyer Ltd"));

        const shown = try renderForTest(.{ .company_name = "Co", .client_name = "Buyer Ltd", .items = &items, .total = 12, .theme = theme });
        defer std.testing.allocator.free(shown);
        try std.testing.expect(contains(shown, "Buyer Ltd"));
    }
}

test "quote meta reads Valid Until unless overridden" {
    const items = [_]LineItem{.{ .description = "Item", .quantity = 1, .unit_price = 10, .total = 10 }};
    const q = try renderForTest(.{ .document_type = "quote", .due_date = "2026-10-01", .items = &items });
    defer std.testing.allocator.free(q);
    try std.testing.expect(contains(q, "Valid Until:"));
    try std.testing.expect(contains(q, "Quote #:"));

    const inv = try renderForTest(.{ .due_date = "2026-10-01", .items = &items });
    defer std.testing.allocator.free(inv);
    try std.testing.expect(contains(inv, "Due Date:"));

    const custom = try renderForTest(.{ .document_type = "quote", .due_date = "2026-10-01", .due_date_label = "Expires:", .items = &items });
    defer std.testing.allocator.free(custom);
    try std.testing.expect(contains(custom, "Expires:"));
    try std.testing.expect(!contains(custom, "Valid Until"));

    var labels = Labels{};
    labels.due_date = "Vence:";
    const localised = try renderForTest(.{ .document_type = "quote", .due_date = "2026-10-01", .labels = labels, .items = &items });
    defer std.testing.allocator.free(localised);
    try std.testing.expect(contains(localised, "Vence:"));
}

test "units, fractional quantities, discounts and the flat-rate table" {
    const items = [_]LineItem{
        .{ .description = "Consulting", .quantity = 2.5, .unit = "hrs", .unit_price = 80, .total = 180, .discount = 10 },
        .{ .description = "Setup", .quantity = 1, .unit_price = 50, .total = 50 },
    };
    for ([_]Theme{ .classic, .squircle, .glass, .minimal, .letterhead }) |theme| {
        const pdf = try renderForTest(.{ .items = &items, .subtotal = 230, .total = 230, .theme = theme });
        defer std.testing.allocator.free(pdf);
        try std.testing.expect(contains(pdf, "(2.5 hrs)"));
        try std.testing.expect(contains(pdf, "10%"));

        const flat = try renderForTest(.{ .items = &items, .subtotal = 230, .total = 230, .theme = theme, .show_qty_columns = false });
        defer std.testing.allocator.free(flat);
        try std.testing.expect(!contains(flat, "2.5 hrs"));
        try std.testing.expect(contains(flat, "Amount") or contains(flat, "AMOUNT"));
    }
}

test "adjustments, payment rows and the PAID IN FULL mark" {
    const items = [_]LineItem{.{ .description = "Goods", .quantity = 1, .unit_price = 100, .total = 100 }};
    const adj = [_]Adjustment{.{ .label = "Shipping", .amount = 12.5 }};
    for ([_]Theme{ .classic, .squircle, .glass, .minimal, .letterhead }) |theme| {
        const rct = try renderForTest(.{
            .document_type = "receipt",
            .show_tax = false,
            .items = &items,
            .adjustments = &adj,
            .subtotal = 100,
            .total = 112.5,
            .amount_paid = 112.5,
            .payment_method = "Card",
            .theme = theme,
        });
        defer std.testing.allocator.free(rct);
        try std.testing.expect(contains(rct, "Shipping"));
        try std.testing.expect(contains(rct, "PAID IN FULL"));
        try std.testing.expect(contains(rct, "Card"));

        const part = try renderForTest(.{ .items = &items, .total = 120, .amount_paid = 50, .theme = theme });
        defer std.testing.allocator.free(part);
        try std.testing.expect(!contains(part, "PAID IN FULL"));
        try std.testing.expect(contains(part, "70.00"));
    }
}

test "bank details and signature blocks draw only when enabled" {
    const items = [_]LineItem{.{ .description = "Goods", .quantity = 1, .unit_price = 100, .total = 100 }};
    const bank = BankDetails{ .account_name = "Example Ltd", .sort_code = "00-00-00", .account_number = "00000000" };
    for ([_]Theme{ .classic, .squircle, .glass, .minimal, .letterhead }) |theme| {
        const on = try renderForTest(.{ .items = &items, .total = 100, .bank_details = bank, .show_signature = true, .signature_name = "A. Signer", .theme = theme });
        defer std.testing.allocator.free(on);
        try std.testing.expect(contains(on, "00-00-00"));
        try std.testing.expect(contains(on, "A. Signer"));

        const off = try renderForTest(.{ .items = &items, .total = 100, .bank_details = bank, .show_bank_details = false, .theme = theme });
        defer std.testing.allocator.free(off);
        try std.testing.expect(!contains(off, "00-00-00"));
        try std.testing.expect(!contains(off, "signature"));
    }
}

test "notes and payment terms honour newlines" {
    const items = [_]LineItem{.{ .description = "Goods", .quantity = 1, .unit_price = 100, .total = 100 }};
    const pdf = try renderForTest(.{ .items = &items, .total = 100, .notes = "First line\nSecond line", .payment_terms = "Net 14\r\n\r\nBank transfer" });
    defer std.testing.allocator.free(pdf);
    try std.testing.expect(contains(pdf, "(First line)"));
    try std.testing.expect(contains(pdf, "(Second line)"));
    try std.testing.expect(contains(pdf, "(Net 14)"));
    try std.testing.expect(contains(pdf, "(Bank transfer)"));
}

test "long tables paginate in every style with page numbers in the typographic ones" {
    var items: [40]LineItem = undefined;
    for (&items, 0..) |*it, i| {
        _ = i;
        it.* = .{ .description = "A line item with a description long enough to be realistic", .quantity = 1, .unit_price = 10, .total = 10 };
    }
    for ([_]Theme{ .classic, .squircle, .glass, .minimal, .letterhead }) |theme| {
        const pdf = try renderForTest(.{ .company_name = "Co", .items = &items, .subtotal = 400, .total = 400, .theme = theme });
        defer std.testing.allocator.free(pdf);
        try std.testing.expect(contains(pdf, "/Count 2") or contains(pdf, "/Count 3"));
        if (theme == .minimal or theme == .letterhead) try std.testing.expect(contains(pdf, "Page 1 of "));
    }
}
