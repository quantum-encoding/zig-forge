//! Share Certificate Generator
//!
//! Generates UK-style share certificates with:
//! - Decorative borders
//! - Company logo and details
//! - Shareholder information
//! - Share class, quantity, and nominal value
//! - Signatory blocks with signatures
//!
//! Usage:
//! ```zig
//! const cert_data = ShareCertificateData{
//!     .certificate = .{ .number = "2025-002", .issue_date = "2025-12-21" },
//!     .company = .{ .name = "QUANTUM ENCODING LTD", ... },
//!     .holder = .{ .name = "LANCE JOHN PEARSON", ... },
//!     .shares = .{ .quantity = 5, .class = "Ordinary", ... },
//!     .signatories = &[_]Signatory{ ... },
//! };
//! const pdf = try generateShareCertificate(allocator, cert_data);
//! ```

const std = @import("std");
const document = @import("document.zig");

// =============================================================================
// Data Structures
// =============================================================================

/// Address structure for company, holder, and signatories
pub const Address = struct {
    line1: []const u8 = "",
    line2: ?[]const u8 = null,
    line3: ?[]const u8 = null,
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
        if (self.line3) |l3| if (l3.len > 0) try parts.append(allocator, l3);
        if (self.city) |c| if (c.len > 0) try parts.append(allocator, c);
        if (self.county) |co| if (co.len > 0) try parts.append(allocator, co);
        if (self.postcode.len > 0) try parts.append(allocator, self.postcode);
        if (self.country.len > 0 and !std.mem.eql(u8, self.country, "United Kingdom"))
            try parts.append(allocator, self.country);

        // Join with ", "
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

    /// Format address as multi-line for signature blocks
    pub fn formatMultiLine(self: Address, allocator: std.mem.Allocator) ![]const u8 {
        var parts: std.ArrayListUnmanaged([]const u8) = .empty;
        defer parts.deinit(allocator);

        // Track allocated city line so we can free it
        var city_copy: ?[]const u8 = null;
        defer if (city_copy) |cc| allocator.free(cc);

        if (self.line1.len > 0) try parts.append(allocator, self.line1);
        if (self.line2) |l2| if (l2.len > 0) try parts.append(allocator, l2);

        // City, postcode on same line
        var city_line_buf: [256]u8 = undefined;
        var city_line_len: usize = 0;
        if (self.city) |c| {
            if (c.len > 0) {
                @memcpy(city_line_buf[0..c.len], c);
                city_line_len = c.len;
            }
        }
        if (self.postcode.len > 0) {
            if (city_line_len > 0) {
                city_line_buf[city_line_len] = ',';
                city_line_buf[city_line_len + 1] = ' ';
                city_line_len += 2;
            }
            @memcpy(city_line_buf[city_line_len..][0..self.postcode.len], self.postcode);
            city_line_len += self.postcode.len;
        }
        if (self.county) |co| {
            if (co.len > 0) {
                if (city_line_len > 0) {
                    city_line_buf[city_line_len] = ' ';
                    city_line_len += 1;
                }
                @memcpy(city_line_buf[city_line_len..][0..co.len], co);
                city_line_len += co.len;
            }
        }
        if (city_line_len > 0) {
            city_copy = try allocator.dupe(u8, city_line_buf[0..city_line_len]);
            try parts.append(allocator, city_copy.?);
        }

        if (self.country.len > 0) try parts.append(allocator, self.country);

        // Join with "\n"
        var total_len: usize = 0;
        for (parts.items, 0..) |part, i| {
            total_len += part.len;
            if (i < parts.items.len - 1) total_len += 1;
        }

        var result = try allocator.alloc(u8, total_len);
        var pos: usize = 0;
        for (parts.items, 0..) |part, i| {
            @memcpy(result[pos..][0..part.len], part);
            pos += part.len;
            if (i < parts.items.len - 1) {
                result[pos] = '\n';
                pos += 1;
            }
        }

        return result;
    }
};

/// Image source (file path or base64)
pub const ImageSource = union(enum) {
    path: []const u8,
    base64: struct {
        data: []const u8,
        mime_type: []const u8,
    },
};

/// Image with optional dimensions
pub const Image = struct {
    source: ImageSource,
    width_mm: ?f32 = null,
    height_mm: ?f32 = null,
};

/// Template styling options
pub const TemplateStyle = struct {
    border_color: []const u8 = "#00B5AD", // Teal
    accent_color: []const u8 = "#00B5AD",
    font_family: []const u8 = "Helvetica",
};

/// Template configuration
pub const Template = struct {
    id: []const u8 = "share_certificate_uk",
    version: []const u8 = "1.0.0",
    style: TemplateStyle = .{},
};

/// Certificate metadata
pub const Certificate = struct {
    number: []const u8,
    issue_date: []const u8,
};

/// Company information
pub const Company = struct {
    name: []const u8,
    registration_number: []const u8,
    registered_address: Address,
    logo: ?Image = null,
};

