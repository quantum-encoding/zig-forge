//! Generic Document/Contract Renderer
//!
//! Generates professional contracts, agreements, and templated documents
//! with variable substitution, multi-page support, and signature blocks.
//!
//! Features:
//! - Variable substitution: {{variable_name}} placeholders
//! - Multi-page support with headers/footers
//! - Section rendering with automatic text wrapping
//! - Bullet point support (lines starting with "- ")
//! - Two-column party layout
//! - Signature blocks with role labels
//! - Template mode (highlighted placeholders when variables empty)

const std = @import("std");
const document = @import("document.zig");
const image = @import("image.zig");

// =============================================================================
// Data Structures
// =============================================================================

pub const Party = struct {
    role: []const u8 = "",
    name: []const u8 = "",
    address: []const u8 = "",
    identifier: []const u8 = "",
};

pub const Section = struct {
    heading: []const u8 = "",
    content: []const u8 = "",
};

pub const Signature = struct {
    role: []const u8 = "",
    name_line: []const u8 = "",
    date_line: []const u8 = "Date: _____________",
};

pub const PageMargins = struct {
    top: f32 = 60,
    right: f32 = 50,
    bottom: f32 = 60,
    left: f32 = 50,
};

pub const Styling = struct {
    primary_color: []const u8 = "#1a365d",
    secondary_color: []const u8 = "#2c5282",
    font_family: []const u8 = "Helvetica",
    heading_size: f32 = 14,
    body_size: f32 = 11,
    line_height: f32 = 1.4,
    page_margins: PageMargins = .{},
};

pub const Header = struct {
    logo_base64: ?[]const u8 = null,
    company_name: []const u8 = "",
    show_on_all_pages: bool = true,
};

pub const ContractData = struct {
    document_type: []const u8 = "document",
    title: []const u8 = "",
    subtitle: []const u8 = "",

    parties: []const Party = &[_]Party{},
    date_line: []const u8 = "",

    sections: []const Section = &[_]Section{},
    signatures: []const Signature = &[_]Signature{},

    footer: []const u8 = "Page {{page_number}} of {{total_pages}}",

    variables: std.StringHashMap([]const u8) = undefined,
    variables_json: ?[]const u8 = null, // For JSON parsing

    styling: Styling = .{},
    header: Header = .{},
};

// =============================================================================
// Contract Renderer
// =============================================================================

