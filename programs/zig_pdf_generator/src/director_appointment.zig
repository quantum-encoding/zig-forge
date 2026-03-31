//! Director Appointment Letter Generator
//!
//! Generates professional Director Appointment Letters for UK companies.
//! These letters formally confirm a director's appointment and set out
//! the key terms of their engagement.
//!
//! Features:
//! - Appointment details and effective date
//! - Role and responsibilities
//! - Remuneration terms
//! - Time commitment expectations
//! - Confidentiality and conflicts provisions

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

pub const DirectorRole = enum {
    Executive,
    NonExecutive,
    Chairman,
    ManagingDirector,
};

pub const Remuneration = struct {
    fee_amount: ?f64 = null,
    fee_period: []const u8 = "per annum",
    expenses_reimbursed: bool = true,
    share_options: bool = false,
    additional_terms: ?[]const u8 = null,
};

pub const TemplateStyle = struct {
    primary_color: []const u8 = "#1a365d",
    accent_color: []const u8 = "#2b6cb0",
};

pub const Template = struct {
    style: TemplateStyle = .{},
};

pub const DirectorAppointmentData = struct {
    company: Company,
    director: Director,
    role: DirectorRole = .NonExecutive,
    appointment_date: []const u8,
    term_years: ?u32 = null, // null = indefinite
    time_commitment: ?[]const u8 = null, // e.g., "10 days per month"
    remuneration: Remuneration = .{},
    committee_memberships: ?[]const []const u8 = null,
    signatory_name: ?[]const u8 = null,
    signatory_title: ?[]const u8 = null,
    letter_date: ?[]const u8 = null,
    template: Template = .{},
};

// =============================================================================
// Renderer
// =============================================================================

