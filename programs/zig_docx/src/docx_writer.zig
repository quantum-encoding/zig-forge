// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! DOCX Writer — serializes a Document model into a valid .docx file.
//!
//! A .docx is a ZIP archive containing WordprocessingML XML files.
//! Uses ArrayListUnmanaged(u8) + appendSlice for XML generation,
//! matching the project's existing string-building pattern.

const std = @import("std");
const docx = @import("docx.zig");
const StyleType = @import("styles.zig").StyleType;
const ZipWriter = @import("zip_writer.zig").ZipWriter;

// Relationship IDs. Styles and numbering use fixed low IDs; the header reserves
// rId5; hyperlinks and images use disjoint base ranges so they never collide.
// Header image lives in a separate rels file and uses its own ID.
const RID_STYLES = "rId1";
const RID_NUMBERING = "rId2";
const RID_HEADER = "rId5";
const RID_FOOTER = "rId6";
const RID_HEADER_IMAGE = "rIdHdr1";
const RID_HYPERLINK_BASE: usize = 10;
const RID_IMAGE_BASE: usize = 100;

// Drawing object IDs must be unique per document. Body images count up from 1;
// the letterhead reserves a high value so it cannot collide even with very
// long documents.
const DRAWING_ID_LETTERHEAD: u32 = 0xFFFF;

// Upper bound on image dimensions in pixels — any valid DOCX image is well
// under this. Prevents u64 overflow when converting to EMU (px * 9525) and
// again when rescaling by max_width.
const MAX_IMAGE_DIM: u32 = 20000;

// Hard cap on image file extension length. The MIME registry supports 3-4
// char extensions; 16 is generous and prevents bufPrint overflow into the
// 64-byte media path buffer.
const MAX_EXT_LEN: usize = 16;

pub const LetterheadImage = struct {
    data: []const u8,
    extension: []const u8,
};

pub const DocumentStyle = enum {
    default, // Arial 11pt, bold black headings, left-aligned
    minutes, // Arial, black bold+underline headings, justified text
    sheet, // Calibri 10pt, en-GB, no space between paragraphs: tables of short entries
    letter, // Times New Roman 12pt, justified, 1.15 lines, bold centred headings: letters and filings

    /// The preset a `--style` flag or `style:` key names; null for any other word.
    pub fn fromName(name: []const u8) ?DocumentStyle {
        return std.meta.stringToEnum(DocumentStyle, name);
    }
};

/// The language of the words the writer adds itself (the footer's "Page N of
/// M") and, in the letter style, of the text for spelling and hyphenation.
pub const Language = enum {
    en,
    es,

    pub fn fromName(name: []const u8) ?Language {
        return std.meta.stringToEnum(Language, name);
    }

    /// The tag the letter style marks text with (`w:lang`).
    fn tag(self: Language) []const u8 {
        return switch (self) {
            .en => "en-GB",
            .es => "es-ES",
        };
    }

    /// "Page", "of": the words around the page number and the page count.
    fn pageWords(self: Language) struct { page: []const u8, of: []const u8 } {
        return switch (self) {
            .en => .{ .page = "Page ", .of = " of " },
            .es => .{ .page = "Página ", .of = " de " },
        };
    }
};

pub const DocxWriterOptions = struct {
    title: []const u8 = "",
    author: []const u8 = "",
    description: []const u8 = "",
    date: []const u8 = "",
    letterhead: ?LetterheadImage = null,
    style: DocumentStyle = .default,
    /// A line of text at the top right of every page. Ignored when there is a
    /// letterhead, which owns the page header.
    page_header: []const u8 = "",
    /// Text at the right of a footer that reads "Page N of M" on every page.
    /// Empty = no footer, unless `page_numbers` asks for one.
    page_footer: []const u8 = "",
    /// The "Page N of M" footer even when `page_footer` is empty.
    page_numbers: bool = false,
    /// The language of "Page N of M" and of the letter style's text.
    language: Language = .en,
    /// A4 paper (210 × 297 mm) instead of the application's default size.
    a4: bool = false,
    /// Turn the page on its side.
    landscape: bool = false,
    /// Every page margin, in twentieths of a point (720 = half an inch);
    /// null keeps the defaults. Header and footer sit half a margin in.
    margin: ?u16 = null,
    /// Who made the document's tracked changes (runs with a `revision`).
    revision_author: []const u8 = "Reviewer",
    /// When, as an xsd:dateTime; "" leaves the date off.
    revision_date: []const u8 = "",
};

/// The least width or height the margins may leave for text: one inch.
const MIN_TEXT_SPAN: u32 = 1440;

/// Page and style settings as words — command-line flags or Markdown
/// frontmatter keys — before they are checked and become DocxWriterOptions.
/// Null means not given. The strings are borrowed.
pub const LayoutSettings = struct {
    /// default, minutes, sheet or letter.
    style: ?[]const u8 = null,
    /// a4 or letter.
    paper: ?[]const u8 = null,
    /// portrait or landscape.
    orientation: ?[]const u8 = null,
    /// Every page margin: 25mm, 2.5cm, 1in, 72pt, or a bare number of mm.
    margin: ?[]const u8 = null,
    /// A line of text at the top right of every page.
    header: ?[]const u8 = null,
    /// Text at the right of the "Page N of M" footer.
    footer: ?[]const u8 = null,
    /// true or false: the "Page N of M" footer without footer text.
    page_numbers: ?[]const u8 = null,
    /// en or es (a region such as es-ES is accepted and ignored).
    lang: ?[]const u8 = null,

    /// `self` with each setting `over` gives in place of its own.
    pub fn overlay(self: LayoutSettings, over: LayoutSettings) LayoutSettings {
        return .{
            .style = over.style orelse self.style,
            .paper = over.paper orelse self.paper,
            .orientation = over.orientation orelse self.orientation,
            .margin = over.margin orelse self.margin,
            .header = over.header orelse self.header,
            .footer = over.footer orelse self.footer,
            .page_numbers = over.page_numbers orelse self.page_numbers,
            .lang = over.lang orelse self.lang,
        };
    }

    /// Checks each setting and writes it into `opts`. Returns what is wrong
    /// with the first bad one, or null when every one is good. The letter
    /// style is on A4 unless a paper size is given.
    pub fn applyTo(self: LayoutSettings, opts: *DocxWriterOptions) ?[]const u8 {
        var word: [16]u8 = undefined;
        if (self.style) |v| opts.style = DocumentStyle.fromName(lowerWord(&word, v)) orelse
            return "style must be default, minutes, sheet or letter";
        if (self.paper) |v| {
            const p = lowerWord(&word, v);
            if (std.mem.eql(u8, p, "a4")) {
                opts.a4 = true;
            } else if (std.mem.eql(u8, p, "letter")) {
                opts.a4 = false;
            } else return "paper must be a4 or letter";
        } else if (opts.style == .letter) opts.a4 = true;
        if (self.orientation) |v| {
            const o = lowerWord(&word, v);
            if (std.mem.eql(u8, o, "landscape")) {
                opts.landscape = true;
            } else if (std.mem.eql(u8, o, "portrait")) {
                opts.landscape = false;
            } else return "orientation must be portrait or landscape";
        }
        if (self.margin) |v| opts.margin = parseLengthTwips(v) orelse
            return "margin must be a length such as 25mm, 2.5cm, 1in or 72pt";
        if (self.header) |v| opts.page_header = v;
        if (self.footer) |v| opts.page_footer = v;
        if (self.page_numbers) |v| {
            const b = lowerWord(&word, v);
            if (std.mem.eql(u8, b, "true") or std.mem.eql(u8, b, "yes")) {
                opts.page_numbers = true;
            } else if (std.mem.eql(u8, b, "false") or std.mem.eql(u8, b, "no")) {
                opts.page_numbers = false;
            } else return "page-numbers must be true or false";
        }
        if (self.lang) |v| {
            const primary = v[0 .. std.mem.indexOfAny(u8, v, "-_") orelse v.len];
            opts.language = Language.fromName(lowerWord(&word, primary)) orelse return "lang must be en or es";
        }
        const parts = SectionParts{ .a4 = opts.a4, .landscape = opts.landscape, .margin = opts.margin };
        const margins = 2 * @as(u32, opts.margin orelse 1440);
        if (parts.textWidth() < MIN_TEXT_SPAN or parts.pageSize().h -| margins < MIN_TEXT_SPAN)
            return "margin leaves less than 1 inch (25.4 mm) of the page for text";
        return null;
    }
};

/// `s` in lower case in `buf`; a word longer than `buf` is cut short, which
/// no setting matches.
fn lowerWord(buf: []u8, s: []const u8) []const u8 {
    const t = std.mem.trim(u8, s, " \t");
    return std.ascii.lowerString(buf, t[0..@min(t.len, buf.len)]);
}

/// A length in twentieths of a point (1440 to the inch): a number followed by
/// mm, cm, in or pt, or a bare number of millimetres. Null for anything else,
/// a negative length, or one past what Word stores (65535).
pub fn parseLengthTwips(s: []const u8) ?u16 {
    const t = std.mem.trim(u8, s, " \t");
    var end = t.len;
    while (end > 0 and std.ascii.isAlphabetic(t[end - 1])) end -= 1;
    const unit = t[end..];
    const per_unit: f64 = if (unit.len == 0 or std.ascii.eqlIgnoreCase(unit, "mm"))
        1440.0 / 25.4
    else if (std.ascii.eqlIgnoreCase(unit, "cm"))
        14400.0 / 25.4
    else if (std.ascii.eqlIgnoreCase(unit, "in"))
        1440.0
    else if (std.ascii.eqlIgnoreCase(unit, "pt"))
        20.0
    else
        return null;
    const number_text = std.mem.trimEnd(u8, t[0..end], " ");
    if (number_text.len == 0) return null;
    const number = std.fmt.parseFloat(f64, number_text) catch return null;
    if (!std.math.isFinite(number) or number < 0) return null;
    const twips = @round(number * per_unit);
    return if (twips <= std.math.maxInt(u16)) @intFromFloat(twips) else null;
}

/// Numbers each tracked change (ids must be unique in a document) and
/// carries the author and date every one of them is stamped with.
const Revisions = struct {
    author: []const u8,
    date: []const u8,
    next_id: u32 = 1,
};

/// What the section properties point at: the header and footer parts and the
/// page size.
const SectionParts = struct {
    image_header: bool = false,
    text_header: bool = false,
    footer: bool = false,
    a4: bool = false,
    landscape: bool = false,
    margin: ?u16 = null,

    fn header(self: SectionParts) bool {
        return self.image_header or self.text_header;
    }
    fn any(self: SectionParts) bool {
        return self.header() or self.footer or self.a4 or self.landscape or self.margin != null;
    }

    /// Page width and height in twentieths of a point: A4 or US Letter
    /// (the application's default), turned for landscape.
    fn pageSize(self: SectionParts) struct { w: u32, h: u32 } {
        const short: u32 = if (self.a4) 11906 else 12240;
        const long: u32 = if (self.a4) 16838 else 15840;
        return if (self.landscape) .{ .w = long, .h = short } else .{ .w = short, .h = long };
    }

    /// The width text runs across: the page less its left and right margins
    /// (none when the margins meet).
    fn textWidth(self: SectionParts) u32 {
        return self.pageSize().w -| 2 * @as(u32, self.margin orelse 1440);
    }
};

/// Tracks hyperlink URLs and assigns relationship IDs during document generation.
const HyperlinkCollector = struct {
    urls: std.ArrayListUnmanaged([]const u8),
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) HyperlinkCollector {
        return .{ .urls = .empty, .allocator = allocator };
    }

    fn deinit(self: *HyperlinkCollector) void {
        for (self.urls.items) |url| self.allocator.free(url);
        self.urls.deinit(self.allocator);
    }

    /// Register a URL and return its relationship ID. Caller owns the returned
    /// slice and must free it.
    fn addUrl(self: *HyperlinkCollector, url: []const u8) ![]const u8 {
        for (self.urls.items, 0..) |existing, i| {
            if (std.mem.eql(u8, existing, url)) {
                return self.formatRId(i);
            }
        }
        try self.urls.append(self.allocator, try self.allocator.dupe(u8, url));
        return self.formatRId(self.urls.items.len - 1);
    }

    fn formatRId(self: *HyperlinkCollector, index: usize) ![]const u8 {
        var tmp: [32]u8 = undefined;
        const s = try std.fmt.bufPrint(&tmp, "rId{d}", .{index + RID_HYPERLINK_BASE});
        return self.allocator.dupe(u8, s);
    }
};

