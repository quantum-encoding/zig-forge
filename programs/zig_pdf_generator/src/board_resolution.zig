//! Board Resolution Generator
//!
//! Generates UK-style Board Resolutions with:
//! - Company details
//! - Meeting information
//! - Directors present
//! - Numbered resolutions
//! - Chairman and Secretary signatures
//!
//! Usage:
//! ```zig
//! const resolution_data = BoardResolutionData{
//!     .company = .{ .name = "QUANTUM ENCODING LTD", ... },
//!     .meeting = .{ .date = "1 January 2026", .type = .Board },
//!     .resolutions = &[_]Resolution{...},
//! };
//! const pdf = try generateBoardResolution(allocator, resolution_data);
//! ```

const std = @import("std");
const document = @import("document.zig");

// =============================================================================
// Data Structures
// =============================================================================

/// Template styling options
pub const TemplateStyle = struct {
    primary_color: []const u8 = "#1a3a5c", // Dark navy
    accent_color: []const u8 = "#2563eb", // Blue
};

/// Template configuration
pub const Template = struct {
    id: []const u8 = "board_resolution_uk",
    version: []const u8 = "1.0.0",
    style: TemplateStyle = .{},
};

/// Company information
pub const Company = struct {
    name: []const u8,
    registration_number: ?[]const u8 = null,
};

/// Meeting type
pub const MeetingType = enum {
    Board,
    General,
    Written,
    Emergency,

    pub fn toString(self: MeetingType) []const u8 {
        return switch (self) {
            .Board => "Board Meeting",
            .General => "General Meeting",
            .Written => "Written Resolution",
            .Emergency => "Emergency Board Meeting",
        };
    }

    pub fn fromString(s: []const u8) MeetingType {
        if (std.mem.eql(u8, s, "General")) return .General;
        if (std.mem.eql(u8, s, "Written")) return .Written;
        if (std.mem.eql(u8, s, "Emergency")) return .Emergency;
        return .Board;
    }
};

/// Meeting information
pub const Meeting = struct {
    type: MeetingType = .Board,
    date: []const u8,
    time: ?[]const u8 = null,
    location: ?[]const u8 = null,
    reference: ?[]const u8 = null,
};

/// Director information
pub const Director = struct {
    name: []const u8,
    present: bool = true,
    role: ?[]const u8 = null, // e.g., "Chairman", "Managing Director"
};

/// Resolution status
pub const ResolutionStatus = enum {
    Proposed,
    Passed,
    Rejected,
    Deferred,

    pub fn toString(self: ResolutionStatus) []const u8 {
        return switch (self) {
            .Proposed => "PROPOSED",
            .Passed => "PASSED",
            .Rejected => "REJECTED",
            .Deferred => "DEFERRED",
        };
    }

    pub fn fromString(s: []const u8) ResolutionStatus {
        if (std.mem.eql(u8, s, "Passed") or std.mem.eql(u8, s, "PASSED")) return .Passed;
        if (std.mem.eql(u8, s, "Rejected") or std.mem.eql(u8, s, "REJECTED")) return .Rejected;
        if (std.mem.eql(u8, s, "Deferred") or std.mem.eql(u8, s, "DEFERRED")) return .Deferred;
        return .Proposed;
    }
};

/// Individual resolution
pub const Resolution = struct {
    number: u32,
    title: []const u8,
    text: []const u8,
    status: ResolutionStatus = .Passed,
    proposer: ?[]const u8 = null,
    seconder: ?[]const u8 = null,
};

/// Signatory information
pub const Signatory = struct {
    role: []const u8, // "Chairman" or "Company Secretary"
    name: []const u8,
    date: []const u8,
};

/// Complete board resolution data
pub const BoardResolutionData = struct {
    template: Template = .{},
    company: Company,
    meeting: Meeting,
    directors: []const Director = &[_]Director{},
    resolutions: []const Resolution,
    notes: ?[]const u8 = null,
    signatories: []const Signatory = &[_]Signatory{},
};

// =============================================================================
// Board Resolution Renderer
// =============================================================================

