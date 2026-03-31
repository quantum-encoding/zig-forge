//! Director Resignation Letter Generator
//!
//! Generates professional Director Resignation Letters for UK companies.
//! These letters formally notify the company of a director's intention
//! to resign from their position.
//!
//! Features:
//! - Effective date specification
//! - Reason for resignation (optional)
//! - Outstanding matters acknowledgment
//! - Confidentiality undertaking

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

pub const Company = struct {
    name: []const u8,
    registration_number: ?[]const u8 = null,
    registered_office: ?Address = null,
};

pub const Director = struct {
    title: ?[]const u8 = null,
    forenames: []const u8,
    surname: []const u8,
    address: ?Address = null,
};

pub const ResignationReason = enum {
    Personal,
    Health,
    OtherCommitments,
    Retirement,
    ConflictOfInterest,
    Other,
    NotSpecified,
};

pub const TemplateStyle = struct {
    primary_color: []const u8 = "#1a365d",
    accent_color: []const u8 = "#2b6cb0",
};

pub const Template = struct {
    style: TemplateStyle = .{},
};

pub const DirectorResignationData = struct {
    company: Company,
    director: Director,
    effective_date: []const u8, // When resignation takes effect
    letter_date: ?[]const u8 = null, // Date of letter
    reason: ResignationReason = .NotSpecified,
    custom_reason: ?[]const u8 = null, // If reason is Other
    notice_period_waived: bool = false,
    return_company_property: bool = true,
    confidentiality_acknowledged: bool = true,
    outstanding_matters: ?[]const u8 = null,
    recipient_name: ?[]const u8 = null, // Chairman/Board addressee
    recipient_title: ?[]const u8 = null,
    template: Template = .{},
};

// =============================================================================
// Renderer
// =============================================================================

