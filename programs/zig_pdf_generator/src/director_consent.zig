//! Director Consent to Act Generator
//!
//! Generates professional Director Consent to Act forms compliant with
//! UK Companies Act 2006 requirements. Required when appointing new directors.
//!
//! Features:
//! - Multiple declaration types (appointment, reappointment, shadow director)
//! - Personal details and qualifications
//! - Statutory declarations
//! - Signature block with witness option

const std = @import("std");
const document = @import("document.zig");

// =============================================================================
// Data Structures
// =============================================================================

pub const Address = struct {
    line1: []const u8,
    line2: ?[]const u8 = null,
    city: []const u8,
    county: ?[]const u8 = null,
    postcode: []const u8,
    country: []const u8 = "United Kingdom",
};

pub const Director = struct {
    title: ?[]const u8 = null, // Mr, Mrs, Ms, Dr, etc.
    forenames: []const u8,
    surname: []const u8,
    former_names: ?[]const u8 = null,
    date_of_birth: []const u8, // YYYY-MM-DD or DD/MM/YYYY
    nationality: []const u8,
    occupation: []const u8,
    residential_address: Address,
    service_address: ?Address = null, // If different from residential

    // Additional requirements
    has_directorships: bool = false,
    other_directorships: ?[]const []const u8 = null,
};

pub const Company = struct {
    name: []const u8,
    registration_number: ?[]const u8 = null,
    registered_office: ?Address = null,
};

pub const ConsentType = enum {
    NewAppointment,
    Reappointment,
    ExistingDirector, // For confirming details
};

pub const Witness = struct {
    name: []const u8,
    address: ?[]const u8 = null,
    occupation: ?[]const u8 = null,
};

pub const TemplateStyle = struct {
    primary_color: []const u8 = "#1a365d", // Dark blue
    accent_color: []const u8 = "#2b6cb0",
    show_statutory_text: bool = true,
    include_witness_block: bool = true,
};

pub const Template = struct {
    style: TemplateStyle = .{},
};

pub const DirectorConsentData = struct {
    company: Company,
    director: Director,
    consent_type: ConsentType = .NewAppointment,
    appointment_date: ?[]const u8 = null,
    witness: ?Witness = null,
    template: Template = .{},

    // Optional custom declarations
    additional_declarations: ?[]const []const u8 = null,
    notes: ?[]const u8 = null,
};

// =============================================================================
// Renderer
// =============================================================================

