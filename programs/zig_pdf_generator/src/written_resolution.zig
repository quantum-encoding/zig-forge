//! Written Resolution Generator
//!
//! Generates professional Written Resolution documents for UK companies.
//! Supports both Ordinary Resolutions (simple majority) and Special
//! Resolutions (75%+ majority) as per Companies Act 2006.
//!
//! Features:
//! - Ordinary and Special resolution types
//! - Multiple resolution items per document
//! - Member consent tracking
//! - Circulation date and deadline management
//! - Statutory notes and requirements

const std = @import("std");
const document = @import("document.zig");

// =============================================================================
// Data Structures
// =============================================================================

pub const ResolutionType = enum {
    Ordinary, // Simple majority (>50%)
    Special, // 75%+ majority required
};

pub const ResolutionStatus = enum {
    Proposed,
    Passed,
    NotPassed,
    Withdrawn,
};

pub const ResolutionItem = struct {
    number: u32 = 1,
    title: []const u8,
    text: []const u8,
    resolution_type: ResolutionType = .Ordinary,
    status: ResolutionStatus = .Proposed,
    votes_for: ?u32 = null,
    votes_against: ?u32 = null,
    votes_abstained: ?u32 = null,
};

pub const Member = struct {
    name: []const u8,
    shares: ?u32 = null,
    voting_rights: ?u32 = null, // If different from shares
    signed: bool = false,
    date_signed: ?[]const u8 = null,
};

pub const Company = struct {
    name: []const u8,
    registration_number: ?[]const u8 = null,
};

pub const TemplateStyle = struct {
    primary_color: []const u8 = "#1a365d",
    accent_color: []const u8 = "#2b6cb0",
    show_statutory_notes: bool = true,
};

pub const Template = struct {
    style: TemplateStyle = .{},
};

pub const WrittenResolutionData = struct {
    company: Company,
    document_title: ?[]const u8 = null, // e.g., "Written Resolution of the Members"
    resolutions: []const ResolutionItem,
    members: ?[]const Member = null,
    circulation_date: []const u8,
    deadline_date: ?[]const u8 = null, // Usually 28 days from circulation
    notes: ?[]const u8 = null,
    proposed_by: ?[]const u8 = null,
    template: Template = .{},
};

// =============================================================================
// Renderer
// =============================================================================