/// Shareholder information
pub const Holder = struct {
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
            .EUR => "\\200", // € requires different handling
            .USD => "$",
        };
    }

    pub fn fromString(s: []const u8) Currency {
        if (std.mem.eql(u8, s, "EUR")) return .EUR;
        if (std.mem.eql(u8, s, "USD")) return .USD;
        return .GBP;
    }
};

/// Paid status
pub const PaidStatus = enum {
    fully_paid,
    partly_paid,
    unpaid,

    pub fn toString(self: PaidStatus) []const u8 {
        return switch (self) {
            .fully_paid => "fully paid",
            .partly_paid => "partly paid",
            .unpaid => "unpaid",
        };
    }

    pub fn fromString(s: []const u8) PaidStatus {
        if (std.mem.eql(u8, s, "partly paid")) return .partly_paid;
        if (std.mem.eql(u8, s, "unpaid")) return .unpaid;
        return .fully_paid;
    }
};

/// Share details
pub const Shares = struct {
    quantity: u32,
    quantity_words: ?[]const u8 = null, // Auto-generated if null
    class: []const u8 = "Ordinary",
    nominal_value: f64,
    currency: Currency = .GBP,
    paid_status: PaidStatus = .fully_paid,
    share_numbers: ?struct {
        from: u32,
        to: u32,
    } = null,
};

/// Signatory role
pub const SignatoryRole = enum {
    Director,
    Secretary,
    Witness,
    AuthorisedSignatory,

    pub fn toString(self: SignatoryRole) []const u8 {
        return switch (self) {
            .Director => "Director",
            .Secretary => "Secretary",
            .Witness => "Witness",
            .AuthorisedSignatory => "Authorised Signatory",
        };
    }

    pub fn fromString(s: []const u8) SignatoryRole {
        if (std.mem.eql(u8, s, "Secretary")) return .Secretary;
        if (std.mem.eql(u8, s, "Witness")) return .Witness;
        if (std.mem.eql(u8, s, "Authorised Signatory")) return .AuthorisedSignatory;
        return .Director;
    }
};

/// Signatory information
pub const Signatory = struct {
    role: SignatoryRole = .Director,
    name: []const u8,
    signature: ?Image = null,
    date: []const u8,
    address: ?Address = null,
};

/// Custom text overrides — allows reusing the certificate layout for
/// warranty certificates, completion certificates, awards, etc.
/// When null, defaults to share certificate text.
pub const CustomText = struct {
    /// Main title (default: "SHARE CERTIFICATE")
    title: ?[]const u8 = null,
    /// Subtitle shown below company details (default: none)
    subtitle: ?[]const u8 = null,
    /// Left header label (default: "Share Certificate Number: {number}")
    header_left: ?[]const u8 = null,
    /// Right header label (default: "Number of Shares: {quantity}")
    header_right: ?[]const u8 = null,
    /// Full certification body text. Use {{holder_name}}, {{holder_address}},
    /// {{company_name}} placeholders. When null, uses default share cert text.
    certification_text: ?[]const u8 = null,
    /// Signing statement (default: "This certificate is signed by the Company as follows:")
    signing_statement: ?[]const u8 = null,
    /// Custom key-value detail rows shown between company details and cert text.
    /// e.g., [["Property", "123 Oak Lane"], ["System", "6.6kW Solar PV"]]
    detail_rows: ?[]const [2][]const u8 = null,
};

/// Complete share certificate data
pub const ShareCertificateData = struct {
    template: Template = .{},
    certificate: Certificate,
    company: Company,
    holder: Holder,
    shares: Shares,
    signatories: []const Signatory,
    /// Optional text overrides for non-share certificate use (warranty, completion, etc.)
    custom: CustomText = .{},
};

// =============================================================================
// Number to Words Conversion
// =============================================================================

const ones = [_][]const u8{
    "", "ONE", "TWO", "THREE", "FOUR", "FIVE", "SIX", "SEVEN", "EIGHT", "NINE",
    "TEN", "ELEVEN", "TWELVE", "THIRTEEN", "FOURTEEN", "FIFTEEN", "SIXTEEN",
    "SEVENTEEN", "EIGHTEEN", "NINETEEN",
};

const tens = [_][]const u8{
    "", "", "TWENTY", "THIRTY", "FORTY", "FIFTY", "SIXTY", "SEVENTY", "EIGHTY", "NINETY",
};