/// Tracks embedded images — file data, ZIP paths, relationship IDs, and cached
/// image dimensions. Image entries are referenced by index; the rel_id →
/// index map gives O(1) lookup during document rendering.
const ImageCollector = struct {
    entries: std.ArrayListUnmanaged(ImageEntry),
    rid_to_index: std.StringHashMapUnmanaged(usize),
    allocator: std.mem.Allocator,

    const ImageEntry = struct {
        zip_path: []const u8, // e.g. "word/media/image1.png"
        rel_id: []const u8, // e.g. "rId100" — owned by collector
        data: []const u8,
        extension: []const u8, // e.g. "png"
        width: u32 = 0, // 0 if detection failed
        height: u32 = 0,
    };

    fn init(allocator: std.mem.Allocator) ImageCollector {
        return .{ .entries = .empty, .rid_to_index = .empty, .allocator = allocator };
    }

    fn deinit(self: *ImageCollector) void {
        for (self.entries.items) |e| {
            self.allocator.free(e.zip_path);
            self.allocator.free(e.rel_id);
            self.allocator.free(e.data);
            self.allocator.free(e.extension);
        }
        self.entries.deinit(self.allocator);
        self.rid_to_index.deinit(self.allocator);
    }

    /// Register an image and return its ZIP index. The rel_id is accessible via
    /// `collector.entries.items[index].rel_id` (borrowed from the collector —
    /// lifetime tied to collector.deinit).
    fn addImage(self: *ImageCollector, data: []const u8, extension: []const u8) !usize {
        if (extension.len > MAX_EXT_LEN) return error.ExtensionTooLong;

        const index = self.entries.items.len;
        var rid_buf: [32]u8 = undefined;
        const rid = try std.fmt.bufPrint(&rid_buf, "rId{d}", .{index + RID_IMAGE_BASE});

        var path_buf: [64]u8 = undefined;
        const zip_path = try std.fmt.bufPrint(&path_buf, "word/media/image{d}.{s}", .{ index + 1, extension });

        const rel_id = try self.allocator.dupe(u8, rid);
        errdefer self.allocator.free(rel_id);
        const zip_path_owned = try self.allocator.dupe(u8, zip_path);
        errdefer self.allocator.free(zip_path_owned);
        const data_owned = try self.allocator.dupe(u8, data);
        errdefer self.allocator.free(data_owned);
        const ext_owned = try self.allocator.dupe(u8, extension);
        errdefer self.allocator.free(ext_owned);

        const dims = detectImageDimensions(data, extension);

        try self.entries.append(self.allocator, .{
            .zip_path = zip_path_owned,
            .rel_id = rel_id,
            .data = data_owned,
            .extension = ext_owned,
            .width = dims.width,
            .height = dims.height,
        });
        // rel_id is stable heap memory, safe to use as map key.
        try self.rid_to_index.put(self.allocator, rel_id, index);
        return index;
    }

    fn findByRid(self: *const ImageCollector, rid: []const u8) ?*const ImageEntry {
        const idx = self.rid_to_index.get(rid) orelse return null;
        return &self.entries.items[idx];
    }
};

/// Generate a complete DOCX file (as bytes) from a Document model.
pub fn generateDocx(
    allocator: std.mem.Allocator,
    doc: *const docx.Document,
    options: DocxWriterOptions,
) ![]u8 {
    var zip = ZipWriter.init(allocator);
    defer zip.deinit();

    var has_lists = false;
    for (doc.elements) |elem| {
        if (elem == .paragraph and elem.paragraph.is_list_item) {
            has_lists = true;
            break;
        }
    }

    var hyperlinks = HyperlinkCollector.init(allocator);
    defer hyperlinks.deinit();

    var images = ImageCollector.init(allocator);
    defer images.deinit();

    // Register document media files and map image_rel_id references
    try resolveMediaToImages(allocator, doc, &images);

    // Handle letterhead before generating rels/content types. Capture the
    // letterhead's entry index at add time — the previous "last entry" pattern
    // was a sequencing invariant waiting to break.
    const has_header = options.letterhead != null;
    const parts = SectionParts{
        .image_header = has_header,
        .text_header = !has_header and options.page_header.len > 0,
        .footer = options.page_footer.len > 0 or options.page_numbers,
        .a4 = options.a4,
        .landscape = options.landscape,
        .margin = options.margin,
    };
    var letterhead_index: ?usize = null;

    if (options.letterhead) |lh| {
        letterhead_index = try images.addImage(lh.data, lh.extension);
    }

    // Drawing object IDs must be unique per document; body images count up.
    var drawing_id_counter: u32 = 1;
    var revisions = Revisions{ .author = options.revision_author, .date = options.revision_date };

    const document_xml = try genDocumentXml(allocator, doc, &hyperlinks, &images, parts, &drawing_id_counter, &revisions);
    defer allocator.free(document_xml);

    const content_types = try genContentTypes(allocator, has_lists, &images, parts);
    defer allocator.free(content_types);
    try zip.addFile("[Content_Types].xml", content_types);

    try zip.addFile("_rels/.rels", rels_xml);

    try zip.addFile("word/document.xml", document_xml);

    const letter_styles = if (options.style == .letter) try genLetterStyles(allocator, options.language) else null;
    defer if (letter_styles) |ls| allocator.free(ls);
    try zip.addFile("word/styles.xml", switch (options.style) {
        .minutes => styles_minutes_xml,
        .default => styles_xml,
        .sheet => styles_sheet_xml,
        .letter => letter_styles.?,
    });

    const doc_rels = try genDocumentRels(allocator, has_lists, &hyperlinks, &images, parts);
    defer allocator.free(doc_rels);
    try zip.addFile("word/_rels/document.xml.rels", doc_rels);

    if (has_lists) {
        try zip.addFile("word/numbering.xml", numbering_xml);
    }

    for (images.entries.items) |entry| {
        try zip.addFile(entry.zip_path, entry.data);
    }

    if (letterhead_index) |lh_idx| {
        const lh_entry = images.entries.items[lh_idx];
        const media_target = if (std.mem.startsWith(u8, lh_entry.zip_path, "word/"))
            lh_entry.zip_path[5..]
        else
            lh_entry.zip_path;

        const header_xml = try genHeaderXml(allocator, RID_HEADER_IMAGE, lh_entry.width, lh_entry.height);
        defer allocator.free(header_xml);
        try zip.addFile("word/header1.xml", header_xml);

        const header_rels = try genHeaderRels(allocator, media_target);
        defer allocator.free(header_rels);
        try zip.addFile("word/_rels/header1.xml.rels", header_rels);
    }

    if (parts.text_header) {
        const header_xml = try genTextHeaderXml(allocator, options.page_header);
        defer allocator.free(header_xml);
        try zip.addFile("word/header1.xml", header_xml);
    }
    if (parts.footer) {
        const footer_xml = try genPageFooterXml(allocator, options.page_footer, parts.textWidth(), options.language);
        defer allocator.free(footer_xml);
        try zip.addFile("word/footer1.xml", footer_xml);
    }

    if (options.title.len > 0 or options.author.len > 0) {
        const core_xml = try genCoreProps(allocator, options);
        defer allocator.free(core_xml);
        try zip.addFile("docProps/core.xml", core_xml);
    }

    return zip.finish();
}

/// Register document media files into the ImageCollector and update
/// run image_rel_id fields from media names to actual relationship IDs.
const NameRidMapping = struct { name: []const u8, rid: []const u8 };

fn resolveMediaToImages(allocator: std.mem.Allocator, doc: *const docx.Document, images: *ImageCollector) !void {
    var name_to_rid: std.ArrayListUnmanaged(NameRidMapping) = .empty;
    defer {
        for (name_to_rid.items) |entry| allocator.free(entry.rid);
        name_to_rid.deinit(allocator);
    }

    for (doc.media) |media| {
        const ext = if (std.mem.lastIndexOfScalar(u8, media.name, '.')) |dot|
            media.name[dot + 1 ..]
        else
            "png";
        const idx = try images.addImage(media.data, ext);
        try name_to_rid.append(allocator, .{
            .name = media.name,
            .rid = try allocator.dupe(u8, images.entries.items[idx].rel_id),
        });
    }

    if (name_to_rid.items.len == 0) return;

    for (doc.elements) |elem| {
        switch (elem) {
            .paragraph => |p| try updateImageRids(allocator, p.runs, name_to_rid.items),
            .table => |t| {
                for (t.rows) |row| {
                    for (row.cells) |cell| {
                        for (cell.paragraphs) |cp| {
                            try updateImageRids(allocator, cp.runs, name_to_rid.items);
                        }
                    }
                }
            },
        }
    }
}

fn updateImageRids(allocator: std.mem.Allocator, runs: []docx.Run, mappings: []const NameRidMapping) !void {
    for (runs) |*run| {
        const img_name = run.image_rel_id orelse continue;
        for (mappings) |m| {
            if (std.mem.eql(u8, img_name, m.name)) {
                const new_rid = try allocator.dupe(u8, m.rid);
                allocator.free(img_name);
                run.image_rel_id = new_rid;
                break;
            }
        }
    }
}

// ── Static XML templates (no allocation needed) ─────────────────

const rels_xml =
    \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    \\<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    \\  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
    \\  <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
    \\</Relationships>
;

const styles_xml =
    \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    \\<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
    \\  <w:docDefaults>
    \\    <w:rPrDefault><w:rPr>
    \\      <w:rFonts w:ascii="Arial" w:hAnsi="Arial" w:cs="Arial"/>
    \\      <w:sz w:val="22"/><w:szCs w:val="22"/>
    \\    </w:rPr></w:rPrDefault>
    \\    <w:pPrDefault><w:pPr>
    \\      <w:spacing w:after="160" w:line="259" w:lineRule="auto"/>
    \\    </w:pPr></w:pPrDefault>
    \\  </w:docDefaults>
    \\  <w:style w:type="paragraph" w:styleId="Normal"><w:name w:val="Normal"/></w:style>
    \\  <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:pPr><w:spacing w:before="240" w:after="120"/></w:pPr><w:rPr><w:b/><w:sz w:val="28"/><w:szCs w:val="28"/></w:rPr></w:style>
    \\  <w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:pPr><w:spacing w:before="200" w:after="80"/></w:pPr><w:rPr><w:b/><w:sz w:val="24"/><w:szCs w:val="24"/></w:rPr></w:style>
    \\  <w:style w:type="paragraph" w:styleId="Heading3"><w:name w:val="heading 3"/><w:pPr><w:spacing w:before="160" w:after="60"/></w:pPr><w:rPr><w:b/><w:sz w:val="22"/><w:szCs w:val="22"/></w:rPr></w:style>
    \\  <w:style w:type="paragraph" w:styleId="Heading4"><w:name w:val="heading 4"/><w:pPr><w:spacing w:before="160" w:after="40"/></w:pPr><w:rPr><w:b/><w:i/><w:sz w:val="24"/><w:szCs w:val="24"/></w:rPr></w:style>
    \\  <w:style w:type="paragraph" w:styleId="Heading5"><w:name w:val="heading 5"/><w:pPr><w:spacing w:before="120" w:after="40"/></w:pPr><w:rPr><w:b/><w:sz w:val="22"/><w:szCs w:val="22"/></w:rPr></w:style>
    \\  <w:style w:type="paragraph" w:styleId="Heading6"><w:name w:val="heading 6"/><w:pPr><w:spacing w:before="120" w:after="40"/></w:pPr><w:rPr><w:b/><w:i/><w:sz w:val="22"/><w:szCs w:val="22"/><w:color w:val="666666"/></w:rPr></w:style>
    \\  <w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/><w:pPr><w:ind w:left="720"/></w:pPr></w:style>
    \\  <w:style w:type="paragraph" w:styleId="CodeBlock"><w:name w:val="Code Block"/><w:pPr><w:spacing w:before="80" w:after="80"/><w:shd w:val="clear" w:color="auto" w:fill="F2F2F2"/></w:pPr><w:rPr><w:rFonts w:ascii="Courier New" w:hAnsi="Courier New" w:cs="Courier New"/><w:sz w:val="20"/><w:szCs w:val="20"/></w:rPr></w:style>
    \\  <w:style w:type="paragraph" w:styleId="Quote"><w:name w:val="Quote"/><w:pPr><w:ind w:left="720"/><w:pBdr><w:left w:val="single" w:sz="12" w:space="8" w:color="CCCCCC"/></w:pBdr></w:pPr><w:rPr><w:i/><w:color w:val="555555"/></w:rPr></w:style>
    \\  <w:style w:type="character" w:styleId="InlineCode"><w:name w:val="Inline Code"/><w:rPr><w:rFonts w:ascii="Courier New" w:hAnsi="Courier New" w:cs="Courier New"/><w:sz w:val="20"/><w:szCs w:val="20"/><w:shd w:val="clear" w:color="auto" w:fill="F2F2F2"/></w:rPr></w:style>
    \\</w:styles>
;

