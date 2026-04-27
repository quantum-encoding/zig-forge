//! DOCX Document Parser
//!
//! Parses DOCX (Office Open XML) files into a structured Document model.
//! DOCX files are ZIP archives containing XML files:
//!   word/document.xml       — main content (paragraphs, tables, images)
//!   word/styles.xml         — style definitions (Heading1, Normal, etc.)
//!   word/_rels/document.xml.rels — relationship map (rId → media files, URLs)
//!   word/media/*            — embedded images

const std = @import("std");
const builtin = @import("builtin");

// Re-exports. claude_code uses libc dirent.d_name (which doesn't exist
// on WASI's struct dirent), and pdf shells out to pdftotext/mutool via
// std.process.run (no subprocess in a WASI sandbox). Gate both so the
// WASM build can compile this module without dragging them in. Native
// builds get the full surface.
const is_wasi = builtin.target.os.tag == .wasi;
pub const xml = @import("xml.zig");
pub const zip = @import("zip.zig");
pub const rels = @import("rels.zig");
pub const styles = @import("styles.zig");
pub const mdx = @import("mdx.zig");
pub const xlsx = @import("xlsx.zig");
pub const pdf = if (is_wasi) struct {} else @import("pdf.zig");
pub const chunker = @import("chunker.zig");
pub const anthropic = @import("anthropic.zig");
pub const claude_code = if (is_wasi) struct {} else @import("claude_code.zig");
pub const md_parser = @import("md_parser.zig");
pub const docx_writer = @import("docx_writer.zig");
pub const zip_writer = @import("zip_writer.zig");
pub const ffi = @import("ffi.zig");
pub const fra = @import("fra.zig");

// Re-export key types
pub const StyleType = styles.StyleType;

// =============================================================================
// Document Model
// =============================================================================

pub const Run = struct {
    text: []const u8,
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
    is_code: bool = false, // inline `code` — rendered as monospace
    color: ?[]const u8 = null, // hex color e.g. "FF0000" for red
    hyperlink_url: ?[]const u8 = null,
    image_rel_id: ?[]const u8 = null,
};

pub const Paragraph = struct {
    style: StyleType = .normal,
    runs: []Run = &[_]Run{},
    is_list_item: bool = false,
    is_ordered: bool = false, // ordered (1. 2. 3.) vs unordered (- * +)
    numbering_level: u8 = 0,
};

pub const TableCell = struct {
    paragraphs: []Paragraph = &[_]Paragraph{},
    col_span: u16 = 1,
};

pub const TableRow = struct {
    cells: []TableCell = &[_]TableCell{},
};

pub const Table = struct {
    rows: []TableRow = &[_]TableRow{},
    /// Column widths in twentieths of a point (dxa). Empty = auto-width.
    col_widths: []const u16 = &[_]u16{},
};

pub const Element = union(enum) {
    paragraph: Paragraph,
    table: Table,
};

pub const MediaFile = struct {
    name: []const u8,
    data: []const u8,
};

pub const Document = struct {
    elements: []Element,
    media: []MediaFile,
    allocator: std.mem.Allocator,
    // Owned sub-allocations (freed in deinit)
    relationships: []const rels.Relationship = &[_]rels.Relationship{},
    style_map: []const styles.StyleInfo = &[_]styles.StyleInfo{},

    pub fn deinit(self: *Document) void {
        for (self.elements) |elem| {
            switch (elem) {
                .paragraph => |p| freeParagraph(self.allocator, &p),
                .table => |t| {
                    for (t.rows) |row| {
                        for (row.cells) |cell| {
                            for (cell.paragraphs) |p| freeParagraph(self.allocator, &p);
                            self.allocator.free(cell.paragraphs);
                        }
                        self.allocator.free(row.cells);
                    }
                    self.allocator.free(t.rows);
                },
            }
        }
        self.allocator.free(self.elements);
        for (self.media) |m| {
            self.allocator.free(m.data);
            self.allocator.free(m.name);
        }
        self.allocator.free(self.media);
        for (self.relationships) |rel| {
            self.allocator.free(rel.id);
            self.allocator.free(rel.target);
        }
        if (self.relationships.len > 0) self.allocator.free(self.relationships);
        for (self.style_map) |s| {
            self.allocator.free(s.id);
        }
        if (self.style_map.len > 0) self.allocator.free(self.style_map);
    }

    fn freeParagraph(allocator: std.mem.Allocator, p: *const Paragraph) void {
        for (p.runs) |run| {
            if (run.text.len > 0) allocator.free(run.text);
            if (run.hyperlink_url) |url| allocator.free(url);
            if (run.image_rel_id) |rel| allocator.free(rel);
        }
        allocator.free(p.runs);
    }
};