/// Convert a number to words (e.g., 5 -> "FIVE", 123 -> "ONE HUNDRED AND TWENTY THREE")
pub fn numberToWords(allocator: std.mem.Allocator, n: u32) ![]const u8 {
    if (n == 0) return try allocator.dupe(u8, "ZERO");
    if (n < 20) return try allocator.dupe(u8, ones[n]);
    if (n < 100) {
        const t = n / 10;
        const o = n % 10;
        if (o == 0) {
            return try allocator.dupe(u8, tens[t]);
        } else {
            return try std.fmt.allocPrint(allocator, "{s} {s}", .{ tens[t], ones[o] });
        }
    }
    if (n < 1000) {
        const h = n / 100;
        const rem = n % 100;
        if (rem == 0) {
            return try std.fmt.allocPrint(allocator, "{s} HUNDRED", .{ones[h]});
        } else {
            const rem_words = try numberToWords(allocator, rem);
            defer allocator.free(rem_words);
            return try std.fmt.allocPrint(allocator, "{s} HUNDRED AND {s}", .{ ones[h], rem_words });
        }
    }
    if (n < 1000000) {
        const th = n / 1000;
        const rem = n % 1000;
        const th_words = try numberToWords(allocator, th);
        defer allocator.free(th_words);
        if (rem == 0) {
            return try std.fmt.allocPrint(allocator, "{s} THOUSAND", .{th_words});
        } else {
            const rem_words = try numberToWords(allocator, rem);
            defer allocator.free(rem_words);
            if (rem < 100) {
                return try std.fmt.allocPrint(allocator, "{s} THOUSAND AND {s}", .{ th_words, rem_words });
            } else {
                return try std.fmt.allocPrint(allocator, "{s} THOUSAND {s}", .{ th_words, rem_words });
            }
        }
    }
    // For very large numbers, just return the digits
    return try std.fmt.allocPrint(allocator, "{d}", .{n});
}

// =============================================================================
// Certificate Renderer
// =============================================================================