pub const DirectorAppointmentRenderer = struct {
    allocator: std.mem.Allocator,
    doc: document.PdfDocument,
    data: DirectorAppointmentData,

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

    pub fn init(allocator: std.mem.Allocator, data: DirectorAppointmentData) DirectorAppointmentRenderer {
        var renderer = DirectorAppointmentRenderer{
            .allocator = allocator,
            .doc = document.PdfDocument.init(allocator),
            .data = data,
        };

        renderer.font_regular = renderer.doc.getFontId(.helvetica);
        renderer.font_bold = renderer.doc.getFontId(.helvetica_bold);
        renderer.current_y = renderer.page_height - renderer.margin;

        return renderer;
    }

    pub fn deinit(self: *DirectorAppointmentRenderer) void {
        self.doc.deinit();
    }

    /// Draw the letter header
    fn drawHeader(self: *DirectorAppointmentRenderer, content: *document.ContentStream) !void {
        const primary = document.Color.fromHex(self.data.template.style.primary_color);
        const gray = document.Color{ .r = 0.4, .g = 0.4, .b = 0.4 };
        const left_x = self.margin;
        var y = self.page_height - self.margin;

        // Company name (top left)
        try content.drawText(self.data.company.name, left_x, y, self.font_bold, 14, primary);
        y -= 16;

        // Company number
        if (self.data.company.registration_number) |reg| {
            var buf: [64]u8 = undefined;
            const reg_text = std.fmt.bufPrint(&buf, "Company No. {s}", .{reg}) catch "";
            try content.drawText(reg_text, left_x, y, self.font_regular, 9, gray);
            y -= 12;
        }

        // Registered office if provided
        if (self.data.company.registered_office) |office| {
            try content.drawText(office.line1, left_x, y, self.font_regular, 9, gray);
            y -= 10;
            if (office.line2) |line2| {
                try content.drawText(line2, left_x, y, self.font_regular, 9, gray);
                y -= 10;
            }
            var addr_buf: [128]u8 = undefined;
            const addr = std.fmt.bufPrint(&addr_buf, "{s}, {s}", .{ office.city, office.postcode }) catch "";
            try content.drawText(addr, left_x, y, self.font_regular, 9, gray);
            y -= 10;
        }

        y -= 20;

        // Letter date
        if (self.data.letter_date) |date| {
            try content.drawText(date, left_x, y, self.font_regular, 10, gray);
            y -= 20;
        }

        // Recipient name and address
        var name_buf: [128]u8 = undefined;
        const full_name = if (self.data.director.title) |title|
            std.fmt.bufPrint(&name_buf, "{s} {s} {s}", .{ title, self.data.director.forenames, self.data.director.surname }) catch ""
        else
            std.fmt.bufPrint(&name_buf, "{s} {s}", .{ self.data.director.forenames, self.data.director.surname }) catch "";

        try content.drawText(full_name, left_x, y, self.font_bold, 10, primary);
        y -= 14;

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

        // Salutation
        var sal_buf: [64]u8 = undefined;
        const salutation = if (self.data.director.title) |title|
            std.fmt.bufPrint(&sal_buf, "Dear {s} {s},", .{ title, self.data.director.surname }) catch ""
        else
            std.fmt.bufPrint(&sal_buf, "Dear {s},", .{self.data.director.surname}) catch "";

        try content.drawText(salutation, left_x, y, self.font_regular, 10, primary);

        self.current_y = y - 25;
    }

    /// Draw the appointment section
    fn drawAppointment(self: *DirectorAppointmentRenderer, content: *document.ContentStream) !void {
        const text_color = document.Color{ .r = 0.1, .g = 0.1, .b = 0.1 };
        const primary = document.Color.fromHex(self.data.template.style.primary_color);
        const left_x = self.margin;
        const content_width = self.page_width - 2 * self.margin;
        var y = self.current_y;

        // Subject line
        const role_text = switch (self.data.role) {
            .Executive => "Executive Director",
            .NonExecutive => "Non-Executive Director",
            .Chairman => "Chairman",
            .ManagingDirector => "Managing Director",
        };

        var subj_buf: [128]u8 = undefined;
        const subject = std.fmt.bufPrint(&subj_buf, "Re: Appointment as {s}", .{role_text}) catch "";
        try content.drawText(subject, left_x, y, self.font_bold, 11, primary);
        y -= 20;

        // Opening paragraph
        var para1_buf: [512]u8 = undefined;
        const para1 = std.fmt.bufPrint(&para1_buf, "I am pleased to confirm your appointment as {s} of {s} " ++
            "with effect from {s}.", .{ role_text, self.data.company.name, self.data.appointment_date }) catch "";

        var wrapper = try document.wrapText(self.allocator, para1, document.Font.helvetica, 10, content_width);
        defer wrapper.deinit();
        for (wrapper.lines) |line| {
            try content.drawText(line, left_x, y, self.font_regular, 10, text_color);
            y -= 14;
        }
        y -= 10;

        // Term of appointment
        if (self.data.term_years) |years| {
            var term_buf: [256]u8 = undefined;
            const term_text = std.fmt.bufPrint(&term_buf, "Your appointment is for an initial term of {d} year(s), " ++
                "subject to the Articles of Association of the Company and re-election at the Annual General Meeting.", .{years}) catch "";

            var term_wrapper = try document.wrapText(self.allocator, term_text, document.Font.helvetica, 10, content_width);
            defer term_wrapper.deinit();
            for (term_wrapper.lines) |line| {
                try content.drawText(line, left_x, y, self.font_regular, 10, text_color);
                y -= 14;
            }
            y -= 10;
        }

        // Time commitment
        if (self.data.time_commitment) |commitment| {
            var commit_buf: [256]u8 = undefined;
            const commit_text = std.fmt.bufPrint(&commit_buf, "The anticipated time commitment for this role is {s}. " ++
                "This may increase during periods of increased activity.", .{commitment}) catch "";

            var commit_wrapper = try document.wrapText(self.allocator, commit_text, document.Font.helvetica, 10, content_width);
            defer commit_wrapper.deinit();
            for (commit_wrapper.lines) |line| {
                try content.drawText(line, left_x, y, self.font_regular, 10, text_color);
                y -= 14;
            }
            y -= 10;
        }

        self.current_y = y;
    }

    /// Draw remuneration section
    fn drawRemuneration(self: *DirectorAppointmentRenderer, content: *document.ContentStream) !void {
        const text_color = document.Color{ .r = 0.1, .g = 0.1, .b = 0.1 };
        const primary = document.Color.fromHex(self.data.template.style.primary_color);
        const left_x = self.margin;
        const content_width = self.page_width - 2 * self.margin;
        var y = self.current_y;

        // Section header
        try content.drawText("Remuneration", left_x, y, self.font_bold, 11, primary);
        y -= 18;

        // Fee
        if (self.data.remuneration.fee_amount) |amount| {
            var fee_buf: [128]u8 = undefined;
            const fee_text = std.fmt.bufPrint(&fee_buf, "You will receive a fee of £{d:.2} {s}, payable in equal monthly instalments.", .{ amount, self.data.remuneration.fee_period }) catch "";

            var fee_wrapper = try document.wrapText(self.allocator, fee_text, document.Font.helvetica, 10, content_width);
            defer fee_wrapper.deinit();
            for (fee_wrapper.lines) |line| {
                try content.drawText(line, left_x, y, self.font_regular, 10, text_color);
                y -= 14;
            }
            y -= 6;
        }

        // Expenses
        if (self.data.remuneration.expenses_reimbursed) {
            const expense_text = "The Company will reimburse you for all reasonable expenses properly incurred in performing your duties.";
            var exp_wrapper = try document.wrapText(self.allocator, expense_text, document.Font.helvetica, 10, content_width);
            defer exp_wrapper.deinit();
            for (exp_wrapper.lines) |line| {
                try content.drawText(line, left_x, y, self.font_regular, 10, text_color);
                y -= 14;
            }
            y -= 6;
        }

        // Additional terms
        if (self.data.remuneration.additional_terms) |terms| {
            var terms_wrapper = try document.wrapText(self.allocator, terms, document.Font.helvetica, 10, content_width);
            defer terms_wrapper.deinit();
            for (terms_wrapper.lines) |line| {
                try content.drawText(line, left_x, y, self.font_regular, 10, text_color);
                y -= 14;
            }
        }

        self.current_y = y - 10;
    }

    /// Draw duties section
    fn drawDuties(self: *DirectorAppointmentRenderer, content: *document.ContentStream) !void {
        const text_color = document.Color{ .r = 0.1, .g = 0.1, .b = 0.1 };
        const primary = document.Color.fromHex(self.data.template.style.primary_color);
        const left_x = self.margin;
        const content_width = self.page_width - 2 * self.margin;
        var y = self.current_y;

        // Section header
        try content.drawText("Duties and Responsibilities", left_x, y, self.font_bold, 11, primary);
        y -= 18;

        const duties = [_][]const u8{
            "Act in accordance with the Company's Articles of Association and comply with all applicable laws and regulations.",
            "Exercise independent judgement and promote the success of the Company for the benefit of its members as a whole.",
            "Avoid conflicts of interest and disclose any actual or potential conflicts to the Board.",
            "Exercise reasonable care, skill and diligence in the performance of your duties.",
            "Maintain confidentiality regarding Company business and not use information for personal gain.",
        };

        for (duties) |duty| {
            try content.drawText("•", left_x, y, self.font_regular, 10, text_color);

            var duty_wrapper = try document.wrapText(self.allocator, duty, document.Font.helvetica, 10, content_width - 15);
            defer duty_wrapper.deinit();
            for (duty_wrapper.lines) |line| {
                try content.drawText(line, left_x + 15, y, self.font_regular, 10, text_color);
                y -= 14;
            }
            y -= 4;
        }

        // Committee memberships
        if (self.data.committee_memberships) |committees| {
            y -= 10;
            try content.drawText("Committee Memberships:", left_x, y, self.font_bold, 10, primary);
            y -= 16;

            for (committees) |committee| {
                try content.drawText("•", left_x, y, self.font_regular, 10, text_color);
                try content.drawText(committee, left_x + 15, y, self.font_regular, 10, text_color);
                y -= 14;
            }
        }

        self.current_y = y - 10;
    }

    /// Draw closing and signature
    fn drawClosing(self: *DirectorAppointmentRenderer, content: *document.ContentStream) !void {
        const text_color = document.Color{ .r = 0.1, .g = 0.1, .b = 0.1 };
        const gray = document.Color{ .r = 0.4, .g = 0.4, .b = 0.4 };
        const left_x = self.margin;
        var y = self.current_y;

        // Closing paragraph
        const closing = "Please confirm your acceptance of this appointment by signing and returning the enclosed copy of this letter.";
        var close_wrapper = try document.wrapText(self.allocator, closing, document.Font.helvetica, 10, self.page_width - 2 * self.margin);
        defer close_wrapper.deinit();
        for (close_wrapper.lines) |line| {
            try content.drawText(line, left_x, y, self.font_regular, 10, text_color);
            y -= 14;
        }
        y -= 20;

        // Yours sincerely
        try content.drawText("Yours sincerely,", left_x, y, self.font_regular, 10, text_color);
        y -= 40;

        // Signature line
        try content.drawLine(left_x, y, left_x + 200, y, gray, 0.5);
        y -= 15;

        // Signatory details
        if (self.data.signatory_name) |name| {
            try content.drawText(name, left_x, y, self.font_bold, 10, text_color);
            y -= 14;
        }
        if (self.data.signatory_title) |title| {
            try content.drawText(title, left_x, y, self.font_regular, 10, gray);
            y -= 14;
        }
        try content.drawText(self.data.company.name, left_x, y, self.font_regular, 10, gray);
        y -= 30;

        // Acceptance block
        try content.drawText("ACCEPTANCE", left_x, y, self.font_bold, 10, text_color);
        y -= 18;
        try content.drawText("I accept the terms of this appointment letter.", left_x, y, self.font_regular, 10, text_color);
        y -= 25;

        // Director signature
        try content.drawText("Signed:", left_x, y, self.font_regular, 10, gray);
        try content.drawLine(left_x + 50, y, left_x + 250, y, gray, 0.5);
        y -= 20;
        try content.drawText("Date:", left_x, y, self.font_regular, 10, gray);
        try content.drawLine(left_x + 50, y, left_x + 150, y, gray, 0.5);

        self.current_y = y;
    }

    /// Render the complete letter
    pub fn render(self: *DirectorAppointmentRenderer) ![]const u8 {
        var content = document.ContentStream.init(self.allocator);
        defer content.deinit();

        // Set page size to A4 portrait
        self.doc.setPageSize(.{ .width = self.page_width, .height = self.page_height });

        try self.drawHeader(&content);
        try self.drawAppointment(&content);
        try self.drawRemuneration(&content);
        try self.drawDuties(&content);
        try self.drawClosing(&content);

        // Add page to document
        try self.doc.addPage(&content);

        return self.doc.build();
    }
};

