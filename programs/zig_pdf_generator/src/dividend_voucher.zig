//! Dividend Voucher Generator
//!
//! Generates dividend vouchers for UK and Ireland with:
//! - Company details and registration number
//! - Shareholder information
//! - Dividend calculation breakdown
//! - Irish DWT (Dividend Withholding Tax) at 25% where applicable
//! - Payment details
//! - Director signature
//!
//! Usage:
//! ```zig
//! const voucher_data = DividendVoucherData{
//!     .voucher = .{ .number = "DIV-2026-001", .date = "31 March 2026" },
//!     .company = .{ .name = "QUANTUM ENCODING LTD", ... },
//!     .shareholder = .{ .name = "Mr Lance Pearson", ... },
//!     .dividend = .{ .shares_held = 5, .rate_per_share = 1.00, ... },
//!     .signatory = .{ .role = .Director, .name = "Richard Tune", ... },
//! };
//! const pdf = try generateDividendVoucher(allocator, voucher_data);
//! ```

const std = @import("std");
const document = @import("document.zig");

// =============================================================================
// Data Structures
// =============================================================================

/// Jurisdiction for tax treatment
pub const Jurisdiction = enum {
    UK,
    Ireland,

    pub fn toString(self: Jurisdiction) []const u8 {
        return switch (self) {
            .UK => "United Kingdom",
            .Ireland => "Ireland",
        };
    }

    pub fn fromString(s: []const u8) Jurisdiction {
        if (std.mem.eql(u8, s, "Ireland") or std.mem.eql(u8, s, "IE") or std.mem.eql(u8, s, "IRL")) {
            return .Ireland;
        }
        return .UK;
    }

    /// Get the default DWT rate for this jurisdiction
    pub fn defaultDwtRate(self: Jurisdiction) f64 {
        return switch (self) {
            .UK => 0.0, // UK has no dividend withholding tax
            .Ireland => 0.25, // Ireland has 25% DWT
        };
    }
};

/// DWT (Dividend Withholding Tax) Exemption types for Ireland
pub const DwtExemptionType = enum {
    None,
    IrishResidentIndividual,
    IrishResidentCompany,
    EuParentSubsidiary,
    TaxTreaty,
    PensionFund,
    Charity,

    pub fn toString(self: DwtExemptionType) []const u8 {
        return switch (self) {
            .None => "None",
            .IrishResidentIndividual => "Irish Resident Individual",
            .IrishResidentCompany => "Irish Resident Company",
            .EuParentSubsidiary => "EU Parent-Subsidiary Directive",
            .TaxTreaty => "Double Tax Treaty",
            .PensionFund => "Pension Fund",
            .Charity => "Charitable Organisation",
        };
    }

    pub fn fromString(s: []const u8) DwtExemptionType {
        if (std.mem.eql(u8, s, "irish_resident_individual")) return .IrishResidentIndividual;
        if (std.mem.eql(u8, s, "irish_resident_company")) return .IrishResidentCompany;
        if (std.mem.eql(u8, s, "eu_parent_subsidiary")) return .EuParentSubsidiary;
        if (std.mem.eql(u8, s, "tax_treaty")) return .TaxTreaty;
        if (std.mem.eql(u8, s, "pension_fund")) return .PensionFund;
        if (std.mem.eql(u8, s, "charity")) return .Charity;
        return .None;
    }
};

/// DWT Exemption details for Ireland
pub const DwtExemption = struct {
    applies: bool = false,
    exemption_type: DwtExemptionType = .None,
    declaration_reference: ?[]const u8 = null,
};