pub const ShareCertificateRenderer = struct {
    allocator: std.mem.Allocator,
    doc: document.PdfDocument,
    data: ShareCertificateData,

    // Page dimensions (A4 landscape)
    page_width: f32 = 842, // A4 landscape width in points
    page_height: f32 = 595, // A4 landscape height in points

    // Margins
    margin: f32 = 30,
    border_width: f32 = 3,
    inner_border_offset: f32 = 8,

    // Font IDs
    font_regular: []const u8 = "F0",
    font_bold: []const u8 = "F1",

    pub fn init(allocator: std.mem.Allocator, data: ShareCertificateData) ShareCertificateRenderer {
        var renderer = ShareCertificateRenderer{
            .allocator = allocator,
            .doc = document.PdfDocument.init(allocator),
            .data = data,
        };

        // Register fonts and get their IDs
        renderer.font_regular = renderer.doc.getFontId(.helvetica);
        renderer.font_bold = renderer.doc.getFontId(.helvetica_bold);

        return renderer;
    }

    pub fn deinit(self: *ShareCertificateRenderer) void {
        self.doc.deinit();
    }

    /// Load image from file path
    /// Note: This requires an absolute path or implementation would need global IO context
    fn loadImageFromFile(self: *ShareCertificateRenderer, file_path: []const u8) ![]u8 {
        // File I/O requires absolute paths and global IO context
        // For now, we try to read the file directly from the heap-allocated path
        _ = file_path; // Suppress unused warning
        _ = self;
        return error.FilePathNotSupported;
    }

    /// Draw the outer decorative border
    fn drawBorder(self: *ShareCertificateRenderer, content: *document.ContentStream) !void {
        const color = document.Color.fromHex(self.data.template.style.border_color);

        // Outer border
        const x1 = self.margin;
        const y1 = self.margin;
        const x2 = self.page_width - self.margin;
        const y2 = self.page_height - self.margin;

        // Draw outer rectangle with thick stroke
        try content.setStrokeColor(color);
        try content.setLineWidth(self.border_width);
        try content.moveTo(x1, y1);
        try content.lineTo(x2, y1);
        try content.lineTo(x2, y2);
        try content.lineTo(x1, y2);
        try content.closePath();
        try content.stroke();

        // Inner border (thinner)
        const ix1 = x1 + self.inner_border_offset;
        const iy1 = y1 + self.inner_border_offset;
        const ix2 = x2 - self.inner_border_offset;
        const iy2 = y2 - self.inner_border_offset;

        try content.setLineWidth(1);
        try content.moveTo(ix1, iy1);
        try content.lineTo(ix2, iy1);
        try content.lineTo(ix2, iy2);
        try content.lineTo(ix1, iy2);
        try content.closePath();
        try content.stroke();
    }

    /// Draw the header row (certificate number and share count / custom labels)
    fn drawHeader(self: *ShareCertificateRenderer, content: *document.ContentStream) !void {
        const y = self.page_height - self.margin - 35;
        const left_x = self.margin + 25;
        const right_x = self.page_width - self.margin - 25;
        const gray_dark = document.Color{ .r = 0.2, .g = 0.2, .b = 0.2 };

        // Left header
        if (self.data.custom.header_left) |custom_left| {
            try content.drawText(custom_left, left_x, y, self.font_regular, 10, gray_dark);
        } else {
            var cert_text_buf: [64]u8 = undefined;
            const cert_text = std.fmt.bufPrint(&cert_text_buf, "Share Certificate Number: {s}", .{self.data.certificate.number}) catch "Share Certificate Number:";
            try content.drawText(cert_text, left_x, y, self.font_regular, 10, gray_dark);
        }

        // Right header
        if (self.data.custom.header_right) |custom_right| {
            const text_width = document.Font.helvetica.measureText(custom_right, 10);
            try content.drawText(custom_right, right_x - text_width, y, self.font_regular, 10, gray_dark);
        } else {
            var shares_text_buf: [64]u8 = undefined;
            const shares_text = std.fmt.bufPrint(&shares_text_buf, "Number of Shares: {d}", .{self.data.shares.quantity}) catch "Number of Shares:";
            const text_width = document.Font.helvetica.measureText(shares_text, 10);
            try content.drawText(shares_text, right_x - text_width, y, self.font_regular, 10, gray_dark);
        }
    }

    /// Draw company logo if provided
    fn drawLogo(self: *ShareCertificateRenderer, content: *document.ContentStream) !?[]const u8 {
        if (self.data.company.logo) |logo| {
            const center_x = self.page_width / 2;
            const logo_y = self.page_height - self.margin - 140;

            // Default logo size
            const logo_w: f32 = if (logo.width_mm) |w| w * 2.83465 else 100; // mm to points
            const logo_h: f32 = if (logo.height_mm) |h| h * 2.83465 else 80;

            switch (logo.source) {
                .base64 => |b64| {
                    // Decode base64 and add image
                    const decoded = try decodeBase64(self.allocator, b64.data);
                    defer self.allocator.free(decoded);

                    const is_png = std.mem.eql(u8, b64.mime_type, "image/png");
                    const img = document.Image{
                        .width = @intFromFloat(logo_w),
                        .height = @intFromFloat(logo_h),
                        .format = if (is_png) .png_rgba else .jpeg,
                        .data = decoded,
                    };
                    const img_id = try self.doc.addImage(img);
                    try content.drawImage(img_id, center_x - logo_w / 2, logo_y - logo_h, logo_w, logo_h);
                    return img_id;
                },
                .path => {
                    // File path handling would require file I/O
                    // For now, skip logo if path-based
                    return null;
                },
            }
        }
        return null;
    }

    /// Draw the main title
    fn drawTitle(self: *ShareCertificateRenderer, content: *document.ContentStream) !void {
        const color = document.Color.fromHex(self.data.template.style.accent_color);
        var y = self.page_height - self.margin - 200;

        const title = self.data.custom.title orelse "SHARE CERTIFICATE";
        const title_width = document.Font.helvetica_bold.measureText(title, 36);
        try content.drawText(title, (self.page_width - title_width) / 2, y, self.font_bold, 36, color);

        // Optional subtitle
        if (self.data.custom.subtitle) |subtitle| {
            y -= 28;
            const sub_width = document.Font.helvetica.measureText(subtitle, 14);
            const text_color = document.Color{ .r = 0.3, .g = 0.3, .b = 0.3 };
            try content.drawText(subtitle, (self.page_width - sub_width) / 2, y, self.font_regular, 14, text_color);
        }
    }

    /// Draw company details
    fn drawCompanyDetails(self: *ShareCertificateRenderer, content: *document.ContentStream) !void {
        var y = self.page_height - self.margin - 255;
        const center_x = self.page_width / 2;
        const text_color = document.Color{ .r = 0.1, .g = 0.1, .b = 0.1 };

        // Company name and registration number
        var company_line_buf: [256]u8 = undefined;
        const company_line = std.fmt.bufPrint(&company_line_buf, "{s} {s}", .{
            self.data.company.name,
            self.data.company.registration_number,
        }) catch self.data.company.name;

        const company_width = document.Font.helvetica_bold.measureText(company_line, 12);
        try content.drawText(company_line, center_x - company_width / 2, y, self.font_bold, 12, text_color);

        y -= 18;

        // Registered address
        const addr = try self.data.company.registered_address.formatSingleLine(self.allocator);
        defer self.allocator.free(addr);

        var addr_line_buf: [512]u8 = undefined;
        const addr_line = std.fmt.bufPrint(&addr_line_buf, "{s} (the \"Company\")", .{addr}) catch addr;
        const addr_width = document.Font.helvetica_bold.measureText(addr_line, 11);
        try content.drawText(addr_line, center_x - addr_width / 2, y, self.font_bold, 11, text_color);
    }

    /// Draw the certification text (custom or default share cert text).
    /// Returns the Y position after the last line (for positioning signatures below).
    fn drawCertificationText(self: *ShareCertificateRenderer, content: *document.ContentStream) !f32 {
        var y = self.page_height - self.margin - 310;
        const left_margin = self.margin + 40;
        const right_margin = self.page_width - self.margin - 40;
        const max_width = right_margin - left_margin;
        const text_color = document.Color{ .r = 0.1, .g = 0.1, .b = 0.1 };
        const center_x = self.page_width / 2;
        const accent = document.Color.fromHex(self.data.template.style.accent_color);

        // Custom detail rows (e.g., Property, System, Warranty Period)
        if (self.data.custom.detail_rows) |rows| {
            for (rows) |row| {
                // Label (bold)
                const label_width = document.Font.helvetica_bold.measureText(row[0], 11);
                try content.drawText(row[0], left_margin, y, self.font_bold, 11, accent);
                // Value
                try content.drawText(row[1], left_margin + label_width + 10, y, self.font_regular, 11, text_color);
                y -= 20;
            }
            y -= 10;
        }

        // Certification body text
        const cert_text = if (self.data.custom.certification_text) |custom| custom else blk: {
            // Default share certificate text
            const holder_addr = try self.data.holder.address.formatSingleLine(self.allocator);
            defer self.allocator.free(holder_addr);

            const qty_words = if (self.data.shares.quantity_words) |qw|
                try self.allocator.dupe(u8, qw)
            else
                try numberToWords(self.allocator, self.data.shares.quantity);
            defer self.allocator.free(qty_words);

            var value_buf: [32]u8 = undefined;
            const value_str = if (self.data.shares.nominal_value < 1.0)
                std.fmt.bufPrint(&value_buf, "\\2430.{d:0>2}", .{@as(u32, @intFromFloat(self.data.shares.nominal_value * 100))}) catch "\\2430.01"
            else
                std.fmt.bufPrint(&value_buf, "\\243{d:.2}", .{self.data.shares.nominal_value}) catch "\\2431.00";

            var cert_buf: [1024]u8 = undefined;
            break :blk std.fmt.bufPrint(&cert_buf, "This is to certify that {s}, of {s} is the registered holder of {d} ({s}) [{s}] shares of {s} each [{s}] in the Company.", .{
                self.data.holder.name,
                holder_addr,
                self.data.shares.quantity,
                qty_words,
                self.data.shares.class,
                value_str,
                self.data.shares.paid_status.toString(),
            }) catch "This is to certify that the holder is the registered holder of shares in the Company.";
        };

        // Word wrap and draw centered
        var wrapped = try document.wrapText(self.allocator, cert_text, .helvetica, 11, max_width);
        defer wrapped.deinit();

        for (wrapped.lines) |line| {
            const line_width = document.Font.helvetica.measureText(line, 11);
            try content.drawText(line, center_x - line_width / 2, y, self.font_regular, 11, text_color);
            y -= 16;
        }

        // Signing statement
        y -= 20;
        const signing_text = self.data.custom.signing_statement orelse "This certificate is signed by the Company as follows:";
        const signing_width = document.Font.helvetica.measureText(signing_text, 11);
        try content.drawText(signing_text, center_x - signing_width / 2, y, self.font_regular, 11, text_color);

        return y - 20; // Return Y below the signing statement
    }

    /// Draw signature blocks. sig_y_hint: Y position from cert text (0 = use default).
    fn drawSignatures(self: *ShareCertificateRenderer, content: *document.ContentStream, sig_y_hint: f32) !void {
        const num_sigs = @min(self.data.signatories.len, 4);
        if (num_sigs == 0) return;

        // Use hint from cert text if provided, otherwise fixed position
        const default_y = self.page_height - self.margin - 380;
        const sig_start_y = if (sig_y_hint > 0 and sig_y_hint < default_y) sig_y_hint else default_y;
        const content_width = self.page_width - 2 * self.margin - 80;
        const text_color = document.Color{ .r = 0.1, .g = 0.1, .b = 0.1 };
        const gray_color = document.Color{ .r = 0.3, .g = 0.3, .b = 0.3 };

        // Calculate column positions
        var col_positions: [4]f32 = undefined;
        const col_width = content_width / @as(f32, @floatFromInt(num_sigs));
        for (0..num_sigs) |i| {
            col_positions[i] = self.margin + 40 + col_width * @as(f32, @floatFromInt(i)) + col_width / 2;
        }

        for (self.data.signatories[0..num_sigs], 0..) |sig, i| {
            const col_x = col_positions[i];
            var y = sig_start_y;

            // Role (bold)
            const role_text = sig.role.toString();
            const role_width = document.Font.helvetica_bold.measureText(role_text, 10);
            try content.drawText(role_text, col_x - role_width / 2, y, self.font_bold, 10, text_color);

            y -= 64; // Space for signature (increased for more room to paste signatures)

            // Draw signature image if provided
            const line_width: f32 = 120;
            if (sig.signature) |sig_img| {
                // Default signature image size (can be overridden by width_mm/height_mm)
                const sig_w: f32 = if (sig_img.width_mm) |w| w * 2.83465 else 80; // mm to points
                const sig_h: f32 = if (sig_img.height_mm) |h| h * 2.83465 else 30;

                switch (sig_img.source) {
                    .base64 => |b64| {
                        const decoded = decodeBase64(self.allocator, b64.data) catch null;
                        if (decoded) |img_data| {
                            defer self.allocator.free(img_data);

                            const is_png = std.mem.eql(u8, b64.mime_type, "image/png");
                            const img = document.Image{
                                .width = @intFromFloat(sig_w),
                                .height = @intFromFloat(sig_h),
                                .format = if (is_png) .png_rgba else .jpeg,
                                .data = img_data,
                            };
                            if (self.doc.addImage(img)) |img_id| {
                                // Position signature image above the line, centered
                                try content.drawImage(img_id, col_x - sig_w / 2, y - sig_h + 5, sig_w, sig_h);
                            } else |_| {}
                        }
                    },
                    .path => |file_path| {
                        // Load signature image from file
                        if (self.loadImageFromFile(file_path)) |img_data| {
                            defer self.allocator.free(img_data);
                            const img = document.Image{
                                .width = @intFromFloat(sig_w),
                                .height = @intFromFloat(sig_h),
                                .format = .png_rgba, // Default to PNG, could be extended
                                .data = img_data,
                            };
                            if (self.doc.addImage(img)) |img_id| {
                                try content.drawImage(img_id, col_x - sig_w / 2, y - sig_h + 5, sig_w, sig_h);
                            } else |_| {}
                        } else |_| {}
                    },
                }
            }

            // Signature line
            try content.setStrokeColor(gray_color);
            try content.setLineWidth(0.5);
            try content.moveTo(col_x - line_width / 2, y);
            try content.lineTo(col_x + line_width / 2, y);
            try content.stroke();

            y -= 10; // Reduced from 12

            // "(Signature)" label
            const sig_label = "(Signature)";
            const sig_label_width = document.Font.helvetica.measureText(sig_label, 8);
            try content.drawText(sig_label, col_x - sig_label_width / 2, y, self.font_regular, 8, gray_color);

            y -= 14; // Reduced from 18

            // Name
            const name_width = document.Font.helvetica.measureText(sig.name, 9);
            try content.drawText(sig.name, col_x - name_width / 2, y, self.font_regular, 9, text_color);

            y -= 12; // Reduced from 14

            // Date
            const date_width = document.Font.helvetica.measureText(sig.date, 9);
            try content.drawText(sig.date, col_x - date_width / 2, y, self.font_regular, 9, text_color);

            y -= 12; // Reduced from 14

            // Address (if provided) - use smaller font
            if (sig.address) |addr| {
                const addr_lines = try addr.formatMultiLine(self.allocator);
                defer self.allocator.free(addr_lines);

                var line_iter = std.mem.splitScalar(u8, addr_lines, '\n');
                var addr_line_count: u32 = 0;
                while (line_iter.next()) |line| {
                    // Limit to 4 address lines to prevent overflow
                    if (addr_line_count >= 4) break;
                    const line_width_px = document.Font.helvetica.measureText(line, 8);
                    try content.drawText(line, col_x - line_width_px / 2, y, self.font_regular, 8, text_color);
                    y -= 10; // Reduced from 12
                    addr_line_count += 1;
                }
            }
        }
    }

    /// Render the complete certificate
    pub fn render(self: *ShareCertificateRenderer) ![]const u8 {
        var content = document.ContentStream.init(self.allocator);
        defer content.deinit(); // Always cleanup, addPage copies the content

        // Set page size to A4 landscape
        self.doc.setPageSize(.{ .width = 842, .height = 595 });

        // Draw all elements
        try self.drawBorder(&content);
        try self.drawHeader(&content);
        _ = try self.drawLogo(&content);
        try self.drawTitle(&content);
        try self.drawCompanyDetails(&content);
        const cert_bottom_y = try self.drawCertificationText(&content);
        try self.drawSignatures(&content, cert_bottom_y);

        // Add page to document
        try self.doc.addPage(&content);

        return self.doc.build();
    }
};