pub const BoardResolutionRenderer = struct {
    allocator: std.mem.Allocator,
    doc: document.PdfDocument,
    data: BoardResolutionData,

    // Page dimensions (A4 portrait)
    page_width: f32 = 595,
    page_height: f32 = 842,

    // Margins
    margin: f32 = 50,

    // Font IDs
    font_regular: []const u8 = "F0",
    font_bold: []const u8 = "F1",

    // Current Y position for content
    current_y: f32 = 0,

    pub fn init(allocator: std.mem.Allocator, data: BoardResolutionData) BoardResolutionRenderer {
        var renderer = BoardResolutionRenderer{
            .allocator = allocator,
            .doc = document.PdfDocument.init(allocator),
            .data = data,
        };

        // Register fonts
        renderer.font_regular = renderer.doc.getFontId(.helvetica);
        renderer.font_bold = renderer.doc.getFontId(.helvetica_bold);
        renderer.current_y = renderer.page_height - renderer.margin;

        return renderer;
    }

    pub fn deinit(self: *BoardResolutionRenderer) void {
        self.doc.deinit();
    }

    /// Draw the header with company name and title
    fn drawHeader(self: *BoardResolutionRenderer, content: *document.ContentStream) !void {
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
        }

        y -= 10;

        // Resolution title
        const title = self.data.meeting.type.toString();
        const title_upper = "BOARD RESOLUTION";
        const title_width = document.Font.helvetica_bold.measureText(title_upper, 16);
        try content.drawText(title_upper, center_x - title_width / 2, y, self.font_bold, 16, primary);

        y -= 18;

        // Meeting type subtitle
        const sub_width = document.Font.helvetica.measureText(title, 10);
        try content.drawText(title, center_x - sub_width / 2, y, self.font_regular, 10, document.Color{ .r = 0.3, .g = 0.3, .b = 0.3 });

        y -= 20;

        // Horizontal line
        try content.setStrokeColor(primary);
        try content.setLineWidth(1.0);
        try content.moveTo(self.margin, y);
        try content.lineTo(self.page_width - self.margin, y);
        try content.stroke();

        self.current_y = y - 20;
    }

    /// Draw meeting information
    fn drawMeetingInfo(self: *BoardResolutionRenderer, content: *document.ContentStream) !void {
        const text_color = document.Color{ .r = 0.1, .g = 0.1, .b = 0.1 };
        const label_color = document.Color{ .r = 0.4, .g = 0.4, .b = 0.4 };
        var y = self.current_y;
        const left_x = self.margin;
        const value_x = left_x + 100;

        // Date
        try content.drawText("Date:", left_x, y, self.font_regular, 10, label_color);
        try content.drawText(self.data.meeting.date, value_x, y, self.font_bold, 10, text_color);

        y -= 16;

        // Time if provided
        if (self.data.meeting.time) |time| {
            try content.drawText("Time:", left_x, y, self.font_regular, 10, label_color);
            try content.drawText(time, value_x, y, self.font_regular, 10, text_color);
            y -= 16;
        }

        // Location if provided
        if (self.data.meeting.location) |loc| {
            try content.drawText("Location:", left_x, y, self.font_regular, 10, label_color);
            try content.drawText(loc, value_x, y, self.font_regular, 10, text_color);
            y -= 16;
        }

        // Reference if provided
        if (self.data.meeting.reference) |ref| {
            try content.drawText("Reference:", left_x, y, self.font_regular, 10, label_color);
            try content.drawText(ref, value_x, y, self.font_regular, 10, text_color);
            y -= 16;
        }

        self.current_y = y - 15;
    }

    /// Draw directors present
    fn drawDirectors(self: *BoardResolutionRenderer, content: *document.ContentStream) !void {
        if (self.data.directors.len == 0) return;

        const primary = document.Color.fromHex(self.data.template.style.primary_color);
        const text_color = document.Color{ .r = 0.1, .g = 0.1, .b = 0.1 };
        var y = self.current_y;
        const left_x = self.margin;

        // Section title
        try content.drawText("Directors Present:", left_x, y, self.font_bold, 10, primary);
        y -= 16;

        // List directors
        for (self.data.directors) |director| {
            if (director.present) {
                var name_buf: [128]u8 = undefined;
                const name_text = if (director.role) |role|
                    std.fmt.bufPrint(&name_buf, "{s} ({s})", .{ director.name, role }) catch director.name
                else
                    director.name;

                try content.drawText(name_text, left_x + 15, y, self.font_regular, 10, text_color);
                y -= 14;
            }
        }

        self.current_y = y - 10;
    }

    /// Draw resolutions
    fn drawResolutions(self: *BoardResolutionRenderer, content: *document.ContentStream) !void {
        const primary = document.Color.fromHex(self.data.template.style.primary_color);
        const text_color = document.Color{ .r = 0.1, .g = 0.1, .b = 0.1 };
        const gray = document.Color{ .r = 0.4, .g = 0.4, .b = 0.4 };
        var y = self.current_y;
        const left_x = self.margin;
        const content_width = self.page_width - 2 * self.margin;

        // Section title
        try content.drawText("RESOLUTIONS", left_x, y, self.font_bold, 11, primary);
        y -= 20;

        for (self.data.resolutions) |resolution| {
            // Resolution number and title
            var num_buf: [32]u8 = undefined;
            const num_text = std.fmt.bufPrint(&num_buf, "{d}.", .{resolution.number}) catch "";
            try content.drawText(num_text, left_x, y, self.font_bold, 10, primary);
            try content.drawText(resolution.title, left_x + 25, y, self.font_bold, 10, text_color);

            // Status badge
            const status_text = resolution.status.toString();
            const status_x = self.page_width - self.margin - 60;
            const status_color = switch (resolution.status) {
                .Passed => document.Color{ .r = 0.0, .g = 0.5, .b = 0.0 },
                .Rejected => document.Color{ .r = 0.7, .g = 0.0, .b = 0.0 },
                .Deferred => document.Color{ .r = 0.6, .g = 0.4, .b = 0.0 },
                .Proposed => gray,
            };
            try content.drawText(status_text, status_x, y, self.font_bold, 9, status_color);

            y -= 16;

            // Resolution text - wrap if needed
            var text_wrapper = try document.wrapText(self.allocator, resolution.text, document.Font.helvetica, 10, content_width - 25);
            defer text_wrapper.deinit();

            for (text_wrapper.lines) |line| {
                try content.drawText(line, left_x + 25, y, self.font_regular, 10, text_color);
                y -= 14;
            }

            // Proposer/Seconder if provided
            if (resolution.proposer) |proposer| {
                var prop_buf: [128]u8 = undefined;
                const prop_text = std.fmt.bufPrint(&prop_buf, "Proposed by: {s}", .{proposer}) catch "";
                try content.drawText(prop_text, left_x + 25, y, self.font_regular, 9, gray);
                y -= 12;
            }

            if (resolution.seconder) |seconder| {
                var sec_buf: [128]u8 = undefined;
                const sec_text = std.fmt.bufPrint(&sec_buf, "Seconded by: {s}", .{seconder}) catch "";
                try content.drawText(sec_text, left_x + 25, y, self.font_regular, 9, gray);
                y -= 12;
            }

            y -= 10;
        }

        self.current_y = y;
    }

    /// Draw notes section
    fn drawNotes(self: *BoardResolutionRenderer, content: *document.ContentStream) !void {
        if (self.data.notes == null) return;

        const gray = document.Color{ .r = 0.4, .g = 0.4, .b = 0.4 };
        var y = self.current_y;
        const left_x = self.margin;

        try content.drawText("Notes:", left_x, y, self.font_bold, 9, gray);
        y -= 14;
        try content.drawText(self.data.notes.?, left_x + 10, y, self.font_regular, 9, gray);

        self.current_y = y - 20;
    }

    /// Draw signature section
    fn drawSignatures(self: *BoardResolutionRenderer, content: *document.ContentStream) !void {
        const text_color = document.Color{ .r = 0.1, .g = 0.1, .b = 0.1 };
        const label_color = document.Color{ .r = 0.4, .g = 0.4, .b = 0.4 };
        var y = self.current_y;
        const left_x = self.margin;
        const right_x = self.page_width / 2 + 30;
        const line_width: f32 = 180;

        if (self.data.signatories.len == 0) {
            // Draw placeholder signatures
            try content.setStrokeColor(label_color);
            try content.setLineWidth(0.5);

            // Chairman signature
            try content.moveTo(left_x, y);
            try content.lineTo(left_x + line_width, y);
            try content.stroke();
            y -= 15;
            try content.drawText("Chairman", left_x, y, self.font_regular, 9, label_color);
            y -= 25;

            try content.moveTo(left_x, y);
            try content.lineTo(left_x + line_width, y);
            try content.stroke();
            y -= 15;
            try content.drawText("Date", left_x, y, self.font_regular, 9, label_color);

            // Reset y for secretary
            y = self.current_y;

            // Secretary signature
            try content.moveTo(right_x, y);
            try content.lineTo(right_x + line_width, y);
            try content.stroke();
            y -= 15;
            try content.drawText("Company Secretary", right_x, y, self.font_regular, 9, label_color);
            y -= 25;

            try content.moveTo(right_x, y);
            try content.lineTo(right_x + line_width, y);
            try content.stroke();
            y -= 15;
            try content.drawText("Date", right_x, y, self.font_regular, 9, label_color);
        } else {
            // Draw actual signatures
            var col: usize = 0;
            for (self.data.signatories) |sig| {
                const sig_x = if (col == 0) left_x else right_x;

                try content.setStrokeColor(label_color);
                try content.setLineWidth(0.5);
                try content.moveTo(sig_x, y);
                try content.lineTo(sig_x + line_width, y);
                try content.stroke();

                try content.drawText(sig.name, sig_x + 5, y + 5, self.font_regular, 9, text_color);
                y -= 15;
                try content.drawText(sig.role, sig_x, y, self.font_regular, 9, label_color);
                y -= 20;
                try content.drawText(sig.date, sig_x, y, self.font_regular, 9, text_color);

                col += 1;
                if (col >= 2) {
                    col = 0;
                    y -= 30;
                } else {
                    y = self.current_y;
                }
            }
        }

        self.current_y = y - 30;
    }

    /// Render the complete resolution
    pub fn render(self: *BoardResolutionRenderer) ![]const u8 {
        var content = document.ContentStream.init(self.allocator);
        defer content.deinit();

        // Set page size to A4 portrait
        self.doc.setPageSize(.{ .width = 595, .height = 842 });

        // Draw all sections
        try self.drawHeader(&content);
        try self.drawMeetingInfo(&content);
        try self.drawDirectors(&content);
        try self.drawResolutions(&content);
        try self.drawNotes(&content);
        try self.drawSignatures(&content);

        // Add page to document
        try self.doc.addPage(&content);

        return self.doc.build();
    }
};