// Minutes style: Arial, justified, bold+underline headings, compact
const styles_minutes_xml =
    \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    \\<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
    \\  <w:docDefaults>
    \\    <w:rPrDefault><w:rPr>
    \\      <w:rFonts w:ascii="Arial" w:hAnsi="Arial" w:cs="Arial"/>
    \\      <w:sz w:val="22"/><w:szCs w:val="22"/>
    \\    </w:rPr></w:rPrDefault>
    \\    <w:pPrDefault><w:pPr>
    \\      <w:spacing w:after="120" w:line="276" w:lineRule="auto"/>
    \\      <w:jc w:val="both"/>
    \\    </w:pPr></w:pPrDefault>
    \\  </w:docDefaults>
    \\  <w:style w:type="paragraph" w:styleId="Normal"><w:name w:val="Normal"/></w:style>
    \\  <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:pPr><w:spacing w:before="240" w:after="120"/><w:jc w:val="center"/></w:pPr><w:rPr><w:b/><w:sz w:val="28"/><w:szCs w:val="28"/><w:u w:val="single"/></w:rPr></w:style>
    \\  <w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:pPr><w:spacing w:before="200" w:after="80"/></w:pPr><w:rPr><w:b/><w:sz w:val="24"/><w:szCs w:val="24"/><w:u w:val="single"/></w:rPr></w:style>
    \\  <w:style w:type="paragraph" w:styleId="Heading3"><w:name w:val="heading 3"/><w:pPr><w:spacing w:before="160" w:after="60"/></w:pPr><w:rPr><w:b/><w:sz w:val="22"/><w:szCs w:val="22"/><w:u w:val="single"/></w:rPr></w:style>
    \\  <w:style w:type="paragraph" w:styleId="Heading4"><w:name w:val="heading 4"/><w:pPr><w:spacing w:before="120" w:after="40"/></w:pPr><w:rPr><w:b/><w:sz w:val="22"/><w:szCs w:val="22"/><w:u w:val="single"/></w:rPr></w:style>
    \\  <w:style w:type="paragraph" w:styleId="Heading5"><w:name w:val="heading 5"/><w:pPr><w:spacing w:before="120" w:after="40"/></w:pPr><w:rPr><w:b/><w:sz w:val="22"/><w:szCs w:val="22"/></w:rPr></w:style>
    \\  <w:style w:type="paragraph" w:styleId="Heading6"><w:name w:val="heading 6"/><w:pPr><w:spacing w:before="120" w:after="40"/></w:pPr><w:rPr><w:b/><w:i/><w:sz w:val="22"/><w:szCs w:val="22"/></w:rPr></w:style>
    \\  <w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/><w:pPr><w:ind w:left="720"/></w:pPr></w:style>
    \\  <w:style w:type="paragraph" w:styleId="CodeBlock"><w:name w:val="Code Block"/><w:pPr><w:spacing w:before="80" w:after="80"/><w:shd w:val="clear" w:color="auto" w:fill="F2F2F2"/></w:pPr><w:rPr><w:rFonts w:ascii="Courier New" w:hAnsi="Courier New" w:cs="Courier New"/><w:sz w:val="20"/><w:szCs w:val="20"/></w:rPr></w:style>
    \\  <w:style w:type="paragraph" w:styleId="Quote"><w:name w:val="Quote"/><w:pPr><w:ind w:left="720"/><w:pBdr><w:left w:val="single" w:sz="12" w:space="8" w:color="CCCCCC"/></w:pBdr></w:pPr><w:rPr><w:i/><w:color w:val="555555"/></w:rPr></w:style>
    \\  <w:style w:type="character" w:styleId="InlineCode"><w:name w:val="Inline Code"/><w:rPr><w:rFonts w:ascii="Courier New" w:hAnsi="Courier New" w:cs="Courier New"/><w:sz w:val="20"/><w:szCs w:val="20"/><w:shd w:val="clear" w:color="auto" w:fill="F2F2F2"/></w:rPr></w:style>
    \\</w:styles>
;

// Sheet style: Calibri 10pt, British English, no space between paragraphs —
// for documents that are mostly a table of short entries (the redline sheet).
const styles_sheet_xml =
    \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    \\<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
    \\  <w:docDefaults>
    \\    <w:rPrDefault><w:rPr>
    \\      <w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:eastAsia="Calibri" w:cs="Calibri"/>
    \\      <w:sz w:val="20"/><w:szCs w:val="20"/><w:lang w:val="en-GB"/>
    \\    </w:rPr></w:rPrDefault>
    \\    <w:pPrDefault><w:pPr>
    \\      <w:spacing w:after="0" w:line="240" w:lineRule="auto"/>
    \\    </w:pPr></w:pPrDefault>
    \\  </w:docDefaults>
    \\  <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>
    \\</w:styles>
;

// Letter style: Times New Roman 12pt, justified, 1.15 line spacing, bold
// centred black headings that stay with the text after them. Code blocks stay
// flush left. The text is marked with the document's language (`w:lang`) so
// Word and LibreOffice spell-check and hyphenate it as that language.
fn genLetterStyles(allocator: std.mem.Allocator, language: Language) ![]u8 {
    return std.mem.concat(allocator, u8, &.{ letter_styles_head, language.tag(), letter_styles_tail });
}

const letter_styles_head =
    \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    \\<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
    \\  <w:docDefaults>
    \\    <w:rPrDefault><w:rPr>
    \\      <w:rFonts w:ascii="Times New Roman" w:hAnsi="Times New Roman" w:eastAsia="Times New Roman" w:cs="Times New Roman"/>
    \\      <w:sz w:val="24"/><w:szCs w:val="24"/><w:lang w:val="
;
const letter_styles_tail =
    \\"/>
    \\    </w:rPr></w:rPrDefault>
    \\    <w:pPrDefault><w:pPr>
    \\      <w:spacing w:after="160" w:line="276" w:lineRule="auto"/>
    \\      <w:jc w:val="both"/>
    \\    </w:pPr></w:pPrDefault>
    \\  </w:docDefaults>
    \\  <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>
    \\  <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:pPr><w:keepNext/><w:spacing w:before="360" w:after="240"/><w:jc w:val="center"/></w:pPr><w:rPr><w:b/><w:color w:val="000000"/><w:sz w:val="28"/><w:szCs w:val="28"/></w:rPr></w:style>
    \\  <w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:pPr><w:keepNext/><w:spacing w:before="240" w:after="160"/><w:jc w:val="center"/></w:pPr><w:rPr><w:b/><w:color w:val="000000"/><w:sz w:val="24"/><w:szCs w:val="24"/></w:rPr></w:style>
    \\  <w:style w:type="paragraph" w:styleId="Heading3"><w:name w:val="heading 3"/><w:pPr><w:keepNext/><w:spacing w:before="240" w:after="120"/><w:jc w:val="center"/></w:pPr><w:rPr><w:b/><w:color w:val="000000"/><w:sz w:val="24"/><w:szCs w:val="24"/></w:rPr></w:style>
    \\  <w:style w:type="paragraph" w:styleId="Heading4"><w:name w:val="heading 4"/><w:pPr><w:keepNext/><w:spacing w:before="200" w:after="120"/><w:jc w:val="center"/></w:pPr><w:rPr><w:b/><w:color w:val="000000"/><w:sz w:val="24"/><w:szCs w:val="24"/></w:rPr></w:style>
    \\  <w:style w:type="paragraph" w:styleId="Heading5"><w:name w:val="heading 5"/><w:pPr><w:keepNext/><w:spacing w:before="200" w:after="120"/><w:jc w:val="center"/></w:pPr><w:rPr><w:b/><w:color w:val="000000"/><w:sz w:val="24"/><w:szCs w:val="24"/></w:rPr></w:style>
    \\  <w:style w:type="paragraph" w:styleId="Heading6"><w:name w:val="heading 6"/><w:pPr><w:keepNext/><w:spacing w:before="200" w:after="120"/><w:jc w:val="center"/></w:pPr><w:rPr><w:b/><w:i/><w:color w:val="000000"/><w:sz w:val="24"/><w:szCs w:val="24"/></w:rPr></w:style>
    \\  <w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/><w:pPr><w:ind w:left="720"/></w:pPr></w:style>
    \\  <w:style w:type="paragraph" w:styleId="CodeBlock"><w:name w:val="Code Block"/><w:pPr><w:shd w:val="clear" w:color="auto" w:fill="F2F2F2"/><w:spacing w:before="80" w:after="80" w:line="240" w:lineRule="auto"/><w:jc w:val="left"/></w:pPr><w:rPr><w:rFonts w:ascii="Courier New" w:hAnsi="Courier New" w:cs="Courier New"/><w:sz w:val="20"/><w:szCs w:val="20"/></w:rPr></w:style>
    \\  <w:style w:type="paragraph" w:styleId="Quote"><w:name w:val="Quote"/><w:pPr><w:ind w:left="720" w:right="720"/></w:pPr><w:rPr><w:i/></w:rPr></w:style>
    \\  <w:style w:type="character" w:styleId="InlineCode"><w:name w:val="Inline Code"/><w:rPr><w:rFonts w:ascii="Courier New" w:hAnsi="Courier New" w:cs="Courier New"/><w:sz w:val="20"/><w:szCs w:val="20"/><w:shd w:val="clear" w:color="auto" w:fill="F2F2F2"/></w:rPr></w:style>
    \\</w:styles>
;

const numbering_xml =
    \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    \\<w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
    \\  <w:abstractNum w:abstractNumId="0">
    \\    <w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="bullet"/><w:lvlText w:val="&#x2022;"/><w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr></w:lvl>
    \\    <w:lvl w:ilvl="1"><w:start w:val="1"/><w:numFmt w:val="bullet"/><w:lvlText w:val="&#x25E6;"/><w:pPr><w:ind w:left="1440" w:hanging="360"/></w:pPr></w:lvl>
    \\    <w:lvl w:ilvl="2"><w:start w:val="1"/><w:numFmt w:val="bullet"/><w:lvlText w:val="&#x25AA;"/><w:pPr><w:ind w:left="2160" w:hanging="360"/></w:pPr></w:lvl>
    \\  </w:abstractNum>
    \\  <w:abstractNum w:abstractNumId="1">
    \\    <w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/><w:lvlText w:val="%1."/><w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr></w:lvl>
    \\    <w:lvl w:ilvl="1"><w:start w:val="1"/><w:numFmt w:val="lowerLetter"/><w:lvlText w:val="%2."/><w:pPr><w:ind w:left="1440" w:hanging="360"/></w:pPr></w:lvl>
    \\    <w:lvl w:ilvl="2"><w:start w:val="1"/><w:numFmt w:val="lowerRoman"/><w:lvlText w:val="%3."/><w:pPr><w:ind w:left="2160" w:hanging="360"/></w:pPr></w:lvl>
    \\  </w:abstractNum>
    \\  <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>
    \\  <w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num>
    \\</w:numbering>
;

// ── Dynamic XML generators ──────────────────────────────────────

fn genContentTypes(allocator: std.mem.Allocator, has_numbering: bool, images: *const ImageCollector, parts: SectionParts) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator,
        \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        \\<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        \\  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        \\  <Default Extension="xml" ContentType="application/xml"/>
        \\  <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
        \\  <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
        \\
    );
    if (has_numbering) {
        try buf.appendSlice(allocator,
            \\  <Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>
            \\
        );
    }

    // Register image content types, one <Default> per unique extension. No
    // fixed cap — all images in the ZIP must have a ContentType registered
    // or the DOCX is non-conformant.
    var seen_ext: std.ArrayListUnmanaged([]const u8) = .empty;
    defer seen_ext.deinit(allocator);
    for (images.entries.items) |entry| {
        var already = false;
        for (seen_ext.items) |s| {
            if (std.mem.eql(u8, s, entry.extension)) {
                already = true;
                break;
            }
        }
        if (already) continue;
        try seen_ext.append(allocator, entry.extension);
        const mime = imageContentType(entry.extension);
        try buf.appendSlice(allocator, "  <Default Extension=\"");
        try buf.appendSlice(allocator, entry.extension);
        try buf.appendSlice(allocator, "\" ContentType=\"");
        try buf.appendSlice(allocator, mime);
        try buf.appendSlice(allocator, "\"/>\n");
    }

    if (parts.header()) {
        try buf.appendSlice(allocator,
            \\  <Override PartName="/word/header1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml"/>
            \\
        );
    }
    if (parts.footer) {
        try buf.appendSlice(allocator,
            \\  <Override PartName="/word/footer1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml"/>
            \\
        );
    }
    try buf.appendSlice(allocator,
        \\  <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
        \\</Types>
    );
    return allocator.dupe(u8, buf.items);
}

fn imageContentType(ext: []const u8) []const u8 {
    if (std.mem.eql(u8, ext, "png")) return "image/png";
    if (std.mem.eql(u8, ext, "jpg") or std.mem.eql(u8, ext, "jpeg")) return "image/jpeg";
    if (std.mem.eql(u8, ext, "gif")) return "image/gif";
    if (std.mem.eql(u8, ext, "bmp")) return "image/bmp";
    if (std.mem.eql(u8, ext, "tiff") or std.mem.eql(u8, ext, "tif")) return "image/tiff";
    if (std.mem.eql(u8, ext, "svg")) return "image/svg+xml";
    if (std.mem.eql(u8, ext, "webp")) return "image/webp";
    return "application/octet-stream";
}