pub const WrittenResolutionRenderer = struct {
    allocator: std.mem.Allocator,
    doc: document.PdfDocument,
    data: WrittenResolutionData,

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

    pub fn init(allocator: std.mem.Allocator, data: WrittenResolutionData) WrittenResolutionRenderer {
        var renderer = WrittenResolutionRenderer{
            .allocator = allocator,
            .doc = document.PdfDocument.init(allocator),
            .data = data,
        };

        renderer.font_regular = renderer.doc.getFontId(.helvetica);
        renderer.font_bold = renderer.doc.getFontId(.helvetica_bold);
        renderer.current_y = renderer.page_height - renderer.margin;

        return renderer;
    }

    pub fn deinit(self: *WrittenResolutionRenderer) void {
        self.doc.deinit();
    }

    /// Draw the document header
    fn drawHeader(self: *WrittenResolutionRenderer, content: *document.ContentStream) !void {
        const primary = document.Color.fromHex(self.data.template.style.primary_color);
        const gray = document.Color{ .r = 0.4, .g = 0.4, .b = 0.4 };
        const center_x = self.page_width / 2;
        var y = self.page_height - self.margin;

        // Company name
        const company_width = document.Font.helvetica_bold.measureText(self.data.company.name, 14);
        try content.drawText(self.data.company.name, center_x - company_width / 2, y, self.font_bold, 14, primary);
        y -= 16;

        // Company number
        if (self.data.company.registration_number) |reg| {
            var buf: [64]u8 = undefined;
            const reg_text = std.fmt.bufPrint(&buf, "(Company No. {s})", .{reg}) catch "";
            const reg_width = document.Font.helvetica.measureText(reg_text, 9);
            try content.drawText(reg_text, center_x - reg_width / 2, y, self.font_regular, 9, gray);
            y -= 20;
        } else {
            y -= 10;
        }

        // Document title
        const title = if (self.data.document_title) |t| t else "WRITTEN RESOLUTION";
        const title_width = document.Font.helvetica_bold.measureText(title, 16);
        try content.drawText(title, center_x - title_width / 2, y, self.font_bold, 16, primary);
        y -= 16;

        // Subtitle based on resolution types
        var has_special = false;
        var has_ordinary = false;
        for (self.data.resolutions) |res| {
            if (res.resolution_type == .Special) has_special = true;
            if (res.resolution_type == .Ordinary) has_ordinary = true;
        }

        const subtitle = if (has_special and has_ordinary)
            "(Ordinary and Special Resolutions)"
        else if (has_special)
            "(Special Resolution - 75% majority required)"
        else
            "(Ordinary Resolution - Simple majority required)";

        const sub_width = document.Font.helvetica.measureText(subtitle, 10);
        try content.drawText(subtitle, center_x - sub_width / 2, y, self.font_regular, 10, gray);

        // Horizontal line
        y -= 20;
        const accent = document.Color.fromHex(self.data.template.style.accent_color);
        try content.drawLine(self.margin, y, self.page_width - self.margin, y, accent, 1.0);

        self.current_y = y - 25;
    }

    /// Draw preamble/intro section
    fn drawPreamble(self: *WrittenResolutionRenderer, content: *document.ContentStream) !void {
        const text_color = document.Color{ .r = 0.1, .g = 0.1, .b = 0.1 };
        const gray = document.Color{ .r = 0.4, .g = 0.4, .b = 0.4 };
        const left_x = self.margin;
        const content_width = self.page_width - 2 * self.margin;
        var y = self.current_y;

        // Circulation information
        try content.drawText("Date of Circulation:", left_x, y, self.font_bold, 10, text_color);
        try content.drawText(self.data.circulation_date, left_x + 120, y, self.font_regular, 10, text_color);
        y -= 14;

        if (self.data.deadline_date) |deadline| {
            try content.drawText("Deadline for Response:", left_x, y, self.font_bold, 10, text_color);
            try content.drawText(deadline, left_x + 120, y, self.font_regular, 10, text_color);
            y -= 14;
        }

        if (self.data.proposed_by) |proposer| {
            try content.drawText("Proposed by:", left_x, y, self.font_bold, 10, text_color);
            try content.drawText(proposer, left_x + 120, y, self.font_regular, 10, text_color);
            y -= 14;
        }

        y -= 10;

        // Explanatory text
        const preamble = "In accordance with Sections 288-300 of the Companies Act 2006, the following " ++
            "resolution(s) are proposed to be passed as written resolution(s) of the Company:";

        var wrapper = try document.wrapText(self.allocator, preamble, document.Font.helvetica, 10, content_width);
        defer wrapper.deinit();
        for (wrapper.lines) |line| {
            try content.drawText(line, left_x, y, self.font_regular, 10, gray);
            y -= 14;
        }

        self.current_y = y - 10;
    }

    /// Draw the resolution items
    fn drawResolutions(self: *WrittenResolutionRenderer, content: *document.ContentStream) !void {
        const text_color = document.Color{ .r = 0.1, .g = 0.1, .b = 0.1 };
        const primary = document.Color.fromHex(self.data.template.style.primary_color);
        const left_x = self.margin;
        const content_width = self.page_width - 2 * self.margin;
        var y = self.current_y;

        for (self.data.resolutions, 0..) |resolution, i| {
            // Resolution header
            var header_buf: [128]u8 = undefined;
            const type_str = if (resolution.resolution_type == .Special) "SPECIAL" else "ORDINARY";
            const header = std.fmt.bufPrint(&header_buf, "Resolution {d} ({s} RESOLUTION)", .{ i + 1, type_str }) catch "";
            try content.drawText(header, left_x, y, self.font_bold, 11, primary);
            y -= 16;

            // Resolution title if different from number
            if (resolution.title.len > 0) {
                try content.drawText(resolution.title, left_x, y, self.font_bold, 10, text_color);
                y -= 16;
            }

            // Resolution text
            var text_wrapper = try document.wrapText(self.allocator, resolution.text, document.Font.helvetica, 10, content_width - 10);
            defer text_wrapper.deinit();
            for (text_wrapper.lines) |line| {
                try content.drawText(line, left_x + 10, y, self.font_regular, 10, text_color);
                y -= 14;
            }

            // Status if not just proposed
            if (resolution.status != .Proposed) {
                y -= 6;
                const status_text = switch (resolution.status) {
                    .Passed => "Status: PASSED",
                    .NotPassed => "Status: NOT PASSED",
                    .Withdrawn => "Status: WITHDRAWN",
                    .Proposed => "",
                };
                const status_color = switch (resolution.status) {
                    .Passed => document.Color{ .r = 0.0, .g = 0.5, .b = 0.0 },
                    .NotPassed => document.Color{ .r = 0.7, .g = 0.0, .b = 0.0 },
                    .Withdrawn => document.Color{ .r = 0.5, .g = 0.5, .b = 0.0 },
                    .Proposed => text_color,
                };
                try content.drawText(status_text, left_x + 10, y, self.font_bold, 9, status_color);
                y -= 12;

                // Voting results if available
                if (resolution.votes_for) |votes_for| {
                    var votes_buf: [128]u8 = undefined;
                    const votes_text = if (resolution.votes_against) |against|
                        std.fmt.bufPrint(&votes_buf, "Votes: For {d}, Against {d}", .{ votes_for, against }) catch ""
                    else
                        std.fmt.bufPrint(&votes_buf, "Votes: For {d}", .{votes_for}) catch "";
                    const gray = document.Color{ .r = 0.4, .g = 0.4, .b = 0.4 };
                    try content.drawText(votes_text, left_x + 10, y, self.font_regular, 9, gray);
                    y -= 12;
                }
            }

            y -= 15;
        }

        self.current_y = y;
    }

    /// Draw member consent section
    fn drawMemberConsent(self: *WrittenResolutionRenderer, content: *document.ContentStream) !void {
        if (self.data.members == null) return;
        const members = self.data.members.?;
        if (members.len == 0) return;

        const text_color = document.Color{ .r = 0.1, .g = 0.1, .b = 0.1 };
        const gray = document.Color{ .r = 0.4, .g = 0.4, .b = 0.4 };
        const primary = document.Color.fromHex(self.data.template.style.primary_color);
        const left_x = self.margin;
        var y = self.current_y;

        // Section header
        try content.drawText("MEMBER CONSENT", left_x, y, self.font_bold, 11, primary);
        y -= 20;

        // Table header
        try content.drawText("Member Name", left_x, y, self.font_bold, 9, text_color);
        try content.drawText("Shares", left_x + 200, y, self.font_bold, 9, text_color);
        try content.drawText("Signature", left_x + 280, y, self.font_bold, 9, text_color);
        try content.drawText("Date", left_x + 400, y, self.font_bold, 9, text_color);
        y -= 4;

        // Horizontal line
        try content.drawLine(left_x, y, self.page_width - self.margin, y, gray, 0.5);
        y -= 14;

        // Member rows
        for (members) |member| {
            try content.drawText(member.name, left_x, y, self.font_regular, 9, text_color);

            if (member.shares) |shares| {
                var shares_buf: [32]u8 = undefined;
                const shares_text = std.fmt.bufPrint(&shares_buf, "{d}", .{shares}) catch "";
                try content.drawText(shares_text, left_x + 200, y, self.font_regular, 9, text_color);
            }

            // Signature line or "Signed" text
            if (member.signed) {
                try content.drawText("[Signed]", left_x + 280, y, self.font_regular, 9, text_color);
            } else {
                try content.drawLine(left_x + 280, y, left_x + 380, y, gray, 0.5);
            }

            // Date
            if (member.date_signed) |date| {
                try content.drawText(date, left_x + 400, y, self.font_regular, 9, text_color);
            } else {
                try content.drawLine(left_x + 400, y, left_x + 480, y, gray, 0.5);
            }

            y -= 18;
        }

        self.current_y = y - 10;
    }

    /// Draw statutory notes
    fn drawStatutoryNotes(self: *WrittenResolutionRenderer, content: *document.ContentStream) !void {
        if (!self.data.template.style.show_statutory_notes) return;

        const gray = document.Color{ .r = 0.5, .g = 0.5, .b = 0.5 };
        const left_x = self.margin;
        const content_width = self.page_width - 2 * self.margin;
        var y = self.current_y - 10;

        // Separator
        try content.drawLine(left_x, y, self.page_width - self.margin, y, gray, 0.5);
        y -= 15;

        const notes = [_][]const u8{
            "NOTES:",
            "1. A written resolution must be passed by members representing the requisite majority:",
            "   - Ordinary resolution: more than 50% of total voting rights",
            "   - Special resolution: 75% or more of total voting rights",
            "2. A written resolution lapses if not passed within 28 days of circulation.",
            "3. Once you have indicated your agreement, you may not revoke it.",
            "4. This written resolution does not apply to resolutions to remove a director or auditor.",
        };

        for (notes) |note| {
            var note_wrapper = try document.wrapText(self.allocator, note, document.Font.helvetica, 8, content_width);
            defer note_wrapper.deinit();
            for (note_wrapper.lines) |line| {
                try content.drawText(line, left_x, y, self.font_regular, 8, gray);
                y -= 10;
            }
        }

        // Additional custom notes
        if (self.data.notes) |custom_notes| {
            y -= 5;
            var custom_wrapper = try document.wrapText(self.allocator, custom_notes, document.Font.helvetica, 8, content_width);
            defer custom_wrapper.deinit();
            for (custom_wrapper.lines) |line| {
                try content.drawText(line, left_x, y, self.font_regular, 8, gray);
                y -= 10;
            }
        }

        self.current_y = y;
    }

    /// Render the complete document
    pub fn render(self: *WrittenResolutionRenderer) ![]const u8 {
        var content = document.ContentStream.init(self.allocator);
        defer content.deinit();

        // Set page size to A4 portrait
        self.doc.setPageSize(.{ .width = self.page_width, .height = self.page_height });

        try self.drawHeader(&content);
        try self.drawPreamble(&content);
        try self.drawResolutions(&content);
        try self.drawMemberConsent(&content);
        try self.drawStatutoryNotes(&content);

        // Add page to document
        try self.doc.addPage(&content);

        return self.doc.build();
    }
};