pub const ContractRenderer = struct {
    allocator: std.mem.Allocator,
    doc: document.PdfDocument,
    data: ContractData,

    // Fonts
    font_regular: []const u8 = "F0",
    font_bold: []const u8 = "F1",

    // Layout state
    current_y: f32 = 0,
    page_number: u32 = 1,
    total_pages: u32 = 1,

    // Computed values
    margin_left: f32 = 50,
    margin_right: f32 = 50,
    margin_top: f32 = 60,
    margin_bottom: f32 = 60,
    page_width: f32 = document.A4_WIDTH,
    page_height: f32 = document.A4_HEIGHT,
    usable_width: f32 = 0,

    // Variables map (parsed from JSON)
    variables: std.StringHashMap([]const u8),

    // Decoded images
    logo_decoded: ?[]u8 = null,
    logo_pixels: ?[]u8 = null,

    // Content pages
    pages: std.ArrayListUnmanaged(document.ContentStream),

    pub fn init(allocator: std.mem.Allocator, data: ContractData) !ContractRenderer {
        var renderer = ContractRenderer{
            .allocator = allocator,
            .doc = document.PdfDocument.init(allocator),
            .data = data,
            .variables = std.StringHashMap([]const u8).init(allocator),
            .pages = .empty,
        };

        // Apply margins from styling
        renderer.margin_left = data.styling.page_margins.left;
        renderer.margin_right = data.styling.page_margins.right;
        renderer.margin_top = data.styling.page_margins.top;
        renderer.margin_bottom = data.styling.page_margins.bottom;
        renderer.usable_width = renderer.page_width - renderer.margin_left - renderer.margin_right;

        // Set up fonts
        if (std.mem.eql(u8, data.styling.font_family, "Times-Roman") or std.mem.eql(u8, data.styling.font_family, "Times")) {
            renderer.font_regular = renderer.doc.getFontId(.times_roman);
            renderer.font_bold = renderer.doc.getFontId(.times_bold);
        } else if (std.mem.eql(u8, data.styling.font_family, "Courier")) {
            renderer.font_regular = renderer.doc.getFontId(.courier);
            renderer.font_bold = renderer.doc.getFontId(.courier_bold);
        } else {
            renderer.font_regular = renderer.doc.getFontId(.helvetica);
            renderer.font_bold = renderer.doc.getFontId(.helvetica_bold);
        }

        renderer.current_y = renderer.page_height - renderer.margin_top;

        return renderer;
    }

    pub fn deinit(self: *ContractRenderer) void {
        if (self.logo_decoded) |d| self.allocator.free(d);

        for (self.pages.items) |*page| {
            page.deinit();
        }
        self.pages.deinit(self.allocator);

        // Free all values stored in the variables hashmap — these were
        // allocated by parseVariables via allocator.dupe.
        var it = self.variables.valueIterator();
        while (it.next()) |v| {
            self.allocator.free(v.*);
        }
        self.variables.deinit();
        self.doc.deinit();
    }

    /// Substitute variables in text: {{var_name}} -> value
    fn substituteVariables(self: *ContractRenderer, text: []const u8) ![]const u8 {
        var result: std.ArrayListUnmanaged(u8) = .empty;
        errdefer result.deinit(self.allocator);

        var i: usize = 0;
        while (i < text.len) {
            if (i + 1 < text.len and text[i] == '{' and text[i + 1] == '{') {
                // Find closing }}
                const start = i + 2;
                var end = start;
                while (end + 1 < text.len) {
                    if (text[end] == '}' and text[end + 1] == '}') {
                        break;
                    }
                    end += 1;
                }

                if (end + 1 < text.len and text[end] == '}') {
                    const var_name = text[start..end];

                    // Check for special variables
                    if (std.mem.eql(u8, var_name, "page_number")) {
                        var buf: [16]u8 = undefined;
                        const num_str = std.fmt.bufPrint(&buf, "{d}", .{self.page_number}) catch "1";
                        try result.appendSlice(self.allocator, num_str);
                    } else if (std.mem.eql(u8, var_name, "total_pages")) {
                        var buf: [16]u8 = undefined;
                        const num_str = std.fmt.bufPrint(&buf, "{d}", .{self.total_pages}) catch "1";
                        try result.appendSlice(self.allocator, num_str);
                    } else if (self.variables.get(var_name)) |value| {
                        try result.appendSlice(self.allocator, value);
                    } else {
                        // Keep placeholder if no value (template mode)
                        try result.appendSlice(self.allocator, "{{");
                        try result.appendSlice(self.allocator, var_name);
                        try result.appendSlice(self.allocator, "}}");
                    }
                    i = end + 2;
                } else {
                    try result.append(self.allocator, text[i]);
                    i += 1;
                }
            } else {
                try result.append(self.allocator, text[i]);
                i += 1;
            }
        }

        return result.toOwnedSlice(self.allocator);
    }

    /// Check if we need a new page
    fn checkPageBreak(self: *ContractRenderer, content: *document.ContentStream, needed_height: f32) !void {
        if (self.current_y - needed_height < self.margin_bottom) {
            // Save current page
            try self.pages.append(self.allocator, content.*);

            // Start new page
            content.* = document.ContentStream.init(self.allocator);
            self.page_number += 1;
            self.current_y = self.page_height - self.margin_top;

            // Draw header on new page if configured
            if (self.data.header.show_on_all_pages) {
                try self.drawHeader(content);
            }
        }
    }

    /// Draw page header
    fn drawHeader(self: *ContractRenderer, content: *document.ContentStream) !void {
        const primary = document.Color.fromHex(self.data.styling.primary_color);

        // Company name in header
        const company_name = try self.substituteVariables(self.data.header.company_name);
        defer self.allocator.free(company_name);

        if (company_name.len > 0) {
            try content.drawText(company_name, self.margin_left, self.page_height - 30, self.font_bold, 12, primary);
        }

        // Separator line
        try content.drawLine(self.margin_left, self.page_height - 45, self.page_width - self.margin_right, self.page_height - 45, primary, 0.5);

        self.current_y = self.page_height - self.margin_top - 10;
    }

    /// Draw page footer
    fn drawFooter(self: *ContractRenderer, content: *document.ContentStream) !void {
        const secondary = document.Color.fromHex(self.data.styling.secondary_color);

        const footer_text = try self.substituteVariables(self.data.footer);
        defer self.allocator.free(footer_text);

        // Center footer
        const font_enum = document.Font.helvetica;
        const footer_width = font_enum.measureText(footer_text, 9);
        const footer_x = (self.page_width - footer_width) / 2;

        try content.drawText(footer_text, footer_x, self.margin_bottom - 20, self.font_regular, 9, secondary);
    }

    /// Draw title section
    fn drawTitle(self: *ContractRenderer, content: *document.ContentStream) !void {
        const primary = document.Color.fromHex(self.data.styling.primary_color);

        // Main title (centered, large)
        if (self.data.title.len > 0) {
            const title = try self.substituteVariables(self.data.title);
            defer self.allocator.free(title);

            const font_enum = document.Font.helvetica_bold;
            const title_width = font_enum.measureText(title, 20);
            const title_x = (self.page_width - title_width) / 2;

            try content.drawText(title, title_x, self.current_y, self.font_bold, 20, primary);
            self.current_y -= 28;
        }

        // Subtitle (centered, smaller)
        if (self.data.subtitle.len > 0) {
            const subtitle = try self.substituteVariables(self.data.subtitle);
            defer self.allocator.free(subtitle);

            const font_enum = document.Font.helvetica;
            const subtitle_width = font_enum.measureText(subtitle, 12);
            const subtitle_x = (self.page_width - subtitle_width) / 2;

            try content.drawText(subtitle, subtitle_x, self.current_y, self.font_regular, 12, document.Color.fromHex("#666666"));
            self.current_y -= 30;
        }
    }

    /// Draw parties in two-column layout
    fn drawParties(self: *ContractRenderer, content: *document.ContentStream) !void {
        if (self.data.parties.len == 0) return;

        const col_width = self.usable_width / 2 - 20;
        const primary = document.Color.fromHex(self.data.styling.primary_color);
        const body_size = self.data.styling.body_size;

        var col_x: f32 = self.margin_left;
        const start_y = self.current_y;
        var max_height: f32 = 0;

        for (self.data.parties, 0..) |party, i| {
            var party_y = start_y;

            // Role header
            const role = try self.substituteVariables(party.role);
            defer self.allocator.free(role);
            try content.drawText(role, col_x, party_y, self.font_bold, body_size, primary);
            party_y -= body_size * 1.4;

            // Name
            const name = try self.substituteVariables(party.name);
            defer self.allocator.free(name);
            if (name.len > 0) {
                try content.drawText(name, col_x, party_y, self.font_bold, body_size, document.Color.black);
                party_y -= body_size * 1.3;
            }

            // Address (may have newlines)
            const address = try self.substituteVariables(party.address);
            defer self.allocator.free(address);
            if (address.len > 0) {
                var lines = std.mem.splitScalar(u8, address, '\n');
                while (lines.next()) |line| {
                    try content.drawText(line, col_x, party_y, self.font_regular, body_size - 1, document.Color.black);
                    party_y -= (body_size - 1) * 1.3;
                }
            }

            // Identifier
            const identifier = try self.substituteVariables(party.identifier);
            defer self.allocator.free(identifier);
            if (identifier.len > 0) {
                try content.drawText(identifier, col_x, party_y, self.font_regular, body_size - 1, document.Color.fromHex("#666666"));
                party_y -= body_size * 1.3;
            }

            const height = start_y - party_y;
            if (height > max_height) max_height = height;

            // Move to second column
            if (i == 0) {
                col_x = self.margin_left + col_width + 40;
            }
        }

        self.current_y -= max_height + 20;

        // Date line
        if (self.data.date_line.len > 0) {
            const date_line = try self.substituteVariables(self.data.date_line);
            defer self.allocator.free(date_line);
            try content.drawText(date_line, self.margin_left, self.current_y, self.font_regular, body_size, document.Color.black);
            self.current_y -= 25;
        }

        // Separator line
        try content.drawLine(self.margin_left, self.current_y, self.page_width - self.margin_right, self.current_y, primary, 0.5);
        self.current_y -= 20;
    }

    /// Draw a section with heading and content
    fn drawSection(self: *ContractRenderer, content: *document.ContentStream, section: Section) !void {
        const primary = document.Color.fromHex(self.data.styling.primary_color);
        const heading_size = self.data.styling.heading_size;
        const body_size = self.data.styling.body_size;
        const line_height = self.data.styling.line_height;

        // Get font enum for text measurement
        const font_enum = if (std.mem.eql(u8, self.data.styling.font_family, "Times"))
            document.Font.times_roman
        else if (std.mem.eql(u8, self.data.styling.font_family, "Courier"))
            document.Font.courier
        else
            document.Font.helvetica;

        // Section heading
        if (section.heading.len > 0) {
            try self.checkPageBreak(content, heading_size * 2);

            const heading = try self.substituteVariables(section.heading);
            defer self.allocator.free(heading);

            try content.drawText(heading, self.margin_left, self.current_y, self.font_bold, heading_size, primary);
            self.current_y -= heading_size * line_height + 8;
        }

        // Section content
        if (section.content.len > 0) {
            const text = try self.substituteVariables(section.content);
            defer self.allocator.free(text);

            // Split by newlines first
            var paragraphs = std.mem.splitScalar(u8, text, '\n');
            while (paragraphs.next()) |paragraph| {
                if (paragraph.len == 0) {
                    self.current_y -= body_size * 0.5; // Empty line = half spacing
                    continue;
                }

                // Check for bullet point
                const is_bullet = paragraph.len > 2 and paragraph[0] == '-' and paragraph[1] == ' ';
                const text_content = if (is_bullet) paragraph[2..] else paragraph;
                const indent: f32 = if (is_bullet) 15 else 0;

                // Wrap text
                var wrapped = try document.wrapText(self.allocator, text_content, font_enum, body_size, self.usable_width - indent);
                defer wrapped.deinit();

                for (wrapped.lines, 0..) |line, line_idx| {
                    try self.checkPageBreak(content, body_size * line_height);

                    // Draw bullet on first line
                    if (is_bullet and line_idx == 0) {
                        try content.drawText("\xe2\x80\xa2", self.margin_left, self.current_y, self.font_regular, body_size, document.Color.black); // bullet character
                    }

                    try content.drawText(line, self.margin_left + indent, self.current_y, self.font_regular, body_size, document.Color.black);
                    self.current_y -= body_size * line_height;
                }
            }

            self.current_y -= 10; // Section spacing
        }
    }

    /// Draw signature blocks
    fn drawSignatures(self: *ContractRenderer, content: *document.ContentStream) !void {
        if (self.data.signatures.len == 0) return;

        const body_size = self.data.styling.body_size;
        const primary = document.Color.fromHex(self.data.styling.primary_color);

        // Ensure enough space for signatures
        const sig_height: f32 = 80;
        try self.checkPageBreak(content, sig_height);

        self.current_y -= 30; // Extra space before signatures

        const sig_width = self.usable_width / @as(f32, @floatFromInt(self.data.signatures.len)) - 30;
        var sig_x = self.margin_left;

        for (self.data.signatures) |sig| {
            const start_y = self.current_y;

            // Role label
            const role = try self.substituteVariables(sig.role);
            defer self.allocator.free(role);
            try content.drawText(role, sig_x, start_y, self.font_bold, body_size - 1, primary);

            // Signature line
            try content.drawLine(sig_x, start_y - 35, sig_x + sig_width, start_y - 35, document.Color.black, 0.5);

            // Name below line
            const name = try self.substituteVariables(sig.name_line);
            defer self.allocator.free(name);
            try content.drawText(name, sig_x, start_y - 48, self.font_regular, body_size - 1, document.Color.black);

            // Date line
            const date = try self.substituteVariables(sig.date_line);
            defer self.allocator.free(date);
            try content.drawText(date, sig_x, start_y - 62, self.font_regular, body_size - 2, document.Color.fromHex("#666666"));

            sig_x += sig_width + 30;
        }

        self.current_y -= sig_height;
    }

    /// Parse variables from JSON string
    fn parseVariables(self: *ContractRenderer, json_str: []const u8) !void {
        // Simple JSON object parser for {"key": "value", ...}
        var i: usize = 0;

        // Skip to opening brace
        while (i < json_str.len and json_str[i] != '{') : (i += 1) {}
        if (i >= json_str.len) return;
        i += 1;

        while (i < json_str.len) {
            // Skip whitespace
            while (i < json_str.len and (json_str[i] == ' ' or json_str[i] == '\n' or json_str[i] == '\r' or json_str[i] == '\t' or json_str[i] == ',')) : (i += 1) {}

            if (i >= json_str.len or json_str[i] == '}') break;

            // Parse key
            if (json_str[i] != '"') {
                i += 1;
                continue;
            }
            i += 1;
            const key_start = i;
            while (i < json_str.len and json_str[i] != '"') : (i += 1) {}
            const key = json_str[key_start..i];
            i += 1;

            // Skip to colon
            while (i < json_str.len and json_str[i] != ':') : (i += 1) {}
            i += 1;

            // Skip whitespace
            while (i < json_str.len and (json_str[i] == ' ' or json_str[i] == '\n' or json_str[i] == '\r' or json_str[i] == '\t')) : (i += 1) {}

            // Parse value
            if (i >= json_str.len or json_str[i] != '"') {
                i += 1;
                continue;
            }
            i += 1;
            const value_start = i;

            // Handle escaped characters in value
            var value_buf: std.ArrayListUnmanaged(u8) = .empty;
            defer value_buf.deinit(self.allocator);

            while (i < json_str.len) {
                if (json_str[i] == '\\' and i + 1 < json_str.len) {
                    const next = json_str[i + 1];
                    if (next == 'n') {
                        try value_buf.append(self.allocator, '\n');
                    } else if (next == 't') {
                        try value_buf.append(self.allocator, '\t');
                    } else if (next == '"') {
                        try value_buf.append(self.allocator, '"');
                    } else if (next == '\\') {
                        try value_buf.append(self.allocator, '\\');
                    } else {
                        try value_buf.append(self.allocator, next);
                    }
                    i += 2;
                } else if (json_str[i] == '"') {
                    break;
                } else {
                    try value_buf.append(self.allocator, json_str[i]);
                    i += 1;
                }
            }
            i += 1; // Skip closing quote

            // Store in hashmap (duplicate the value since it's from ArrayList)
            const value_copy = try self.allocator.dupe(u8, value_buf.items);
            try self.variables.put(key, value_copy);
            _ = value_start;
        }
    }

    /// Generate the complete document PDF
    pub fn render(self: *ContractRenderer) ![]const u8 {
        // Parse variables if provided as JSON string
        if (self.data.variables_json) |vars_json| {
            try self.parseVariables(vars_json);
        }

        var content = document.ContentStream.init(self.allocator);
        // No defer deinit here — ownership transfers to self.pages via append
        // at line ~600 (or earlier via checkPageBreak). renderer.deinit()
        // iterates self.pages and deinits each ContentStream.

        // Load logo if provided
        var logo_id: ?[]const u8 = null;
        if (self.data.header.logo_base64) |logo_b64| {
            if (logo_b64.len > 0) {
                const result = image.loadImageFromBase64(self.allocator, logo_b64) catch null;
                if (result) |r| {
                    self.logo_decoded = r.decoded_bytes;
                    if (r.image.format != .jpeg) {
                        self.logo_pixels = @constCast(r.image.data);
                    }
                    logo_id = self.doc.addImage(r.image) catch null;
                }
            }
        }

        // Draw header
        try self.drawHeader(&content);

        // Draw title
        try self.drawTitle(&content);

        // Draw parties
        try self.drawParties(&content);

        // Draw sections
        for (self.data.sections) |section| {
            try self.drawSection(&content, section);
        }

        // Draw signatures
        try self.drawSignatures(&content);

        // Add final page
        try self.pages.append(self.allocator, content);

        // Update total pages count
        self.total_pages = @intCast(self.pages.items.len);

        // Now render all pages with correct page numbers
        for (self.pages.items, 0..) |*page, page_idx| {
            self.page_number = @intCast(page_idx + 1);

            // Draw footer on each page
            try self.drawFooter(page);

            // Add page to document
            try self.doc.addPage(page);
        }

        // Generate final PDF
        return self.doc.build();
    }

    /// Generate document to file
    pub fn generateToFile(self: *ContractRenderer, path: []const u8) !void {
        const pdf_data = try self.render();
        defer self.allocator.free(pdf_data);

        const io = std.Io.Threaded.global_single_threaded.io();
        const file = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);

        _ = try file.writeAll(io, pdf_data);
    }
};