fn genDocumentRels(allocator: std.mem.Allocator, has_numbering: bool, hyperlinks: *const HyperlinkCollector, images: *const ImageCollector, parts: SectionParts) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator,
        \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        \\<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        \\
    );
    try buf.appendSlice(allocator, "  <Relationship Id=\"");
    try buf.appendSlice(allocator, RID_STYLES);
    try buf.appendSlice(allocator, "\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>\n");

    if (has_numbering) {
        try buf.appendSlice(allocator, "  <Relationship Id=\"");
        try buf.appendSlice(allocator, RID_NUMBERING);
        try buf.appendSlice(allocator, "\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering\" Target=\"numbering.xml\"/>\n");
    }

    // Hyperlink relationships — rId formula matches HyperlinkCollector.formatRId.
    for (hyperlinks.urls.items, 0..) |url, i| {
        var rid_buf: [32]u8 = undefined;
        const rid = try std.fmt.bufPrint(&rid_buf, "rId{d}", .{i + RID_HYPERLINK_BASE});
        try buf.appendSlice(allocator, "  <Relationship Id=\"");
        try buf.appendSlice(allocator, rid);
        try buf.appendSlice(allocator, "\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\" Target=\"");
        try appendXmlEscaped(allocator, &buf, url);
        try buf.appendSlice(allocator, "\" TargetMode=\"External\"/>\n");
    }

    for (images.entries.items) |entry| {
        try buf.appendSlice(allocator, "  <Relationship Id=\"");
        try buf.appendSlice(allocator, entry.rel_id);
        try buf.appendSlice(allocator, "\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"");
        if (std.mem.startsWith(u8, entry.zip_path, "word/")) {
            try buf.appendSlice(allocator, entry.zip_path[5..]);
        } else {
            try buf.appendSlice(allocator, entry.zip_path);
        }
        try buf.appendSlice(allocator, "\"/>\n");
    }

    if (parts.header()) {
        try buf.appendSlice(allocator, "  <Relationship Id=\"");
        try buf.appendSlice(allocator, RID_HEADER);
        try buf.appendSlice(allocator, "\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/header\" Target=\"header1.xml\"/>\n");
    }
    if (parts.footer) {
        try buf.appendSlice(allocator, "  <Relationship Id=\"");
        try buf.appendSlice(allocator, RID_FOOTER);
        try buf.appendSlice(allocator, "\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer\" Target=\"footer1.xml\"/>\n");
    }
    try buf.appendSlice(allocator, "</Relationships>");
    return allocator.dupe(u8, buf.items);
}

fn genDocumentXml(
    allocator: std.mem.Allocator,
    doc: *const docx.Document,
    hyperlinks: *HyperlinkCollector,
    images: *ImageCollector,
    parts: SectionParts,
    drawing_id: *u32,
    revisions: *Revisions,
) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator,
        \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        \\<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
        \\            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        \\            xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
        \\            xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
        \\            xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">
        \\<w:body>
        \\
    );

    for (doc.elements) |elem| {
        switch (elem) {
            .paragraph => |p| try writeParagraph(allocator, &buf, &p, hyperlinks, images, drawing_id, revisions),
            .table => |t| try writeTable(allocator, &buf, &t, hyperlinks, images, drawing_id, revisions, parts.textWidth()),
        }
    }

    if (parts.any()) {
        // Schema order: header and footer references, then page size, then margins.
        try buf.appendSlice(allocator, "<w:sectPr>");
        if (parts.header()) {
            try buf.appendSlice(allocator, "<w:headerReference w:type=\"default\" r:id=\"");
            try buf.appendSlice(allocator, RID_HEADER);
            try buf.appendSlice(allocator, "\"/>");
        }
        if (parts.footer) {
            try buf.appendSlice(allocator, "<w:footerReference w:type=\"default\" r:id=\"");
            try buf.appendSlice(allocator, RID_FOOTER);
            try buf.appendSlice(allocator, "\"/>");
        }
        if (parts.a4 or parts.landscape) {
            const size = parts.pageSize();
            var tmp: [96]u8 = undefined;
            try buf.appendSlice(allocator, try std.fmt.bufPrint(&tmp, "<w:pgSz w:w=\"{d}\" w:h=\"{d}\"{s}/>", .{
                size.w, size.h, if (parts.landscape) " w:orient=\"landscape\"" else "",
            }));
        }
        if (parts.margin) |m| {
            var tmp: [160]u8 = undefined;
            try buf.appendSlice(allocator, try std.fmt.bufPrint(&tmp, "<w:pgMar w:top=\"{d}\" w:right=\"{d}\" w:bottom=\"{d}\" w:left=\"{d}\" w:header=\"{d}\" w:footer=\"{d}\" w:gutter=\"0\"/>", .{ m, m, m, m, m / 2, m / 2 }));
        } else if (parts.image_header) {
            try buf.appendSlice(allocator, "<w:pgMar w:top=\"1800\" w:right=\"1440\" w:bottom=\"1440\" w:left=\"1440\" w:header=\"720\" w:footer=\"720\"/>");
        } else {
            try buf.appendSlice(allocator, "<w:pgMar w:top=\"1440\" w:right=\"1440\" w:bottom=\"1440\" w:left=\"1440\" w:header=\"708\" w:footer=\"708\"/>");
        }
        try buf.appendSlice(allocator, "</w:sectPr>");
    }

    try buf.appendSlice(allocator, "</w:body>\n</w:document>");
    return allocator.dupe(u8, buf.items);
}

fn writeParagraph(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    p: *const docx.Paragraph,
    hyperlinks: *HyperlinkCollector,
    images: *ImageCollector,
    drawing_id: *u32,
    revisions: *Revisions,
) !void {
    // A page-break marker is a standalone paragraph whose only content is a
    // hard page break. Emit it and return — no style/run processing needed.
    if (p.style == .page_break) {
        try buf.appendSlice(allocator, "<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>\n");
        return;
    }

    // Paragraph properties in CT_PPrBase order: pStyle, keepNext, numPr,
    // pBdr, spacing, jc.
    try buf.appendSlice(allocator, "<w:p><w:pPr>");

    switch (p.style) {
        .heading1 => try buf.appendSlice(allocator, "<w:pStyle w:val=\"Heading1\"/>"),
        .heading2 => try buf.appendSlice(allocator, "<w:pStyle w:val=\"Heading2\"/>"),
        .heading3 => try buf.appendSlice(allocator, "<w:pStyle w:val=\"Heading3\"/>"),
        .heading4 => try buf.appendSlice(allocator, "<w:pStyle w:val=\"Heading4\"/>"),
        .heading5 => try buf.appendSlice(allocator, "<w:pStyle w:val=\"Heading5\"/>"),
        .heading6 => try buf.appendSlice(allocator, "<w:pStyle w:val=\"Heading6\"/>"),
        .code_block => try buf.appendSlice(allocator, "<w:pStyle w:val=\"CodeBlock\"/>"),
        .blockquote => try buf.appendSlice(allocator, "<w:pStyle w:val=\"Quote\"/>"),
        .list_paragraph => try buf.appendSlice(allocator, "<w:pStyle w:val=\"ListParagraph\"/>"),
        else => {},
    }

    if (p.keep_next) try buf.appendSlice(allocator, "<w:keepNext/>");

    if (p.is_list_item) {
        var tmp: [128]u8 = undefined;
        const num_id: u8 = if (p.is_ordered) 2 else 1;
        const s = try std.fmt.bufPrint(&tmp, "<w:numPr><w:ilvl w:val=\"{d}\"/><w:numId w:val=\"{d}\"/></w:numPr>", .{ p.numbering_level, num_id });
        try buf.appendSlice(allocator, s);
    }

    if (p.style == .horizontal_rule) {
        try buf.appendSlice(allocator, "<w:pBdr><w:bottom w:val=\"single\" w:sz=\"6\" w:space=\"1\" w:color=\"999999\"/></w:pBdr>");
    }

    if (p.spacing_after) |after| {
        var tmp: [48]u8 = undefined;
        try buf.appendSlice(allocator, try std.fmt.bufPrint(&tmp, "<w:spacing w:after=\"{d}\"/>", .{after}));
    }

    if (p.alignment) |a| {
        try buf.appendSlice(allocator, "<w:jc w:val=\"");
        try buf.appendSlice(allocator, a.jcValue());
        try buf.appendSlice(allocator, "\"/>");
    }

    try buf.appendSlice(allocator, "</w:pPr>");

    for (p.runs) |run| {
        if (run.hyperlink_url) |url| {
            const rid = try hyperlinks.addUrl(url);
            defer allocator.free(rid);
            try buf.appendSlice(allocator, "<w:hyperlink r:id=\"");
            try buf.appendSlice(allocator, rid);
            try buf.appendSlice(allocator, "\">");
            try writeHyperlinkRun(allocator, buf, &run);
            try buf.appendSlice(allocator, "</w:hyperlink>");
        } else if (run.image_rel_id) |_| {
            try writeImageRun(allocator, buf, &run, images, drawing_id);
        } else if (run.revision) |rev| {
            try writeRevisionRun(allocator, buf, &run, rev, revisions);
        } else {
            try writeRun(allocator, buf, &run);
        }
    }

    try buf.appendSlice(allocator, "</w:p>\n");
}

fn writeRun(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), run: *const docx.Run) !void {
    try writeRunXml(allocator, buf, run, .text);
}

fn writeHyperlinkRun(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), run: *const docx.Run) !void {
    try writeRunXml(allocator, buf, run, .hyperlink);
}

/// A run as a Word tracked change: `w:ins` around an ordinary run, or `w:del`
/// around one whose text is `w:delText`. Each carries a document-unique id,
/// the author and, when given, the date.
fn writeRevisionRun(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), run: *const docx.Run, rev: docx.Revision, revisions: *Revisions) !void {
    const tag = switch (rev) {
        .inserted => "w:ins",
        .deleted => "w:del",
    };
    var tmp: [48]u8 = undefined;
    try buf.appendSlice(allocator, try std.fmt.bufPrint(&tmp, "<{s} w:id=\"{d}\" w:author=\"", .{ tag, revisions.next_id }));
    revisions.next_id += 1;
    try appendXmlEscaped(allocator, buf, revisions.author);
    try buf.append(allocator, '"');
    if (revisions.date.len > 0) {
        try buf.appendSlice(allocator, " w:date=\"");
        try appendXmlEscaped(allocator, buf, revisions.date);
        try buf.append(allocator, '"');
    }
    try buf.append(allocator, '>');
    try writeRunXml(allocator, buf, run, if (rev == .deleted) .deleted else .text);
    try buf.appendSlice(allocator, "</");
    try buf.appendSlice(allocator, tag);
    try buf.append(allocator, '>');
}

/// Where a run is written: in ordinary text, as the text of a hyperlink
/// (blue and underlined unless the run has its own colour), or inside a
/// tracked deletion (`w:del`), whose text Word requires as `w:delText`.
pub const RunContext = enum { text, hyperlink, deleted };

/// `<w:rPr>` for `run`, its elements in the sequence CT_RPr requires
/// (ECMA-376 Part 1, 17.3.2.28): rStyle, b, i, strike, color, sz, szCs,
/// highlight, u, shd. Word refuses a document whose run properties are out
/// of that order.
pub fn writeRunProps(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), run: *const docx.Run, context: RunContext) !void {
    try buf.appendSlice(allocator, "<w:rPr>");
    if (run.is_code) try buf.appendSlice(allocator, "<w:rStyle w:val=\"InlineCode\"/>");
    if (run.bold) try buf.appendSlice(allocator, "<w:b/>");
    if (run.italic) try buf.appendSlice(allocator, "<w:i/>");
    if (run.strike) try buf.appendSlice(allocator, "<w:strike/>");
    if (run.fg) |c| {
        try buf.appendSlice(allocator, "<w:color w:val=\"");
        try buf.appendSlice(allocator, &c);
        try buf.appendSlice(allocator, "\"/>");
    } else if (run.color) |c| {
        try buf.appendSlice(allocator, "<w:color w:val=\"");
        try appendXmlEscaped(allocator, buf, c);
        try buf.appendSlice(allocator, "\"/>");
    } else if (context == .hyperlink) {
        try buf.appendSlice(allocator, "<w:color w:val=\"0563C1\"/>");
    }
    if (run.half_points) |hp| {
        var tmp: [64]u8 = undefined;
        try buf.appendSlice(allocator, try std.fmt.bufPrint(&tmp, "<w:sz w:val=\"{d}\"/><w:szCs w:val=\"{d}\"/>", .{ hp, hp }));
    }
    if (run.highlight) try buf.appendSlice(allocator, "<w:highlight w:val=\"yellow\"/>");
    if (run.underline or context == .hyperlink) try buf.appendSlice(allocator, "<w:u w:val=\"single\"/>");
    if (run.bg) |c| {
        try buf.appendSlice(allocator, "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"");
        try buf.appendSlice(allocator, &c);
        try buf.appendSlice(allocator, "\"/>");
    }
    try buf.appendSlice(allocator, "</w:rPr>");
}

/// `<w:r>` holding `run`'s properties and text. Word does not read a newline
/// or a tab inside `w:t`, so a newline is written as `w:br` and a tab as
/// `w:tab`; a carriage return is dropped.
pub fn writeRunXml(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), run: *const docx.Run, context: RunContext) !void {
    try buf.appendSlice(allocator, "<w:r>");
    try writeRunProps(allocator, buf, run, context);
    const open = if (context == .deleted) "<w:delText xml:space=\"preserve\">" else "<w:t xml:space=\"preserve\">";
    const close = if (context == .deleted) "</w:delText>" else "</w:t>";
    const text = run.text;
    var start: usize = 0;
    for (text, 0..) |c, i| {
        if (c != '\n' and c != '\t' and c != '\r') continue;
        if (i > start) {
            try buf.appendSlice(allocator, open);
            try appendXmlEscaped(allocator, buf, text[start..i]);
            try buf.appendSlice(allocator, close);
        }
        switch (c) {
            '\n' => try buf.appendSlice(allocator, "<w:br/>"),
            '\t' => try buf.appendSlice(allocator, "<w:tab/>"),
            else => {},
        }
        start = i + 1;
    }
    if (start < text.len or text.len == 0) {
        try buf.appendSlice(allocator, open);
        try appendXmlEscaped(allocator, buf, text[start..]);
        try buf.appendSlice(allocator, close);
    }
    try buf.appendSlice(allocator, "</w:r>");
}