// =============================================================================
// Parser State Machine
// =============================================================================

const ParserState = struct {
    allocator: std.mem.Allocator,
    relationships: []const rels.Relationship,
    style_map: []const styles.StyleInfo,

    // Document-level collections
    elements: std.ArrayListUnmanaged(Element),

    // Paragraph state
    in_body: bool = false,
    in_paragraph: bool = false,
    in_run: bool = false,
    in_run_props: bool = false,
    in_para_props: bool = false,
    in_hyperlink: bool = false,
    in_table: bool = false,
    in_table_row: bool = false,
    in_table_cell: bool = false,
    in_drawing: bool = false,
    in_num_props: bool = false,

    // Current paragraph being built
    current_runs: std.ArrayListUnmanaged(Run),
    current_style: StyleType = .normal,
    current_is_list: bool = false,
    current_num_level: u8 = 0,

    // Current run being built
    current_text: std.ArrayListUnmanaged(u8),
    current_bold: bool = false,
    current_italic: bool = false,
    current_underline: bool = false,
    current_hyperlink_url: ?[]const u8 = null,
    current_image_rel: ?[]const u8 = null,

    // Table state
    table_rows: std.ArrayListUnmanaged(TableRow),
    row_cells: std.ArrayListUnmanaged(TableCell),
    cell_paragraphs: std.ArrayListUnmanaged(Paragraph),
    current_col_span: u16 = 1,

    fn init(allocator: std.mem.Allocator, relationships: []const rels.Relationship, style_map: []const styles.StyleInfo) ParserState {
        return .{
            .allocator = allocator,
            .relationships = relationships,
            .style_map = style_map,
            .elements = .empty,
            .current_runs = .empty,
            .current_text = .empty,
            .table_rows = .empty,
            .row_cells = .empty,
            .cell_paragraphs = .empty,
        };
    }

    fn finishRun(self: *ParserState) !void {
        if (self.current_text.items.len == 0 and self.current_image_rel == null) return;

        const text = if (self.current_text.items.len > 0)
            try self.allocator.dupe(u8, self.current_text.items)
        else
            "";

        // Dupe pointer-into-XML strings so they outlive the XML buffer
        const hyper_url = if (self.current_hyperlink_url) |url|
            try self.allocator.dupe(u8, url)
        else
            null;
        const img_rel = if (self.current_image_rel) |rel|
            try self.allocator.dupe(u8, rel)
        else
            null;

        try self.current_runs.append(self.allocator, .{
            .text = text,
            .bold = self.current_bold,
            .italic = self.current_italic,
            .underline = self.current_underline,
            .hyperlink_url = hyper_url,
            .image_rel_id = img_rel,
        });

        self.current_text.items.len = 0;
        self.current_bold = false;
        self.current_italic = false;
        self.current_underline = false;
        // Don't clear hyperlink_url here — it persists across runs within a hyperlink
        self.current_image_rel = null;
    }

    fn finishParagraph(self: *ParserState) !void {
        try self.finishRun();

        const para = Paragraph{
            .style = self.current_style,
            .runs = try self.current_runs.toOwnedSlice(self.allocator),
            .is_list_item = self.current_is_list,
            .numbering_level = self.current_num_level,
        };

        if (self.in_table_cell) {
            try self.cell_paragraphs.append(self.allocator, para);
        } else {
            try self.elements.append(self.allocator, .{ .paragraph = para });
        }

        self.current_style = .normal;
        self.current_is_list = false;
        self.current_num_level = 0;
    }

    fn finishCell(self: *ParserState) !void {
        try self.row_cells.append(self.allocator, .{
            .paragraphs = try self.cell_paragraphs.toOwnedSlice(self.allocator),
            .col_span = self.current_col_span,
        });
        self.current_col_span = 1;
    }

    fn finishRow(self: *ParserState) !void {
        try self.table_rows.append(self.allocator, .{
            .cells = try self.row_cells.toOwnedSlice(self.allocator),
        });
    }

    fn finishTable(self: *ParserState) !void {
        try self.elements.append(self.allocator, .{
            .table = .{
                .rows = try self.table_rows.toOwnedSlice(self.allocator),
            },
        });
    }

    fn handleElementStart(self: *ParserState, es: xml.Event.ElementStart) !void {
        const name = es.name;

        if (std.mem.eql(u8, name, "body")) {
            self.in_body = true;
        } else if (std.mem.eql(u8, name, "tbl")) {
            self.in_table = true;
        } else if (std.mem.eql(u8, name, "tr")) {
            self.in_table_row = true;
        } else if (std.mem.eql(u8, name, "tc")) {
            self.in_table_cell = true;
            self.current_col_span = 1;
        } else if (std.mem.eql(u8, name, "gridSpan")) {
            // Column span for merged cells
            if (xml.getAttr(es.attrs, "val")) |val| {
                self.current_col_span = std.fmt.parseInt(u16, val, 10) catch 1;
            }
        } else if (std.mem.eql(u8, name, "p")) {
            self.in_paragraph = true;
            self.current_style = .normal;
        } else if (std.mem.eql(u8, name, "pPr")) {
            self.in_para_props = true;
        } else if (self.in_para_props and std.mem.eql(u8, name, "pStyle")) {
            // Paragraph style reference
            if (xml.getAttr(es.attrs, "val")) |style_id| {
                if (styles.findStyleById(self.style_map, style_id)) |info| {
                    self.current_style = info.style_type;
                } else {
                    // Try classifying the ID directly
                    self.current_style = styles.classifyStyleId(style_id);
                }
            }
        } else if (self.in_para_props and std.mem.eql(u8, name, "numPr")) {
            self.in_num_props = true;
            self.current_is_list = true;
        } else if (self.in_num_props and std.mem.eql(u8, name, "ilvl")) {
            if (xml.getAttr(es.attrs, "val")) |val| {
                self.current_num_level = std.fmt.parseInt(u8, val, 10) catch 0;
            }
        } else if (std.mem.eql(u8, name, "hyperlink")) {
            self.in_hyperlink = true;
            // Look up relationship for URL
            if (xml.getAttr(es.attrs, "id")) |rid| {
                if (rels.findRelById(self.relationships, rid)) |rel| {
                    self.current_hyperlink_url = rel.target;
                }
            }
        } else if (std.mem.eql(u8, name, "r")) {
            self.in_run = true;
            self.current_bold = false;
            self.current_italic = false;
            self.current_underline = false;
        } else if (self.in_run and std.mem.eql(u8, name, "rPr")) {
            self.in_run_props = true;
        } else if (self.in_run_props and std.mem.eql(u8, name, "b")) {
            const val = xml.getAttr(es.attrs, "val") orelse "1";
            self.current_bold = !std.mem.eql(u8, val, "0");
        } else if (self.in_run_props and std.mem.eql(u8, name, "i")) {
            const val = xml.getAttr(es.attrs, "val") orelse "1";
            self.current_italic = !std.mem.eql(u8, val, "0");
        } else if (self.in_run_props and std.mem.eql(u8, name, "u")) {
            const val = xml.getAttr(es.attrs, "val") orelse "single";
            self.current_underline = !std.mem.eql(u8, val, "none");
        } else if (std.mem.eql(u8, name, "drawing") or std.mem.eql(u8, name, "pict")) {
            self.in_drawing = true;
        } else if (self.in_drawing and std.mem.eql(u8, name, "blip")) {
            // Image reference: r:embed="rId4"
            if (xml.getAttr(es.attrs, "embed")) |rid| {
                self.current_image_rel = rid;
            }
        } else if (self.in_run and std.mem.eql(u8, name, "br")) {
            // Line break within a run
            try self.current_text.append(self.allocator, '\n');
        }
    }

    fn handleElementEnd(self: *ParserState, name: []const u8) !void {
        if (std.mem.eql(u8, name, "body")) {
            self.in_body = false;
        } else if (std.mem.eql(u8, name, "tbl")) {
            try self.finishTable();
            self.in_table = false;
        } else if (std.mem.eql(u8, name, "tr")) {
            try self.finishRow();
            self.in_table_row = false;
        } else if (std.mem.eql(u8, name, "tc")) {
            try self.finishCell();
            self.in_table_cell = false;
        } else if (std.mem.eql(u8, name, "p")) {
            try self.finishParagraph();
            self.in_paragraph = false;
        } else if (std.mem.eql(u8, name, "pPr")) {
            self.in_para_props = false;
        } else if (std.mem.eql(u8, name, "numPr")) {
            self.in_num_props = false;
        } else if (std.mem.eql(u8, name, "hyperlink")) {
            try self.finishRun();
            self.in_hyperlink = false;
            self.current_hyperlink_url = null;
        } else if (std.mem.eql(u8, name, "r")) {
            try self.finishRun();
            self.in_run = false;
        } else if (std.mem.eql(u8, name, "rPr")) {
            self.in_run_props = false;
        } else if (std.mem.eql(u8, name, "drawing") or std.mem.eql(u8, name, "pict")) {
            self.in_drawing = false;
        }
    }

    fn handleText(self: *ParserState, text: []const u8) !void {
        if (self.in_run and !self.in_run_props and !self.in_drawing) {
            try self.current_text.appendSlice(self.allocator, text);
        }
    }
};

