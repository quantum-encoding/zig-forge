//! Stock Transfer Form (J30) Generator
//!
//! Generates UK Stock Transfer Forms for share transfers with:
//! - Transferor (seller) details
//! - Transferee (buyer) details
//! - Share/stock description
//! - Consideration amount
//! - SDRT certification
//! - Signature blocks
//!
//! Usage:
//! ```zig
//! const transfer_data = StockTransferData{
//!     .transfer = .{ .date = "1 January 2026" },
//!     .company = .{ .name = "QUANTUM ENCODING LTD", ... },
//!     .transferor = .{ .name = "Mr John Smith", ... },
//!     .transferee = .{ .name = "Ms Jane Doe", ... },
//!     .shares = .{ .quantity = 100, .class = "Ordinary", ... },
//!     .consideration = .{ .amount = 1000.00, ... },
//! };
//! const pdf = try generateStockTransfer(allocator, transfer_data);
//! ```

const std = @import("std");
const document = @import("document.zig");

// =============================================================================
// Data Structures
// =============================================================================

/// Address structure
pub const Address = struct {
    line1: []const u8 = "",
    line2: ?[]const u8 = null,
    city: ?[]const u8 = null,
    county: ?[]const u8 = null,
    postcode: []const u8 = "",
    country: []const u8 = "United Kingdom",

    /// Format address as multiline
    pub fn formatMultiLine(self: Address, allocator: std.mem.Allocator) ![]const u8 {
        var lines: std.ArrayListUnmanaged([]const u8) = .empty;
        defer lines.deinit(allocator);

        if (self.line1.len > 0) try lines.append(allocator, self.line1);
        if (self.line2) |l2| if (l2.len > 0) try lines.append(allocator, l2);
        if (self.city) |c| if (c.len > 0) try lines.append(allocator, c);
        if (self.postcode.len > 0) try lines.append(allocator, self.postcode);

        var total_len: usize = 0;
        for (lines.items, 0..) |line, i| {
            total_len += line.len;
            if (i < lines.items.len - 1) total_len += 2; // ", "
        }

        var result = try allocator.alloc(u8, total_len);
        var pos: usize = 0;
        for (lines.items, 0..) |line, i| {
            @memcpy(result[pos..][0..line.len], line);
            pos += line.len;
            if (i < lines.items.len - 1) {
                result[pos] = ',';
                result[pos + 1] = ' ';
                pos += 2;
            }
        }

        return result;
    }
};

/// Template styling options
pub const TemplateStyle = struct {
    primary_color: []const u8 = "#1a3c5f", // Dark blue
    accent_color: []const u8 = "#2563eb", // Blue
    font_family: []const u8 = "Helvetica",
};

/// Template configuration
pub const Template = struct {
    id: []const u8 = "stock_transfer_j30",
    version: []const u8 = "1.0.0",
    style: TemplateStyle = .{},
};

/// Transfer metadata
pub const Transfer = struct {
    reference: ?[]const u8 = null,
    date: []const u8,
};

/// Company whose shares are being transferred
pub const Company = struct {
    name: []const u8,
    registration_number: ?[]const u8 = null,
};

/// Party type (transferor or transferee)
pub const PartyType = enum {
    Individual,
    Company,
    Trust,
    Partnership,

    pub fn toString(self: PartyType) []const u8 {
        return switch (self) {
            .Individual => "Individual",
            .Company => "Company",
            .Trust => "Trust",
            .Partnership => "Partnership",
        };
    }

    pub fn fromString(s: []const u8) PartyType {
        if (std.mem.eql(u8, s, "Company")) return .Company;
        if (std.mem.eql(u8, s, "Trust")) return .Trust;
        if (std.mem.eql(u8, s, "Partnership")) return .Partnership;
        return .Individual;
    }
};

/// Transferor (seller) information
pub const Transferor = struct {
    name: []const u8,
    address: Address,
    party_type: PartyType = .Individual,
};

/// Transferee (buyer) information
pub const Transferee = struct {
    name: []const u8,
    address: Address,
    party_type: PartyType = .Individual,
};

/// Share details
pub const Shares = struct {
    quantity: u32,
    class: []const u8 = "Ordinary",
    nominal_value: f64 = 0.01,
    currency: []const u8 = "GBP",
    description: ?[]const u8 = null, // e.g., "Fully paid Ordinary shares of GBP 0.01 each"
};