// =============================================================================
// Public API
// =============================================================================

/// Generate a Written Resolution PDF document
pub fn generateWrittenResolution(allocator: std.mem.Allocator, data: WrittenResolutionData) ![]u8 {
    var renderer = WrittenResolutionRenderer.init(allocator, data);
    defer renderer.deinit();

    const pdf_output = try renderer.render();
    return try allocator.dupe(u8, pdf_output);
}

/// Generate from JSON string
pub fn generateWrittenResolutionFromJson(allocator: std.mem.Allocator, json_str: []const u8) ![]u8 {
    const parsed = std.json.parseFromSlice(WrittenResolutionData, allocator, json_str, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| {
        std.log.err("Failed to parse Written Resolution JSON: {}", .{err});
        return err;
    };
    defer parsed.deinit();

    return try generateWrittenResolution(allocator, parsed.value);
}

/// Generate a demo Written Resolution (Ordinary)
pub fn generateDemoOrdinaryResolution(allocator: std.mem.Allocator) ![]u8 {
    const resolutions = [_]ResolutionItem{
        .{
            .number = 1,
            .title = "Approval of Annual Accounts",
            .text = "THAT the annual accounts of the Company for the financial year ended 31 December 2025, " ++
                "together with the directors' report and auditors' report thereon, be and are hereby received and adopted.",
            .resolution_type = .Ordinary,
        },
        .{
            .number = 2,
            .title = "Re-appointment of Auditors",
            .text = "THAT Smith & Partners LLP be and are hereby re-appointed as auditors of the Company to hold office " ++
                "until the conclusion of the next general meeting at which accounts are laid before the Company.",
            .resolution_type = .Ordinary,
        },
    };

    const members = [_]Member{
        .{ .name = "Richard A. Tune", .shares = 5000 },
        .{ .name = "Lance J. Pearson", .shares = 3000 },
        .{ .name = "Jennifer M. Walsh", .shares = 2000 },
    };

    const data = WrittenResolutionData{
        .company = .{
            .name = "QUANTUM ENCODING LTD",
            .registration_number = "12345678",
        },
        .resolutions = &resolutions,
        .members = &members,
        .circulation_date = "1 March 2026",
        .deadline_date = "29 March 2026",
        .proposed_by = "Richard A. Tune (Director)",
    };

    return try generateWrittenResolution(allocator, data);
}

/// Generate a demo Written Resolution (Special)
pub fn generateDemoSpecialResolution(allocator: std.mem.Allocator) ![]u8 {
    const resolutions = [_]ResolutionItem{
        .{
            .number = 1,
            .title = "Change of Company Name",
            .text = "THAT the name of the Company be and is hereby changed from 'QUANTUM ENCODING LTD' " ++
                "to 'QUANTUM TECHNOLOGIES LTD' and that the Articles of Association be amended accordingly.",
            .resolution_type = .Special,
        },
        .{
            .number = 2,
            .title = "Amendment of Articles",
            .text = "THAT Article 10 of the Company's Articles of Association be amended to increase the " ++
                "maximum number of directors from five (5) to seven (7).",
            .resolution_type = .Special,
        },
    };

    const members = [_]Member{
        .{ .name = "Richard A. Tune", .shares = 5000 },
        .{ .name = "Lance J. Pearson", .shares = 3000 },
        .{ .name = "Jennifer M. Walsh", .shares = 2000 },
    };

    const data = WrittenResolutionData{
        .company = .{
            .name = "QUANTUM ENCODING LTD",
            .registration_number = "12345678",
        },
        .document_title = "WRITTEN SPECIAL RESOLUTION",
        .resolutions = &resolutions,
        .members = &members,
        .circulation_date = "15 March 2026",
        .deadline_date = "12 April 2026",
        .proposed_by = "The Board of Directors",
    };

    return try generateWrittenResolution(allocator, data);
}

// =============================================================================
// Tests
// =============================================================================

test "generate demo ordinary resolution" {
    const allocator = std.testing.allocator;
    const pdf = try generateDemoOrdinaryResolution(allocator);
    defer allocator.free(pdf);

    try std.testing.expect(pdf.len > 1000);
    try std.testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4"));
}

test "generate demo special resolution" {
    const allocator = std.testing.allocator;
    const pdf = try generateDemoSpecialResolution(allocator);
    defer allocator.free(pdf);

    try std.testing.expect(pdf.len > 1000);
    try std.testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4"));
}

test "written resolution from json" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "company": {
        \\    "name": "Test Company Ltd"
        \\  },
        \\  "resolutions": [
        \\    {
        \\      "title": "Test Resolution",
        \\      "text": "That this resolution be passed."
        \\    }
        \\  ],
        \\  "circulation_date": "1 January 2026"
        \\}
    ;

    const pdf = try generateWrittenResolutionFromJson(allocator, json);
    defer allocator.free(pdf);

    try std.testing.expect(pdf.len > 1000);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "Test Company Ltd") != null);
}