// Make classifyStyleId accessible from styles module
pub const classifyStyleId = styles.classifyStyleId;

// =============================================================================
// Public API
// =============================================================================

pub fn parseDocument(allocator: std.mem.Allocator, archive: *const zip.ZipArchive) !Document {
    // 1. Parse relationships
    var relationships: []const rels.Relationship = &[_]rels.Relationship{};
    if (archive.findEntry("word/_rels/document.xml.rels")) |entry| {
        const rels_xml = try archive.extract(entry);
        defer allocator.free(rels_xml);
        relationships = try rels.parseRelationships(allocator, rels_xml);
    }

    // 2. Parse styles (optional)
    var style_map: []const styles.StyleInfo = &[_]styles.StyleInfo{};
    if (archive.findEntry("word/styles.xml")) |entry| {
        const styles_xml = try archive.extract(entry);
        defer allocator.free(styles_xml);
        style_map = try styles.parseStyles(allocator, styles_xml);
    }

    // 3. Parse document.xml
    const doc_entry = archive.findEntry("word/document.xml") orelse
        return error.InvalidDocx;
    const doc_xml = try archive.extract(doc_entry);
    defer allocator.free(doc_xml);

    var state = ParserState.init(allocator, relationships, style_map);
    defer state.current_text.deinit(allocator);
    defer state.current_runs.deinit(allocator);
    defer state.cell_paragraphs.deinit(allocator);
    defer state.row_cells.deinit(allocator);
    defer state.table_rows.deinit(allocator);
    var parser = xml.XmlParser.init(doc_xml);

    while (parser.next()) |event| {
        switch (event) {
            .element_start => |es| try state.handleElementStart(es),
            .element_end => |name| try state.handleElementEnd(name),
            .text => |text| try state.handleText(text),
        }
    }

    // 4. Extract media files
    var media: std.ArrayListUnmanaged(MediaFile) = .empty;
    for (archive.entries) |*entry| {
        if (std.mem.startsWith(u8, entry.filename, "word/media/")) {
            const data = archive.extract(entry) catch continue;
            // Strip "word/" prefix — relationships reference "media/image1.png"
            const name = if (std.mem.startsWith(u8, entry.filename, "word/"))
                entry.filename[5..]
            else
                entry.filename;
            try media.append(allocator, .{
                .name = try allocator.dupe(u8, name),
                .data = data,
            });
        }
    }

    return .{
        .elements = try state.elements.toOwnedSlice(allocator),
        .media = try media.toOwnedSlice(allocator),
        .allocator = allocator,
        .relationships = relationships,
        .style_map = style_map,
    };
}