/// Consideration type
pub const ConsiderationType = enum {
    Cash,
    Gift,
    NominalValue,
    MarketValue,
    Other,

    pub fn toString(self: ConsiderationType) []const u8 {
        return switch (self) {
            .Cash => "Cash",
            .Gift => "Gift (no consideration)",
            .NominalValue => "Nominal value",
            .MarketValue => "Market value",
            .Other => "Other",
        };
    }

    pub fn fromString(s: []const u8) ConsiderationType {
        if (std.mem.eql(u8, s, "Gift")) return .Gift;
        if (std.mem.eql(u8, s, "Nominal")) return .NominalValue;
        if (std.mem.eql(u8, s, "Market")) return .MarketValue;
        if (std.mem.eql(u8, s, "Other")) return .Other;
        return .Cash;
    }
};

/// Consideration (payment) details
pub const Consideration = struct {
    type: ConsiderationType = .Cash,
    amount: f64 = 0.0,
    currency: []const u8 = "GBP",
    description: ?[]const u8 = null, // For "Other" type
};

/// SDRT exemption certificate types
pub const ExemptionCategory = enum {
    None,
    CategoryA, // Transfer to beneficial owner
    CategoryB, // Transfer between associated companies
    CategoryC, // Gift
    CategoryD, // Transfer in contemplation of sale
    CategoryE, // Stock lending
    CategoryF, // Depositary interest
    CategoryG, // Pension fund
    Other,

    pub fn toString(self: ExemptionCategory) []const u8 {
        return switch (self) {
            .None => "No exemption claimed",
            .CategoryA => "Category A - Transfer to beneficial owner",
            .CategoryB => "Category B - Associated companies",
            .CategoryC => "Category C - Gift",
            .CategoryD => "Category D - Sale contemplation",
            .CategoryE => "Category E - Stock lending",
            .CategoryF => "Category F - Depositary interest",
            .CategoryG => "Category G - Pension fund",
            .Other => "Other exemption",
        };
    }

    pub fn fromString(s: []const u8) ExemptionCategory {
        if (std.mem.eql(u8, s, "A") or std.mem.eql(u8, s, "CategoryA")) return .CategoryA;
        if (std.mem.eql(u8, s, "B") or std.mem.eql(u8, s, "CategoryB")) return .CategoryB;
        if (std.mem.eql(u8, s, "C") or std.mem.eql(u8, s, "CategoryC")) return .CategoryC;
        if (std.mem.eql(u8, s, "D") or std.mem.eql(u8, s, "CategoryD")) return .CategoryD;
        if (std.mem.eql(u8, s, "E") or std.mem.eql(u8, s, "CategoryE")) return .CategoryE;
        if (std.mem.eql(u8, s, "F") or std.mem.eql(u8, s, "CategoryF")) return .CategoryF;
        if (std.mem.eql(u8, s, "G") or std.mem.eql(u8, s, "CategoryG")) return .CategoryG;
        if (std.mem.eql(u8, s, "Other")) return .Other;
        return .None;
    }
};

/// SDRT Certification
pub const Certification = struct {
    exempt: bool = false,
    exemption_category: ExemptionCategory = .None,
    exemption_details: ?[]const u8 = null,
};

/// Signature information
pub const Signature = struct {
    party: []const u8, // "Transferor" or "Transferee"
    name: []const u8,
    date: []const u8,
    capacity: ?[]const u8 = null, // e.g., "Director" for company transfers
};

/// Complete stock transfer data
pub const StockTransferData = struct {
    template: Template = .{},
    transfer: Transfer,
    company: Company,
    transferor: Transferor,
    transferee: Transferee,
    shares: Shares,
    consideration: Consideration,
    certification: Certification = .{},
    signatures: []const Signature = &[_]Signature{},
};

// =============================================================================
// Stock Transfer Renderer
// =============================================================================