pub const DirectorConsentRenderer = struct {
    allocator: std.mem.Allocator,
    doc: document.PdfDocument,
    data: DirectorConsentData,

    // Page dimensions (A4)
    page_width: f32 = 595,
    page_height: f32 = 842,

    // Margins
    margin: f32 = 50,

    // Font IDs
    font_regular: []const u8 = "F0",
    font_bold: []const u8 = "F1",

    // Current Y position
    current_y: f32 = 0,

    pub fn init(allocator: std.mem.Allocator, data: DirectorConsentData) DirectorConsentRenderer {
        var renderer = DirectorConsentRenderer{
            .allocator = allocator,
            .doc = document.PdfDocument.init(allocator),
            .data = data,
        };

        renderer.font_regular = renderer.doc.getFontId(.helvetica);
        renderer.font_bold = renderer.doc.getFontId(.helvetica_bold);
        renderer.current_y = renderer.page_height - renderer.margin;

        return renderer;
    }

    pub fn deinit(self: *DirectorConsentRenderer) void {
        self.doc.deinit();
    }

    /// Draw the document header
    fn drawHeader(self: *DirectorConsentRenderer, content: *document.ContentStream) !void {
        const primary = document.Color.fromHex(self.data.template.style.primary_color);
        const center_x = self.page_width / 2;
        var y = self.page_height - self.margin;

        // Company name
        const company_width = document.Font.helvetica_bold.measureText(self.data.company.name, 14);
        try content.drawText(self.data.company.name, center_x - company_width / 2, y, self.font_bold, 14, primary);

        y -= 16;

        // Company number if provided
        if (self.data.company.registration_number) |reg| {
            var buf: [64]u8 = undefined;
            const reg_text = std.fmt.bufPrint(&buf, "(Company No. {s})", .{reg}) catch "";
            const reg_width = document.Font.helvetica.measureText(reg_text, 9);
            const gray = document.Color{ .r = 0.4, .g = 0.4, .b = 0.4 };
            try content.drawText(reg_text, center_x - reg_width / 2, y, self.font_regular, 9, gray);
            y -= 20;
        } else {
            y -= 10;
        }

        // Document title
        const title = "CONSENT TO ACT AS DIRECTOR";
        const title_width = document.Font.helvetica_bold.measureText(title, 16);
        try content.drawText(title, center_x - title_width / 2, y, self.font_bold, 16, primary);

        y -= 16;

        // Subtitle based on consent type
        const subtitle = switch (self.data.consent_type) {
            .NewAppointment => "(Section 167A Companies Act 2006)",
            .Reappointment => "(Reappointment)",
            .ExistingDirector => "(Confirmation of Details)",
        };
        const sub_width = document.Font.helvetica.measureText(subtitle, 10);
        const gray = document.Color{ .r = 0.4, .g = 0.4, .b = 0.4 };
        try content.drawText(subtitle, center_x - sub_width / 2, y, self.font_regular, 10, gray);

        // Horizontal line
        y -= 20;
        const accent = document.Color.fromHex(self.data.template.style.accent_color);
        try content.drawLine(self.margin, y, self.page_width - self.margin, y, accent, 1.0);

        self.current_y = y - 25;
    }

    /// Draw personal details section
    fn drawPersonalDetails(self: *DirectorConsentRenderer, content: *document.ContentStream) !void {
        const text_color = document.Color{ .r = 0.1, .g = 0.1, .b = 0.1 };
        const label_color = document.Color{ .r = 0.3, .g = 0.3, .b = 0.3 };
        const primary = document.Color.fromHex(self.data.template.style.primary_color);
        const left_x = self.margin;
        const label_x = left_x;
        const value_x = left_x + 130;
        var y = self.current_y;

        // Section header
        try content.drawText("PERSONAL DETAILS", left_x, y, self.font_bold, 11, primary);
        y -= 20;

        // Full name
        try content.drawText("Full Name:", label_x, y, self.font_regular, 10, label_color);
        var name_buf: [128]u8 = undefined;
        const full_name = if (self.data.director.title) |title|
            std.fmt.bufPrint(&name_buf, "{s} {s} {s}", .{ title, self.data.director.forenames, self.data.director.surname }) catch ""
        else
            std.fmt.bufPrint(&name_buf, "{s} {s}", .{ self.data.director.forenames, self.data.director.surname }) catch "";
        try content.drawText(full_name, value_x, y, self.font_bold, 10, text_color);
        y -= 14;

        // Former names if any
        if (self.data.director.former_names) |former| {
            try content.drawText("Former Names:", label_x, y, self.font_regular, 10, label_color);
            try content.drawText(former, value_x, y, self.font_regular, 10, text_color);
            y -= 14;
        }

        // Date of birth
        try content.drawText("Date of Birth:", label_x, y, self.font_regular, 10, label_color);
        try content.drawText(self.data.director.date_of_birth, value_x, y, self.font_regular, 10, text_color);
        y -= 14;

        // Nationality
        try content.drawText("Nationality:", label_x, y, self.font_regular, 10, label_color);
        try content.drawText(self.data.director.nationality, value_x, y, self.font_regular, 10, text_color);
        y -= 14;

        // Occupation
        try content.drawText("Occupation:", label_x, y, self.font_regular, 10, label_color);
        try content.drawText(self.data.director.occupation, value_x, y, self.font_regular, 10, text_color);
        y -= 20;

        // Residential Address
        try content.drawText("Residential Address:", label_x, y, self.font_regular, 10, label_color);
        const addr = self.data.director.residential_address;
        try content.drawText(addr.line1, value_x, y, self.font_regular, 10, text_color);
        y -= 12;
        if (addr.line2) |line2| {
            try content.drawText(line2, value_x, y, self.font_regular, 10, text_color);
            y -= 12;
        }
        var city_buf: [128]u8 = undefined;
        const city_line = if (addr.county) |county|
            std.fmt.bufPrint(&city_buf, "{s}, {s}", .{ addr.city, county }) catch ""
        else
            addr.city;
        try content.drawText(city_line, value_x, y, self.font_regular, 10, text_color);
        y -= 12;
        try content.drawText(addr.postcode, value_x, y, self.font_regular, 10, text_color);
        y -= 12;
        try content.drawText(addr.country, value_x, y, self.font_regular, 10, text_color);
        y -= 20;

        // Service Address if different
        if (self.data.director.service_address) |service| {
            try content.drawText("Service Address:", label_x, y, self.font_regular, 10, label_color);
            try content.drawText(service.line1, value_x, y, self.font_regular, 10, text_color);
            y -= 12;
            if (service.line2) |line2| {
                try content.drawText(line2, value_x, y, self.font_regular, 10, text_color);
                y -= 12;
            }
            var svc_buf: [128]u8 = undefined;
            const svc_city = if (service.county) |county|
                std.fmt.bufPrint(&svc_buf, "{s}, {s}", .{ service.city, county }) catch ""
            else
                service.city;
            try content.drawText(svc_city, value_x, y, self.font_regular, 10, text_color);
            y -= 12;
            try content.drawText(service.postcode, value_x, y, self.font_regular, 10, text_color);
            y -= 12;
            try content.drawText(service.country, value_x, y, self.font_regular, 10, text_color);
            y -= 20;
        }

        self.current_y = y;
    }

    /// Draw declarations section
    fn drawDeclarations(self: *DirectorConsentRenderer, content: *document.ContentStream) !void {
        const text_color = document.Color{ .r = 0.1, .g = 0.1, .b = 0.1 };
        const primary = document.Color.fromHex(self.data.template.style.primary_color);
        const left_x = self.margin;
        const content_width = self.page_width - 2 * self.margin;
        var y = self.current_y;

        // Section header
        try content.drawText("DECLARATIONS", left_x, y, self.font_bold, 11, primary);
        y -= 20;

        // Standard declarations
        const declarations = [_][]const u8{
            "I hereby consent to act as a director of the above-named company.",
            "I confirm that I am not disqualified from acting as a director under the Company Directors Disqualification Act 1986 or otherwise.",
            "I confirm that I am not an undischarged bankrupt.",
            "I confirm that I have not been subject to a bankruptcy restrictions order (or equivalent) that is still in force.",
            "I acknowledge that my personal information will be held on the public register at Companies House.",
        };

        for (declarations, 0..) |decl, i| {
            var num_buf: [8]u8 = undefined;
            const num_text = std.fmt.bufPrint(&num_buf, "{d}.", .{i + 1}) catch "";
            try content.drawText(num_text, left_x, y, self.font_regular, 10, text_color);

            // Wrap declaration text
            var wrapper = try document.wrapText(self.allocator, decl, document.Font.helvetica, 10, content_width - 25);
            defer wrapper.deinit();

            for (wrapper.lines) |line| {
                try content.drawText(line, left_x + 20, y, self.font_regular, 10, text_color);
                y -= 14;
            }
            y -= 6;
        }

        // Additional declarations if provided
        if (self.data.additional_declarations) |additional| {
            for (additional, declarations.len..) |decl, i| {
                var num_buf: [8]u8 = undefined;
                const num_text = std.fmt.bufPrint(&num_buf, "{d}.", .{i + 1}) catch "";
                try content.drawText(num_text, left_x, y, self.font_regular, 10, text_color);

                var wrapper = try document.wrapText(self.allocator, decl, document.Font.helvetica, 10, content_width - 25);
                defer wrapper.deinit();

                for (wrapper.lines) |line| {
                    try content.drawText(line, left_x + 20, y, self.font_regular, 10, text_color);
                    y -= 14;
                }
                y -= 6;
            }
        }

        // Other directorships disclosure
        if (self.data.director.has_directorships) {
            y -= 10;
            try content.drawText("Other Directorships:", left_x, y, self.font_bold, 10, text_color);
            y -= 14;

            if (self.data.director.other_directorships) |dirs| {
                for (dirs) |dir| {
                    try content.drawText("•", left_x + 10, y, self.font_regular, 10, text_color);
                    try content.drawText(dir, left_x + 25, y, self.font_regular, 10, text_color);
                    y -= 12;
                }
            }
        }

        self.current_y = y;
    }

    /// Draw signature block
    fn drawSignatureBlock(self: *DirectorConsentRenderer, content: *document.ContentStream) !void {
        const text_color = document.Color{ .r = 0.1, .g = 0.1, .b = 0.1 };
        const gray = document.Color{ .r = 0.4, .g = 0.4, .b = 0.4 };
        const primary = document.Color.fromHex(self.data.template.style.primary_color);
        const left_x = self.margin;
        var y = self.current_y - 20;

        // Signature section header
        try content.drawText("SIGNATURE", left_x, y, self.font_bold, 11, primary);
        y -= 25;

        // Signature line
        try content.drawLine(left_x, y, left_x + 250, y, gray, 0.5);
        y -= 12;
        try content.drawText("Signature", left_x, y, self.font_regular, 9, gray);
        y -= 25;

        // Printed name
        var name_buf: [128]u8 = undefined;
        const printed_name = std.fmt.bufPrint(&name_buf, "{s} {s}", .{
            self.data.director.forenames,
            self.data.director.surname,
        }) catch "";
        try content.drawText("Print Name:", left_x, y, self.font_regular, 10, gray);
        try content.drawText(printed_name, left_x + 80, y, self.font_bold, 10, text_color);
        y -= 20;

        // Date
        try content.drawText("Date:", left_x, y, self.font_regular, 10, gray);
        try content.drawLine(left_x + 80, y, left_x + 200, y, gray, 0.5);

        // Witness block if enabled
        if (self.data.template.style.include_witness_block) {
            const witness_x = self.page_width / 2 + 20;
            var wy = self.current_y - 20;

            try content.drawText("WITNESS", witness_x, wy, self.font_bold, 11, primary);
            wy -= 25;

            try content.drawLine(witness_x, wy, witness_x + 200, wy, gray, 0.5);
            wy -= 12;
            try content.drawText("Witness Signature", witness_x, wy, self.font_regular, 9, gray);
            wy -= 25;

            try content.drawText("Print Name:", witness_x, wy, self.font_regular, 10, gray);
            if (self.data.witness) |witness| {
                try content.drawText(witness.name, witness_x + 80, wy, self.font_regular, 10, text_color);
            } else {
                try content.drawLine(witness_x + 80, wy, witness_x + 200, wy, gray, 0.5);
            }
            wy -= 18;

            try content.drawText("Address:", witness_x, wy, self.font_regular, 10, gray);
            if (self.data.witness) |witness| {
                if (witness.address) |addr| {
                    try content.drawText(addr, witness_x + 80, wy, self.font_regular, 9, text_color);
                }
            }
            wy -= 18;

            try content.drawText("Occupation:", witness_x, wy, self.font_regular, 10, gray);
            if (self.data.witness) |witness| {
                if (witness.occupation) |occ| {
                    try content.drawText(occ, witness_x + 80, wy, self.font_regular, 9, text_color);
                }
            }

            self.current_y = @min(y - 20, wy - 20);
        } else {
            self.current_y = y - 20;
        }
    }

    /// Draw footer with statutory notes
    fn drawFooter(self: *DirectorConsentRenderer, content: *document.ContentStream) !void {
        if (!self.data.template.style.show_statutory_text) return;

        const gray = document.Color{ .r = 0.5, .g = 0.5, .b = 0.5 };
        const left_x = self.margin;
        var y: f32 = 70;

        // Draw separator line
        try content.drawLine(left_x, y + 10, self.page_width - self.margin, y + 10, gray, 0.5);

        const notes = [_][]const u8{
            "This consent is made pursuant to Section 167A of the Companies Act 2006.",
            "False statements may result in criminal prosecution.",
        };

        for (notes) |note| {
            try content.drawText(note, left_x, y, self.font_regular, 8, gray);
            y -= 10;
        }
    }

    /// Render the complete document
    pub fn render(self: *DirectorConsentRenderer) ![]const u8 {
        var content = document.ContentStream.init(self.allocator);
        defer content.deinit();

        // Set page size to A4 portrait
        self.doc.setPageSize(.{ .width = self.page_width, .height = self.page_height });

        try self.drawHeader(&content);
        try self.drawPersonalDetails(&content);
        try self.drawDeclarations(&content);
        try self.drawSignatureBlock(&content);
        try self.drawFooter(&content);

        // Add page to document
        try self.doc.addPage(&content);

        return self.doc.build();
    }
};

