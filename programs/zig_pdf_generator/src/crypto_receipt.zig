//! Sovereign Document Engine - Crypto Transaction PDF Generator
//! Generates professional, branded PDF documents for cryptocurrency transactions
//! with embedded identicons, QR codes, and clickable hyperlinks.
//!
//! Supports multiple document types and all major blockchain networks.
//! Part of the Quantum Vault ecosystem.

const std = @import("std");
const Allocator = std.mem.Allocator;
const document = @import("document.zig");
const identicon = @import("identicon.zig");
const qrcode = @import("qrcode.zig");

// ============================================================================
// Document Types
// ============================================================================

/// Document type determines the title and layout style
pub const DocumentType = enum {
    transaction_receipt,
    payment_request,
    payment_confirmation,
    wallet_statement,
    transfer_notice,

    pub fn title(self: DocumentType) []const u8 {
        return switch (self) {
            .transaction_receipt => "Transaction Receipt",
            .payment_request => "Payment Request",
            .payment_confirmation => "Payment Confirmation",
            .wallet_statement => "Wallet Statement",
            .transfer_notice => "Transfer Notice",
        };
    }

    pub fn fromString(s: []const u8) DocumentType {
        if (std.mem.eql(u8, s, "payment_request")) return .payment_request;
        if (std.mem.eql(u8, s, "payment_confirmation")) return .payment_confirmation;
        if (std.mem.eql(u8, s, "wallet_statement")) return .wallet_statement;
        if (std.mem.eql(u8, s, "transfer_notice")) return .transfer_notice;
        return .transaction_receipt;
    }
};

// ============================================================================
// Supported Networks - All Major Chains
// ============================================================================

/// Supported cryptocurrency networks with brand colors and symbols
pub const Network = enum {
    // Major chains
    bitcoin,
    ethereum,
    polygon,
    litecoin,
    solana,
    tron,
    dogecoin,
    cardano,
    xrp,
    bnb,
    // Stablecoins
    usdt,
    usdc,
    // Legacy/Other
    bitcoin_cash,
    lightning,
    custom,

    /// Official ticker symbol
    pub fn symbol(self: Network) []const u8 {
        return switch (self) {
            .bitcoin => "BTC",
            .ethereum => "ETH",
            .polygon => "MATIC",
            .litecoin => "LTC",
            .solana => "SOL",
            .tron => "TRX",
            .dogecoin => "DOGE",
            .cardano => "ADA",
            .xrp => "XRP",
            .bnb => "BNB",
            .usdt => "USDT",
            .usdc => "USDC",
            .bitcoin_cash => "BCH",
            .lightning => "BTC",
            .custom => "",
        };
    }

    /// Official brand color (hex)
    pub fn color(self: Network) []const u8 {
        return switch (self) {
            .bitcoin => "#f7931a", // Bitcoin orange
            .ethereum => "#627eea", // Ethereum blue
            .polygon => "#8247e5", // Polygon purple
            .litecoin => "#345d9d", // Litecoin blue
            .solana => "#9945ff", // Solana purple
            .tron => "#eb0029", // Tron red
            .dogecoin => "#c2a633", // Doge gold
            .cardano => "#0033ad", // Cardano blue
            .xrp => "#23292f", // XRP dark
            .bnb => "#f3ba2f", // BNB yellow
            .usdt => "#26a17b", // Tether green
            .usdc => "#2775ca", // USDC blue
            .bitcoin_cash => "#8dc351", // BCH green
            .lightning => "#792de4", // Lightning purple
            .custom => "#6b21a8", // Quantum purple
        };
    }

    /// Display name for headers
    pub fn displayName(self: Network) []const u8 {
        return switch (self) {
            .bitcoin => "Bitcoin Network",
            .ethereum => "Ethereum Network",
            .polygon => "Polygon Network",
            .litecoin => "Litecoin Network",
            .solana => "Solana Network",
            .tron => "Tron Network",
            .dogecoin => "Dogecoin Network",
            .cardano => "Cardano Network",
            .xrp => "XRP Ledger",
            .bnb => "BNB Chain",
            .usdt => "Tether (USDT)",
            .usdc => "USD Coin (USDC)",
            .bitcoin_cash => "Bitcoin Cash Network",
            .lightning => "Lightning Network",
            .custom => "Blockchain Network",
        };
    }

    /// Unicode symbol for display
    pub fn unicodeSymbol(self: Network) []const u8 {
        return switch (self) {
            .bitcoin, .bitcoin_cash, .lightning => "₿",
            .ethereum => "Ξ",
            .litecoin => "Ł",
            .dogecoin => "Ð",
            .cardano => "₳",
            .usdt, .usdc => "$",
            else => "◈",
        };
    }

    pub fn fromString(s: []const u8) Network {
        const lower = s; // Assume lowercase input
        if (std.mem.eql(u8, lower, "bitcoin") or std.mem.eql(u8, lower, "btc")) return .bitcoin;
        if (std.mem.eql(u8, lower, "ethereum") or std.mem.eql(u8, lower, "eth")) return .ethereum;
        if (std.mem.eql(u8, lower, "polygon") or std.mem.eql(u8, lower, "matic")) return .polygon;
        if (std.mem.eql(u8, lower, "litecoin") or std.mem.eql(u8, lower, "ltc")) return .litecoin;
        if (std.mem.eql(u8, lower, "solana") or std.mem.eql(u8, lower, "sol")) return .solana;
        if (std.mem.eql(u8, lower, "tron") or std.mem.eql(u8, lower, "trx")) return .tron;
        if (std.mem.eql(u8, lower, "dogecoin") or std.mem.eql(u8, lower, "doge")) return .dogecoin;
        if (std.mem.eql(u8, lower, "cardano") or std.mem.eql(u8, lower, "ada")) return .cardano;
        if (std.mem.eql(u8, lower, "xrp") or std.mem.eql(u8, lower, "ripple")) return .xrp;
        if (std.mem.eql(u8, lower, "bnb") or std.mem.eql(u8, lower, "binance")) return .bnb;
        if (std.mem.eql(u8, lower, "usdt") or std.mem.eql(u8, lower, "tether")) return .usdt;
        if (std.mem.eql(u8, lower, "usdc")) return .usdc;
        if (std.mem.eql(u8, lower, "bitcoin_cash") or std.mem.eql(u8, lower, "bch")) return .bitcoin_cash;
        if (std.mem.eql(u8, lower, "lightning") or std.mem.eql(u8, lower, "ln")) return .lightning;
        return .custom;
    }
};