/// Print document structure summary to a buffer
pub fn printDocumentInfo(allocator: std.mem.Allocator, doc: *const Document) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const writer = &aw.writer;

    var para_count: usize = 0;
    var table_count: usize = 0;
    var heading_count: usize = 0;
    var list_count: usize = 0;
    var image_count: usize = 0;

    for (doc.elements) |elem| {
        switch (elem) {
            .paragraph => |p| {
                para_count += 1;
                if (p.style == .heading1 or p.style == .heading2 or p.style == .heading3 or
                    p.style == .heading4 or p.style == .heading5 or p.style == .heading6 or
                    p.style == .title) heading_count += 1;
                if (p.is_list_item) list_count += 1;
                for (p.runs) |run| {
                    if (run.image_rel_id != null) image_count += 1;
                }
            },
            .table => table_count += 1,
        }
    }

    try writer.print("Document Structure:\n", .{});
    try writer.print("  Paragraphs: {d}\n", .{para_count});
    try writer.print("  Headings:   {d}\n", .{heading_count});
    try writer.print("  Tables:     {d}\n", .{table_count});
    try writer.print("  List items: {d}\n", .{list_count});
    try writer.print("  Images:     {d} (refs), {d} (media files)\n", .{ image_count, doc.media.len });

    try writer.print("\nContent outline:\n", .{});
    for (doc.elements) |elem| {
        switch (elem) {
            .paragraph => |p| {
                const prefix: []const u8 = switch (p.style) {
                    .heading1 => "# ",
                    .heading2 => "## ",
                    .heading3 => "### ",
                    .heading4 => "#### ",
                    .heading5 => "##### ",
                    .heading6 => "###### ",
                    .title => "[TITLE] ",
                    .subtitle => "[SUBTITLE] ",
                    .list_paragraph => "  - ",
                    else => if (p.is_list_item) "  - " else "  ",
                };
                try writer.print("{s}", .{prefix});

                // Print first 80 chars of text
                var text_len: usize = 0;
                for (p.runs) |run| {
                    if (run.image_rel_id != null) {
                        try writer.print("[IMAGE] ", .{});
                        continue;
                    }
                    const remaining = 80 - @min(text_len, @as(usize, 80));
                    if (remaining == 0) break;
                    const show = run.text[0..@min(run.text.len, remaining)];
                    try writer.print("{s}", .{show});
                    text_len += show.len;
                }
                try writer.print("\n", .{});
            },
            .table => |t| {
                try writer.print("  [TABLE: {d} rows", .{t.rows.len});
                if (t.rows.len > 0) {
                    try writer.print(" x {d} cols", .{t.rows[0].cells.len});
                }
                try writer.print("]\n", .{});
            },
        }
    }

    return aw.toOwnedSlice();
}