// =============================================================================
// Public API
// =============================================================================

/// Generate a board resolution PDF
pub fn generateBoardResolution(allocator: std.mem.Allocator, data: BoardResolutionData) ![]u8 {
    var renderer = BoardResolutionRenderer.init(allocator, data);
    defer renderer.deinit();

    const pdf_output = try renderer.render();
    return try allocator.dupe(u8, pdf_output);
}

/// Generate board resolution from JSON string
pub fn generateBoardResolutionFromJson(allocator: std.mem.Allocator, json_str: []const u8) ![]u8 {
    const result = try parseBoardResolutionJson(allocator, json_str);
    defer freeBoardResolutionData(allocator, &result.data, &result.tracking);
    return generateBoardResolution(allocator, result.data);
}

/// Generate a demo board resolution
pub fn generateDemoBoardResolution(allocator: std.mem.Allocator) ![]u8 {
    const directors = [_]Director{
        .{ .name = "RICHARD ALEXANDER TUNE", .present = true, .role = "Chairman" },
        .{ .name = "LANCE JOHN PEARSON", .present = true },
    };

    const resolutions = [_]Resolution{
        .{
            .number = 1,
            .title = "Allotment of Shares",
            .text = "RESOLVED that the Company allot 5 Ordinary shares of GBP 0.01 each to Lance John Pearson for a consideration of GBP 0.05.",
            .status = .Passed,
            .proposer = "Richard Tune",
            .seconder = "Lance Pearson",
        },
        .{
            .number = 2,
            .title = "Share Certificate",
            .text = "RESOLVED that a share certificate be issued to the allottee in respect of the shares allotted pursuant to Resolution 1.",
            .status = .Passed,
        },
        .{
            .number = 3,
            .title = "Companies House Filing",
            .text = "RESOLVED that the Company Secretary be authorised to file the necessary returns with Companies House.",
            .status = .Passed,
        },
    };

    const signatories = [_]Signatory{
        .{ .role = "Chairman", .name = "RICHARD ALEXANDER TUNE", .date = "21 December 2025" },
        .{ .role = "Company Secretary", .name = "RICHARD ALEXANDER TUNE", .date = "21 December 2025" },
    };

    const data = BoardResolutionData{
        .template = .{
            .style = .{
                .primary_color = "#1a3a5c",
                .accent_color = "#2563eb",
            },
        },
        .company = .{
            .name = "QUANTUM ENCODING LTD",
            .registration_number = "16575953",
        },
        .meeting = .{
            .type = .Board,
            .date = "21 December 2025",
            .time = "10:00 AM",
            .location = "33 Oxford Street, Coalville, LE67 3GS",
            .reference = "BR-2025-001",
        },
        .directors = &directors,
        .resolutions = &resolutions,
        .notes = "Meeting concluded at 10:30 AM",
        .signatories = &signatories,
    };

    return generateBoardResolution(allocator, data);
}