// ============================================================================
// Document Data Structure
// ============================================================================

/// Crypto transaction document data
pub const CryptoReceiptData = struct {
    // Document type (determines title)
    document_type: DocumentType = .transaction_receipt,

    // Required transaction details
    tx_hash: []const u8,
    from_address: []const u8,
    to_address: []const u8,
    amount: []const u8,
    symbol: []const u8 = "BTC",
    network: Network = .bitcoin,

    // Optional transaction details
    timestamp: ?[]const u8 = null,
    confirmations: ?u32 = null,
    block_height: ?u64 = null,
    network_fee: ?[]const u8 = null,
    fee_symbol: ?[]const u8 = null,

    // Fiat conversion (optional)
    fiat_value: ?f64 = null,
    fiat_symbol: []const u8 = "USD",
    exchange_rate: ?f64 = null,

    // Memo/note
    memo: ?[]const u8 = null,

    // QR code content (auto-generated from tx_hash if null)
    qr_content: ?[]const u8 = null,

    // Styling overrides
    primary_color: ?[]const u8 = null, // Default: network brand color
    secondary_color: []const u8 = "#2c3e50",
    show_identicons: bool = true,

    // Custom title override (null = use document_type title)
    custom_title: ?[]const u8 = null,
    footer_text: ?[]const u8 = null,

    /// Get the document title
    pub fn getTitle(self: *const CryptoReceiptData) []const u8 {
        return self.custom_title orelse self.document_type.title();
    }
};