pub const DirectorResignationRenderer = struct {
    allocator: std.mem.Allocator,
    doc: document.PdfDocument,
    data: DirectorResignationData,

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

    pub fn init(allocator: std.mem.Allocator, data: DirectorResignationData) DirectorResignationRenderer {
        var renderer = DirectorResignationRenderer{
            .allocator = allocator,
            .doc = document.PdfDocument.init(allocator),
            .data = data,
        };

        renderer.font_regular = renderer.doc.getFontId(.helvetica);
        renderer.font_bold = renderer.doc.getFontId(.helvetica_bold);
        renderer.current_y = renderer.page_height - renderer.margin;

        return renderer;
    }

    pub fn deinit(self: *DirectorResignationRenderer) void {
        self.doc.deinit();
    }

    /// Draw the letter header with director's details
    fn drawHeader(self: *DirectorResignationRenderer, content: *document.ContentStream) !void {
        const gray = document.Color{ .r = 0.4, .g = 0.4, .b = 0.4 };
        const text_color = document.Color{ .r = 0.1, .g = 0.1, .b = 0.1 };
        const left_x = self.margin;
        var y = self.page_height - self.margin;

        // Director's name (top right or left depending on format)
        var name_buf: [128]u8 = undefined;
        const full_name = if (self.data.director.title) |title|
            std.fmt.bufPrint(&name_buf, "{s} {s} {s}", .{ title, self.data.director.forenames, self.data.director.surname }) catch ""
        else
            std.fmt.bufPrint(&name_buf, "{s} {s}", .{ self.data.director.forenames, self.data.director.surname }) catch "";

        try content.drawText(full_name, left_x, y, self.font_bold, 11, text_color);
        y -= 14;

        // Director's address
        if (self.data.director.address) |addr| {
            try content.drawText(addr.line1, left_x, y, self.font_regular, 10, gray);
            y -= 12;
            if (addr.line2) |line2| {
                try content.drawText(line2, left_x, y, self.font_regular, 10, gray);
                y -= 12;
            }
            try content.drawText(addr.city, left_x, y, self.font_regular, 10, gray);
            y -= 12;
            try content.drawText(addr.postcode, left_x, y, self.font_regular, 10, gray);
            y -= 12;
        }

        y -= 15;

        // Letter date
        if (self.data.letter_date) |date| {
            try content.drawText(date, left_x, y, self.font_regular, 10, gray);
            y -= 20;
        }

        // Recipient (usually Chairman or Board)
        if (self.data.recipient_name) |recipient| {
            try content.drawText(recipient, left_x, y, self.font_bold, 10, text_color);
            y -= 14;
        }
        if (self.data.recipient_title) |title| {
            try content.drawText(title, left_x, y, self.font_regular, 10, gray);
            y -= 14;
        }

        try content.drawText(self.data.company.name, left_x, y, self.font_bold, 10, text_color);
        y -= 14;

        if (self.data.company.registered_office) |office| {
            try content.drawText(office.line1, left_x, y, self.font_regular, 10, gray);
            y -= 12;
            if (office.line2) |line2| {
                try content.drawText(line2, left_x, y, self.font_regular, 10, gray);
                y -= 12;
            }
            var addr_buf: [128]u8 = undefined;
            const addr = std.fmt.bufPrint(&addr_buf, "{s}, {s}", .{ office.city, office.postcode }) catch "";
            try content.drawText(addr, left_x, y, self.font_regular, 10, gray);
            y -= 12;
        }

        y -= 15;

        // Salutation
        const salutation = if (self.data.recipient_name != null) "Dear Sir/Madam," else "Dear Board Members,";
        try content.drawText(salutation, left_x, y, self.font_regular, 10, text_color);

        self.current_y = y - 25;
    }

    /// Draw the main body of the resignation letter
    fn drawBody(self: *DirectorResignationRenderer, content: *document.ContentStream) !void {
        const text_color = document.Color{ .r = 0.1, .g = 0.1, .b = 0.1 };
        const primary = document.Color.fromHex(self.data.template.style.primary_color);
        const left_x = self.margin;
        const content_width = self.page_width - 2 * self.margin;
        var y = self.current_y;

        // Subject line
        const subject = "Re: Resignation as Director";
        try content.drawText(subject, left_x, y, self.font_bold, 11, primary);
        y -= 20;

        // Opening paragraph with resignation notice
        var para1_buf: [512]u8 = undefined;
        const para1 = std.fmt.bufPrint(&para1_buf, "I hereby give notice of my resignation as a director of {s} " ++
            "with effect from {s}.", .{ self.data.company.name, self.data.effective_date }) catch "";

        var wrapper = try document.wrapText(self.allocator, para1, document.Font.helvetica, 10, content_width);
        defer wrapper.deinit();
        for (wrapper.lines) |line| {
            try content.drawText(line, left_x, y, self.font_regular, 10, text_color);
            y -= 14;
        }
        y -= 10;

        // Reason for resignation (if provided)
        if (self.data.reason != .NotSpecified) {
            const reason_text = switch (self.data.reason) {
                .Personal => "I am resigning due to personal reasons.",
                .Health => "I am resigning due to health-related matters.",
                .OtherCommitments => "I am resigning due to other professional commitments that require my full attention.",
                .Retirement => "I am resigning as I have decided to retire.",
                .ConflictOfInterest => "I am resigning due to a potential conflict of interest.",
                .Other => if (self.data.custom_reason) |reason| reason else "I am resigning for other reasons.",
                .NotSpecified => "",
            };

            if (reason_text.len > 0) {
                var reason_wrapper = try document.wrapText(self.allocator, reason_text, document.Font.helvetica, 10, content_width);
                defer reason_wrapper.deinit();
                for (reason_wrapper.lines) |line| {
                    try content.drawText(line, left_x, y, self.font_regular, 10, text_color);
                    y -= 14;
                }
                y -= 10;
            }
        }

        // Notice period
        if (self.data.notice_period_waived) {
            const notice_text = "I request that any contractual notice period be waived to allow my resignation to take " ++
                "immediate effect on the date stated above.";
            var notice_wrapper = try document.wrapText(self.allocator, notice_text, document.Font.helvetica, 10, content_width);
            defer notice_wrapper.deinit();
            for (notice_wrapper.lines) |line| {
                try content.drawText(line, left_x, y, self.font_regular, 10, text_color);
                y -= 14;
            }
            y -= 10;
        }

        // Outstanding matters
        if (self.data.outstanding_matters) |matters| {
            try content.drawText("Outstanding Matters:", left_x, y, self.font_bold, 10, text_color);
            y -= 16;
            var matters_wrapper = try document.wrapText(self.allocator, matters, document.Font.helvetica, 10, content_width);
            defer matters_wrapper.deinit();
            for (matters_wrapper.lines) |line| {
                try content.drawText(line, left_x, y, self.font_regular, 10, text_color);
                y -= 14;
            }
            y -= 10;
        }

        self.current_y = y;
    }

    /// Draw undertakings section
    fn drawUndertakings(self: *DirectorResignationRenderer, content: *document.ContentStream) !void {
        const text_color = document.Color{ .r = 0.1, .g = 0.1, .b = 0.1 };
        const primary = document.Color.fromHex(self.data.template.style.primary_color);
        const left_x = self.margin;
        const content_width = self.page_width - 2 * self.margin;
        var y = self.current_y;

        // Section header
        try content.drawText("Undertakings", left_x, y, self.font_bold, 10, primary);
        y -= 16;

        // Return of company property
        if (self.data.return_company_property) {
            const prop_text = "I undertake to return all company property, including documents, equipment, keys, " ++
                "and access cards, on or before my last day of office.";
            try content.drawText("•", left_x, y, self.font_regular, 10, text_color);
            var prop_wrapper = try document.wrapText(self.allocator, prop_text, document.Font.helvetica, 10, content_width - 15);
            defer prop_wrapper.deinit();
            for (prop_wrapper.lines) |line| {
                try content.drawText(line, left_x + 15, y, self.font_regular, 10, text_color);
                y -= 14;
            }
            y -= 4;
        }

        // Confidentiality
        if (self.data.confidentiality_acknowledged) {
            const conf_text = "I acknowledge that my obligations of confidentiality to the Company continue " ++
                "after my resignation and I will not disclose any confidential information.";
            try content.drawText("•", left_x, y, self.font_regular, 10, text_color);
            var conf_wrapper = try document.wrapText(self.allocator, conf_text, document.Font.helvetica, 10, content_width - 15);
            defer conf_wrapper.deinit();
            for (conf_wrapper.lines) |line| {
                try content.drawText(line, left_x + 15, y, self.font_regular, 10, text_color);
                y -= 14;
            }
            y -= 4;
        }

        // Companies House notification
        const ch_text = "I understand that the Company will notify Companies House of my resignation " ++
            "in accordance with statutory requirements.";
        try content.drawText("•", left_x, y, self.font_regular, 10, text_color);
        var ch_wrapper = try document.wrapText(self.allocator, ch_text, document.Font.helvetica, 10, content_width - 15);
        defer ch_wrapper.deinit();
        for (ch_wrapper.lines) |line| {
            try content.drawText(line, left_x + 15, y, self.font_regular, 10, text_color);
            y -= 14;
        }

        self.current_y = y - 10;
    }

    /// Draw closing and signature
    fn drawClosing(self: *DirectorResignationRenderer, content: *document.ContentStream) !void {
        const text_color = document.Color{ .r = 0.1, .g = 0.1, .b = 0.1 };
        const gray = document.Color{ .r = 0.4, .g = 0.4, .b = 0.4 };
        const left_x = self.margin;
        var y = self.current_y;

        // Closing paragraph
        const closing = "I would like to thank the Board and my fellow directors for the opportunity to serve " ++
            "the Company and wish it continued success.";
        var close_wrapper = try document.wrapText(self.allocator, closing, document.Font.helvetica, 10, self.page_width - 2 * self.margin);
        defer close_wrapper.deinit();
        for (close_wrapper.lines) |line| {
            try content.drawText(line, left_x, y, self.font_regular, 10, text_color);
            y -= 14;
        }
        y -= 20;

        // Yours faithfully
        try content.drawText("Yours faithfully,", left_x, y, self.font_regular, 10, text_color);
        y -= 40;

        // Signature line
        try content.drawLine(left_x, y, left_x + 200, y, gray, 0.5);
        y -= 15;

        // Director name
        var name_buf: [128]u8 = undefined;
        const full_name = if (self.data.director.title) |title|
            std.fmt.bufPrint(&name_buf, "{s} {s} {s}", .{ title, self.data.director.forenames, self.data.director.surname }) catch ""
        else
            std.fmt.bufPrint(&name_buf, "{s} {s}", .{ self.data.director.forenames, self.data.director.surname }) catch "";
        try content.drawText(full_name, left_x, y, self.font_bold, 10, text_color);
        y -= 14;
        try content.drawText("Director", left_x, y, self.font_regular, 10, gray);

        self.current_y = y;
    }

    /// Render the complete letter
    pub fn render(self: *DirectorResignationRenderer) ![]const u8 {
        var content = document.ContentStream.init(self.allocator);
        defer content.deinit();

        // Set page size to A4 portrait
        self.doc.setPageSize(.{ .width = self.page_width, .height = self.page_height });

        try self.drawHeader(&content);
        try self.drawBody(&content);
        try self.drawUndertakings(&content);
        try self.drawClosing(&content);

        // Add page to document
        try self.doc.addPage(&content);

        return self.doc.build();
    }
};