// =============================================================================
// JSON Parsing
// =============================================================================

pub const ParsedDataTracking = struct {
    company_name: bool = false,
    company_reg_number: bool = false,
    meeting_date: bool = false,
    meeting_time: bool = false,
    meeting_location: bool = false,
    meeting_reference: bool = false,
    notes: bool = false,
    template_primary_color: bool = false,
    template_accent_color: bool = false,
    // Directors and resolutions are handled separately
    directors_allocated: bool = false,
    resolutions_allocated: bool = false,
    signatories_allocated: bool = false,
};

pub fn freeBoardResolutionData(allocator: std.mem.Allocator, data: *const BoardResolutionData, tracking: *const ParsedDataTracking) void {
    if (tracking.template_primary_color) allocator.free(data.template.style.primary_color);
    if (tracking.template_accent_color) allocator.free(data.template.style.accent_color);
    if (tracking.company_name) allocator.free(data.company.name);
    if (tracking.company_reg_number) if (data.company.registration_number) |r| allocator.free(r);
    if (tracking.meeting_date) allocator.free(data.meeting.date);
    if (tracking.meeting_time) if (data.meeting.time) |t| allocator.free(t);
    if (tracking.meeting_location) if (data.meeting.location) |l| allocator.free(l);
    if (tracking.meeting_reference) if (data.meeting.reference) |r| allocator.free(r);
    if (tracking.notes) if (data.notes) |n| allocator.free(n);

    // Free directors array and contents
    if (tracking.directors_allocated) {
        for (data.directors) |dir| {
            if (dir.name.len > 0) allocator.free(dir.name);
            if (dir.role) |r| allocator.free(r);
        }
        allocator.free(data.directors);
    }

    // Free resolutions array and contents
    if (tracking.resolutions_allocated) {
        for (data.resolutions) |res| {
            if (res.title.len > 0) allocator.free(res.title);
            if (res.text.len > 0) allocator.free(res.text);
            if (res.proposer) |p| allocator.free(p);
            if (res.seconder) |s| allocator.free(s);
        }
        allocator.free(data.resolutions);
    }

    // Free signatories array and contents
    if (tracking.signatories_allocated) {
        for (data.signatories) |sig| {
            if (sig.role.len > 0) allocator.free(sig.role);
            if (sig.name.len > 0) allocator.free(sig.name);
            if (sig.date.len > 0) allocator.free(sig.date);
        }
        allocator.free(data.signatories);
    }
}