/// The space Word leaves between a cell's left or right edge and its text
/// when the table does not say (its built-in "Normal Table" style), in
/// twentieths of a point.
const WORD_CELL_PADDING: u32 = 108;

/// Text width of a portrait US Letter page with one-inch margins, in
/// twentieths of a point: what a table with neither widths nor weights
/// shares out equally between its columns, whatever the page.
const CONTENT_WIDTH_TWIPS: u16 = 9360;

/// EMU per pixel at 96 DPI (914400 EMU to the inch), for drawing geometry.
const EMU_PER_PIXEL: u64 = 9525;
const MAX_IMAGE_WIDTH_EMU: u64 = 5486400; // 6 inches
const DEFAULT_IMAGE_CX: u64 = 5486400; // 6 inches
const DEFAULT_IMAGE_CY: u64 = 3657600; // 4 inches
const DEFAULT_HEADER_CY: u64 = 914400; // 1 inch

/// Convert detected pixel dimensions to EMU, capping width at `max_cx` (at
/// most 6 inches) and preserving aspect ratio. Inputs are clamped at detectImageDimensions so
/// the intermediate `cy * max / cx` cannot overflow u64.
fn pixelsToEmu(width_px: u32, height_px: u32, default_cx: u64, default_cy: u64, max_cx: u64) struct { cx: u64, cy: u64 } {
    if (width_px == 0 or height_px == 0) {
        return .{ .cx = default_cx, .cy = default_cy };
    }
    var cx: u64 = @as(u64, width_px) * EMU_PER_PIXEL;
    var cy: u64 = @as(u64, height_px) * EMU_PER_PIXEL;
    if (cx > max_cx) {
        // Multiply BEFORE dividing. Dividing first computed cy/cx in integer
        // arithmetic, which is 0 for every image wider than it is tall — so a
        // landscape screenshot came out with cy="0" and Word drew nothing.
        //
        // Overflow is not reachable: dimensions are clamped to MAX_IMAGE_DIM,
        // so cy is at most 20000 * 9525 ≈ 1.9e8 and the product with
        // MAX_IMAGE_WIDTH_EMU ≈ 5.5e6 is ≈ 1.0e15, four orders of magnitude
        // inside u64.
        cy = cy * max_cx / cx;
        cx = max_cx;
    }
    return .{ .cx = cx, .cy = cy };
}

fn writeImageRun(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    run: *const docx.Run,
    images: *const ImageCollector,
    drawing_id: *u32,
) !void {
    const rel_id = run.image_rel_id orelse return;

    // An unregistered rel_id means nothing resolved this reference: the CLI
    // could not load the file, or a host called the library without supplying
    // the bytes. Writing the drawing anyway puts the unresolved value —
    // typically the raw markdown path — into r:embed with no matching
    // relationship and no word/media entry, which Word reports as unreadable
    // content. A document that silently lacks a picture is a lesser fault
    // than one that will not open, so the alt text stands in its place.
    const entry = images.findByRid(rel_id) orelse {
        if (run.text.len > 0) try writeRun(allocator, buf, run);
        return;
    };

    const emu = pixelsToEmu(entry.width, entry.height, DEFAULT_IMAGE_CX, DEFAULT_IMAGE_CY, @min(run.image_max_width_emu orelse MAX_IMAGE_WIDTH_EMU, MAX_IMAGE_WIDTH_EMU));
    const cx: u64 = emu.cx;
    const cy: u64 = emu.cy;

    const id_val = drawing_id.*;
    drawing_id.* += 1;

    // bufPrint buffers hold only the dynamic number portions; static template
    // fragments are appended directly so buffer size never bounds the markup.
    var num_buf: [32]u8 = undefined;
    try buf.appendSlice(allocator, "<w:r><w:drawing><wp:inline distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\">");
    try buf.appendSlice(allocator, "<wp:extent cx=\"");
    try buf.appendSlice(allocator, try std.fmt.bufPrint(&num_buf, "{d}", .{cx}));
    try buf.appendSlice(allocator, "\" cy=\"");
    try buf.appendSlice(allocator, try std.fmt.bufPrint(&num_buf, "{d}", .{cy}));
    try buf.appendSlice(allocator, "\"/>");
    try buf.appendSlice(allocator, "<wp:docPr id=\"");
    try buf.appendSlice(allocator, try std.fmt.bufPrint(&num_buf, "{d}", .{id_val}));
    try buf.appendSlice(allocator, "\" name=\"");
    try appendXmlEscaped(allocator, buf, run.text); // alt text
    try buf.appendSlice(allocator, "\"/>");
    try buf.appendSlice(allocator, "<a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\">");
    try buf.appendSlice(allocator, "<pic:pic><pic:nvPicPr><pic:cNvPr id=\"");
    try buf.appendSlice(allocator, try std.fmt.bufPrint(&num_buf, "{d}", .{id_val}));
    try buf.appendSlice(allocator, "\" name=\"image\"/><pic:cNvPicPr/></pic:nvPicPr>");
    try buf.appendSlice(allocator, "<pic:blipFill><a:blip r:embed=\"");
    try buf.appendSlice(allocator, rel_id);
    try buf.appendSlice(allocator, "\"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>");
    try buf.appendSlice(allocator, "<pic:spPr><a:xfrm>");
    try buf.appendSlice(allocator, "<a:off x=\"0\" y=\"0\"/>");
    try buf.appendSlice(allocator, "<a:ext cx=\"");
    try buf.appendSlice(allocator, try std.fmt.bufPrint(&num_buf, "{d}", .{cx}));
    try buf.appendSlice(allocator, "\" cy=\"");
    try buf.appendSlice(allocator, try std.fmt.bufPrint(&num_buf, "{d}", .{cy}));
    try buf.appendSlice(allocator, "\"/>");
    try buf.appendSlice(allocator, "</a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr>");
    try buf.appendSlice(allocator, "</pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>");
}

const ImageDimensions = struct { width: u32, height: u32 };

fn detectImageDimensions(data: []const u8, ext: []const u8) ImageDimensions {
    var result: ImageDimensions = .{ .width = 0, .height = 0 };

    // PNG: IHDR at byte 16..24, gated by the 8-byte signature.
    if (std.mem.eql(u8, ext, "png") and data.len >= 24) {
        if (std.mem.eql(u8, data[0..4], &[_]u8{ 0x89, 0x50, 0x4E, 0x47 })) {
            result = .{
                .width = std.mem.readInt(u32, data[16..20], .big),
                .height = std.mem.readInt(u32, data[20..24], .big),
            };
        }
    }
    // JPEG: require SOI (FFD8) at offset 0, then walk segments to the first
    // SOFn marker. Trusting ext without a signature check let hostile input
    // feed garbage dims into the EMU conversion.
    else if ((std.mem.eql(u8, ext, "jpg") or std.mem.eql(u8, ext, "jpeg")) and
        data.len >= 4 and data[0] == 0xFF and data[1] == 0xD8)
    {
        var i: usize = 2;
        while (i + 9 < data.len) {
            if (data[i] != 0xFF) {
                i += 1;
                continue;
            }
            const marker = data[i + 1];
            // SOFn frame markers that carry dimensions. Excludes DHT (C4),
            // JPG (C8), DAC (CC) which share the FFCn range but aren't SOFs.
            const is_sof = (marker >= 0xC0 and marker <= 0xCF) and
                marker != 0xC4 and marker != 0xC8 and marker != 0xCC;
            if (is_sof) {
                result = .{
                    .height = std.mem.readInt(u16, data[i + 5 ..][0..2], .big),
                    .width = std.mem.readInt(u16, data[i + 7 ..][0..2], .big),
                };
                break;
            }
            if (i + 3 >= data.len) break;
            const seg_len = std.mem.readInt(u16, data[i + 2 ..][0..2], .big);
            if (seg_len < 2) break; // malformed — guarantees forward progress
            i += 2 + seg_len;
        }
    }

    // Clamp to a sane upper bound. Real DOCX images are well under 20000 px
    // per side; clamping here prevents u64 overflow later in pixelsToEmu.
    if (result.width > MAX_IMAGE_DIM) result.width = MAX_IMAGE_DIM;
    if (result.height > MAX_IMAGE_DIM) result.height = MAX_IMAGE_DIM;
    return result;
}