// =============================================================================
// Public API
// =============================================================================

/// Generate a Director Resignation Letter PDF
pub fn generateDirectorResignation(allocator: std.mem.Allocator, data: DirectorResignationData) ![]u8 {
    var renderer = DirectorResignationRenderer.init(allocator, data);
    defer renderer.deinit();

    const pdf_output = try renderer.render();
    return try allocator.dupe(u8, pdf_output);
}

/// Generate from JSON string
pub fn generateDirectorResignationFromJson(allocator: std.mem.Allocator, json_str: []const u8) ![]u8 {
    const parsed = std.json.parseFromSlice(DirectorResignationData, allocator, json_str, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| {
        std.log.err("Failed to parse Director Resignation JSON: {}", .{err});
        return err;
    };
    defer parsed.deinit();

    return try generateDirectorResignation(allocator, parsed.value);
}

/// Generate a demo Director Resignation Letter
pub fn generateDemoDirectorResignation(allocator: std.mem.Allocator) ![]u8 {
    const data = DirectorResignationData{
        .company = .{
            .name = "QUANTUM ENCODING LTD",
            .registration_number = "12345678",
            .registered_office = .{
                .line1 = "42 Technology Park",
                .city = "Cambridge",
                .postcode = "CB1 2AB",
            },
        },
        .director = .{
            .title = "Mr",
            .forenames = "James Alexander",
            .surname = "Smith",
            .address = .{
                .line1 = "15 Innovation Drive",
                .city = "London",
                .postcode = "EC1V 9BD",
            },
        },
        .effective_date = "31 March 2026",
        .letter_date = "1 March 2026",
        .reason = .OtherCommitments,
        .notice_period_waived = false,
        .return_company_property = true,
        .confidentiality_acknowledged = true,
        .recipient_name = "Richard A. Tune",
        .recipient_title = "Chairman",
    };

    return try generateDirectorResignation(allocator, data);
}

// =============================================================================
// Tests
// =============================================================================

test "generate demo director resignation" {
    const allocator = std.testing.allocator;
    const pdf = try generateDemoDirectorResignation(allocator);
    defer allocator.free(pdf);

    try std.testing.expect(pdf.len > 1000);
    try std.testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4"));
}

test "director resignation from json" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "company": {
        \\    "name": "Test Company Ltd"
        \\  },
        \\  "director": {
        \\    "forenames": "John",
        \\    "surname": "Doe"
        \\  },
        \\  "effective_date": "1 April 2026"
        \\}
    ;

    const pdf = try generateDirectorResignationFromJson(allocator, json);
    defer allocator.free(pdf);

    try std.testing.expect(pdf.len > 1000);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "Test Company Ltd") != null);
}