// =============================================================================
// Helper Functions
// =============================================================================

/// Decode base64 string
fn decodeBase64(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    // Strip data URI prefix if present
    var data = encoded;
    if (std.mem.indexOf(u8, encoded, ",")) |comma_pos| {
        data = encoded[comma_pos + 1 ..];
    }

    const decoder = std.base64.standard;
    const decoded_len = try decoder.Decoder.calcSizeForSlice(data);
    const decoded = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(decoded);

    _ = try decoder.Decoder.decode(decoded, data);
    return decoded;
}

// =============================================================================
// Public API
// =============================================================================

/// Generate a share certificate PDF
pub fn generateShareCertificate(allocator: std.mem.Allocator, data: ShareCertificateData) ![]u8 {
    var renderer = ShareCertificateRenderer.init(allocator, data);
    defer renderer.deinit();

    const pdf_output = try renderer.render();
    return try allocator.dupe(u8, pdf_output);
}

/// Generate share certificate from JSON string
pub fn generateShareCertificateFromJson(allocator: std.mem.Allocator, json_str: []const u8) ![]u8 {
    const parsed = try parseShareCertificateJson(allocator, json_str);
    // Note: parsed data contains allocated strings that should be freed
    // For simplicity, we'll let them leak in this version (they're small)

    return generateShareCertificate(allocator, parsed);
}