fn writeTable(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    t: *const docx.Table,
    hyperlinks: *HyperlinkCollector,
    images: *ImageCollector,
    drawing_id: *u32,
    revisions: *Revisions,
    text_width: u32,
) !void {
    // Relative widths become real ones here, where the text width is known.
    // A table with no lines is wider than the text by its cells' side
    // padding, and centred, so the text in its outer columns lines up with
    // the body text instead of sitting a padding's width inside it.
    var weighted: ?[]u16 = null;
    defer if (weighted) |w| allocator.free(w);
    if (t.col_widths.len == 0 and t.col_weights.len > 0) {
        const overhang: u32 = if (!t.borderless) 0 else if (t.cell_margins) |m| @as(u32, m.left) + m.right else 2 * WORD_CELL_PADDING;
        weighted = try shareWidth(allocator, t.col_weights, text_width + overhang);
    }
    const declared: []const u16 = if (t.col_widths.len > 0) t.col_widths else weighted orelse &[_]u16{};

    // Table properties in CT_TblPr order (ECMA-376 Part 1, 17.4.60): tblStyle,
    // tblW, jc, tblBorders, tblLayout, tblCellMar, tblLook.
    try buf.appendSlice(allocator, "<w:tbl><w:tblPr>\n  <w:tblStyle w:val=\"TableGrid\"/>\n");

    if (declared.len > 0) {
        var total: u32 = 0;
        for (declared) |w| total += w;
        var tmp: [64]u8 = undefined;
        const s = try std.fmt.bufPrint(&tmp, "  <w:tblW w:w=\"{d}\" w:type=\"dxa\"/>\n", .{total});
        try buf.appendSlice(allocator, s);
    } else {
        try buf.appendSlice(allocator, "  <w:tblW w:w=\"0\" w:type=\"auto\"/>\n");
    }

    try buf.appendSlice(allocator,
        \\  <w:jc w:val="center"/>
        \\  <w:tblBorders>
        \\
    );
    const border_color = t.border_color orelse "auto";
    for ([_][]const u8{ "top", "left", "bottom", "right", "insideH", "insideV" }) |edge| {
        try buf.appendSlice(allocator, "    <w:");
        try buf.appendSlice(allocator, edge);
        if (t.borderless) {
            try buf.appendSlice(allocator, " w:val=\"none\" w:sz=\"0\" w:space=\"0\" w:color=\"auto\"/>\n");
            continue;
        }
        try buf.appendSlice(allocator, " w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"");
        try appendXmlEscaped(allocator, buf, border_color);
        try buf.appendSlice(allocator, "\"/>\n");
    }
    try buf.appendSlice(allocator, "  </w:tblBorders>\n");
    if (t.fixed_layout) try buf.appendSlice(allocator, "  <w:tblLayout w:type=\"fixed\"/>\n");
    if (t.cell_margins) |m| {
        var tmp: [224]u8 = undefined;
        try buf.appendSlice(allocator, try std.fmt.bufPrint(&tmp, "  <w:tblCellMar><w:top w:w=\"{d}\" w:type=\"dxa\"/><w:left w:w=\"{d}\" w:type=\"dxa\"/><w:bottom w:w=\"{d}\" w:type=\"dxa\"/><w:right w:w=\"{d}\" w:type=\"dxa\"/></w:tblCellMar>\n", .{ m.top, m.left, m.bottom, m.right }));
    }
    try buf.appendSlice(allocator,
        \\  <w:tblLook w:val="04A0" w:firstRow="1" w:lastRow="0" w:firstColumn="1" w:lastColumn="0" w:noHBand="0" w:noVBand="1"/>
        \\</w:tblPr>
        \\
    );

    // A table has to declare its grid. ECMA-376 requires tblGrid, and without
    // it a reader has nothing to lay the columns out against: LibreOffice
    // collapsed the first column to nothing and ran the second off the page.
    // Builders that know their widths (fra.zig) supply them, a table with
    // relative widths has had them shared out above, and any other table
    // shares the content width equally.
    var widths: []const u16 = declared;
    var computed: ?[]u16 = null;
    defer if (computed) |c| allocator.free(c);
    if (widths.len == 0) {
        var col_count: usize = 0;
        for (t.rows) |row| col_count = @max(col_count, row.cells.len);
        if (col_count > 0) {
            const each: u16 = @intCast(CONTENT_WIDTH_TWIPS / col_count);
            const buf_widths = try allocator.alloc(u16, col_count);
            @memset(buf_widths, each);
            // The last column takes the rounding, so the columns still sum to
            // the full text width.
            buf_widths[col_count - 1] = CONTENT_WIDTH_TWIPS - each * @as(u16, @intCast(col_count - 1));
            computed = buf_widths;
            widths = buf_widths;
        }
    }

    if (widths.len > 0) {
        try buf.appendSlice(allocator, "<w:tblGrid>");
        for (widths) |w| {
            var tmp: [32]u8 = undefined;
            const s = try std.fmt.bufPrint(&tmp, "<w:gridCol w:w=\"{d}\"/>", .{w});
            try buf.appendSlice(allocator, s);
        }
        try buf.appendSlice(allocator, "</w:tblGrid>\n");
    }

    for (t.rows) |row| {
        try buf.appendSlice(allocator, "<w:tr>");
        if (row.header or row.cant_split) {
            try buf.appendSlice(allocator, "<w:trPr>");
            if (row.cant_split) try buf.appendSlice(allocator, "<w:cantSplit/>");
            if (row.header) try buf.appendSlice(allocator, "<w:tblHeader/>");
            try buf.appendSlice(allocator, "</w:trPr>");
        }
        // A cell spanning columns starts at grid column `col` and is as wide
        // as the columns it covers.
        var col: usize = 0;
        for (row.cells) |cell| {
            const span: usize = @max(cell.col_span, 1);
            try buf.appendSlice(allocator, "<w:tc><w:tcPr>");
            if (col < widths.len) {
                var w: u32 = 0;
                for (widths[col..@min(col + span, widths.len)]) |cw| w += cw;
                var tmp: [64]u8 = undefined;
                const s = try std.fmt.bufPrint(&tmp, "<w:tcW w:w=\"{d}\" w:type=\"dxa\"/>", .{w});
                try buf.appendSlice(allocator, s);
            } else {
                try buf.appendSlice(allocator, "<w:tcW w:w=\"0\" w:type=\"auto\"/>");
            }
            if (span > 1) {
                var tmp: [40]u8 = undefined;
                try buf.appendSlice(allocator, try std.fmt.bufPrint(&tmp, "<w:gridSpan w:val=\"{d}\"/>", .{span}));
            }
            col += span;
            if (cell.shading) |fill| {
                try buf.appendSlice(allocator, "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"");
                try appendXmlEscaped(allocator, buf, fill);
                try buf.appendSlice(allocator, "\"/>");
            }
            try buf.appendSlice(allocator, "</w:tcPr>");
            for (cell.paragraphs) |p| {
                try writeParagraph(allocator, buf, &p, hyperlinks, images, drawing_id, revisions);
            }
            // A cell must end in a paragraph; Word refuses one that does not.
            if (cell.paragraphs.len == 0) try buf.appendSlice(allocator, "<w:p/>");
            try buf.appendSlice(allocator, "</w:tc>");
        }
        try buf.appendSlice(allocator, "</w:tr>\n");
    }

    try buf.appendSlice(allocator, "</w:tbl>\n");
}

/// `text_width` shared out in the proportions of `weights`, the last column
/// taking the rounding so the columns sum to the whole width. Weights that
/// are all zero share it equally.
fn shareWidth(allocator: std.mem.Allocator, weights: []const u16, text_width: u32) ![]u16 {
    const widths = try allocator.alloc(u16, weights.len);
    var sum: u64 = 0;
    for (weights) |w| sum += w;
    var given: u32 = 0;
    for (weights, 0..) |w, i| {
        const share: u64 = if (sum == 0) 1 else w;
        const whole: u64 = if (sum == 0) weights.len else sum;
        const width: u32 = if (i + 1 == weights.len) text_width -| given else @intCast(@as(u64, text_width) * share / whole);
        widths[i] = @intCast(@min(width, std.math.maxInt(u16)));
        given += width;
    }
    return widths;
}

fn genCoreProps(allocator: std.mem.Allocator, options: DocxWriterOptions) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator,
        \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        \\<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties"
        \\                   xmlns:dc="http://purl.org/dc/elements/1.1/"
        \\                   xmlns:dcterms="http://purl.org/dc/terms/">
        \\
    );

    if (options.title.len > 0) {
        try buf.appendSlice(allocator, "  <dc:title>");
        try appendXmlEscaped(allocator, &buf, options.title);
        try buf.appendSlice(allocator, "</dc:title>\n");
    }
    if (options.author.len > 0) {
        try buf.appendSlice(allocator, "  <dc:creator>");
        try appendXmlEscaped(allocator, &buf, options.author);
        try buf.appendSlice(allocator, "</dc:creator>\n");
    }
    if (options.description.len > 0) {
        try buf.appendSlice(allocator, "  <dc:description>");
        try appendXmlEscaped(allocator, &buf, options.description);
        try buf.appendSlice(allocator, "</dc:description>\n");
    }

    try buf.appendSlice(allocator, "</cp:coreProperties>");
    return allocator.dupe(u8, buf.items);
}

// ── Header XML (letterhead) ─────────────────────────────────────

/// A page header holding one line of small grey text at the right.
fn genTextHeaderXml(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator,
        \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        \\<w:hdr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:p><w:pPr><w:jc w:val="right"/></w:pPr><w:r><w:rPr><w:color w:val="808080"/><w:sz w:val="16"/><w:szCs w:val="16"/></w:rPr><w:t xml:space="preserve">
    );
    try appendXmlEscaped(allocator, &buf, text);
    try buf.appendSlice(allocator, "</w:t></w:r></w:p></w:hdr>");
    return allocator.dupe(u8, buf.items);
}

/// A page footer reading "Page N of M" (in `language`) at the left and `text`,
/// when there is any, at the right, small and grey. N and M are Word fields,
/// so they are right on every page.
fn genPageFooterXml(allocator: std.mem.Allocator, text: []const u8, text_width: u32, language: Language) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    const rpr = "<w:rPr><w:color w:val=\"808080\"/><w:sz w:val=\"16\"/><w:szCs w:val=\"16\"/></w:rPr>";
    try buf.appendSlice(allocator,
        \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        \\<w:ftr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:p><w:pPr><w:tabs><w:tab w:val="right" w:pos="
    );
    // The right tab stop sits at the right margin: the text width of the page.
    var width_buf: [16]u8 = undefined;
    try buf.appendSlice(allocator, try std.fmt.bufPrint(&width_buf, "{d}", .{text_width}));
    try buf.appendSlice(allocator, "\"/></w:tabs></w:pPr>");
    const field = struct {
        fn write(a: std.mem.Allocator, b: *std.ArrayListUnmanaged(u8), r: []const u8, instr: []const u8) !void {
            try b.appendSlice(a, "<w:r>");
            try b.appendSlice(a, r);
            try b.appendSlice(a, "<w:fldChar w:fldCharType=\"begin\"/></w:r><w:r>");
            try b.appendSlice(a, r);
            try b.appendSlice(a, "<w:instrText xml:space=\"preserve\"> ");
            try b.appendSlice(a, instr);
            try b.appendSlice(a, " </w:instrText></w:r><w:r>");
            try b.appendSlice(a, r);
            try b.appendSlice(a, "<w:fldChar w:fldCharType=\"separate\"/></w:r><w:r>");
            try b.appendSlice(a, r);
            try b.appendSlice(a, "<w:t>1</w:t></w:r><w:r>");
            try b.appendSlice(a, r);
            try b.appendSlice(a, "<w:fldChar w:fldCharType=\"end\"/></w:r>");
        }
    };
    const words = language.pageWords();
    try buf.appendSlice(allocator, "<w:r>" ++ rpr ++ "<w:t xml:space=\"preserve\">");
    try buf.appendSlice(allocator, words.page);
    try buf.appendSlice(allocator, "</w:t></w:r>");
    try field.write(allocator, &buf, rpr, "PAGE");
    try buf.appendSlice(allocator, "<w:r>" ++ rpr ++ "<w:t xml:space=\"preserve\">");
    try buf.appendSlice(allocator, words.of);
    try buf.appendSlice(allocator, "</w:t></w:r>");
    try field.write(allocator, &buf, rpr, "NUMPAGES");
    if (text.len > 0) {
        try buf.appendSlice(allocator, "<w:r>" ++ rpr ++ "<w:tab/><w:t xml:space=\"preserve\">");
        try appendXmlEscaped(allocator, &buf, text);
        try buf.appendSlice(allocator, "</w:t></w:r>");
    }
    try buf.appendSlice(allocator, "</w:p></w:ftr>");
    return allocator.dupe(u8, buf.items);
}

fn genHeaderXml(allocator: std.mem.Allocator, img_rid: []const u8, width_px: u32, height_px: u32) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    const emu = pixelsToEmu(width_px, height_px, DEFAULT_IMAGE_CX, DEFAULT_HEADER_CY, MAX_IMAGE_WIDTH_EMU);
    const cx = emu.cx;
    const cy = emu.cy;

    try buf.appendSlice(allocator,
        \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        \\<w:hdr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
        \\       xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        \\       xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
        \\       xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
        \\       xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">
        \\<w:p><w:pPr><w:jc w:val="center"/></w:pPr>
        \\<w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0">
        \\
    );

    var num_buf: [32]u8 = undefined;
    try buf.appendSlice(allocator, "<wp:extent cx=\"");
    try buf.appendSlice(allocator, try std.fmt.bufPrint(&num_buf, "{d}", .{cx}));
    try buf.appendSlice(allocator, "\" cy=\"");
    try buf.appendSlice(allocator, try std.fmt.bufPrint(&num_buf, "{d}", .{cy}));
    try buf.appendSlice(allocator, "\"/>");
    try buf.appendSlice(allocator, "<wp:docPr id=\"");
    try buf.appendSlice(allocator, try std.fmt.bufPrint(&num_buf, "{d}", .{DRAWING_ID_LETTERHEAD}));
    try buf.appendSlice(allocator, "\" name=\"Letterhead\"/>");
    try buf.appendSlice(allocator, "<a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\">");
    try buf.appendSlice(allocator, "<pic:pic><pic:nvPicPr><pic:cNvPr id=\"");
    try buf.appendSlice(allocator, try std.fmt.bufPrint(&num_buf, "{d}", .{DRAWING_ID_LETTERHEAD}));
    try buf.appendSlice(allocator, "\" name=\"letterhead\"/><pic:cNvPicPr/></pic:nvPicPr>");
    try buf.appendSlice(allocator, "<pic:blipFill><a:blip r:embed=\"");
    try buf.appendSlice(allocator, img_rid);
    try buf.appendSlice(allocator, "\"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>");
    try buf.appendSlice(allocator, "<pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/>");
    try buf.appendSlice(allocator, "<a:ext cx=\"");
    try buf.appendSlice(allocator, try std.fmt.bufPrint(&num_buf, "{d}", .{cx}));
    try buf.appendSlice(allocator, "\" cy=\"");
    try buf.appendSlice(allocator, try std.fmt.bufPrint(&num_buf, "{d}", .{cy}));
    try buf.appendSlice(allocator, "\"/>");
    try buf.appendSlice(allocator, "</a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr>");
    try buf.appendSlice(allocator, "</pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>\n");
    try buf.appendSlice(allocator, "</w:hdr>");

    return allocator.dupe(u8, buf.items);
}

fn genHeaderRels(allocator: std.mem.Allocator, media_target: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator,
        \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        \\<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        \\  <Relationship Id="
    );
    try buf.appendSlice(allocator, RID_HEADER_IMAGE);
    try buf.appendSlice(allocator, "\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"");
    try appendXmlEscaped(allocator, &buf, media_target);
    try buf.appendSlice(allocator, "\"/>\n</Relationships>");
    return allocator.dupe(u8, buf.items);
}

// ── XML escaping ────────────────────────────────────────────────