pub const StockTransferRenderer = struct {
    allocator: std.mem.Allocator,
    doc: document.PdfDocument,
    data: StockTransferData,

    // Page dimensions (A4 portrait)
    page_width: f32 = 595,
    page_height: f32 = 842,

    // Margins
    margin: f32 = 40,

    // Font IDs
    font_regular: []const u8 = "F0",
    font_bold: []const u8 = "F1",

    pub fn init(allocator: std.mem.Allocator, data: StockTransferData) StockTransferRenderer {
        var renderer = StockTransferRenderer{
            .allocator = allocator,
            .doc = document.PdfDocument.init(allocator),
            .data = data,
        };

        // Register fonts
        renderer.font_regular = renderer.doc.getFontId(.helvetica);
        renderer.font_bold = renderer.doc.getFontId(.helvetica_bold);

        return renderer;
    }

    pub fn deinit(self: *StockTransferRenderer) void {
        self.doc.deinit();
    }

    /// Draw the form header
    fn drawHeader(self: *StockTransferRenderer, content: *document.ContentStream) !void {
        const primary = document.Color.fromHex(self.data.template.style.primary_color);
        const center_x = self.page_width / 2;
        var y = self.page_height - self.margin;

        // Title
        const title = "STOCK TRANSFER FORM";
        const title_width = document.Font.helvetica_bold.measureText(title, 18);
        try content.drawText(title, center_x - title_width / 2, y, self.font_bold, 18, primary);

        y -= 16;

        // Subtitle
        const subtitle = "(For shares/stock not traded on a recognised stock exchange)";
        const sub_width = document.Font.helvetica.measureText(subtitle, 9);
        const gray = document.Color{ .r = 0.4, .g = 0.4, .b = 0.4 };
        try content.drawText(subtitle, center_x - sub_width / 2, y, self.font_regular, 9, gray);

        y -= 20;

        // Horizontal line
        try content.setStrokeColor(primary);
        try content.setLineWidth(1.0);
        try content.moveTo(self.margin, y);
        try content.lineTo(self.page_width - self.margin, y);
        try content.stroke();
    }

    /// Draw company information section
    fn drawCompanySection(self: *StockTransferRenderer, content: *document.ContentStream) !void {
        const text_color = document.Color{ .r = 0.1, .g = 0.1, .b = 0.1 };
        const label_color = document.Color{ .r = 0.3, .g = 0.3, .b = 0.3 };
        const primary = document.Color.fromHex(self.data.template.style.primary_color);
        var y = self.page_height - self.margin - 60;
        const left_x = self.margin;

        // Section title
        try content.drawText("1. NAME OF UNDERTAKING", left_x, y, self.font_bold, 10, primary);
        y -= 18;

        // Company name
        try content.drawText(self.data.company.name, left_x + 10, y, self.font_bold, 11, text_color);

        if (self.data.company.registration_number) |reg| {
            var buf: [64]u8 = undefined;
            const reg_text = std.fmt.bufPrint(&buf, "(Company No. {s})", .{reg}) catch "";
            try content.drawText(reg_text, left_x + 10, y - 14, self.font_regular, 9, label_color);
        }
    }

    /// Draw shares description section
    fn drawSharesSection(self: *StockTransferRenderer, content: *document.ContentStream) !void {
        const text_color = document.Color{ .r = 0.1, .g = 0.1, .b = 0.1 };
        const primary = document.Color.fromHex(self.data.template.style.primary_color);
        var y = self.page_height - self.margin - 110;
        const left_x = self.margin;

        // Section title
        try content.drawText("2. DESCRIPTION OF SHARES/STOCK", left_x, y, self.font_bold, 10, primary);
        y -= 18;

        // Number of shares
        var qty_buf: [64]u8 = undefined;
        const qty_text = std.fmt.bufPrint(&qty_buf, "{d} {s} shares", .{ self.data.shares.quantity, self.data.shares.class }) catch "";
        try content.drawText(qty_text, left_x + 10, y, self.font_regular, 10, text_color);

        y -= 14;

        // Nominal value
        var val_buf: [64]u8 = undefined;
        const val_text = std.fmt.bufPrint(&val_buf, "Nominal value: {s} {d:.2} each", .{ self.data.shares.currency, self.data.shares.nominal_value }) catch "";
        try content.drawText(val_text, left_x + 10, y, self.font_regular, 10, text_color);

        if (self.data.shares.description) |desc| {
            y -= 14;
            try content.drawText(desc, left_x + 10, y, self.font_regular, 9, text_color);
        }
    }

    /// Draw consideration section
    fn drawConsiderationSection(self: *StockTransferRenderer, content: *document.ContentStream) !void {
        const text_color = document.Color{ .r = 0.1, .g = 0.1, .b = 0.1 };
        const primary = document.Color.fromHex(self.data.template.style.primary_color);
        var y = self.page_height - self.margin - 175;
        const left_x = self.margin;

        // Section title
        try content.drawText("3. CONSIDERATION", left_x, y, self.font_bold, 10, primary);
        y -= 18;

        // Consideration amount
        if (self.data.consideration.type == .Gift) {
            try content.drawText("Gift - Nil consideration", left_x + 10, y, self.font_regular, 10, text_color);
        } else {
            var amount_buf: [64]u8 = undefined;
            const amount_text = std.fmt.bufPrint(&amount_buf, "{s} {d:.2}", .{ self.data.consideration.currency, self.data.consideration.amount }) catch "";
            try content.drawText(amount_text, left_x + 10, y, self.font_bold, 11, text_color);

            y -= 14;
            try content.drawText(self.data.consideration.type.toString(), left_x + 10, y, self.font_regular, 9, text_color);
        }
    }

    /// Draw transferor section
    fn drawTransferorSection(self: *StockTransferRenderer, content: *document.ContentStream) !void {
        const text_color = document.Color{ .r = 0.1, .g = 0.1, .b = 0.1 };
        const label_color = document.Color{ .r = 0.4, .g = 0.4, .b = 0.4 };
        const primary = document.Color.fromHex(self.data.template.style.primary_color);
        var y = self.page_height - self.margin - 230;
        const left_x = self.margin;

        // Section title
        try content.drawText("4. TRANSFEROR(S) - Full name(s) and address(es)", left_x, y, self.font_bold, 10, primary);
        y -= 20;

        // Name
        try content.drawText("Name:", left_x + 10, y, self.font_regular, 9, label_color);
        try content.drawText(self.data.transferor.name, left_x + 60, y, self.font_bold, 10, text_color);

        y -= 16;

        // Address
        try content.drawText("Address:", left_x + 10, y, self.font_regular, 9, label_color);
        const addr = try self.data.transferor.address.formatMultiLine(self.allocator);
        defer self.allocator.free(addr);
        try content.drawText(addr, left_x + 60, y, self.font_regular, 9, text_color);
    }

    /// Draw transferee section
    fn drawTransfereeSection(self: *StockTransferRenderer, content: *document.ContentStream) !void {
        const text_color = document.Color{ .r = 0.1, .g = 0.1, .b = 0.1 };
        const label_color = document.Color{ .r = 0.4, .g = 0.4, .b = 0.4 };
        const primary = document.Color.fromHex(self.data.template.style.primary_color);
        var y = self.page_height - self.margin - 310;
        const left_x = self.margin;

        // Section title
        try content.drawText("5. TRANSFEREE(S) - Full name(s) and address(es)", left_x, y, self.font_bold, 10, primary);
        y -= 20;

        // Name
        try content.drawText("Name:", left_x + 10, y, self.font_regular, 9, label_color);
        try content.drawText(self.data.transferee.name, left_x + 60, y, self.font_bold, 10, text_color);

        y -= 16;

        // Address
        try content.drawText("Address:", left_x + 10, y, self.font_regular, 9, label_color);
        const addr = try self.data.transferee.address.formatMultiLine(self.allocator);
        defer self.allocator.free(addr);
        try content.drawText(addr, left_x + 60, y, self.font_regular, 9, text_color);
    }

    /// Draw certification section
    fn drawCertificationSection(self: *StockTransferRenderer, content: *document.ContentStream) !void {
        const text_color = document.Color{ .r = 0.1, .g = 0.1, .b = 0.1 };
        const primary = document.Color.fromHex(self.data.template.style.primary_color);
        var y = self.page_height - self.margin - 390;
        const left_x = self.margin;

        // Section title
        try content.drawText("6. CERTIFICATION", left_x, y, self.font_bold, 10, primary);
        y -= 18;

        if (self.data.certification.exempt) {
            try content.drawText("Exempt from Stamp Duty", left_x + 10, y, self.font_regular, 10, text_color);
            y -= 14;
            try content.drawText(self.data.certification.exemption_category.toString(), left_x + 10, y, self.font_regular, 9, text_color);
        } else {
            try content.drawText("No stamp duty exemption claimed", left_x + 10, y, self.font_regular, 10, text_color);
        }
    }

    /// Draw signature section
    fn drawSignatureSection(self: *StockTransferRenderer, content: *document.ContentStream) !void {
        const text_color = document.Color{ .r = 0.1, .g = 0.1, .b = 0.1 };
        const label_color = document.Color{ .r = 0.4, .g = 0.4, .b = 0.4 };
        const primary = document.Color.fromHex(self.data.template.style.primary_color);
        var y = self.page_height - self.margin - 460;
        const left_x = self.margin;
        const mid_x = self.page_width / 2 + 20;

        // Section title
        try content.drawText("7. EXECUTION", left_x, y, self.font_bold, 10, primary);
        y -= 25;

        // Transferor signature
        try content.drawText("TRANSFEROR SIGNATURE", left_x, y, self.font_bold, 9, primary);
        try content.drawText("TRANSFEREE SIGNATURE", mid_x, y, self.font_bold, 9, primary);

        y -= 40;

        // Signature lines
        try content.setStrokeColor(label_color);
        try content.setLineWidth(0.5);

        // Transferor line
        try content.moveTo(left_x, y);
        try content.lineTo(left_x + 200, y);
        try content.stroke();

        // Transferee line
        try content.moveTo(mid_x, y);
        try content.lineTo(mid_x + 200, y);
        try content.stroke();

        y -= 15;
        try content.drawText("Signature", left_x, y, self.font_regular, 8, label_color);
        try content.drawText("Signature", mid_x, y, self.font_regular, 8, label_color);

        y -= 25;

        // Name lines
        try content.moveTo(left_x, y);
        try content.lineTo(left_x + 200, y);
        try content.stroke();

        try content.moveTo(mid_x, y);
        try content.lineTo(mid_x + 200, y);
        try content.stroke();

        y -= 15;
        try content.drawText("Print Name", left_x, y, self.font_regular, 8, label_color);
        try content.drawText("Print Name", mid_x, y, self.font_regular, 8, label_color);

        y -= 25;

        // Date lines
        try content.moveTo(left_x, y);
        try content.lineTo(left_x + 200, y);
        try content.stroke();

        try content.moveTo(mid_x, y);
        try content.lineTo(mid_x + 200, y);
        try content.stroke();

        y -= 15;
        try content.drawText("Date", left_x, y, self.font_regular, 8, label_color);
        try content.drawText("Date", mid_x, y, self.font_regular, 8, label_color);

        // Fill in signatures if provided
        if (self.data.signatures.len > 0) {
            for (self.data.signatures) |sig| {
                const sig_x = if (std.mem.eql(u8, sig.party, "Transferor")) left_x else mid_x;
                const sig_y = self.page_height - self.margin - 500;

                try content.drawText(sig.name, sig_x + 5, sig_y + 25, self.font_regular, 9, text_color);
                try content.drawText(sig.date, sig_x + 5, sig_y - 25, self.font_regular, 9, text_color);
            }
        }
    }

    /// Draw footer
    fn drawFooter(self: *StockTransferRenderer, content: *document.ContentStream) !void {
        const gray = document.Color{ .r = 0.5, .g = 0.5, .b = 0.5 };
        const center_x = self.page_width / 2;
        var y = self.margin + 30;

        // Transfer date
        var date_buf: [64]u8 = undefined;
        const date_text = std.fmt.bufPrint(&date_buf, "Transfer Date: {s}", .{self.data.transfer.date}) catch "";
        const date_width = document.Font.helvetica.measureText(date_text, 9);
        try content.drawText(date_text, center_x - date_width / 2, y, self.font_regular, 9, gray);

        y -= 14;

        // Reference if provided
        if (self.data.transfer.reference) |ref| {
            var ref_buf: [64]u8 = undefined;
            const ref_text = std.fmt.bufPrint(&ref_buf, "Reference: {s}", .{ref}) catch "";
            const ref_width = document.Font.helvetica.measureText(ref_text, 8);
            try content.drawText(ref_text, center_x - ref_width / 2, y, self.font_regular, 8, gray);
        }
    }

    /// Render the complete form
    pub fn render(self: *StockTransferRenderer) ![]const u8 {
        var content = document.ContentStream.init(self.allocator);
        defer content.deinit();

        // Set page size to A4 portrait
        self.doc.setPageSize(.{ .width = 595, .height = 842 });

        // Draw all sections
        try self.drawHeader(&content);
        try self.drawCompanySection(&content);
        try self.drawSharesSection(&content);
        try self.drawConsiderationSection(&content);
        try self.drawTransferorSection(&content);
        try self.drawTransfereeSection(&content);
        try self.drawCertificationSection(&content);
        try self.drawSignatureSection(&content);
        try self.drawFooter(&content);

        // Add page to document
        try self.doc.addPage(&content);

        return self.doc.build();
    }
};