// =============================================================================
// Public API
// =============================================================================

/// Generate a Director Appointment Letter PDF
pub fn generateDirectorAppointment(allocator: std.mem.Allocator, data: DirectorAppointmentData) ![]u8 {
    var renderer = DirectorAppointmentRenderer.init(allocator, data);
    defer renderer.deinit();

    const pdf_output = try renderer.render();
    return try allocator.dupe(u8, pdf_output);
}

/// Generate from JSON string
pub fn generateDirectorAppointmentFromJson(allocator: std.mem.Allocator, json_str: []const u8) ![]u8 {
    const parsed = std.json.parseFromSlice(DirectorAppointmentData, allocator, json_str, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| {
        std.log.err("Failed to parse Director Appointment JSON: {}", .{err});
        return err;
    };
    defer parsed.deinit();

    return try generateDirectorAppointment(allocator, parsed.value);
}

/// Generate a demo Director Appointment Letter
pub fn generateDemoDirectorAppointment(allocator: std.mem.Allocator) ![]u8 {
    const committees = [_][]const u8{
        "Audit Committee",
        "Remuneration Committee",
    };

    const data = DirectorAppointmentData{
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
        .role = .NonExecutive,
        .appointment_date = "1 January 2026",
        .term_years = 3,
        .time_commitment = "approximately 15 days per year",
        .remuneration = .{
            .fee_amount = 35000.00,
            .fee_period = "per annum",
            .expenses_reimbursed = true,
        },
        .committee_memberships = &committees,
        .signatory_name = "Richard A. Tune",
        .signatory_title = "Chairman",
        .letter_date = "15 December 2025",
    };

    return try generateDirectorAppointment(allocator, data);
}

// =============================================================================
// Tests
// =============================================================================

test "generate demo director appointment" {
    const allocator = std.testing.allocator;
    const pdf = try generateDemoDirectorAppointment(allocator);
    defer allocator.free(pdf);

    try std.testing.expect(pdf.len > 1000);
    try std.testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4"));
}

test "director appointment from json" {
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
        \\  "appointment_date": "1 March 2026"
        \\}
    ;

    const pdf = try generateDirectorAppointmentFromJson(allocator, json);
    defer allocator.free(pdf);

    try std.testing.expect(pdf.len > 1000);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "Test Company Ltd") != null);
}