// =============================================================================
// Tests
// =============================================================================

test {
    _ = xml;
    _ = rels;
    _ = styles;
    _ = mdx;
}

test "parse minimal document XML" {
    // This tests the XML parser + state machine on raw XML (no ZIP needed)
    const allocator = std.testing.allocator;

    const doc_xml =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        \\  <w:body>
        \\    <w:p>
        \\      <w:pPr><w:pStyle w:val="Heading1"/></w:pPr>
        \\      <w:r><w:t>Hello World</w:t></w:r>
        \\    </w:p>
        \\    <w:p>
        \\      <w:r><w:rPr><w:b/></w:rPr><w:t>Bold text</w:t></w:r>
        \\      <w:r><w:t> and normal</w:t></w:r>
        \\    </w:p>
        \\  </w:body>
        \\</w:document>
    ;

    var state = ParserState.init(allocator, &[_]rels.Relationship{}, &[_]styles.StyleInfo{});
    defer state.current_text.deinit(allocator);
    defer state.current_runs.deinit(allocator);
    defer state.cell_paragraphs.deinit(allocator);
    defer state.row_cells.deinit(allocator);
    defer state.table_rows.deinit(allocator);
    var parser = xml.XmlParser.init(doc_xml);

    while (parser.next()) |event| {
        switch (event) {
            .element_start => |es| try state.handleElementStart(es),
            .element_end => |name| try state.handleElementEnd(name),
            .text => |text| try state.handleText(text),
        }
    }

    var doc = Document{
        .elements = try state.elements.toOwnedSlice(allocator),
        .media = @constCast(&[_]MediaFile{}),
        .allocator = allocator,
    };
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 2), doc.elements.len);

    // First element: Heading1 paragraph
    const h1 = doc.elements[0].paragraph;
    try std.testing.expectEqual(StyleType.heading1, h1.style);
    try std.testing.expectEqual(@as(usize, 1), h1.runs.len);
    try std.testing.expectEqualStrings("Hello World", h1.runs[0].text);

    // Second element: paragraph with bold + normal runs
    const p2 = doc.elements[1].paragraph;
    try std.testing.expectEqual(@as(usize, 2), p2.runs.len);
    try std.testing.expect(p2.runs[0].bold);
    try std.testing.expectEqualStrings("Bold text", p2.runs[0].text);
    try std.testing.expect(!p2.runs[1].bold);
    try std.testing.expectEqualStrings(" and normal", p2.runs[1].text);
}