/// Crypto Receipt Renderer
pub const CryptoReceiptRenderer = struct {
    allocator: Allocator,
    data: CryptoReceiptData,
    doc: document.PdfDocument,
    content: document.ContentStream,

    // Font IDs
    font_regular: []const u8 = "F0",
    font_bold: []const u8 = "F1",
    font_mono: []const u8 = "F2",

    // Image IDs for identicons and QR
    from_identicon_id: ?[]const u8 = null,
    to_identicon_id: ?[]const u8 = null,
    qr_id: ?[]const u8 = null,

    // Pixel data that needs to be freed after build()
    from_pixels: ?[]u8 = null,
    to_pixels: ?[]u8 = null,
    qr_pixels: ?[]u8 = null,

    // Page dimensions
    const PAGE_WIDTH: f32 = document.A4_WIDTH;
    const PAGE_HEIGHT: f32 = document.A4_HEIGHT;
    const MARGIN: f32 = 50;
    const CONTENT_WIDTH: f32 = PAGE_WIDTH - 2 * MARGIN;

    pub fn init(allocator: Allocator, data: CryptoReceiptData) CryptoReceiptRenderer {
        const doc = document.PdfDocument.init(allocator);
        const content = document.ContentStream.init(allocator);

        return .{
            .allocator = allocator,
            .data = data,
            .doc = doc,
            .content = content,
        };
    }

    pub fn deinit(self: *CryptoReceiptRenderer) void {
        // Free pixel data that was kept alive for build()
        if (self.from_pixels) |p| self.allocator.free(p);
        if (self.to_pixels) |p| self.allocator.free(p);
        if (self.qr_pixels) |p| self.allocator.free(p);

        self.content.deinit();
        self.doc.deinit();
    }

    /// Generate the receipt PDF
    pub fn render(self: *CryptoReceiptRenderer) ![]const u8 {
        // Register fonts
        self.font_regular = self.doc.getFontId(.helvetica);
        self.font_bold = self.doc.getFontId(.helvetica_bold);
        self.font_mono = self.doc.getFontId(.courier);

        // Generate and add identicons if enabled
        if (self.data.show_identicons) {
            try self.generateIdenticons();
        }

        // Generate and add QR code
        try self.generateQrCode();

        // Get primary color (from data or network default)
        const primary_hex = self.data.primary_color orelse self.data.network.color();
        const primary = document.Color.fromHex(primary_hex);
        const secondary = document.Color.fromHex(self.data.secondary_color);

        var y: f32 = PAGE_HEIGHT - MARGIN;

        // === HEADER ===
        y = try self.drawHeader(y, primary);

        // === FROM/TO SECTION ===
        y = try self.drawAddresses(y, secondary);

        // === AMOUNT SECTION ===
        y = try self.drawAmount(y, primary);

        // === TRANSACTION DETAILS ===
        y = try self.drawTransactionDetails(y, secondary);

        // === MEMO (if present) ===
        if (self.data.memo) |memo| {
            y = try self.drawMemo(y, memo, secondary);
        }

        // === FOOTER ===
        _ = try self.drawFooter(secondary);

        // Add page to document
        try self.doc.addPage(&self.content);

        // Build and return PDF
        return self.doc.build();
    }

    fn drawHeader(self: *CryptoReceiptRenderer, start_y: f32, color: document.Color) !f32 {
        var y = start_y;

        // Main Title - Large, prominent, centered
        const title = self.data.getTitle();
        const title_width = estimateTextWidth(title, 28);
        try self.content.drawText(
            title,
            (PAGE_WIDTH - title_width) / 2,
            y,
            self.font_bold,
            28,
            color,
        );
        y -= 35;

        // Network subtitle - Smaller, spaced down, centered
        const network_name = self.data.network.displayName();
        const network_width = estimateTextWidth(network_name, 11);
        try self.content.drawText(
            network_name,
            (PAGE_WIDTH - network_width) / 2,
            y,
            self.font_regular,
            11,
            document.Color.fromHex("#888888"),
        );
        y -= 25;

        // Separator line - Network brand color
        try self.content.drawLine(
            MARGIN + 50,
            y,
            PAGE_WIDTH - MARGIN - 50,
            y,
            color,
            2.0,
        );
        y -= 35;

        return y;
    }

    fn drawAddresses(self: *CryptoReceiptRenderer, start_y: f32, color: document.Color) !f32 {
        var y = start_y;
        const col_width = CONTENT_WIDTH / 2 - 20;

        // For payment requests, only show the receiving address (centered)
        const is_payment_request = self.data.document_type == .payment_request;

        if (is_payment_request) {
            // Single address layout - centered "Pay To" address
            const label = "Pay To:";
            const label_width = estimateTextWidth(label, 12);
            try self.content.drawText(label, (PAGE_WIDTH - label_width) / 2, y, self.font_bold, 12, color);
            y -= 20;

            // Draw identicon centered (if available)
            if (self.data.show_identicons) {
                const icon_size: f32 = 64; // Larger for single address
                if (self.to_identicon_id) |id| {
                    try self.content.drawImage(id, (PAGE_WIDTH - icon_size) / 2, y - icon_size, icon_size, icon_size);
                }
                y -= 85; // 64px icon + 21px gap before address
            }

            // Full address (not truncated) - centered
            const to_display = self.data.to_address;
            const addr_width = estimateTextWidth(to_display, 9);
            // If address is too wide, truncate it
            if (addr_width > CONTENT_WIDTH) {
                const truncated = truncateAddress(to_display);
                const trunc_width = estimateTextWidth(truncated, 9);
                try self.content.drawText(truncated, (PAGE_WIDTH - trunc_width) / 2, y, self.font_mono, 9, document.Color.black);
            } else {
                try self.content.drawText(to_display, (PAGE_WIDTH - addr_width) / 2, y, self.font_mono, 9, document.Color.black);
            }
            y -= 40;
        } else {
            // Standard two-column layout for receipts/confirmations
            // "From" label
            try self.content.drawText("From:", MARGIN, y, self.font_bold, 12, color);
            // "To" label
            try self.content.drawText("To:", MARGIN + col_width + 40, y, self.font_bold, 12, color);
            y -= 20;

            // Draw identicons (if available)
            if (self.data.show_identicons) {
                const icon_size: f32 = 48;
                if (self.from_identicon_id) |id| {
                    try self.content.drawImage(id, MARGIN, y - icon_size, icon_size, icon_size);
                }
                if (self.to_identicon_id) |id| {
                    try self.content.drawImage(id, MARGIN + col_width + 40, y - icon_size, icon_size, icon_size);
                }
                y -= 65; // 48px icon + 17px gap before address
            }

            // Truncate addresses for display
            const from_display = truncateAddress(self.data.from_address);
            const to_display = truncateAddress(self.data.to_address);

            try self.content.drawText(from_display, MARGIN, y, self.font_mono, 9, document.Color.black);
            try self.content.drawText(to_display, MARGIN + col_width + 40, y, self.font_mono, 9, document.Color.black);
            y -= 40;
        }

        return y;
    }

    fn drawAmount(self: *CryptoReceiptRenderer, start_y: f32, color: document.Color) !f32 {
        var y = start_y;

        // Amount box background
        try self.content.drawRect(
            MARGIN,
            y - 60,
            CONTENT_WIDTH,
            60,
            document.Color.fromHex("#f8f9fa"),
            null,
        );

        // Amount label
        try self.content.drawText("Amount", MARGIN + 15, y - 20, self.font_regular, 11, document.Color.fromHex("#666666"));

        // Amount value with symbol
        var amount_buf: [128]u8 = undefined;
        const amount_str = std.fmt.bufPrint(&amount_buf, "{s} {s}", .{ self.data.amount, self.data.symbol }) catch self.data.amount;
        try self.content.drawText(amount_str, MARGIN + 15, y - 45, self.font_bold, 20, color);

        // Fiat value (if available)
        if (self.data.fiat_value) |fiat| {
            var fiat_buf: [64]u8 = undefined;
            const fiat_str = std.fmt.bufPrint(&fiat_buf, "{s} {d:.2}", .{ self.data.fiat_symbol, fiat }) catch "";
            try self.content.drawText(fiat_str, MARGIN + 250, y - 45, self.font_regular, 14, document.Color.fromHex("#666666"));
        }

        y -= 80;
        return y;
    }

    fn drawTransactionDetails(self: *CryptoReceiptRenderer, start_y: f32, color: document.Color) !f32 {
        var y = start_y;

        // Section header
        try self.content.drawText("Transaction Details", MARGIN, y, self.font_bold, 14, color);
        y -= 25;

        // Transaction hash
        try self.content.drawText("Transaction Hash:", MARGIN, y, self.font_regular, 10, document.Color.fromHex("#666666"));
        y -= 15;
        const tx_display = truncateHash(self.data.tx_hash);
        try self.content.drawText(tx_display, MARGIN, y, self.font_mono, 9, document.Color.black);
        y -= 25;

        // Draw QR code on the right
        if (self.qr_id) |qr| {
            const qr_size: f32 = 100;
            try self.content.drawImage(qr, PAGE_WIDTH - MARGIN - qr_size, y + 60, qr_size, qr_size);
        }

        // Timestamp
        if (self.data.timestamp) |ts| {
            try self.content.drawText("Timestamp:", MARGIN, y, self.font_regular, 10, document.Color.fromHex("#666666"));
            y -= 15;
            try self.content.drawText(ts, MARGIN, y, self.font_regular, 10, document.Color.black);
            y -= 20;
        }

        // Confirmations
        if (self.data.confirmations) |conf| {
            try self.content.drawText("Confirmations:", MARGIN, y, self.font_regular, 10, document.Color.fromHex("#666666"));
            y -= 15;
            var conf_buf: [32]u8 = undefined;
            const conf_str = std.fmt.bufPrint(&conf_buf, "{d}", .{conf}) catch "?";
            const status = if (conf >= 6) " (confirmed)" else if (conf >= 1) " (pending)" else " (unconfirmed)";
            var status_buf: [64]u8 = undefined;
            const full_status = std.fmt.bufPrint(&status_buf, "{s}{s}", .{ conf_str, status }) catch conf_str;
            try self.content.drawText(full_status, MARGIN, y, self.font_regular, 10, document.Color.black);
            y -= 20;
        }

        // Block height
        if (self.data.block_height) |height| {
            try self.content.drawText("Block Height:", MARGIN, y, self.font_regular, 10, document.Color.fromHex("#666666"));
            y -= 15;
            var height_buf: [32]u8 = undefined;
            const height_str = std.fmt.bufPrint(&height_buf, "{d}", .{height}) catch "?";
            try self.content.drawText(height_str, MARGIN, y, self.font_regular, 10, document.Color.black);
            y -= 20;
        }

        // Network fee
        if (self.data.network_fee) |fee| {
            try self.content.drawText("Network Fee:", MARGIN, y, self.font_regular, 10, document.Color.fromHex("#666666"));
            y -= 15;
            var fee_buf: [64]u8 = undefined;
            const fee_sym = self.data.fee_symbol orelse self.data.symbol;
            const fee_str = std.fmt.bufPrint(&fee_buf, "{s} {s}", .{ fee, fee_sym }) catch fee;
            try self.content.drawText(fee_str, MARGIN, y, self.font_regular, 10, document.Color.black);
            y -= 20;
        }

        return y;
    }

    fn drawMemo(self: *CryptoReceiptRenderer, start_y: f32, memo: []const u8, color: document.Color) !f32 {
        var y = start_y - 20;

        // Separator
        try self.content.drawLine(MARGIN, y + 10, PAGE_WIDTH - MARGIN, y + 10, document.Color.fromHex("#eeeeee"), 0.5);

        try self.content.drawText("Memo:", MARGIN, y, self.font_bold, 11, color);
        y -= 18;
        try self.content.drawText(memo, MARGIN, y, self.font_regular, 10, document.Color.black);
        y -= 25;

        return y;
    }

    fn drawFooter(self: *CryptoReceiptRenderer, color: document.Color) !f32 {
        _ = color;
        var y: f32 = MARGIN + 55;

        // ══════════════════════════════════════════════════════════════════
        // THE SOVEREIGN SEAL - Quantum Vault Branding
        // ══════════════════════════════════════════════════════════════════

        // Top separator line
        try self.content.drawLine(
            MARGIN + 80,
            y + 30,
            PAGE_WIDTH - MARGIN - 80,
            y + 30,
            document.Color.fromHex("#e0e0e0"),
            0.5,
        );

        // Custom footer text (if provided) - centered above branding
        if (self.data.footer_text) |footer| {
            const footer_width = estimateTextWidth(footer, 8);
            try self.content.drawText(
                footer,
                (PAGE_WIDTH - footer_width) / 2,
                y + 15,
                self.font_regular,
                8,
                document.Color.fromHex("#999999"),
            );
        }

        // Brand name - "Quantum Vault" - centered, bold, purple
        const brand_name = "Quantum Vault";
        const brand_width = estimateTextWidth(brand_name, 14);
        try self.content.drawText(
            brand_name,
            (PAGE_WIDTH - brand_width) / 2,
            y - 5,
            self.font_bold,
            14,
            document.Color.fromHex("#6b21a8"), // Quantum purple
        );

        y -= 18;

        // Tagline - centered, elegant gray
        const tagline = "Your keys, your coins, your edge.";
        const tagline_width = estimateTextWidth(tagline, 10);
        try self.content.drawText(
            tagline,
            (PAGE_WIDTH - tagline_width) / 2,
            y,
            self.font_regular,
            10,
            document.Color.fromHex("#666666"),
        );

        y -= 18;

        // URL - centered, clickable blue (will be hyperlinked)
        const url = "quantumencoding.io/software/quantum-vault";
        const url_width = estimateTextWidth(url, 9);
        const url_x = (PAGE_WIDTH - url_width) / 2;
        try self.content.drawText(
            url,
            url_x,
            y,
            self.font_mono,
            9,
            document.Color.fromHex("#2563eb"), // Link blue
        );

        // Store URL position for hyperlink annotation
        // (Hyperlink will be added via PDF annotation in document)
        self.doc.addLinkAnnotation(
            url_x,
            y - 3,
            url_x + url_width,
            y + 10,
            "https://quantumencoding.io/software/quantum-vault",
        ) catch {};

        return y;
    }

    fn generateIdenticons(self: *CryptoReceiptRenderer) !void {
        const is_payment_request = self.data.document_type == .payment_request;

        // Generate "from" identicon only for non-payment-request documents
        // (payment requests don't have a "from" address to show)
        if (!is_payment_request) {
            const from_icon = try identicon.generate(self.allocator, self.data.from_address, .{ .scale = 8 });
            self.from_pixels = from_icon.pixels;

            const from_img = document.Image{
                .width = from_icon.width,
                .height = from_icon.height,
                .format = .raw_rgb,
                .data = from_icon.pixels,
            };
            self.from_identicon_id = try self.doc.addImage(from_img);
        }

        // Generate "to" identicon - pixels freed in deinit()
        // Use larger scale for payment requests (displayed centered and larger)
        const to_scale: u8 = if (is_payment_request) 10 else 8;
        const to_icon = try identicon.generate(self.allocator, self.data.to_address, .{ .scale = to_scale });
        self.to_pixels = to_icon.pixels;

        const to_img = document.Image{
            .width = to_icon.width,
            .height = to_icon.height,
            .format = .raw_rgb,
            .data = to_icon.pixels,
        };
        self.to_identicon_id = try self.doc.addImage(to_img);
    }

    fn generateQrCode(self: *CryptoReceiptRenderer) !void {
        // Determine QR content
        const qr_content = self.data.qr_content orelse self.data.tx_hash;

        // Generate QR code - pixels freed in deinit()
        const qr_img = try qrcode.encodeAndRender(self.allocator, qr_content, 4, .{ .ec_level = .M, .quiet_zone = 2 });
        self.qr_pixels = qr_img.pixels;

        const img = document.Image{
            .width = qr_img.width,
            .height = qr_img.height,
            .format = .raw_rgb,
            .data = qr_img.pixels,
        };
        self.qr_id = try self.doc.addImage(img);
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

/// Estimate text width for centering (approximate, based on Helvetica metrics)
/// Returns width in PDF points
fn estimateTextWidth(text: []const u8, font_size: f32) f32 {
    // Average character width for Helvetica is ~0.5 * font_size
    // Adjust for common characters (rough approximation)
    var width: f32 = 0;
    for (text) |c| {
        const char_width: f32 = switch (c) {
            'i', 'l', 'I', '1', '.', ',', ':', ';', '!' => 0.3,
            'm', 'w', 'M', 'W' => 0.85,
            ' ' => 0.3,
            else => 0.55,
        };
        width += char_width * font_size;
    }
    return width;
}

/// Truncate address for display (first 8 + ... + last 6 chars)
fn truncateAddress(addr: []const u8) []const u8 {
    if (addr.len <= 20) return addr;
    // For display, we'd need to allocate. For now return full address.
    return addr;
}

/// Truncate transaction hash for display
fn truncateHash(hash: []const u8) []const u8 {
    if (hash.len <= 30) return hash;
    return hash;
}

/// Generate crypto receipt PDF from data
pub fn generateReceipt(allocator: Allocator, data: CryptoReceiptData) ![]u8 {
    var renderer = CryptoReceiptRenderer.init(allocator, data);
    defer renderer.deinit();

    const pdf = try renderer.render();
    return try allocator.dupe(u8, pdf);
}

// ============================================================================
// Tests
// ============================================================================

test "generate basic receipt" {
    const allocator = std.testing.allocator;

    const data = CryptoReceiptData{
        .tx_hash = "abc123def456789012345678901234567890",
        .from_address = "bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq",
        .to_address = "bc1qc7slrfxkknqcq2jevvvkdgvrt8080852dfjewde",
        .amount = "0.12345678",
        .symbol = "BTC",
        .network = .bitcoin,
        .timestamp = "2025-01-04 12:34:56 UTC",
        .confirmations = 6,
        .block_height = 823456,
        .network_fee = "0.00001234",
        .fiat_value = 5432.10,
    };

    const pdf = try generateReceipt(allocator, data);
    defer allocator.free(pdf);

    try std.testing.expect(pdf.len > 0);
    try std.testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4"));
}

test "network colors" {
    try std.testing.expectEqualStrings("#f7931a", Network.bitcoin.color());
    try std.testing.expectEqualStrings("#627eea", Network.ethereum.color());
}