pub fn appendXmlEscaped(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '&' => try buf.appendSlice(allocator, "&amp;"),
            '<' => try buf.appendSlice(allocator, "&lt;"),
            '>' => try buf.appendSlice(allocator, "&gt;"),
            '"' => try buf.appendSlice(allocator, "&quot;"),
            // Strip XML 1.0 illegal control chars (everything below 0x20 except
            // TAB/LF/CR). Leaving them in produces ill-formed XML that Word
            // refuses to open.
            0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => {},
            else => try buf.append(allocator, c),
        }
    }
}

// ─── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;

test "a landscape image keeps its aspect ratio when scaled to the page" {
    // 1920x1032 — an ordinary screen recording frame, and wider than the six
    // inches a page can give it.
    const emu = pixelsToEmu(1920, 1032, DEFAULT_IMAGE_CX, DEFAULT_IMAGE_CY, MAX_IMAGE_WIDTH_EMU);
    try testing.expectEqual(MAX_IMAGE_WIDTH_EMU, emu.cx);
    try testing.expect(emu.cy > 0); // dividing before multiplying gave 0 here

    // Within a pixel of the true ratio.
    const expected_cy: u64 = MAX_IMAGE_WIDTH_EMU * 1032 / 1920;
    try testing.expectApproxEqAbs(
        @as(f64, @floatFromInt(emu.cy)),
        @as(f64, @floatFromInt(expected_cy)),
        @as(f64, EMU_PER_PIXEL),
    );
}

test "an image that already fits is left alone, and a zero-sized one falls back" {
    const small = pixelsToEmu(300, 200, DEFAULT_IMAGE_CX, DEFAULT_IMAGE_CY, MAX_IMAGE_WIDTH_EMU);
    try testing.expectEqual(@as(u64, 300 * EMU_PER_PIXEL), small.cx);
    try testing.expectEqual(@as(u64, 200 * EMU_PER_PIXEL), small.cy);

    const unknown = pixelsToEmu(0, 0, DEFAULT_IMAGE_CX, DEFAULT_IMAGE_CY, MAX_IMAGE_WIDTH_EMU);
    try testing.expectEqual(DEFAULT_IMAGE_CX, unknown.cx);
    try testing.expectEqual(DEFAULT_IMAGE_CY, unknown.cy);
}

test "a portrait image is scaled by height as well" {
    // Taller than wide and over the limit: the width caps, the height follows.
    const emu = pixelsToEmu(1200, 2400, DEFAULT_IMAGE_CX, DEFAULT_IMAGE_CY, MAX_IMAGE_WIDTH_EMU);
    try testing.expectEqual(MAX_IMAGE_WIDTH_EMU, emu.cx);
    try testing.expectEqual(MAX_IMAGE_WIDTH_EMU * 2, emu.cy);
}

test "a markdown table declares a grid so readers can lay it out" {
    const allocator = testing.allocator;

    var cell_a = [_]docx.Paragraph{.{ .runs = &[_]docx.Run{} }};
    var cell_b = [_]docx.Paragraph{.{ .runs = &[_]docx.Run{} }};
    var cells = [_]docx.TableCell{
        .{ .paragraphs = &cell_a },
        .{ .paragraphs = &cell_b },
    };
    var rows = [_]docx.TableRow{.{ .cells = &cells }};
    const table = docx.Table{ .rows = &rows };

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    var hyperlinks = HyperlinkCollector.init(allocator);
    defer hyperlinks.deinit();
    var images = ImageCollector.init(allocator);
    defer images.deinit();
    var drawing_id: u32 = 1;
    var revisions = Revisions{ .author = "", .date = "" };

    try writeTable(allocator, &buf, &table, &hyperlinks, &images, &drawing_id, &revisions, CONTENT_WIDTH_TWIPS);

    const xml = buf.items;
    try testing.expect(std.mem.indexOf(u8, xml, "<w:tblGrid>") != null);
    // Two equal columns that between them fill the text width.
    try testing.expect(std.mem.indexOf(u8, xml, "<w:gridCol w:w=\"4680\"/>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<w:tcW w:w=\"4680\" w:type=\"dxa\"/>") != null);
}

test "run properties are written in schema order" {
    const allocator = testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    const run = docx.Run{
        .text = "x",
        .bold = true,
        .italic = true,
        .underline = true,
        .strike = true,
        .highlight = true,
        .is_code = true,
        .fg = "A00000".*,
        .bg = "FDDADA".*,
        .half_points = 17,
    };
    try writeRunProps(allocator, &buf, &run, .text);
    try testing.expectEqualStrings(
        "<w:rPr><w:rStyle w:val=\"InlineCode\"/><w:b/><w:i/><w:strike/><w:color w:val=\"A00000\"/>" ++
            "<w:sz w:val=\"17\"/><w:szCs w:val=\"17\"/><w:highlight w:val=\"yellow\"/><w:u w:val=\"single\"/>" ++
            "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"FDDADA\"/></w:rPr>",
        buf.items,
    );

    // A hyperlink is blue and underlined unless the run says otherwise.
    buf.clearRetainingCapacity();
    try writeRunProps(allocator, &buf, &docx.Run{ .text = "l" }, .hyperlink);
    try testing.expectEqualStrings("<w:rPr><w:color w:val=\"0563C1\"/><w:u w:val=\"single\"/></w:rPr>", buf.items);
}

test "newlines and tabs become breaks and tab stops; a deleted run uses delText" {
    const allocator = testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    try writeRunXml(allocator, &buf, &docx.Run{ .text = "a\r\nb\tc\n" }, .text);
    try testing.expectEqualStrings(
        "<w:r><w:rPr></w:rPr><w:t xml:space=\"preserve\">a</w:t><w:br/><w:t xml:space=\"preserve\">b</w:t><w:tab/><w:t xml:space=\"preserve\">c</w:t><w:br/></w:r>",
        buf.items,
    );
    buf.clearRetainingCapacity();
    try writeRunXml(allocator, &buf, &docx.Run{ .text = "gone & <done>" }, .deleted);
    try testing.expectEqualStrings(
        "<w:r><w:rPr></w:rPr><w:delText xml:space=\"preserve\">gone &amp; &lt;done&gt;</w:delText></w:r>",
        buf.items,
    );
}

test "rows repeat or hold together, cells span columns, tracked changes are numbered" {
    const allocator = testing.allocator;
    var ins_runs = [_]docx.Run{
        .{ .text = "kept " },
        .{ .text = "old", .revision = .deleted },
        .{ .text = "new", .revision = .inserted },
    };
    var head_para = [_]docx.Paragraph{.{ .runs = &[_]docx.Run{}, .keep_next = true, .spacing_after = 0 }};
    var body_para = [_]docx.Paragraph{.{ .runs = &ins_runs }};
    var head_cells = [_]docx.TableCell{.{ .paragraphs = &head_para, .col_span = 2, .shading = "222222" }};
    var body_cells = [_]docx.TableCell{ .{ .paragraphs = &body_para }, .{} };
    var rows = [_]docx.TableRow{
        .{ .cells = &head_cells, .header = true, .cant_split = true },
        .{ .cells = &body_cells, .cant_split = true },
    };
    const table = docx.Table{
        .rows = &rows,
        .col_widths = &[_]u16{ 1000, 3000 },
        .border_color = "BBBBBB",
        .fixed_layout = true,
        .cell_margins = .{ .top = 50, .left = 90, .bottom = 50, .right = 90 },
    };

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    var hyperlinks = HyperlinkCollector.init(allocator);
    defer hyperlinks.deinit();
    var images = ImageCollector.init(allocator);
    defer images.deinit();
    var drawing_id: u32 = 1;
    var revisions = Revisions{ .author = "Ed & Co", .date = "2026-01-02T00:00:00Z" };
    try writeTable(allocator, &buf, &table, &hyperlinks, &images, &drawing_id, &revisions, CONTENT_WIDTH_TWIPS);
    const xml = buf.items;

    const has = struct {
        fn f(hay: []const u8, needle: []const u8) bool {
            return std.mem.indexOf(u8, hay, needle) != null;
        }
    }.f;
    try testing.expect(has(xml, "<w:tr><w:trPr><w:cantSplit/><w:tblHeader/></w:trPr>"));
    try testing.expect(has(xml, "<w:tcW w:w=\"4000\" w:type=\"dxa\"/><w:gridSpan w:val=\"2\"/><w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"222222\"/>"));
    try testing.expect(has(xml, "<w:pPr><w:keepNext/><w:spacing w:after=\"0\"/></w:pPr>"));
    try testing.expect(has(xml, "<w:top w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"BBBBBB\"/>"));
    try testing.expect(has(xml, "<w:tblLayout w:type=\"fixed\"/>"));
    try testing.expect(has(xml, "<w:tblCellMar><w:top w:w=\"50\" w:type=\"dxa\"/>"));
    try testing.expect(has(xml, "<w:del w:id=\"1\" w:author=\"Ed &amp; Co\" w:date=\"2026-01-02T00:00:00Z\"><w:r><w:rPr></w:rPr><w:delText xml:space=\"preserve\">old</w:delText></w:r></w:del>"));
    try testing.expect(has(xml, "<w:ins w:id=\"2\" w:author=\"Ed &amp; Co\" w:date=\"2026-01-02T00:00:00Z\"><w:r><w:rPr></w:rPr><w:t xml:space=\"preserve\">new</w:t></w:r></w:ins>"));
    // A cell with no paragraphs still ends in one.
    try testing.expect(has(xml, "<w:tcW w:w=\"3000\" w:type=\"dxa\"/></w:tcPr><w:p/></w:tc>"));
    try testing.expectEqual(@as(u32, 3), revisions.next_id);

    // A table with none of the new properties is written as before.
    buf.clearRetainingCapacity();
    var plain_cells = [_]docx.TableCell{.{ .paragraphs = &body_para }};
    var plain_rows = [_]docx.TableRow{.{ .cells = &plain_cells }};
    try writeTable(allocator, &buf, &docx.Table{ .rows = &plain_rows }, &hyperlinks, &images, &drawing_id, &revisions, CONTENT_WIDTH_TWIPS);
    try testing.expect(has(buf.items, "<w:tr><w:tc>"));
    try testing.expect(has(buf.items, "w:color=\"auto\"/>\n  </w:tblBorders>\n  <w:tblLook "));
}

test "landscape A4 with narrow margins; the footer's tab stop follows the text width" {
    const parts = SectionParts{ .a4 = true, .landscape = true, .margin = 720 };
    try testing.expectEqual(@as(u32, 16838), parts.pageSize().w);
    try testing.expectEqual(@as(u32, 15398), parts.textWidth());
    try testing.expectEqual(@as(u32, 9026), (SectionParts{ .a4 = true }).textWidth());
    try testing.expectEqual(@as(u32, 9360), (SectionParts{}).textWidth());
}

test "table properties are in schema order" {
    const allocator = testing.allocator;
    var paras = [_]docx.Paragraph{.{}};
    var cells = [_]docx.TableCell{.{ .paragraphs = &paras }};
    var rows = [_]docx.TableRow{.{ .cells = &cells }};
    const table = docx.Table{
        .rows = &rows,
        .col_widths = &[_]u16{1000},
        .fixed_layout = true,
        .cell_margins = .{ .top = 1, .left = 2, .bottom = 3, .right = 4 },
    };
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    var hyperlinks = HyperlinkCollector.init(allocator);
    defer hyperlinks.deinit();
    var images = ImageCollector.init(allocator);
    defer images.deinit();
    var drawing_id: u32 = 1;
    var revisions = Revisions{ .author = "", .date = "" };
    try writeTable(allocator, &buf, &table, &hyperlinks, &images, &drawing_id, &revisions, CONTENT_WIDTH_TWIPS);

    // CT_TblPr: each element after the one before it.
    const order = [_][]const u8{ "<w:tblStyle ", "<w:tblW ", "<w:jc ", "<w:tblBorders>", "<w:tblLayout ", "<w:tblCellMar>", "<w:tblLook ", "</w:tblPr>" };
    var at: usize = 0;
    for (order) |tag| {
        const found = std.mem.indexOfPos(u8, buf.items, at, tag) orelse {
            std.debug.print("{s} missing or out of order\n", .{tag});
            return error.TestUnexpectedResult;
        };
        at = found + tag.len;
    }
}

// ── Layout: alignment, column widths, borders, page settings ──────

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

/// One part of a generated .docx, read back through the ZIP reader (from a
/// copy, which the archive owns). Caller frees.
fn docxPart(allocator: std.mem.Allocator, bytes: []const u8, name: []const u8) ![]u8 {
    const copy = try allocator.dupe(u8, bytes);
    var archive = @import("zip.zig").ZipArchive.openFromMemory(allocator, copy) catch |err| {
        allocator.free(copy);
        return err;
    };
    defer archive.close();
    const entry = archive.findEntry(name) orelse return error.PartMissing;
    return archive.extract(entry);
}