test "paragraph formatting - italic and underline" {
    const allocator = std.testing.allocator;

    const doc_xml =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        \\  <w:body>
        \\    <w:p>
        \\      <w:r><w:rPr><w:i/></w:rPr><w:t>Italic</w:t></w:r>
        \\      <w:r><w:rPr><w:u/></w:rPr><w:t>Underline</w:t></w:r>
        \\    </w:p>
        \\  </w:body>
        \\</w:document>
    ;

    var state = ParserState.init(allocator, &[_]rels.Relationship{}, &[_]styles.StyleInfo{});
    defer state.current_text.deinit(allocator);
    defer state.current_runs.deinit(allocator);
    defer state.cell_paragraphs.deinit(allocator);
    defer state.row_cells.deinit(allocator);
    defer state.table_rows.deinit(allocator);
    var parser = xml.XmlParser.init(doc_xml);

    while (parser.next()) |event| {
        switch (event) {
            .element_start => |es| try state.handleElementStart(es),
            .element_end => |name| try state.handleElementEnd(name),
            .text => |text| try state.handleText(text),
        }
    }

    var doc = Document{
        .elements = try state.elements.toOwnedSlice(allocator),
        .media = @constCast(&[_]MediaFile{}),
        .allocator = allocator,
    };
    defer doc.deinit();

    const para = doc.elements[0].paragraph;
    try std.testing.expectEqual(@as(usize, 2), para.runs.len);
    try std.testing.expect(para.runs[0].italic);
    try std.testing.expect(!para.runs[0].bold);
    try std.testing.expect(para.runs[1].underline);
}

test "table generation with cells and rows" {
    const allocator = std.testing.allocator;

    const doc_xml =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        \\  <w:body>
        \\    <w:tbl>
        \\      <w:tr>
        \\        <w:tc>
        \\          <w:p><w:r><w:t>Cell 1</w:t></w:r></w:p>
        \\        </w:tc>
        \\        <w:tc>
        \\          <w:p><w:r><w:t>Cell 2</w:t></w:r></w:p>
        \\        </w:tc>
        \\      </w:tr>
        \\      <w:tr>
        \\        <w:tc>
        \\          <w:p><w:r><w:t>Cell 3</w:t></w:r></w:p>
        \\        </w:tc>
        \\        <w:tc>
        \\          <w:p><w:r><w:t>Cell 4</w:t></w:r></w:p>
        \\        </w:tc>
        \\      </w:tr>
        \\    </w:tbl>
        \\  </w:body>
        \\</w:document>
    ;

    var state = ParserState.init(allocator, &[_]rels.Relationship{}, &[_]styles.StyleInfo{});
    defer state.current_text.deinit(allocator);
    defer state.current_runs.deinit(allocator);
    defer state.cell_paragraphs.deinit(allocator);
    defer state.row_cells.deinit(allocator);
    defer state.table_rows.deinit(allocator);
    var parser = xml.XmlParser.init(doc_xml);

    while (parser.next()) |event| {
        switch (event) {
            .element_start => |es| try state.handleElementStart(es),
            .element_end => |name| try state.handleElementEnd(name),
            .text => |text| try state.handleText(text),
        }
    }

    var doc = Document{
        .elements = try state.elements.toOwnedSlice(allocator),
        .media = @constCast(&[_]MediaFile{}),
        .allocator = allocator,
    };
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.elements.len);
    const table = doc.elements[0].table;
    try std.testing.expectEqual(@as(usize, 2), table.rows.len);
    try std.testing.expectEqual(@as(usize, 2), table.rows[0].cells.len);
    try std.testing.expectEqualStrings("Cell 1", table.rows[0].cells[0].paragraphs[0].runs[0].text);
    try std.testing.expectEqualStrings("Cell 4", table.rows[1].cells[1].paragraphs[0].runs[0].text);
}