// =============================================================================
// Public API
// =============================================================================

/// Generate a contract/document PDF from ContractData
pub fn generateContract(allocator: std.mem.Allocator, data: ContractData) ![]u8 {
    var renderer = try ContractRenderer.init(allocator, data);
    defer renderer.deinit();

    const pdf_output = try renderer.render();

    // Make a copy since the original is owned by renderer.doc
    return try allocator.dupe(u8, pdf_output);
}

/// Generate contract from JSON string
pub fn generateContractFromJson(allocator: std.mem.Allocator, json_str: []const u8) ![]u8 {
    const parsed = try parseContractJson(allocator, json_str);
    defer parsed.deinit(allocator);

    var renderer = try ContractRenderer.init(allocator, parsed.data);
    defer renderer.deinit();

    // Pass variables JSON to renderer
    renderer.data.variables_json = parsed.variables_json;

    const pdf_output = try renderer.render();

    // Make a copy since the original is owned by renderer.doc
    return try allocator.dupe(u8, pdf_output);
}

/// Parsed contract data with cleanup
const ParsedContract = struct {
    data: ContractData,
    parties_buf: []Party,
    sections_buf: []Section,
    signatures_buf: []Signature,
    variables_json: ?[]const u8,

    pub fn deinit(self: ParsedContract, allocator: std.mem.Allocator) void {
        // Free all duped strings in top-level data fields
        allocator.free(self.data.document_type);
        allocator.free(self.data.title);
        allocator.free(self.data.subtitle);
        allocator.free(self.data.date_line);
        allocator.free(self.data.footer);
        allocator.free(self.data.header.company_name);
        if (self.data.header.logo_base64) |b| allocator.free(b);
        allocator.free(self.data.styling.primary_color);
        allocator.free(self.data.styling.secondary_color);
        allocator.free(self.data.styling.font_family);

        // Free duped strings inside each party
        for (self.parties_buf) |p| {
            allocator.free(p.role);
            allocator.free(p.name);
            allocator.free(p.address);
            allocator.free(p.identifier);
        }
        allocator.free(self.parties_buf);

        // Free duped strings inside each section
        for (self.sections_buf) |s| {
            allocator.free(s.heading);
            allocator.free(s.content);
        }
        allocator.free(self.sections_buf);

        // Free duped strings inside each signature
        for (self.signatures_buf) |sig| {
            allocator.free(sig.role);
            allocator.free(sig.name_line);
            allocator.free(sig.date_line);
        }
        allocator.free(self.signatures_buf);

        // Free the extracted variables JSON substring
        if (self.variables_json) |v| allocator.free(v);
    }
};