/// A table written on its own, as genDocumentXml writes it. Caller frees.
fn tableXml(allocator: std.mem.Allocator, table: *const docx.Table, text_width: u32) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    var hyperlinks = HyperlinkCollector.init(allocator);
    defer hyperlinks.deinit();
    var images = ImageCollector.init(allocator);
    defer images.deinit();
    var drawing_id: u32 = 1;
    var revisions = Revisions{ .author = "", .date = "" };
    try writeTable(allocator, &buf, table, &hyperlinks, &images, &drawing_id, &revisions, text_width);
    return buf.toOwnedSlice(allocator);
}

/// Twentieths of a point in `mm` millimetres, to the nearest (25.4 mm and
/// 1440 to the inch).
fn mmToTwips(mm: f64) u16 {
    return std.math.lossyCast(u16, @round(mm / 25.4 * 1440.0));
}

test "a paragraph's alignment is written as w:jc, after its spacing" {
    const allocator = testing.allocator;
    var hyperlinks = HyperlinkCollector.init(allocator);
    defer hyperlinks.deinit();
    var images = ImageCollector.init(allocator);
    defer images.deinit();
    var drawing_id: u32 = 1;
    var revisions = Revisions{ .author = "", .date = "" };
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    // ST_Jc (ECMA-376 Part 1, 17.18.44) spells justified "both".
    const cases = [_]struct { a: docx.Alignment, jc: []const u8 }{
        .{ .a = .left, .jc = "left" },
        .{ .a = .center, .jc = "center" },
        .{ .a = .right, .jc = "right" },
        .{ .a = .justify, .jc = "both" },
    };
    for (cases) |c| {
        buf.clearRetainingCapacity();
        const p = docx.Paragraph{ .alignment = c.a, .spacing_after = 0 };
        try writeParagraph(allocator, &buf, &p, &hyperlinks, &images, &drawing_id, &revisions);
        var want: [96]u8 = undefined;
        try testing.expectEqualStrings(
            try std.fmt.bufPrint(&want, "<w:p><w:pPr><w:spacing w:after=\"0\"/><w:jc w:val=\"{s}\"/></w:pPr></w:p>\n", .{c.jc}),
            buf.items,
        );
    }
    // No alignment, no w:jc: the style decides.
    buf.clearRetainingCapacity();
    try writeParagraph(allocator, &buf, &docx.Paragraph{ .style = .heading1 }, &hyperlinks, &images, &drawing_id, &revisions);
    try testing.expectEqualStrings("<w:p><w:pPr><w:pStyle w:val=\"Heading1\"/></w:pPr></w:p>\n", buf.items);
}

test "relative column widths share out the page's text width" {
    const allocator = testing.allocator;
    var a = [_]docx.Paragraph{.{}};
    var b = [_]docx.Paragraph{.{}};
    var cells = [_]docx.TableCell{ .{ .paragraphs = &a }, .{ .paragraphs = &b } };
    var rows = [_]docx.TableRow{.{ .cells = &cells }};

    // A4 with one-inch margins: 210 mm less two inches.
    const a4_text: u32 = mmToTwips(210) - 2 * 1440;
    const xml = try tableXml(allocator, &docx.Table{ .rows = &rows, .col_weights = &.{ 30, 70 }, .fixed_layout = true }, a4_text);
    defer allocator.free(xml);
    const first = a4_text * 30 / 100;
    var tmp: [160]u8 = undefined;
    try testing.expect(contains(xml, try std.fmt.bufPrint(&tmp, "<w:tblW w:w=\"{d}\" w:type=\"dxa\"/>", .{a4_text})));
    try testing.expect(contains(xml, try std.fmt.bufPrint(&tmp, "<w:tblGrid><w:gridCol w:w=\"{d}\"/><w:gridCol w:w=\"{d}\"/></w:tblGrid>", .{ first, a4_text - first })));
    try testing.expect(contains(xml, try std.fmt.bufPrint(&tmp, "<w:tcW w:w=\"{d}\" w:type=\"dxa\"/>", .{first})));
    try testing.expect(contains(xml, try std.fmt.bufPrint(&tmp, "<w:tcW w:w=\"{d}\" w:type=\"dxa\"/>", .{a4_text - first})));
    try testing.expect(contains(xml, "<w:tblLayout w:type=\"fixed\"/>"));

    // Explicit widths still win over weights.
    const fixed = try tableXml(allocator, &docx.Table{ .rows = &rows, .col_widths = &.{ 1000, 2000 }, .col_weights = &.{ 1, 1 } }, a4_text);
    defer allocator.free(fixed);
    try testing.expect(contains(fixed, "<w:tblGrid><w:gridCol w:w=\"1000\"/><w:gridCol w:w=\"2000\"/></w:tblGrid>"));
}

test "a borderless table has no lines and reaches past the text by its cell padding" {
    const allocator = testing.allocator;
    var a = [_]docx.Paragraph{.{}};
    var b = [_]docx.Paragraph{.{}};
    var cells = [_]docx.TableCell{ .{ .paragraphs = &a }, .{ .paragraphs = &b } };
    var rows = [_]docx.TableRow{.{ .cells = &cells }};
    const xml = try tableXml(allocator, &docx.Table{ .rows = &rows, .col_weights = &.{ 1, 1 }, .borderless = true }, 9000);
    defer allocator.free(xml);
    for ([_][]const u8{ "top", "left", "bottom", "right", "insideH", "insideV" }) |edge| {
        var tmp: [96]u8 = undefined;
        try testing.expect(contains(xml, try std.fmt.bufPrint(&tmp, "<w:{s} w:val=\"none\" w:sz=\"0\" w:space=\"0\" w:color=\"auto\"/>", .{edge})));
    }
    try testing.expect(!contains(xml, "w:val=\"single\""));
    // Word's default padding is 108 at each side; the centred table is that much wider.
    try testing.expect(contains(xml, "<w:tblW w:w=\"9216\" w:type=\"dxa\"/>"));
    try testing.expect(contains(xml, "<w:gridCol w:w=\"4608\"/><w:gridCol w:w=\"4608\"/>"));
}

test "page settings named in words reach the page, the margins and the footer" {
    const allocator = testing.allocator;
    var runs = [_]docx.Run{.{ .text = "Body" }};
    var elements = [_]docx.Element{.{ .paragraph = .{ .runs = &runs } }};
    const doc = docx.Document{ .elements = &elements, .media = &.{}, .allocator = allocator };

    var opts = DocxWriterOptions{};
    try testing.expect((LayoutSettings{ .paper = "A4", .margin = "25mm", .page_numbers = "true", .lang = "es-ES" }).applyTo(&opts) == null);
    const bytes = try generateDocx(allocator, &doc, opts);
    defer allocator.free(bytes);

    const body = try docxPart(allocator, bytes, "word/document.xml");
    defer allocator.free(body);
    var tmp: [160]u8 = undefined;
    // ISO 216 A4 is 210 × 297 mm.
    try testing.expect(contains(body, try std.fmt.bufPrint(&tmp, "<w:pgSz w:w=\"{d}\" w:h=\"{d}\"/>", .{ mmToTwips(210), mmToTwips(297) })));
    const m = mmToTwips(25);
    try testing.expect(contains(body, try std.fmt.bufPrint(&tmp, "<w:pgMar w:top=\"{d}\" w:right=\"{d}\" w:bottom=\"{d}\" w:left=\"{d}\"", .{ m, m, m, m })));
    try testing.expect(contains(body, "<w:footerReference w:type=\"default\" r:id=\"rId6\"/>"));

    // Page numbers with no footer text: the words and both fields, no tab.
    const footer = try docxPart(allocator, bytes, "word/footer1.xml");
    defer allocator.free(footer);
    try testing.expect(contains(footer, "<w:t xml:space=\"preserve\">Página </w:t>"));
    try testing.expect(contains(footer, "<w:t xml:space=\"preserve\"> de </w:t>"));
    try testing.expect(contains(footer, "<w:instrText xml:space=\"preserve\"> PAGE </w:instrText>"));
    try testing.expect(contains(footer, "<w:instrText xml:space=\"preserve\"> NUMPAGES </w:instrText>"));
    try testing.expect(!contains(footer, "<w:tab/>"));
    try testing.expect(!contains(footer, "Page "));

    // In English, with text at the right.
    const en = try genPageFooterXml(allocator, "Ref 1", 9026, .en);
    defer allocator.free(en);
    try testing.expect(contains(en, "<w:t xml:space=\"preserve\">Page </w:t>"));
    try testing.expect(contains(en, "<w:t xml:space=\"preserve\"> of </w:t>"));
    try testing.expect(contains(en, "<w:tab/><w:t xml:space=\"preserve\">Ref 1</w:t>"));
}

test "the letter style: 12pt justified text at 1.15 lines, bold centred black headings, on A4" {
    const allocator = testing.allocator;
    const es = try genLetterStyles(allocator, .es);
    defer allocator.free(es);
    try testing.expect(contains(es, "<w:sz w:val=\"24\"/><w:szCs w:val=\"24\"/><w:lang w:val=\"es-ES\"/>"));
    // 1.15 lines is 276 two-hundred-and-fortieths of a line.
    try testing.expect(contains(es, "<w:spacing w:after=\"160\" w:line=\"276\" w:lineRule=\"auto\"/>\n      <w:jc w:val=\"both\"/>\n    </w:pPr></w:pPrDefault>"));
    try testing.expect(contains(es, "w:styleId=\"Heading1\"><w:name w:val=\"heading 1\"/><w:pPr><w:keepNext/><w:spacing w:before=\"360\" w:after=\"240\"/><w:jc w:val=\"center\"/></w:pPr><w:rPr><w:b/><w:color w:val=\"000000\"/>"));
    const en = try genLetterStyles(allocator, .en);
    defer allocator.free(en);
    try testing.expect(contains(en, "<w:lang w:val=\"en-GB\"/>"));

    // A4 unless a paper size is given; a flag over the frontmatter wins.
    var letter = DocxWriterOptions{};
    try testing.expect((LayoutSettings{ .style = "letter" }).applyTo(&letter) == null);
    try testing.expect(letter.style == .letter and letter.a4);
    var us = DocxWriterOptions{};
    try testing.expect((LayoutSettings{ .style = "letter", .paper = "letter" }).applyTo(&us) == null);
    try testing.expect(!us.a4);
    const frontmatter = LayoutSettings{ .style = "letter", .lang = "es", .margin = "30mm" };
    var flagged = DocxWriterOptions{};
    try testing.expect(frontmatter.overlay(.{ .style = "default", .margin = "1in" }).applyTo(&flagged) == null);
    try testing.expect(flagged.style == .default and !flagged.a4 and flagged.language == .es and flagged.margin.? == 1440);

    // The other presets are untouched by the language.
    try testing.expect(!contains(styles_xml, "w:lang") and !contains(styles_minutes_xml, "w:lang"));
}

test "bad page settings say what is wrong" {
    const cases = [_]struct { s: LayoutSettings, problem: []const u8 }{
        .{ .s = .{ .style = "fancy" }, .problem = "style must be default, minutes, sheet or letter" },
        .{ .s = .{ .paper = "a5" }, .problem = "paper must be a4 or letter" },
        .{ .s = .{ .orientation = "sideways" }, .problem = "orientation must be portrait or landscape" },
        .{ .s = .{ .margin = "3 furlongs" }, .problem = "margin must be a length such as 25mm, 2.5cm, 1in or 72pt" },
        .{ .s = .{ .page_numbers = "maybe" }, .problem = "page-numbers must be true or false" },
        .{ .s = .{ .lang = "fr" }, .problem = "lang must be en or es" },
        // 2 × 95 mm of a 210 mm A4 page leaves under an inch.
        .{ .s = .{ .paper = "a4", .margin = "95mm" }, .problem = "margin leaves less than 1 inch (25.4 mm) of the page for text" },
        // Landscape Letter is 8.5 inches tall: 2 × 3.8 in leaves under one.
        .{ .s = .{ .orientation = "landscape", .margin = "3.8in" }, .problem = "margin leaves less than 1 inch (25.4 mm) of the page for text" },
    };
    for (cases) |c| {
        var opts = DocxWriterOptions{};
        try testing.expectEqualStrings(c.problem, c.s.applyTo(&opts) orelse "(accepted)");
    }
}

test "lengths in mm, cm, in and pt" {
    const good = [_]struct { s: []const u8, twips: u16 }{
        .{ .s = "25mm", .twips = mmToTwips(25) },
        .{ .s = "2.5cm", .twips = mmToTwips(25) },
        .{ .s = " 12.7 mm ", .twips = 720 },
        .{ .s = "20", .twips = mmToTwips(20) },
        .{ .s = "1in", .twips = 1440 },
        .{ .s = "0.75IN", .twips = 1080 },
        .{ .s = "72pt", .twips = 1440 },
        .{ .s = "0mm", .twips = 0 },
    };
    for (good) |g| try testing.expectEqual(@as(?u16, g.twips), parseLengthTwips(g.s));
    const bad = [_][]const u8{ "", "mm", "-5mm", "5km", "nan", "inf", "1e9mm", "1,5cm", "2 in in" };
    for (bad) |b| try testing.expectEqual(@as(?u16, null), parseLengthTwips(b));
}