pub const ParsedResult = struct {
    data: BoardResolutionData,
    tracking: ParsedDataTracking,
};

fn parseBoardResolutionJson(allocator: std.mem.Allocator, json_str: []const u8) !ParsedResult {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const root = parsed.value.object;

    var tracking = ParsedDataTracking{};
    var data = BoardResolutionData{
        .company = .{ .name = "" },
        .meeting = .{ .date = "" },
        .resolutions = &[_]Resolution{},
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

    // Parse meeting
    if (root.get("meeting")) |m| {
        data.meeting.type = if (m.object.get("type")) |v| MeetingType.fromString(v.string) else .Board;
        if (m.object.get("date")) |v| {
            data.meeting.date = try allocator.dupe(u8, v.string);
            tracking.meeting_date = true;
        } else {
            data.meeting.date = "";
        }
        if (m.object.get("time")) |v| {
            data.meeting.time = try allocator.dupe(u8, v.string);
            tracking.meeting_time = true;
        }
        if (m.object.get("location")) |v| {
            data.meeting.location = try allocator.dupe(u8, v.string);
            tracking.meeting_location = true;
        }
        if (m.object.get("reference")) |v| {
            data.meeting.reference = try allocator.dupe(u8, v.string);
            tracking.meeting_reference = true;
        }
    }

    // Parse notes
    if (root.get("notes")) |v| {
        data.notes = try allocator.dupe(u8, v.string);
        tracking.notes = true;
    }

    // Parse directors array
    if (root.get("directors")) |d| {
        if (d == .array) {
            const directors_arr = d.array;
            var directors = try allocator.alloc(Director, directors_arr.items.len);
            for (directors_arr.items, 0..) |dir_val, i| {
                if (dir_val == .object) {
                    const dir_obj = dir_val.object;
                    directors[i] = Director{
                        .name = if (dir_obj.get("name")) |v| try allocator.dupe(u8, v.string) else "",
                        .present = if (dir_obj.get("present")) |v| v.bool else true,
                        .role = if (dir_obj.get("role")) |v| try allocator.dupe(u8, v.string) else null,
                    };
                }
            }
            data.directors = directors;
            tracking.directors_allocated = true;
        }
    }

    // Parse resolutions array
    if (root.get("resolutions")) |r| {
        if (r == .array) {
            const res_arr = r.array;
            var resolutions = try allocator.alloc(Resolution, res_arr.items.len);
            for (res_arr.items, 0..) |res_val, i| {
                if (res_val == .object) {
                    const res_obj = res_val.object;
                    resolutions[i] = Resolution{
                        .number = if (res_obj.get("number")) |v| @intCast(v.integer) else @as(u32, @intCast(i + 1)),
                        .title = if (res_obj.get("title")) |v| try allocator.dupe(u8, v.string) else "",
                        .text = if (res_obj.get("text")) |v| try allocator.dupe(u8, v.string) else "",
                        .status = if (res_obj.get("status")) |v| ResolutionStatus.fromString(v.string) else .Passed,
                        .proposer = if (res_obj.get("proposer")) |v| try allocator.dupe(u8, v.string) else null,
                        .seconder = if (res_obj.get("seconder")) |v| try allocator.dupe(u8, v.string) else null,
                    };
                }
            }
            data.resolutions = resolutions;
            tracking.resolutions_allocated = true;
        }
    }

    // Parse signatories array
    if (root.get("signatories")) |s| {
        if (s == .array) {
            const sig_arr = s.array;
            var signatories = try allocator.alloc(Signatory, sig_arr.items.len);
            for (sig_arr.items, 0..) |sig_val, i| {
                if (sig_val == .object) {
                    const sig_obj = sig_val.object;
                    signatories[i] = Signatory{
                        .role = if (sig_obj.get("role")) |v| try allocator.dupe(u8, v.string) else "",
                        .name = if (sig_obj.get("name")) |v| try allocator.dupe(u8, v.string) else "",
                        .date = if (sig_obj.get("date")) |v| try allocator.dupe(u8, v.string) else "",
                    };
                }
            }
            data.signatories = signatories;
            tracking.signatories_allocated = true;
        }
    }

    return ParsedResult{ .data = data, .tracking = tracking };
}

// =============================================================================
// Tests
// =============================================================================

test "board resolution generation" {
    const allocator = std.testing.allocator;
    const pdf = try generateDemoBoardResolution(allocator);
    defer allocator.free(pdf);
    try std.testing.expect(pdf.len > 1000);
}