/// Helper to extract a number as f32 from JSON Value (handles both int and float)
fn getJsonFloat(v: std.json.Value) f32 {
    return switch (v) {
        .float => @floatCast(v.float),
        .integer => @floatFromInt(v.integer),
        else => 0,
    };
}

/// Helper to duplicate a JSON string (returns null if field is null or missing)
fn dupeJsonString(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) !?[]const u8 {
    if (obj.get(key)) |v| {
        return switch (v) {
            .string => |s| try allocator.dupe(u8, s),
            else => null,
        };
    }
    return null;
}

/// Helper to duplicate a JSON string with default
fn dupeJsonStringDefault(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8, default: []const u8) ![]const u8 {
    return try dupeJsonString(allocator, obj, key) orelse try allocator.dupe(u8, default);
}

/// Parse contract data from JSON
fn parseContractJson(allocator: std.mem.Allocator, json_str: []const u8) !ParsedContract {
    // Use standard library JSON parser
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const root = parsed.value.object;

    var data = ContractData{};

    // Parse basic fields (duplicate strings so they survive after JSON is freed)
    data.document_type = try dupeJsonStringDefault(allocator, root, "document_type", "document");
    data.title = try dupeJsonStringDefault(allocator, root, "title", "");
    data.subtitle = try dupeJsonStringDefault(allocator, root, "subtitle", "");
    data.date_line = try dupeJsonStringDefault(allocator, root, "date_line", "");
    data.footer = try dupeJsonStringDefault(allocator, root, "footer", "Page {{page_number}} of {{total_pages}}");

    // Parse header
    if (root.get("header")) |h| {
        data.header.logo_base64 = try dupeJsonString(allocator, h.object, "logo_base64");
        data.header.company_name = try dupeJsonStringDefault(allocator, h.object, "company_name", "");
        if (h.object.get("show_on_all_pages")) |v| {
            if (v == .bool) data.header.show_on_all_pages = v.bool;
        }
    } else {
        data.header.company_name = try allocator.dupe(u8, "");
    }

    // Parse styling
    if (root.get("styling")) |s| {
        data.styling.primary_color = try dupeJsonStringDefault(allocator, s.object, "primary_color", "#1a365d");
        data.styling.secondary_color = try dupeJsonStringDefault(allocator, s.object, "secondary_color", "#2c5282");
        data.styling.font_family = try dupeJsonStringDefault(allocator, s.object, "font_family", "Helvetica");
        if (s.object.get("heading_size")) |v| data.styling.heading_size = getJsonFloat(v);
        if (s.object.get("body_size")) |v| data.styling.body_size = getJsonFloat(v);
        if (s.object.get("line_height")) |v| data.styling.line_height = getJsonFloat(v);

        if (s.object.get("page_margins")) |m| {
            if (m.object.get("top")) |v| data.styling.page_margins.top = getJsonFloat(v);
            if (m.object.get("right")) |v| data.styling.page_margins.right = getJsonFloat(v);
            if (m.object.get("bottom")) |v| data.styling.page_margins.bottom = getJsonFloat(v);
            if (m.object.get("left")) |v| data.styling.page_margins.left = getJsonFloat(v);
        }
    } else {
        data.styling.primary_color = try allocator.dupe(u8, "#1a365d");
        data.styling.secondary_color = try allocator.dupe(u8, "#2c5282");
        data.styling.font_family = try allocator.dupe(u8, "Helvetica");
    }

    // Parse parties
    var parties_buf: []Party = &[_]Party{};
    if (root.get("parties")) |p| {
        if (p == .array) {
            const parties_arr = p.array.items;
            parties_buf = try allocator.alloc(Party, parties_arr.len);
            for (parties_arr, 0..) |party_val, i| {
                if (party_val == .object) {
                    parties_buf[i] = .{
                        .role = try dupeJsonStringDefault(allocator, party_val.object, "role", ""),
                        .name = try dupeJsonStringDefault(allocator, party_val.object, "name", ""),
                        .address = try dupeJsonStringDefault(allocator, party_val.object, "address", ""),
                        .identifier = try dupeJsonStringDefault(allocator, party_val.object, "identifier", ""),
                    };
                }
            }
            data.parties = parties_buf;
        }
    }

    // Parse sections
    var sections_buf: []Section = &[_]Section{};
    if (root.get("sections")) |s| {
        if (s == .array) {
            const sections_arr = s.array.items;
            sections_buf = try allocator.alloc(Section, sections_arr.len);
            for (sections_arr, 0..) |section_val, i| {
                if (section_val == .object) {
                    sections_buf[i] = .{
                        .heading = try dupeJsonStringDefault(allocator, section_val.object, "heading", ""),
                        .content = try dupeJsonStringDefault(allocator, section_val.object, "content", ""),
                    };
                }
            }
            data.sections = sections_buf;
        }
    }

    // Parse signatures
    var signatures_buf: []Signature = &[_]Signature{};
    if (root.get("signatures")) |s| {
        if (s == .array) {
            const sigs_arr = s.array.items;
            signatures_buf = try allocator.alloc(Signature, sigs_arr.len);
            for (sigs_arr, 0..) |sig_val, i| {
                if (sig_val == .object) {
                    signatures_buf[i] = .{
                        .role = try dupeJsonStringDefault(allocator, sig_val.object, "role", ""),
                        .name_line = try dupeJsonStringDefault(allocator, sig_val.object, "name_line", ""),
                        .date_line = try dupeJsonStringDefault(allocator, sig_val.object, "date_line", "Date: _____________"),
                    };
                }
            }
            data.signatures = signatures_buf;
        }
    }

    // Extract variables JSON substring for later parsing (this is safe as json_str lives longer)
    var variables_json: ?[]const u8 = null;
    if (std.mem.indexOf(u8, json_str, "\"variables\"")) |start| {
        // Find the opening brace after "variables":
        var i = start + 11;
        while (i < json_str.len and json_str[i] != '{') : (i += 1) {}
        if (i < json_str.len) {
            const obj_start = i;
            var depth: i32 = 1;
            i += 1;
            while (i < json_str.len and depth > 0) : (i += 1) {
                if (json_str[i] == '{') depth += 1;
                if (json_str[i] == '}') depth -= 1;
            }
            variables_json = try allocator.dupe(u8, json_str[obj_start..i]);
        }
    }

    return .{
        .data = data,
        .parties_buf = parties_buf,
        .sections_buf = sections_buf,
        .signatures_buf = signatures_buf,
        .variables_json = variables_json,
    };
}