// =============================================================================
// Public API
// =============================================================================

/// Generate a stock transfer form PDF
pub fn generateStockTransfer(allocator: std.mem.Allocator, data: StockTransferData) ![]u8 {
    var renderer = StockTransferRenderer.init(allocator, data);
    defer renderer.deinit();

    const pdf_output = try renderer.render();
    return try allocator.dupe(u8, pdf_output);
}

/// Generate stock transfer form from JSON string
pub fn generateStockTransferFromJson(allocator: std.mem.Allocator, json_str: []const u8) ![]u8 {
    const result = try parseStockTransferJson(allocator, json_str);
    defer freeStockTransferData(allocator, &result.data, &result.tracking);
    return generateStockTransfer(allocator, result.data);
}

/// Generate a demo stock transfer form
pub fn generateDemoStockTransfer(allocator: std.mem.Allocator) ![]u8 {
    const signatures = [_]Signature{
        .{ .party = "Transferor", .name = "RICHARD ALEXANDER TUNE", .date = "1 January 2026" },
        .{ .party = "Transferee", .name = "LANCE JOHN PEARSON", .date = "1 January 2026" },
    };

    const data = StockTransferData{
        .template = .{
            .style = .{
                .primary_color = "#1a3c5f",
                .accent_color = "#2563eb",
            },
        },
        .transfer = .{
            .reference = "STF-2026-001",
            .date = "1 January 2026",
        },
        .company = .{
            .name = "QUANTUM ENCODING LTD",
            .registration_number = "16575953",
        },
        .transferor = .{
            .name = "RICHARD ALEXANDER TUNE",
            .address = .{
                .line1 = "COIN",
                .city = "MALAGA",
                .postcode = "29100",
                .country = "SPAIN",
            },
            .party_type = .Individual,
        },
        .transferee = .{
            .name = "LANCE JOHN PEARSON",
            .address = .{
                .line1 = "172 SEA FRONT",
                .city = "HAYLING ISLAND",
                .postcode = "PO11 9HP",
                .country = "United Kingdom",
            },
            .party_type = .Individual,
        },
        .shares = .{
            .quantity = 5,
            .class = "Ordinary",
            .nominal_value = 0.01,
            .currency = "GBP",
            .description = "Fully paid Ordinary shares of GBP 0.01 each",
        },
        .consideration = .{
            .type = .Cash,
            .amount = 0.05,
            .currency = "GBP",
        },
        .certification = .{
            .exempt = false,
            .exemption_category = .None,
        },
        .signatures = &signatures,
    };

    return generateStockTransfer(allocator, data);
}