// =============================================================================
// Public API
// =============================================================================

/// Generate a Director Consent to Act PDF document
pub fn generateDirectorConsent(allocator: std.mem.Allocator, data: DirectorConsentData) ![]u8 {
    var renderer = DirectorConsentRenderer.init(allocator, data);
    defer renderer.deinit();

    const pdf_output = try renderer.render();
    return try allocator.dupe(u8, pdf_output);
}

/// Generate from JSON string
pub fn generateDirectorConsentFromJson(allocator: std.mem.Allocator, json_str: []const u8) ![]u8 {
    const parsed = std.json.parseFromSlice(DirectorConsentData, allocator, json_str, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| {
        std.log.err("Failed to parse Director Consent JSON: {}", .{err});
        return err;
    };
    defer parsed.deinit();

    return try generateDirectorConsent(allocator, parsed.value);
}

/// Generate a demo Director Consent document
pub fn generateDemoDirectorConsent(allocator: std.mem.Allocator) ![]u8 {
    const data = DirectorConsentData{
        .company = .{
            .name = "QUANTUM ENCODING LTD",
            .registration_number = "12345678",
        },
        .director = .{
            .title = "Mr",
            .forenames = "James Alexander",
            .surname = "Smith",
            .date_of_birth = "15/03/1980",
            .nationality = "British",
            .occupation = "Software Engineer",
            .residential_address = .{
                .line1 = "42 Technology Park",
                .line2 = "Innovation Quarter",
                .city = "Cambridge",
                .county = "Cambridgeshire",
                .postcode = "CB1 2AB",
            },
            .has_directorships = true,
            .other_directorships = &[_][]const u8{
                "Tech Ventures Ltd (Director)",
                "Digital Solutions Holdings PLC (Non-Executive Director)",
            },
        },
        .consent_type = .NewAppointment,
        .witness = .{
            .name = "Sarah Johnson",
            .address = "15 High Street, Cambridge",
            .occupation = "Solicitor",
        },
    };

    return try generateDirectorConsent(allocator, data);
}

// =============================================================================
// Tests
// =============================================================================

test "generate demo director consent" {
    const allocator = std.testing.allocator;
    const pdf = try generateDemoDirectorConsent(allocator);
    defer allocator.free(pdf);

    try std.testing.expect(pdf.len > 1000);
    try std.testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4"));
}

test "director consent from json" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "company": {
        \\    "name": "Test Company Ltd",
        \\    "registration_number": "87654321"
        \\  },
        \\  "director": {
        \\    "forenames": "John",
        \\    "surname": "Doe",
        \\    "date_of_birth": "01/01/1990",
        \\    "nationality": "British",
        \\    "occupation": "Director",
        \\    "residential_address": {
        \\      "line1": "1 Test Street",
        \\      "city": "London",
        \\      "postcode": "EC1A 1BB"
        \\    }
        \\  }
        \\}
    ;

    const pdf = try generateDirectorConsentFromJson(allocator, json);
    defer allocator.free(pdf);

    try std.testing.expect(pdf.len > 1000);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "Test Company Ltd") != null);
}