// =============================================================================
// Demo Generator
// =============================================================================

pub fn generateDemoContract(allocator: std.mem.Allocator) ![]u8 {
    const demo_json =
        \\{
        \\  "document_type": "document",
        \\  "title": "Kitchen Renovation Contract",
        \\  "subtitle": "Service Agreement",
        \\  "parties": [
        \\    {
        \\      "role": "Contractor",
        \\      "name": "{{contractor_name}}",
        \\      "address": "{{contractor_address}}",
        \\      "identifier": "Company No: {{contractor_company_no}}"
        \\    },
        \\    {
        \\      "role": "Client",
        \\      "name": "{{client_name}}",
        \\      "address": "{{client_address}}",
        \\      "identifier": ""
        \\    }
        \\  ],
        \\  "date_line": "Dated: {{contract_date}}",
        \\  "sections": [
        \\    {
        \\      "heading": "1. Scope of Work",
        \\      "content": "The Contractor agrees to perform the following work at {{property_address}}:\n\n- Remove existing kitchen units and appliances\n- Install new kitchen cabinets and units\n- Fit granite worktops\n- Complete all plumbing connections\n- Complete all electrical work\n- Final clean and handover"
        \\    },
        \\    {
        \\      "heading": "2. Payment Terms",
        \\      "content": "Total contract price: £{{total_price}}\n\n- Deposit: £{{deposit_amount}} due on signing this agreement\n- Progress payment: £{{progress_amount}} due at mid-point\n- Final balance: £{{balance_amount}} due on satisfactory completion"
        \\    },
        \\    {
        \\      "heading": "3. Timeline",
        \\      "content": "Work to commence: {{start_date}}\nEstimated completion: {{end_date}}\n\nThe Contractor will make every effort to complete the work within the estimated timeframe, subject to unforeseen circumstances and weather conditions."
        \\    },
        \\    {
        \\      "heading": "4. Warranties",
        \\      "content": "The Contractor warrants all workmanship for a period of 12 months from completion. Manufacturer warranties apply to all materials and appliances as per their terms."
        \\    },
        \\    {
        \\      "heading": "5. Terms and Conditions",
        \\      "content": "- All work to be carried out in accordance with current Building Regulations\n- The Client agrees to provide access to the property during working hours\n- Any variations to the scope must be agreed in writing\n- The Contractor maintains public liability insurance of £2,000,000"
        \\    }
        \\  ],
        \\  "signatures": [
        \\    {
        \\      "role": "For and on behalf of the Contractor",
        \\      "name_line": "{{contractor_name}}",
        \\      "date_line": "Date: _____________"
        \\    },
        \\    {
        \\      "role": "Client",
        \\      "name_line": "{{client_name}}",
        \\      "date_line": "Date: _____________"
        \\    }
        \\  ],
        \\  "footer": "Page {{page_number}} of {{total_pages}}",
        \\  "variables": {
        \\    "contractor_name": "Smith Building Services Ltd",
        \\    "contractor_address": "45 Trade Street\nBirmingham\nB1 2AB",
        \\    "contractor_company_no": "12345678",
        \\    "client_name": "John Wilson",
        \\    "client_address": "12 Residential Lane\nCoventry\nCV1 3CD",
        \\    "property_address": "12 Residential Lane, Coventry",
        \\    "contract_date": "9th January 2025",
        \\    "total_price": "8,500.00",
        \\    "deposit_amount": "2,500.00",
        \\    "progress_amount": "3,000.00",
        \\    "balance_amount": "3,000.00",
        \\    "start_date": "15th January 2025",
        \\    "end_date": "15th February 2025"
        \\  },
        \\  "styling": {
        \\    "primary_color": "#1a365d",
        \\    "secondary_color": "#2c5282",
        \\    "font_family": "Helvetica",
        \\    "heading_size": 13,
        \\    "body_size": 10,
        \\    "line_height": 1.4,
        \\    "page_margins": { "top": 60, "right": 50, "bottom": 60, "left": 50 }
        \\  },
        \\  "header": {
        \\    "company_name": "{{contractor_name}}",
        \\    "show_on_all_pages": true
        \\  }
        \\}
    ;

    return generateContractFromJson(allocator, demo_json);
}