// =============================================================================
// JSON Parsing
// =============================================================================

/// Track which strings were allocated during JSON parsing
pub const ParsedDataTracking = struct {
    transfer_reference: bool = false,
    transfer_date: bool = false,
    company_name: bool = false,
    company_reg_number: bool = false,
    transferor_name: bool = false,
    transferor_addr_line1: bool = false,
    transferor_addr_line2: bool = false,
    transferor_addr_city: bool = false,
    transferor_addr_county: bool = false,
    transferor_addr_postcode: bool = false,
    transferor_addr_country: bool = false,
    transferee_name: bool = false,
    transferee_addr_line1: bool = false,
    transferee_addr_line2: bool = false,
    transferee_addr_city: bool = false,
    transferee_addr_county: bool = false,
    transferee_addr_postcode: bool = false,
    transferee_addr_country: bool = false,
    shares_class: bool = false,
    shares_currency: bool = false,
    shares_description: bool = false,
    consideration_currency: bool = false,
    consideration_description: bool = false,
    cert_exemption_details: bool = false,
    template_primary_color: bool = false,
    template_accent_color: bool = false,
};

/// Free allocated strings from parsed stock transfer data
pub fn freeStockTransferData(allocator: std.mem.Allocator, data: *const StockTransferData, tracking: *const ParsedDataTracking) void {
    if (tracking.template_primary_color) allocator.free(data.template.style.primary_color);
    if (tracking.template_accent_color) allocator.free(data.template.style.accent_color);
    if (tracking.transfer_reference) if (data.transfer.reference) |r| allocator.free(r);
    if (tracking.transfer_date) allocator.free(data.transfer.date);
    if (tracking.company_name) allocator.free(data.company.name);
    if (tracking.company_reg_number) if (data.company.registration_number) |r| allocator.free(r);
    if (tracking.transferor_name) allocator.free(data.transferor.name);
    if (tracking.transferor_addr_line1) allocator.free(data.transferor.address.line1);
    if (tracking.transferor_addr_line2) if (data.transferor.address.line2) |l| allocator.free(l);
    if (tracking.transferor_addr_city) if (data.transferor.address.city) |c| allocator.free(c);
    if (tracking.transferor_addr_county) if (data.transferor.address.county) |c| allocator.free(c);
    if (tracking.transferor_addr_postcode) allocator.free(data.transferor.address.postcode);
    if (tracking.transferor_addr_country) allocator.free(data.transferor.address.country);
    if (tracking.transferee_name) allocator.free(data.transferee.name);
    if (tracking.transferee_addr_line1) allocator.free(data.transferee.address.line1);
    if (tracking.transferee_addr_line2) if (data.transferee.address.line2) |l| allocator.free(l);
    if (tracking.transferee_addr_city) if (data.transferee.address.city) |c| allocator.free(c);
    if (tracking.transferee_addr_county) if (data.transferee.address.county) |c| allocator.free(c);
    if (tracking.transferee_addr_postcode) allocator.free(data.transferee.address.postcode);
    if (tracking.transferee_addr_country) allocator.free(data.transferee.address.country);
    if (tracking.shares_class) allocator.free(data.shares.class);
    if (tracking.shares_currency) allocator.free(data.shares.currency);
    if (tracking.shares_description) if (data.shares.description) |d| allocator.free(d);
    if (tracking.consideration_currency) allocator.free(data.consideration.currency);
    if (tracking.consideration_description) if (data.consideration.description) |d| allocator.free(d);
    if (tracking.cert_exemption_details) if (data.certification.exemption_details) |d| allocator.free(d);
}