/// Generate a demo share certificate
pub fn generateDemoShareCertificate(allocator: std.mem.Allocator) ![]u8 {
    const data = ShareCertificateData{
        .template = .{
            .id = "share_certificate_uk",
            .version = "1.0.0",
            .style = .{
                .border_color = "#00B5AD",
                .accent_color = "#00B5AD",
            },
        },
        .certificate = .{
            .number = "2025-002",
            .issue_date = "2025-12-21",
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
        .holder = .{
            .name = "LANCE JOHN PEARSON",
            .address = .{
                .line1 = "172 SEA FRONT",
                .city = "HAYLING ISLAND",
                .postcode = "PO11 9HP",
                .country = "United Kingdom",
            },
        },
        .shares = .{
            .quantity = 5,
            .class = "Ordinary",
            .nominal_value = 0.01,
            .currency = .GBP,
            .paid_status = .fully_paid,
        },
        .signatories = &[_]Signatory{
            .{
                .role = .Director,
                .name = "RICHARD ALEXANDER TUNE",
                .date = "21/12/2025",
                .address = .{
                    .line1 = "COIN",
                    .city = "MALAGA",
                    .postcode = "29100",
                    .country = "SPAIN",
                },
            },
            .{
                .role = .Witness,
                .name = "SUSANA CALERO CALERO",
                .date = "21/12/2025",
                .address = .{
                    .line1 = "PARTIDO MALARA ALTA 166",
                    .line2 = "COIN",
                    .postcode = "29100",
                    .city = "MALAGA",
                    .country = "SPAIN",
                },
            },
        },
    };

    return generateShareCertificate(allocator, data);
}

// =============================================================================
// JSON Parsing
// =============================================================================

fn parseShareCertificateJson(allocator: std.mem.Allocator, json_str: []const u8) !ShareCertificateData {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const root = parsed.value.object;

    var data = ShareCertificateData{
        .certificate = undefined,
        .company = undefined,
        .holder = undefined,
        .shares = undefined,
        .signatories = &[_]Signatory{},
    };

    // Parse template
    if (root.get("template")) |t| {
        if (t.object.get("id")) |v| data.template.id = try allocator.dupe(u8, v.string);
        if (t.object.get("version")) |v| data.template.version = try allocator.dupe(u8, v.string);
        if (t.object.get("style")) |s| {
            if (s.object.get("border_color")) |v| data.template.style.border_color = try allocator.dupe(u8, v.string);
            if (s.object.get("accent_color")) |v| data.template.style.accent_color = try allocator.dupe(u8, v.string);
            if (s.object.get("font_family")) |v| data.template.style.font_family = try allocator.dupe(u8, v.string);
        }
    }

    // Parse certificate
    if (root.get("certificate")) |c| {
        data.certificate = .{
            .number = if (c.object.get("number")) |v| try allocator.dupe(u8, v.string) else "",
            .issue_date = if (c.object.get("issue_date")) |v| try allocator.dupe(u8, v.string) else "",
        };
    }

    // Parse company
    if (root.get("company")) |c| {
        data.company = .{
            .name = if (c.object.get("name")) |v| try allocator.dupe(u8, v.string) else "",
            .registration_number = if (c.object.get("registration_number")) |v| try allocator.dupe(u8, v.string) else "",
            .registered_address = try parseAddress(allocator, c.object.get("registered_address")),
        };
        // Logo parsing would go here
    }

    // Parse holder
    if (root.get("holder")) |h| {
        data.holder = .{
            .name = if (h.object.get("name")) |v| try allocator.dupe(u8, v.string) else "",
            .address = try parseAddress(allocator, h.object.get("address")),
        };
    }

    // Parse shares
    if (root.get("shares")) |s| {
        data.shares = .{
            .quantity = if (s.object.get("quantity")) |v| @intCast(v.integer) else 0,
            .quantity_words = if (s.object.get("quantity_words")) |v| try allocator.dupe(u8, v.string) else null,
            .class = if (s.object.get("class")) |v| try allocator.dupe(u8, v.string) else "Ordinary",
            .nominal_value = if (s.object.get("nominal_value")) |v| getJsonFloatValue(v) else 0.01,
            .currency = if (s.object.get("currency")) |v| Currency.fromString(v.string) else .GBP,
            .paid_status = if (s.object.get("paid_status")) |v| PaidStatus.fromString(v.string) else .fully_paid,
        };
    }

    // Parse signatories
    if (root.get("signatories")) |sigs| {
        const sigs_arr = sigs.array.items;
        var signatories = try allocator.alloc(Signatory, sigs_arr.len);
        for (sigs_arr, 0..) |sig_val, i| {
            signatories[i] = .{
                .role = if (sig_val.object.get("role")) |v| SignatoryRole.fromString(v.string) else .Director,
                .name = if (sig_val.object.get("name")) |v| try allocator.dupe(u8, v.string) else "",
                .date = if (sig_val.object.get("date")) |v| try allocator.dupe(u8, v.string) else "",
                .address = try parseAddress(allocator, sig_val.object.get("address")),
                .signature = try parseImage(allocator, sig_val.object.get("signature")),
            };
        }
        data.signatories = signatories;
    }

    // Parse custom text overrides (for warranty certs, completion certs, etc.)
    if (root.get("custom")) |c| {
        if (c.object.get("title")) |v| data.custom.title = try allocator.dupe(u8, v.string);
        if (c.object.get("subtitle")) |v| data.custom.subtitle = try allocator.dupe(u8, v.string);
        if (c.object.get("header_left")) |v| data.custom.header_left = try allocator.dupe(u8, v.string);
        if (c.object.get("header_right")) |v| data.custom.header_right = try allocator.dupe(u8, v.string);
        if (c.object.get("certification_text")) |v| data.custom.certification_text = try allocator.dupe(u8, v.string);
        if (c.object.get("signing_statement")) |v| data.custom.signing_statement = try allocator.dupe(u8, v.string);

        if (c.object.get("detail_rows")) |rows_val| {
            const arr = rows_val.array.items;
            var rows = try allocator.alloc([2][]const u8, arr.len);
            for (arr, 0..) |row, i| {
                const row_arr = row.array.items;
                rows[i] = .{
                    if (row_arr.len > 0) try allocator.dupe(u8, row_arr[0].string) else "",
                    if (row_arr.len > 1) try allocator.dupe(u8, row_arr[1].string) else "",
                };
            }
            data.custom.detail_rows = rows;
        }
    }

    return data;
}

/// Parse image from JSON (supports base64 data or file path)
fn parseImage(allocator: std.mem.Allocator, img_val: ?std.json.Value) !?Image {
    if (img_val) |img| {
        if (img == .object) {
            // Check for base64 data
            if (img.object.get("data")) |data_val| {
                const mime_type = if (img.object.get("mime_type")) |m| try allocator.dupe(u8, m.string) else "image/png";
                return Image{
                    .source = .{
                        .base64 = .{
                            .data = try allocator.dupe(u8, data_val.string),
                            .mime_type = mime_type,
                        },
                    },
                    .width_mm = if (img.object.get("width_mm")) |w| @as(f32, @floatCast(getJsonFloatValue(w))) else null,
                    .height_mm = if (img.object.get("height_mm")) |h| @as(f32, @floatCast(getJsonFloatValue(h))) else null,
                };
            }
            // Check for file path
            if (img.object.get("path")) |path_val| {
                return Image{
                    .source = .{ .path = try allocator.dupe(u8, path_val.string) },
                    .width_mm = if (img.object.get("width_mm")) |w| @as(f32, @floatCast(getJsonFloatValue(w))) else null,
                    .height_mm = if (img.object.get("height_mm")) |h| @as(f32, @floatCast(getJsonFloatValue(h))) else null,
                };
            }
        }
    }
    return null;
}

fn parseAddress(allocator: std.mem.Allocator, addr_val: ?std.json.Value) !Address {
    if (addr_val) |a| {
        if (a == .object) {
            return .{
                .line1 = if (a.object.get("line1")) |v| if (v == .string) try allocator.dupe(u8, v.string) else "" else "",
                .line2 = if (a.object.get("line2")) |v| if (v == .string) try allocator.dupe(u8, v.string) else null else null,
                .line3 = if (a.object.get("line3")) |v| if (v == .string) try allocator.dupe(u8, v.string) else null else null,
                .city = if (a.object.get("city")) |v| if (v == .string) try allocator.dupe(u8, v.string) else null else null,
                .county = if (a.object.get("county")) |v| if (v == .string) try allocator.dupe(u8, v.string) else null else null,
                .postcode = if (a.object.get("postcode")) |v| if (v == .string) try allocator.dupe(u8, v.string) else "" else "",
                .country = if (a.object.get("country")) |v| if (v == .string) try allocator.dupe(u8, v.string) else "United Kingdom" else "United Kingdom",
            };
        }
    }
    return .{};
}

fn getJsonFloatValue(v: std.json.Value) f64 {
    return switch (v) {
        .float => v.float,
        .integer => @floatFromInt(v.integer),
        else => 0,
    };
}

// =============================================================================
// Tests
// =============================================================================

test "number to words" {
    const allocator = std.testing.allocator;

    const five = try numberToWords(allocator, 5);
    defer allocator.free(five);
    try std.testing.expectEqualStrings("FIVE", five);

    const hundred = try numberToWords(allocator, 100);
    defer allocator.free(hundred);
    try std.testing.expectEqualStrings("ONE HUNDRED", hundred);

    const complex = try numberToWords(allocator, 1234);
    defer allocator.free(complex);
    try std.testing.expectEqualStrings("ONE THOUSAND TWO HUNDRED AND THIRTY FOUR", complex);
}

test "generate demo certificate" {
    const allocator = std.testing.allocator;
    const pdf = try generateDemoShareCertificate(allocator);
    defer allocator.free(pdf);

    try std.testing.expect(pdf.len > 0);
    try std.testing.expect(std.mem.startsWith(u8, pdf, "%PDF"));
}