test "list items with numbering level" {
    const allocator = std.testing.allocator;

    const doc_xml =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        \\  <w:body>
        \\    <w:p>
        \\      <w:pPr>
        \\        <w:numPr><w:ilvl w:val="0"/></w:numPr>
        \\      </w:pPr>
        \\      <w:r><w:t>Item 1</w:t></w:r>
        \\    </w:p>
        \\    <w:p>
        \\      <w:pPr>
        \\        <w:numPr><w:ilvl w:val="1"/></w:numPr>
        \\      </w:pPr>
        \\      <w:r><w:t>Item 1.1</w:t></w:r>
        \\    </w:p>
        \\  </w:body>
        \\</w:document>
    ;

    var state = ParserState.init(allocator, &[_]rels.Relationship{}, &[_]styles.StyleInfo{});
    defer state.current_text.deinit(allocator);
    defer state.current_runs.deinit(allocator);
    defer state.cell_paragraphs.deinit(allocator);
    defer state.row_cells.deinit(allocator);
    defer state.table_rows.deinit(allocator);
    var parser = xml.XmlParser.init(doc_xml);

    while (parser.next()) |event| {
        switch (event) {
            .element_start => |es| try state.handleElementStart(es),
            .element_end => |name| try state.handleElementEnd(name),
            .text => |text| try state.handleText(text),
        }
    }

    var doc = Document{
        .elements = try state.elements.toOwnedSlice(allocator),
        .media = @constCast(&[_]MediaFile{}),
        .allocator = allocator,
    };
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 2), doc.elements.len);
    const p1 = doc.elements[0].paragraph;
    const p2 = doc.elements[1].paragraph;

    try std.testing.expect(p1.is_list_item);
    try std.testing.expectEqual(@as(u8, 0), p1.numbering_level);
    try std.testing.expect(p2.is_list_item);
    try std.testing.expectEqual(@as(u8, 1), p2.numbering_level);
}

test "text extraction from generated document" {
    const allocator = std.testing.allocator;

    const doc_xml =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        \\  <w:body>
        \\    <w:p>
        \\      <w:r><w:t>Hello</w:t></w:r>
        \\      <w:r><w:t> World</w:t></w:r>
        \\    </w:p>
        \\  </w:body>
        \\</w:document>
    ;

    var state = ParserState.init(allocator, &[_]rels.Relationship{}, &[_]styles.StyleInfo{});
    defer state.current_text.deinit(allocator);
    defer state.current_runs.deinit(allocator);
    defer state.cell_paragraphs.deinit(allocator);
    defer state.row_cells.deinit(allocator);
    defer state.table_rows.deinit(allocator);
    var parser = xml.XmlParser.init(doc_xml);

    while (parser.next()) |event| {
        switch (event) {
            .element_start => |es| try state.handleElementStart(es),
            .element_end => |name| try state.handleElementEnd(name),
            .text => |text| try state.handleText(text),
        }
    }

    var doc = Document{
        .elements = try state.elements.toOwnedSlice(allocator),
        .media = @constCast(&[_]MediaFile{}),
        .allocator = allocator,
    };
    defer doc.deinit();

    const para = doc.elements[0].paragraph;
    try std.testing.expectEqual(@as(usize, 2), para.runs.len);
    try std.testing.expectEqualStrings("Hello", para.runs[0].text);
    try std.testing.expectEqualStrings(" World", para.runs[1].text);
}

test "cell colspan parsing" {
    const allocator = std.testing.allocator;

    const doc_xml =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        \\  <w:body>
        \\    <w:tbl>
        \\      <w:tr>
        \\        <w:tc>
        \\          <w:tcPr><w:gridSpan w:val="2"/></w:tcPr>
        \\          <w:p><w:r><w:t>Merged Cell</w:t></w:r></w:p>
        \\        </w:tc>
        \\      </w:tr>
        \\    </w:tbl>
        \\  </w:body>
        \\</w:document>
    ;

    var state = ParserState.init(allocator, &[_]rels.Relationship{}, &[_]styles.StyleInfo{});
    defer state.current_text.deinit(allocator);
    defer state.current_runs.deinit(allocator);
    defer state.cell_paragraphs.deinit(allocator);
    defer state.row_cells.deinit(allocator);
    defer state.table_rows.deinit(allocator);
    var parser = xml.XmlParser.init(doc_xml);

    while (parser.next()) |event| {
        switch (event) {
            .element_start => |es| try state.handleElementStart(es),
            .element_end => |name| try state.handleElementEnd(name),
            .text => |text| try state.handleText(text),
        }
    }

    var doc = Document{
        .elements = try state.elements.toOwnedSlice(allocator),
        .media = @constCast(&[_]MediaFile{}),
        .allocator = allocator,
    };
    defer doc.deinit();

    const table = doc.elements[0].table;
    try std.testing.expectEqual(@as(u16, 2), table.rows[0].cells[0].col_span);
}