/// Address structure
pub const Address = struct {
    line1: []const u8 = "",
    line2: ?[]const u8 = null,
    city: ?[]const u8 = null,
    county: ?[]const u8 = null,
    postcode: []const u8 = "",
    country: []const u8 = "United Kingdom",

    /// Format address as single line
    pub fn formatSingleLine(self: Address, allocator: std.mem.Allocator) ![]const u8 {
        var parts: std.ArrayListUnmanaged([]const u8) = .empty;
        defer parts.deinit(allocator);

        if (self.line1.len > 0) try parts.append(allocator, self.line1);
        if (self.line2) |l2| if (l2.len > 0) try parts.append(allocator, l2);
        if (self.city) |c| if (c.len > 0) try parts.append(allocator, c);
        if (self.postcode.len > 0) try parts.append(allocator, self.postcode);

        var total_len: usize = 0;
        for (parts.items, 0..) |part, i| {
            total_len += part.len;
            if (i < parts.items.len - 1) total_len += 2;
        }

        var result = try allocator.alloc(u8, total_len);
        var pos: usize = 0;
        for (parts.items, 0..) |part, i| {
            @memcpy(result[pos..][0..part.len], part);
            pos += part.len;
            if (i < parts.items.len - 1) {
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
    primary_color: []const u8 = "#1a5f3d", // Dark green
    accent_color: []const u8 = "#2d8a5e", // Medium green
    font_family: []const u8 = "Helvetica",
};

/// Template configuration
pub const Template = struct {
    id: []const u8 = "dividend_voucher_uk",
    version: []const u8 = "1.0.0",
    style: TemplateStyle = .{},
};

/// Voucher metadata
pub const Voucher = struct {
    number: []const u8,
    date: []const u8,
    tax_year: []const u8 = "2025/26",
};

/// Company information
pub const Company = struct {
    name: []const u8,
    registration_number: []const u8,
    registered_address: Address,
};

/// Shareholder information
pub const Shareholder = struct {
    name: []const u8,
    address: Address,
};

/// Currency type
pub const Currency = enum {
    GBP,
    EUR,
    USD,

    pub fn symbol(self: Currency) []const u8 {
        return switch (self) {
            .GBP => "\\243", // £ in PDF encoding
            .EUR => "EUR ",
            .USD => "$",
        };
    }

    pub fn fromString(s: []const u8) Currency {
        if (std.mem.eql(u8, s, "EUR")) return .EUR;
        if (std.mem.eql(u8, s, "USD")) return .USD;
        return .GBP;
    }
};

/// Dividend details
pub const Dividend = struct {
    shares_held: u32,
    share_class: []const u8 = "Ordinary",
    rate_per_share: f64,
    gross_amount: f64,
    tax_credit: f64 = 0.0, // UK tax credit (historical)
    // Irish DWT fields
    dwt_rate: f64 = 0.0, // DWT rate (0.25 for Ireland, 0.0 for UK)
    dwt_withheld: f64 = 0.0, // Amount withheld for DWT
    dwt_exemption: DwtExemption = .{}, // Exemption details for Ireland
    net_payable: f64,
    currency: Currency = .GBP,
};

/// Payment information
pub const Payment = struct {
    method: []const u8 = "Bank Transfer",
    date: []const u8,
    reference: ?[]const u8 = null,
};

/// Declaration details
pub const Declaration = struct {
    resolution_date: []const u8,
    payment_date: []const u8,
};

/// Signatory role
pub const SignatoryRole = enum {
    Director,
    Secretary,
    AuthorisedSignatory,

    pub fn toString(self: SignatoryRole) []const u8 {
        return switch (self) {
            .Director => "Director",
            .Secretary => "Company Secretary",
            .AuthorisedSignatory => "Authorised Signatory",
        };
    }

    pub fn fromString(s: []const u8) SignatoryRole {
        if (std.mem.eql(u8, s, "Secretary")) return .Secretary;
        if (std.mem.eql(u8, s, "Authorised Signatory")) return .AuthorisedSignatory;
        return .Director;
    }
};

/// Signatory information
pub const Signatory = struct {
    role: SignatoryRole = .Director,
    name: []const u8,
    date: []const u8,
};

/// Complete dividend voucher data
pub const DividendVoucherData = struct {
    jurisdiction: Jurisdiction = .UK,
    template: Template = .{},
    voucher: Voucher,
    company: Company,
    shareholder: Shareholder,
    dividend: Dividend,
    payment: Payment,
    declaration: Declaration,
    signatory: Signatory,
};

// =============================================================================
// Voucher Renderer
// =============================================================================

pub const DividendVoucherRenderer = struct {
    allocator: std.mem.Allocator,
    doc: document.PdfDocument,
    data: DividendVoucherData,

    // Page dimensions (A4 portrait)
    page_width: f32 = 595,
    page_height: f32 = 842,

    // Margins
    margin: f32 = 50,

    // Font IDs
    font_regular: []const u8 = "F0",
    font_bold: []const u8 = "F1",

    pub fn init(allocator: std.mem.Allocator, data: DividendVoucherData) DividendVoucherRenderer {
        var renderer = DividendVoucherRenderer{
            .allocator = allocator,
            .doc = document.PdfDocument.init(allocator),
            .data = data,
        };

        // Register fonts
        renderer.font_regular = renderer.doc.getFontId(.helvetica);
        renderer.font_bold = renderer.doc.getFontId(.helvetica_bold);

        return renderer;
    }

    pub fn deinit(self: *DividendVoucherRenderer) void {
        self.doc.deinit();
    }

    /// Draw the header with company name and "DIVIDEND VOUCHER" title
    fn drawHeader(self: *DividendVoucherRenderer, content: *document.ContentStream) !void {
        const primary = document.Color.fromHex(self.data.template.style.primary_color);
        const center_x = self.page_width / 2;
        var y = self.page_height - self.margin;

        // Company name
        const company_width = document.Font.helvetica_bold.measureText(self.data.company.name, 16);
        try content.drawText(self.data.company.name, center_x - company_width / 2, y, self.font_bold, 16, primary);

        y -= 18;

        // Company registration number
        var reg_buf: [64]u8 = undefined;
        const reg_text = std.fmt.bufPrint(&reg_buf, "(Company No. {s})", .{self.data.company.registration_number}) catch self.data.company.registration_number;
        const reg_width = document.Font.helvetica.measureText(reg_text, 10);
        const gray = document.Color{ .r = 0.4, .g = 0.4, .b = 0.4 };
        try content.drawText(reg_text, center_x - reg_width / 2, y, self.font_regular, 10, gray);

        y -= 35;

        // DIVIDEND VOUCHER title
        const title = "DIVIDEND VOUCHER";
        const title_width = document.Font.helvetica_bold.measureText(title, 24);
        try content.drawText(title, center_x - title_width / 2, y, self.font_bold, 24, primary);

        y -= 25;

        // Voucher number and tax year
        var info_buf: [128]u8 = undefined;
        const info_text = std.fmt.bufPrint(&info_buf, "Voucher No: {s}  |  Tax Year: {s}", .{ self.data.voucher.number, self.data.voucher.tax_year }) catch "";
        const info_width = document.Font.helvetica.measureText(info_text, 10);
        try content.drawText(info_text, center_x - info_width / 2, y, self.font_regular, 10, gray);

        y -= 15;

        // Horizontal line
        try content.setStrokeColor(primary);
        try content.setLineWidth(1.5);
        try content.moveTo(self.margin, y);
        try content.lineTo(self.page_width - self.margin, y);
        try content.stroke();
    }

    /// Draw shareholder details section
    fn drawShareholderDetails(self: *DividendVoucherRenderer, content: *document.ContentStream) !void {
        const text_color = document.Color{ .r = 0.1, .g = 0.1, .b = 0.1 };
        const label_color = document.Color{ .r = 0.4, .g = 0.4, .b = 0.4 };
        var y = self.page_height - self.margin - 130;
        const left_x = self.margin;

        // Section title
        try content.drawText("SHAREHOLDER DETAILS", left_x, y, self.font_bold, 12, document.Color.fromHex(self.data.template.style.primary_color));

        y -= 25;

        // Name
        try content.drawText("Name:", left_x, y, self.font_regular, 10, label_color);
        try content.drawText(self.data.shareholder.name, left_x + 100, y, self.font_bold, 10, text_color);

        y -= 18;

        // Address
        try content.drawText("Address:", left_x, y, self.font_regular, 10, label_color);
        const addr = try self.data.shareholder.address.formatSingleLine(self.allocator);
        defer self.allocator.free(addr);
        try content.drawText(addr, left_x + 100, y, self.font_regular, 10, text_color);
    }

    /// Draw dividend calculation section
    fn drawDividendDetails(self: *DividendVoucherRenderer, content: *document.ContentStream) !void {
        const text_color = document.Color{ .r = 0.1, .g = 0.1, .b = 0.1 };
        const label_color = document.Color{ .r = 0.4, .g = 0.4, .b = 0.4 };
        const primary = document.Color.fromHex(self.data.template.style.primary_color);
        var y = self.page_height - self.margin - 220;
        const left_x = self.margin;
        const value_x = self.page_width - self.margin - 100;

        // Currency symbol based on jurisdiction
        const currency_symbol: []const u8 = switch (self.data.jurisdiction) {
            .Ireland => "EUR ",
            .UK => "\\243", // £ in PDF encoding
        };

        // Section title
        try content.drawText("DIVIDEND DETAILS", left_x, y, self.font_bold, 12, primary);

        y -= 30;

        // Date of dividend
        try content.drawText("Date of Dividend:", left_x, y, self.font_regular, 10, label_color);
        try content.drawText(self.data.voucher.date, value_x, y, self.font_regular, 10, text_color);

        y -= 18;

        // Share class
        try content.drawText("Share Class:", left_x, y, self.font_regular, 10, label_color);
        try content.drawText(self.data.dividend.share_class, value_x, y, self.font_regular, 10, text_color);

        y -= 18;

        // Shares held
        try content.drawText("Number of Shares Held:", left_x, y, self.font_regular, 10, label_color);
        var shares_buf: [32]u8 = undefined;
        const shares_text = std.fmt.bufPrint(&shares_buf, "{d}", .{self.data.dividend.shares_held}) catch "0";
        try content.drawText(shares_text, value_x, y, self.font_regular, 10, text_color);

        y -= 18;

        // Rate per share
        try content.drawText("Dividend Rate per Share:", left_x, y, self.font_regular, 10, label_color);
        var rate_buf: [32]u8 = undefined;
        const rate_text = std.fmt.bufPrint(&rate_buf, "{s}{d:.4}", .{ currency_symbol, self.data.dividend.rate_per_share }) catch "";
        try content.drawText(rate_text, value_x, y, self.font_regular, 10, text_color);

        y -= 30;

        // Horizontal line
        try content.setStrokeColor(label_color);
        try content.setLineWidth(0.5);
        try content.moveTo(left_x, y);
        try content.lineTo(self.page_width - self.margin, y);
        try content.stroke();

        y -= 20;

        // Gross dividend
        try content.drawText("Gross Dividend:", left_x, y, self.font_regular, 11, text_color);
        var gross_buf: [32]u8 = undefined;
        const gross_text = std.fmt.bufPrint(&gross_buf, "{s}{d:.2}", .{ currency_symbol, self.data.dividend.gross_amount }) catch "";
        try content.drawText(gross_text, value_x, y, self.font_regular, 11, text_color);

        y -= 18;

        // Irish DWT (Dividend Withholding Tax)
        if (self.data.jurisdiction == .Ireland) {
            if (self.data.dividend.dwt_exemption.applies) {
                // Show exemption notice
                try content.drawText("DWT (25%):", left_x, y, self.font_regular, 11, text_color);
                try content.drawText("EXEMPT", value_x, y, self.font_bold, 11, primary);
                y -= 14;
                // Exemption details
                var exempt_buf: [128]u8 = undefined;
                const exempt_text = std.fmt.bufPrint(&exempt_buf, "({s})", .{
                    self.data.dividend.dwt_exemption.exemption_type.toString(),
                }) catch "";
                try content.drawText(exempt_text, left_x + 20, y, self.font_regular, 9, label_color);
                y -= 18;
            } else if (self.data.dividend.dwt_withheld > 0) {
                // Show DWT withheld
                try content.drawText("DWT Withheld (25%):", left_x, y, self.font_regular, 11, text_color);
                var dwt_buf: [32]u8 = undefined;
                const dwt_text = std.fmt.bufPrint(&dwt_buf, "-{s}{d:.2}", .{ currency_symbol, self.data.dividend.dwt_withheld }) catch "";
                const dwt_color = document.Color{ .r = 0.8, .g = 0.2, .b = 0.2 }; // Red for deductions
                try content.drawText(dwt_text, value_x, y, self.font_regular, 11, dwt_color);
                y -= 18;
            }
        }

        // UK Tax credit (if applicable - historical, pre-2016)
        if (self.data.jurisdiction == .UK and self.data.dividend.tax_credit > 0) {
            try content.drawText("Tax Credit:", left_x, y, self.font_regular, 11, text_color);
            var tax_buf: [32]u8 = undefined;
            const tax_text = std.fmt.bufPrint(&tax_buf, "{s}{d:.2}", .{ currency_symbol, self.data.dividend.tax_credit }) catch "";
            try content.drawText(tax_text, value_x, y, self.font_regular, 11, text_color);
            y -= 18;
        }

        // Horizontal line before total
        try content.setLineWidth(1.0);
        try content.moveTo(value_x - 50, y + 5);
        try content.lineTo(self.page_width - self.margin, y + 5);
        try content.stroke();

        y -= 5;

        // Net payable
        try content.drawText("NET DIVIDEND PAYABLE:", left_x, y, self.font_bold, 12, text_color);
        var net_buf: [32]u8 = undefined;
        const net_text = std.fmt.bufPrint(&net_buf, "{s}{d:.2}", .{ currency_symbol, self.data.dividend.net_payable }) catch "";
        try content.drawText(net_text, value_x, y, self.font_bold, 12, primary);
    }

    /// Draw payment details section
    fn drawPaymentDetails(self: *DividendVoucherRenderer, content: *document.ContentStream) !void {
        const text_color = document.Color{ .r = 0.1, .g = 0.1, .b = 0.1 };
        const label_color = document.Color{ .r = 0.4, .g = 0.4, .b = 0.4 };
        const primary = document.Color.fromHex(self.data.template.style.primary_color);
        var y = self.page_height - self.margin - 440;
        const left_x = self.margin;
        const value_x = left_x + 120;

        // Section title
        try content.drawText("PAYMENT DETAILS", left_x, y, self.font_bold, 12, primary);

        y -= 25;

        // Payment method
        try content.drawText("Payment Method:", left_x, y, self.font_regular, 10, label_color);
        try content.drawText(self.data.payment.method, value_x, y, self.font_regular, 10, text_color);

        y -= 18;

        // Payment date
        try content.drawText("Payment Date:", left_x, y, self.font_regular, 10, label_color);
        try content.drawText(self.data.payment.date, value_x, y, self.font_regular, 10, text_color);

        y -= 18;

        // Reference (if provided)
        if (self.data.payment.reference) |ref| {
            try content.drawText("Reference:", left_x, y, self.font_regular, 10, label_color);
            try content.drawText(ref, value_x, y, self.font_regular, 10, text_color);
        }
    }

    /// Draw declaration and signature section
    fn drawDeclarationAndSignature(self: *DividendVoucherRenderer, content: *document.ContentStream) !void {
        const text_color = document.Color{ .r = 0.1, .g = 0.1, .b = 0.1 };
        const label_color = document.Color{ .r = 0.4, .g = 0.4, .b = 0.4 };
        const primary = document.Color.fromHex(self.data.template.style.primary_color);
        var y = self.page_height - self.margin - 540;
        const left_x = self.margin;

        // Currency symbol based on jurisdiction
        const currency_symbol: []const u8 = switch (self.data.jurisdiction) {
            .Ireland => "EUR ",
            .UK => "\\243",
        };

        // Declaration text
        try content.drawText("DECLARATION", left_x, y, self.font_bold, 12, primary);

        y -= 25;

        var decl_buf: [256]u8 = undefined;
        const decl_text = std.fmt.bufPrint(&decl_buf, "I confirm that a dividend of {s}{d:.2} per {s} share was declared by resolution", .{
            currency_symbol,
            self.data.dividend.rate_per_share,
            self.data.dividend.share_class,
        }) catch "I confirm that the above dividend was declared by resolution";
        try content.drawText(decl_text, left_x, y, self.font_regular, 10, text_color);

        y -= 14;

        var decl2_buf: [256]u8 = undefined;
        const decl2_text = std.fmt.bufPrint(&decl2_buf, "of the directors dated {s}, payable on {s}.", .{
            self.data.declaration.resolution_date,
            self.data.declaration.payment_date,
        }) catch "of the directors.";
        try content.drawText(decl2_text, left_x, y, self.font_regular, 10, text_color);

        // For Ireland, add DWT declaration if DWT was withheld
        if (self.data.jurisdiction == .Ireland and self.data.dividend.dwt_withheld > 0) {
            y -= 14;
            var dwt_decl_buf: [256]u8 = undefined;
            const dwt_decl = std.fmt.bufPrint(&dwt_decl_buf, "Dividend Withholding Tax of {s}{d:.2} has been deducted and will be remitted to Revenue.", .{
                currency_symbol,
                self.data.dividend.dwt_withheld,
            }) catch "";
            try content.drawText(dwt_decl, left_x, y, self.font_regular, 10, text_color);
        }

        y -= 50;

        // Signature line
        const sig_x = left_x;
        const line_width: f32 = 200;

        try content.setStrokeColor(label_color);
        try content.setLineWidth(0.5);
        try content.moveTo(sig_x, y);
        try content.lineTo(sig_x + line_width, y);
        try content.stroke();

        y -= 15;

        // Signatory name and role
        try content.drawText(self.data.signatory.name, sig_x, y, self.font_bold, 10, text_color);

        y -= 14;

        try content.drawText(self.data.signatory.role.toString(), sig_x, y, self.font_regular, 10, label_color);

        y -= 14;

        var date_buf: [64]u8 = undefined;
        const date_text = std.fmt.bufPrint(&date_buf, "Date: {s}", .{self.data.signatory.date}) catch "";
        try content.drawText(date_text, sig_x, y, self.font_regular, 10, label_color);
    }

    /// Draw footer with company address
    fn drawFooter(self: *DividendVoucherRenderer, content: *document.ContentStream) !void {
        const gray = document.Color{ .r = 0.5, .g = 0.5, .b = 0.5 };
        const center_x = self.page_width / 2;
        var y = self.margin + 30;

        // Registered office
        const addr = try self.data.company.registered_address.formatSingleLine(self.allocator);
        defer self.allocator.free(addr);

        var footer_buf: [256]u8 = undefined;
        const footer_text = std.fmt.bufPrint(&footer_buf, "Registered Office: {s}", .{addr}) catch "";
        const footer_width = document.Font.helvetica.measureText(footer_text, 8);
        try content.drawText(footer_text, center_x - footer_width / 2, y, self.font_regular, 8, gray);

        y -= 12;

        // Keep this voucher message
        const keep_text = "Please retain this voucher for your tax records.";
        const keep_width = document.Font.helvetica.measureText(keep_text, 8);
        try content.drawText(keep_text, center_x - keep_width / 2, y, self.font_regular, 8, gray);
    }

    /// Render the complete voucher
    pub fn render(self: *DividendVoucherRenderer) ![]const u8 {
        var content = document.ContentStream.init(self.allocator);
        defer content.deinit();

        // Set page size to A4 portrait
        self.doc.setPageSize(.{ .width = 595, .height = 842 });

        // Draw all elements
        try self.drawHeader(&content);
        try self.drawShareholderDetails(&content);
        try self.drawDividendDetails(&content);
        try self.drawPaymentDetails(&content);
        try self.drawDeclarationAndSignature(&content);
        try self.drawFooter(&content);

        // Add page to document
        try self.doc.addPage(&content);

        return self.doc.build();
    }
};

// =============================================================================
// Public API
// =============================================================================

/// Generate a dividend voucher PDF
pub fn generateDividendVoucher(allocator: std.mem.Allocator, data: DividendVoucherData) ![]u8 {
    var renderer = DividendVoucherRenderer.init(allocator, data);
    defer renderer.deinit();

    const pdf_output = try renderer.render();
    return try allocator.dupe(u8, pdf_output);
}

/// Generate dividend voucher from JSON string
pub fn generateDividendVoucherFromJson(allocator: std.mem.Allocator, json_str: []const u8) ![]u8 {
    const result = try parseDividendVoucherJson(allocator, json_str);
    defer freeDividendVoucherData(allocator, &result.data, &result.tracking);
    return generateDividendVoucher(allocator, result.data);
}

/// Generate a demo dividend voucher
pub fn generateDemoDividendVoucher(allocator: std.mem.Allocator) ![]u8 {
    const data = DividendVoucherData{
        .template = .{
            .style = .{
                .primary_color = "#1a5f3d",
                .accent_color = "#2d8a5e",
            },
        },
        .voucher = .{
            .number = "DIV-2026-001",
            .date = "31 March 2026",
            .tax_year = "2025/26",
        },
        .company = .{
            .name = "QUANTUM ENCODING LTD",
            .registration_number = "16575953",
            .registered_address = .{
                .line1 = "33 OXFORD STREET",
                .city = "COALVILLE",
                .postcode = "LE67 3GS",
                .country = "United Kingdom",
            },
        },
        .shareholder = .{
            .name = "Mr Lance John Pearson",
            .address = .{
                .line1 = "172 SEA FRONT",
                .city = "HAYLING ISLAND",
                .postcode = "PO11 9HP",
                .country = "United Kingdom",
            },
        },
        .dividend = .{
            .shares_held = 5,
            .share_class = "Ordinary",
            .rate_per_share = 1.00,
            .gross_amount = 5.00,
            .tax_credit = 0.00,
            .net_payable = 5.00,
            .currency = .GBP,
        },
        .payment = .{
            .method = "Bank Transfer",
            .date = "1 April 2026",
            .reference = "DIV-LANCE-Q1-2026",
        },
        .declaration = .{
            .resolution_date = "25 March 2026",
            .payment_date = "1 April 2026",
        },
        .signatory = .{
            .role = .Director,
            .name = "RICHARD ALEXANDER TUNE",
            .date = "31 March 2026",
        },
    };

    return generateDividendVoucher(allocator, data);
}

/// Generate a demo Irish dividend voucher with DWT
pub fn generateDemoIrishDividendVoucher(allocator: std.mem.Allocator) ![]u8 {
    const data = DividendVoucherData{
        .jurisdiction = .Ireland,
        .template = .{
            .style = .{
                .primary_color = "#006B4D", // Irish green
                .accent_color = "#169B62",
            },
        },
        .voucher = .{
            .number = "DIV-IE-2026-001",
            .date = "31 March 2026",
            .tax_year = "2025",
        },
        .company = .{
            .name = "QUANTUM ENCODING IRELAND LIMITED",
            .registration_number = "123456",
            .registered_address = .{
                .line1 = "1 GRAND CANAL SQUARE",
                .line2 = "GRAND CANAL HARBOUR",
                .city = "DUBLIN 2",
                .postcode = "D02 P820",
                .country = "Ireland",
            },
        },
        .shareholder = .{
            .name = "Mr Seamus O'Connor",
            .address = .{
                .line1 = "42 GRAFTON STREET",
                .city = "DUBLIN 2",
                .postcode = "D02 HF85",
                .country = "Ireland",
            },
        },
        .dividend = .{
            .shares_held = 100,
            .share_class = "Ordinary",
            .rate_per_share = 10.00,
            .gross_amount = 1000.00,
            .dwt_rate = 0.25, // Irish 25% DWT
            .dwt_withheld = 250.00, // 25% of 1000
            .dwt_exemption = .{
                .applies = false,
                .exemption_type = .None,
            },
            .net_payable = 750.00, // 1000 - 250
            .currency = .EUR,
        },
        .payment = .{
            .method = "Bank Transfer",
            .date = "1 April 2026",
            .reference = "DIV-IE-SEAMUS-Q1-2026",
        },
        .declaration = .{
            .resolution_date = "25 March 2026",
            .payment_date = "1 April 2026",
        },
        .signatory = .{
            .role = .Director,
            .name = "PATRICK MURPHY",
            .date = "31 March 2026",
        },
    };

    return generateDividendVoucher(allocator, data);
}

/// Generate a demo Irish dividend voucher with DWT exemption
pub fn generateDemoIrishDividendVoucherExempt(allocator: std.mem.Allocator) ![]u8 {
    const data = DividendVoucherData{
        .jurisdiction = .Ireland,
        .template = .{
            .style = .{
                .primary_color = "#006B4D",
                .accent_color = "#169B62",
            },
        },
        .voucher = .{
            .number = "DIV-IE-2026-002",
            .date = "31 March 2026",
            .tax_year = "2025",
        },
        .company = .{
            .name = "QUANTUM ENCODING IRELAND LIMITED",
            .registration_number = "123456",
            .registered_address = .{
                .line1 = "1 GRAND CANAL SQUARE",
                .line2 = "GRAND CANAL HARBOUR",
                .city = "DUBLIN 2",
                .postcode = "D02 P820",
                .country = "Ireland",
            },
        },
        .shareholder = .{
            .name = "ACME HOLDINGS PLC",
            .address = .{
                .line1 = "100 BOULEVARD HAUSSMANN",
                .city = "PARIS",
                .postcode = "75008",
                .country = "France",
            },
        },
        .dividend = .{
            .shares_held = 1000,
            .share_class = "Ordinary",
            .rate_per_share = 5.00,
            .gross_amount = 5000.00,
            .dwt_rate = 0.25,
            .dwt_withheld = 0.00, // Exempt
            .dwt_exemption = .{
                .applies = true,
                .exemption_type = .EuParentSubsidiary,
                .declaration_reference = "DWT-EXEMPT-2026-001",
            },
            .net_payable = 5000.00, // Full amount, no DWT
            .currency = .EUR,
        },
        .payment = .{
            .method = "Wire Transfer",
            .date = "1 April 2026",
            .reference = "DIV-IE-ACME-Q1-2026",
        },
        .declaration = .{
            .resolution_date = "25 March 2026",
            .payment_date = "1 April 2026",
        },
        .signatory = .{
            .role = .Director,
            .name = "PATRICK MURPHY",
            .date = "31 March 2026",
        },
    };

    return generateDividendVoucher(allocator, data);
}

// =============================================================================
// JSON Parsing
// =============================================================================

const AddressParseResult = struct {
    address: Address,
    line1: bool = false,
    line2: bool = false,
    city: bool = false,
    county: bool = false,
    postcode: bool = false,
    country: bool = false,
};

fn parseAddressWithTracking(allocator: std.mem.Allocator, addr_val: ?std.json.Value) !AddressParseResult {
    var result = AddressParseResult{ .address = Address{} };

    if (addr_val) |a| {
        if (a == .object) {
            if (a.object.get("line1")) |v| {
                result.address.line1 = try allocator.dupe(u8, v.string);
                result.line1 = true;
            }
            if (a.object.get("line2")) |v| {
                result.address.line2 = try allocator.dupe(u8, v.string);
                result.line2 = true;
            }
            if (a.object.get("city")) |v| {
                result.address.city = try allocator.dupe(u8, v.string);
                result.city = true;
            }
            if (a.object.get("county")) |v| {
                result.address.county = try allocator.dupe(u8, v.string);
                result.county = true;
            }
            if (a.object.get("postcode")) |v| {
                result.address.postcode = try allocator.dupe(u8, v.string);
                result.postcode = true;
            }
            if (a.object.get("country")) |v| {
                result.address.country = try allocator.dupe(u8, v.string);
                result.country = true;
            }
        }
    }
    return result;
}

fn getJsonFloatValue(v: std.json.Value) f64 {
    return switch (v) {
        .float => v.float,
        .integer => @floatFromInt(v.integer),
        else => 0.0,
    };
}

/// Track which strings were allocated during JSON parsing
pub const ParsedDataTracking = struct {
    template_primary_color: bool = false,
    template_accent_color: bool = false,
    voucher_number: bool = false,
    voucher_date: bool = false,
    voucher_tax_year: bool = false,
    company_name: bool = false,
    company_reg_number: bool = false,
    company_addr_line1: bool = false,
    company_addr_line2: bool = false,
    company_addr_city: bool = false,
    company_addr_county: bool = false,
    company_addr_postcode: bool = false,
    company_addr_country: bool = false,
    shareholder_name: bool = false,
    shareholder_addr_line1: bool = false,
    shareholder_addr_line2: bool = false,
    shareholder_addr_city: bool = false,
    shareholder_addr_county: bool = false,
    shareholder_addr_postcode: bool = false,
    shareholder_addr_country: bool = false,
    dividend_share_class: bool = false,
    dwt_exemption_declaration_reference: bool = false, // Irish DWT exemption reference
    payment_method: bool = false,
    payment_date: bool = false,
    payment_reference: bool = false,
    declaration_resolution_date: bool = false,
    declaration_payment_date: bool = false,
    signatory_name: bool = false,
    signatory_date: bool = false,
};

/// Free allocated strings from parsed dividend voucher data
/// Note: This only frees strings that were allocated during JSON parsing
/// Demo data uses string literals which must NOT be freed
pub fn freeDividendVoucherData(allocator: std.mem.Allocator, data: *const DividendVoucherData, tracking: *const ParsedDataTracking) void {
    // Free template style strings
    if (tracking.template_primary_color) allocator.free(data.template.style.primary_color);
    if (tracking.template_accent_color) allocator.free(data.template.style.accent_color);

    // Free voucher strings
    if (tracking.voucher_number) allocator.free(data.voucher.number);
    if (tracking.voucher_date) allocator.free(data.voucher.date);
    if (tracking.voucher_tax_year) allocator.free(data.voucher.tax_year);

    // Free company strings
    if (tracking.company_name) allocator.free(data.company.name);
    if (tracking.company_reg_number) allocator.free(data.company.registration_number);
    if (tracking.company_addr_line1) allocator.free(data.company.registered_address.line1);
    if (tracking.company_addr_line2) if (data.company.registered_address.line2) |l2| allocator.free(l2);
    if (tracking.company_addr_city) if (data.company.registered_address.city) |c| allocator.free(c);
    if (tracking.company_addr_county) if (data.company.registered_address.county) |co| allocator.free(co);
    if (tracking.company_addr_postcode) allocator.free(data.company.registered_address.postcode);
    if (tracking.company_addr_country) allocator.free(data.company.registered_address.country);

    // Free shareholder strings
    if (tracking.shareholder_name) allocator.free(data.shareholder.name);
    if (tracking.shareholder_addr_line1) allocator.free(data.shareholder.address.line1);
    if (tracking.shareholder_addr_line2) if (data.shareholder.address.line2) |l2| allocator.free(l2);
    if (tracking.shareholder_addr_city) if (data.shareholder.address.city) |c| allocator.free(c);
    if (tracking.shareholder_addr_county) if (data.shareholder.address.county) |co| allocator.free(co);
    if (tracking.shareholder_addr_postcode) allocator.free(data.shareholder.address.postcode);
    if (tracking.shareholder_addr_country) allocator.free(data.shareholder.address.country);

    // Free dividend strings
    if (tracking.dividend_share_class) allocator.free(data.dividend.share_class);
    if (tracking.dwt_exemption_declaration_reference) {
        if (data.dividend.dwt_exemption.declaration_reference) |ref| allocator.free(ref);
    }

    // Free payment strings
    if (tracking.payment_method) allocator.free(data.payment.method);
    if (tracking.payment_date) allocator.free(data.payment.date);
    if (tracking.payment_reference) if (data.payment.reference) |ref| allocator.free(ref);

    // Free declaration strings
    if (tracking.declaration_resolution_date) allocator.free(data.declaration.resolution_date);
    if (tracking.declaration_payment_date) allocator.free(data.declaration.payment_date);

    // Free signatory strings
    if (tracking.signatory_name) allocator.free(data.signatory.name);
    if (tracking.signatory_date) allocator.free(data.signatory.date);
}

/// Parsed result with tracking for memory management
pub const ParsedResult = struct {
    data: DividendVoucherData,
    tracking: ParsedDataTracking,
};

fn parseDividendVoucherJson(allocator: std.mem.Allocator, json_str: []const u8) !ParsedResult {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const root = parsed.value.object;

    var tracking = ParsedDataTracking{};
    var data = DividendVoucherData{
        .voucher = .{ .number = "", .date = "" },
        .company = .{ .name = "", .registration_number = "", .registered_address = .{} },
        .shareholder = .{ .name = "", .address = .{} },
        .dividend = .{ .shares_held = 0, .rate_per_share = 0.0, .gross_amount = 0.0, .net_payable = 0.0 },
        .payment = .{ .date = "" },
        .declaration = .{ .resolution_date = "", .payment_date = "" },
        .signatory = .{ .name = "", .date = "" },
    };

    // Parse jurisdiction
    if (root.get("jurisdiction")) |j| {
        data.jurisdiction = Jurisdiction.fromString(j.string);
    }

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

    // Parse voucher
    if (root.get("voucher")) |v| {
        if (v.object.get("number")) |n| {
            data.voucher.number = try allocator.dupe(u8, n.string);
            tracking.voucher_number = true;
        } else {
            data.voucher.number = "";
        }
        if (v.object.get("date")) |d| {
            data.voucher.date = try allocator.dupe(u8, d.string);
            tracking.voucher_date = true;
        } else {
            data.voucher.date = "";
        }
        if (v.object.get("tax_year")) |ty| {
            data.voucher.tax_year = try allocator.dupe(u8, ty.string);
            tracking.voucher_tax_year = true;
        } else {
            data.voucher.tax_year = "2025/26";
        }
    }

    // Parse company
    if (root.get("company")) |c| {
        if (c.object.get("name")) |n| {
            data.company.name = try allocator.dupe(u8, n.string);
            tracking.company_name = true;
        } else {
            data.company.name = "";
        }
        if (c.object.get("registration_number")) |r| {
            data.company.registration_number = try allocator.dupe(u8, r.string);
            tracking.company_reg_number = true;
        } else {
            data.company.registration_number = "";
        }
        const addr_result = try parseAddressWithTracking(allocator, c.object.get("registered_address"));
        data.company.registered_address = addr_result.address;
        tracking.company_addr_line1 = addr_result.line1;
        tracking.company_addr_line2 = addr_result.line2;
        tracking.company_addr_city = addr_result.city;
        tracking.company_addr_county = addr_result.county;
        tracking.company_addr_postcode = addr_result.postcode;
        tracking.company_addr_country = addr_result.country;
    }

    // Parse shareholder
    if (root.get("shareholder")) |s| {
        if (s.object.get("name")) |n| {
            data.shareholder.name = try allocator.dupe(u8, n.string);
            tracking.shareholder_name = true;
        } else {
            data.shareholder.name = "";
        }
        const addr_result = try parseAddressWithTracking(allocator, s.object.get("address"));
        data.shareholder.address = addr_result.address;
        tracking.shareholder_addr_line1 = addr_result.line1;
        tracking.shareholder_addr_line2 = addr_result.line2;
        tracking.shareholder_addr_city = addr_result.city;
        tracking.shareholder_addr_county = addr_result.county;
        tracking.shareholder_addr_postcode = addr_result.postcode;
        tracking.shareholder_addr_country = addr_result.country;
    }

    // Parse dividend
    if (root.get("dividend")) |d| {
        data.dividend.shares_held = if (d.object.get("shares_held")) |v| @intCast(v.integer) else 0;
        if (d.object.get("share_class")) |v| {
            data.dividend.share_class = try allocator.dupe(u8, v.string);
            tracking.dividend_share_class = true;
        } else {
            data.dividend.share_class = "Ordinary";
        }
        data.dividend.rate_per_share = if (d.object.get("rate_per_share")) |v| getJsonFloatValue(v) else 0.0;
        data.dividend.gross_amount = if (d.object.get("gross_amount")) |v| getJsonFloatValue(v) else 0.0;
        data.dividend.tax_credit = if (d.object.get("tax_credit")) |v| getJsonFloatValue(v) else 0.0;

        // Irish DWT fields
        data.dividend.dwt_rate = if (d.object.get("dwt_rate")) |v| getJsonFloatValue(v) else 0.0;
        data.dividend.dwt_withheld = if (d.object.get("dwt_withheld")) |v| getJsonFloatValue(v) else 0.0;

        // Parse DWT exemption
        if (d.object.get("dwt_exemption")) |ex| {
            if (ex == .object) {
                data.dividend.dwt_exemption.applies = if (ex.object.get("applies")) |v| v.bool else false;
                if (ex.object.get("exemption_type")) |v| {
                    data.dividend.dwt_exemption.exemption_type = DwtExemptionType.fromString(v.string);
                }
                if (ex.object.get("declaration_reference")) |v| {
                    if (v != .null) {
                        data.dividend.dwt_exemption.declaration_reference = try allocator.dupe(u8, v.string);
                        tracking.dwt_exemption_declaration_reference = true;
                    }
                }
            }
        }

        data.dividend.net_payable = if (d.object.get("net_payable")) |v| getJsonFloatValue(v) else 0.0;
        data.dividend.currency = if (d.object.get("currency")) |v| Currency.fromString(v.string) else .GBP;
    }

    // Parse payment
    if (root.get("payment")) |p| {
        if (p.object.get("method")) |v| {
            data.payment.method = try allocator.dupe(u8, v.string);
            tracking.payment_method = true;
        } else {
            data.payment.method = "Bank Transfer";
        }
        if (p.object.get("date")) |v| {
            data.payment.date = try allocator.dupe(u8, v.string);
            tracking.payment_date = true;
        } else {
            data.payment.date = "";
        }
        if (p.object.get("reference")) |v| {
            data.payment.reference = try allocator.dupe(u8, v.string);
            tracking.payment_reference = true;
        } else {
            data.payment.reference = null;
        }
    }

    // Parse declaration
    if (root.get("declaration")) |d| {
        if (d.object.get("resolution_date")) |v| {
            data.declaration.resolution_date = try allocator.dupe(u8, v.string);
            tracking.declaration_resolution_date = true;
        } else {
            data.declaration.resolution_date = "";
        }
        if (d.object.get("payment_date")) |v| {
            data.declaration.payment_date = try allocator.dupe(u8, v.string);
            tracking.declaration_payment_date = true;
        } else {
            data.declaration.payment_date = "";
        }
    }

    // Parse signatory
    if (root.get("signatory")) |s| {
        data.signatory.role = if (s.object.get("role")) |v| SignatoryRole.fromString(v.string) else .Director;
        if (s.object.get("name")) |v| {
            data.signatory.name = try allocator.dupe(u8, v.string);
            tracking.signatory_name = true;
        } else {
            data.signatory.name = "";
        }
        if (s.object.get("date")) |v| {
            data.signatory.date = try allocator.dupe(u8, v.string);
            tracking.signatory_date = true;
        } else {
            data.signatory.date = "";
        }
    }

    return ParsedResult{ .data = data, .tracking = tracking };
}

// =============================================================================
// Tests
// =============================================================================

test "dividend voucher generation" {
    const allocator = std.testing.allocator;
    const pdf = try generateDemoDividendVoucher(allocator);
    defer allocator.free(pdf);
    try std.testing.expect(pdf.len > 1000);
}