/// Parsed result with tracking for memory management
pub const ParsedResult = struct {
    data: StockTransferData,
    tracking: ParsedDataTracking,
};

fn getJsonFloatValue(v: std.json.Value) f64 {
    return switch (v) {
        .float => v.float,
        .integer => @floatFromInt(v.integer),
        else => 0.0,
    };
}

fn parseStockTransferJson(allocator: std.mem.Allocator, json_str: []const u8) !ParsedResult {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const root = parsed.value.object;

    var tracking = ParsedDataTracking{};
    var data = StockTransferData{
        .transfer = .{ .date = "" },
        .company = .{ .name = "" },
        .transferor = .{ .name = "", .address = .{} },
        .transferee = .{ .name = "", .address = .{} },
        .shares = .{ .quantity = 0, .class = "", .nominal_value = 0.0 },
        .consideration = .{ .amount = 0.0 },
    };

    // Parse template
    if (root.get("template")) |t| {
        if (t.object.get("style")) |s| {
            if (s.object.get("primary_color")) |v| {
                data.template.style.primary_color = try allocator.dupe(u8, v.string);
                tracking.template_primary_color = true;
            }
            if (s.object.get("accent_color")) |v| {
                data.template.style.accent_color = try allocator.dupe(u8, v.string);
                tracking.template_accent_color = true;
            }
        }
    }

    // Parse transfer
    if (root.get("transfer")) |t| {
        if (t.object.get("reference")) |v| {
            data.transfer.reference = try allocator.dupe(u8, v.string);
            tracking.transfer_reference = true;
        }
        if (t.object.get("date")) |v| {
            data.transfer.date = try allocator.dupe(u8, v.string);
            tracking.transfer_date = true;
        } else {
            data.transfer.date = "";
        }
    }

    // Parse company
    if (root.get("company")) |c| {
        if (c.object.get("name")) |v| {
            data.company.name = try allocator.dupe(u8, v.string);
            tracking.company_name = true;
        } else {
            data.company.name = "";
        }
        if (c.object.get("registration_number")) |v| {
            data.company.registration_number = try allocator.dupe(u8, v.string);
            tracking.company_reg_number = true;
        }
    }

    // Parse transferor
    if (root.get("transferor")) |t| {
        if (t.object.get("name")) |v| {
            data.transferor.name = try allocator.dupe(u8, v.string);
            tracking.transferor_name = true;
        } else {
            data.transferor.name = "";
        }
        data.transferor.party_type = if (t.object.get("party_type")) |v| PartyType.fromString(v.string) else .Individual;
        if (t.object.get("address")) |a| {
            if (a.object.get("line1")) |v| {
                data.transferor.address.line1 = try allocator.dupe(u8, v.string);
                tracking.transferor_addr_line1 = true;
            }
            if (a.object.get("line2")) |v| {
                data.transferor.address.line2 = try allocator.dupe(u8, v.string);
                tracking.transferor_addr_line2 = true;
            }
            if (a.object.get("city")) |v| {
                data.transferor.address.city = try allocator.dupe(u8, v.string);
                tracking.transferor_addr_city = true;
            }
            if (a.object.get("county")) |v| {
                data.transferor.address.county = try allocator.dupe(u8, v.string);
                tracking.transferor_addr_county = true;
            }
            if (a.object.get("postcode")) |v| {
                data.transferor.address.postcode = try allocator.dupe(u8, v.string);
                tracking.transferor_addr_postcode = true;
            }
            if (a.object.get("country")) |v| {
                data.transferor.address.country = try allocator.dupe(u8, v.string);
                tracking.transferor_addr_country = true;
            }
        }
    }

    // Parse transferee
    if (root.get("transferee")) |t| {
        if (t.object.get("name")) |v| {
            data.transferee.name = try allocator.dupe(u8, v.string);
            tracking.transferee_name = true;
        } else {
            data.transferee.name = "";
        }
        data.transferee.party_type = if (t.object.get("party_type")) |v| PartyType.fromString(v.string) else .Individual;
        if (t.object.get("address")) |a| {
            if (a.object.get("line1")) |v| {
                data.transferee.address.line1 = try allocator.dupe(u8, v.string);
                tracking.transferee_addr_line1 = true;
            }
            if (a.object.get("line2")) |v| {
                data.transferee.address.line2 = try allocator.dupe(u8, v.string);
                tracking.transferee_addr_line2 = true;
            }
            if (a.object.get("city")) |v| {
                data.transferee.address.city = try allocator.dupe(u8, v.string);
                tracking.transferee_addr_city = true;
            }
            if (a.object.get("county")) |v| {
                data.transferee.address.county = try allocator.dupe(u8, v.string);
                tracking.transferee_addr_county = true;
            }
            if (a.object.get("postcode")) |v| {
                data.transferee.address.postcode = try allocator.dupe(u8, v.string);
                tracking.transferee_addr_postcode = true;
            }
            if (a.object.get("country")) |v| {
                data.transferee.address.country = try allocator.dupe(u8, v.string);
                tracking.transferee_addr_country = true;
            }
        }
    }

    // Parse shares
    if (root.get("shares")) |s| {
        data.shares.quantity = if (s.object.get("quantity")) |v| @intCast(v.integer) else 0;
        if (s.object.get("class")) |v| {
            data.shares.class = try allocator.dupe(u8, v.string);
            tracking.shares_class = true;
        } else {
            data.shares.class = "Ordinary";
        }
        data.shares.nominal_value = if (s.object.get("nominal_value")) |v| getJsonFloatValue(v) else 0.01;
        if (s.object.get("currency")) |v| {
            data.shares.currency = try allocator.dupe(u8, v.string);
            tracking.shares_currency = true;
        } else {
            data.shares.currency = "GBP";
        }
        if (s.object.get("description")) |v| {
            data.shares.description = try allocator.dupe(u8, v.string);
            tracking.shares_description = true;
        }
    }

    // Parse consideration
    if (root.get("consideration")) |c| {
        data.consideration.type = if (c.object.get("type")) |v| ConsiderationType.fromString(v.string) else .Cash;
        data.consideration.amount = if (c.object.get("amount")) |v| getJsonFloatValue(v) else 0.0;
        if (c.object.get("currency")) |v| {
            data.consideration.currency = try allocator.dupe(u8, v.string);
            tracking.consideration_currency = true;
        } else {
            data.consideration.currency = "GBP";
        }
        if (c.object.get("description")) |v| {
            data.consideration.description = try allocator.dupe(u8, v.string);
            tracking.consideration_description = true;
        }
    }

    // Parse certification
    if (root.get("certification")) |c| {
        data.certification.exempt = if (c.object.get("exempt")) |v| v.bool else false;
        data.certification.exemption_category = if (c.object.get("exemption_category")) |v| ExemptionCategory.fromString(v.string) else .None;
        if (c.object.get("exemption_details")) |v| {
            data.certification.exemption_details = try allocator.dupe(u8, v.string);
            tracking.cert_exemption_details = true;
        }
    }

    return ParsedResult{ .data = data, .tracking = tracking };
}

// =============================================================================
// Tests
// =============================================================================

test "stock transfer form generation" {
    const allocator = std.testing.allocator;
    const pdf = try generateDemoStockTransfer(allocator);
    defer allocator.free(pdf);
    try std.testing.expect(pdf.len > 1000);
}
