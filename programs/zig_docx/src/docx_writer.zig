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
    default, // Calibri, blue headings, left-aligned
    minutes, // Arial, black bold+underline headings, justified text
};

pub const DocxWriterOptions = struct {
    title: []const u8 = "",
    author: []const u8 = "",
    description: []const u8 = "",
    date: []const u8 = "",
    letterhead: ?LetterheadImage = null,
    style: DocumentStyle = .default,
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
    var letterhead_index: ?usize = null;

    if (options.letterhead) |lh| {
        letterhead_index = try images.addImage(lh.data, lh.extension);
    }

    // Drawing object IDs must be unique per document; body images count up.
    var drawing_id_counter: u32 = 1;

    const document_xml = try genDocumentXml(allocator, doc, &hyperlinks, &images, has_header, &drawing_id_counter);
    defer allocator.free(document_xml);

    const content_types = try genContentTypes(allocator, has_lists, &images, has_header);
    defer allocator.free(content_types);
    try zip.addFile("[Content_Types].xml", content_types);

    try zip.addFile("_rels/.rels", rels_xml);

    try zip.addFile("word/document.xml", document_xml);

    try zip.addFile("word/styles.xml", switch (options.style) {
        .minutes => styles_minutes_xml,
        .default => styles_xml,
    });

    const doc_rels = try genDocumentRels(allocator, has_lists, &hyperlinks, &images, has_header);
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

fn genContentTypes(allocator: std.mem.Allocator, has_numbering: bool, images: *const ImageCollector, has_header: bool) ![]u8 {
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

    if (has_header) {
        try buf.appendSlice(allocator,
            \\  <Override PartName="/word/header1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml"/>
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

fn genDocumentRels(allocator: std.mem.Allocator, has_numbering: bool, hyperlinks: *const HyperlinkCollector, images: *const ImageCollector, has_header: bool) ![]u8 {
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

    if (has_header) {
        try buf.appendSlice(allocator, "  <Relationship Id=\"");
        try buf.appendSlice(allocator, RID_HEADER);
        try buf.appendSlice(allocator, "\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/header\" Target=\"header1.xml\"/>\n");
    }
    try buf.appendSlice(allocator, "</Relationships>");
    return allocator.dupe(u8, buf.items);
}

fn genDocumentXml(
    allocator: std.mem.Allocator,
    doc: *const docx.Document,
    hyperlinks: *HyperlinkCollector,
    images: *ImageCollector,
    has_header: bool,
    drawing_id: *u32,
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
            .paragraph => |p| try writeParagraph(allocator, &buf, &p, hyperlinks, images, drawing_id),
            .table => |t| try writeTable(allocator, &buf, &t, hyperlinks, images, drawing_id),
        }
    }

    if (has_header) {
        try buf.appendSlice(allocator, "<w:sectPr><w:headerReference w:type=\"default\" r:id=\"");
        try buf.appendSlice(allocator, RID_HEADER);
        try buf.appendSlice(allocator, "\"/>");
        try buf.appendSlice(allocator, "<w:pgMar w:top=\"1800\" w:right=\"1440\" w:bottom=\"1440\" w:left=\"1440\" w:header=\"720\" w:footer=\"720\"/>");
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
) !void {
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
        .horizontal_rule => try buf.appendSlice(allocator, "<w:pBdr><w:bottom w:val=\"single\" w:sz=\"6\" w:space=\"1\" w:color=\"999999\"/></w:pBdr>"),
        .list_paragraph => try buf.appendSlice(allocator, "<w:pStyle w:val=\"ListParagraph\"/>"),
        else => {},
    }

    if (p.is_list_item) {
        var tmp: [128]u8 = undefined;
        const num_id: u8 = if (p.is_ordered) 2 else 1;
        const s = try std.fmt.bufPrint(&tmp, "<w:numPr><w:ilvl w:val=\"{d}\"/><w:numId w:val=\"{d}\"/></w:numPr>", .{ p.numbering_level, num_id });
        try buf.appendSlice(allocator, s);
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
        } else {
            try writeRun(allocator, buf, &run);
        }
    }

    try buf.appendSlice(allocator, "</w:p>\n");
}

fn writeRun(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), run: *const docx.Run) !void {
    try buf.appendSlice(allocator, "<w:r><w:rPr>");
    if (run.bold) try buf.appendSlice(allocator, "<w:b/>");
    if (run.italic) try buf.appendSlice(allocator, "<w:i/>");
    if (run.underline) try buf.appendSlice(allocator, "<w:u w:val=\"single\"/>");
    if (run.is_code) try buf.appendSlice(allocator, "<w:rStyle w:val=\"InlineCode\"/>");
    if (run.color) |c| {
        try buf.appendSlice(allocator, "<w:color w:val=\"");
        try buf.appendSlice(allocator, c);
        try buf.appendSlice(allocator, "\"/>");
    }
    try buf.appendSlice(allocator, "</w:rPr><w:t xml:space=\"preserve\">");
    try appendXmlEscaped(allocator, buf, run.text);
    try buf.appendSlice(allocator, "</w:t></w:r>");
}

fn writeHyperlinkRun(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), run: *const docx.Run) !void {
    try buf.appendSlice(allocator, "<w:r><w:rPr>");
    try buf.appendSlice(allocator, "<w:color w:val=\"0563C1\"/><w:u w:val=\"single\"/>");
    if (run.bold) try buf.appendSlice(allocator, "<w:b/>");
    if (run.italic) try buf.appendSlice(allocator, "<w:i/>");
    try buf.appendSlice(allocator, "</w:rPr><w:t xml:space=\"preserve\">");
    try appendXmlEscaped(allocator, buf, run.text);
    try buf.appendSlice(allocator, "</w:t></w:r>");
}

/// EMU per inch (914400) and per pixel at 96 DPI (9525) for drawing geometry.
const EMU_PER_PIXEL: u64 = 9525;
const MAX_IMAGE_WIDTH_EMU: u64 = 5486400; // 6 inches
const DEFAULT_IMAGE_CX: u64 = 5486400; // 6 inches
const DEFAULT_IMAGE_CY: u64 = 3657600; // 4 inches
const DEFAULT_HEADER_CY: u64 = 914400; // 1 inch

/// Convert detected pixel dimensions to EMU, capping width at 6 inches and
/// preserving aspect ratio. Inputs are clamped at detectImageDimensions so
/// the intermediate `cy * max / cx` cannot overflow u64.
fn pixelsToEmu(width_px: u32, height_px: u32, default_cx: u64, default_cy: u64) struct { cx: u64, cy: u64 } {
    if (width_px == 0 or height_px == 0) {
        return .{ .cx = default_cx, .cy = default_cy };
    }
    var cx: u64 = @as(u64, width_px) * EMU_PER_PIXEL;
    var cy: u64 = @as(u64, height_px) * EMU_PER_PIXEL;
    if (cx > MAX_IMAGE_WIDTH_EMU) {
        // Reorder to scale down first — loses a tiny amount of precision
        // but cannot overflow u64 even with extreme inputs.
        cy = (cy / cx) * MAX_IMAGE_WIDTH_EMU;
        cx = MAX_IMAGE_WIDTH_EMU;
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

    var cx: u64 = DEFAULT_IMAGE_CX;
    var cy: u64 = DEFAULT_IMAGE_CY;
    if (images.findByRid(rel_id)) |entry| {
        const emu = pixelsToEmu(entry.width, entry.height, DEFAULT_IMAGE_CX, DEFAULT_IMAGE_CY);
        cx = emu.cx;
        cy = emu.cy;
    }

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
) !void {
    try buf.appendSlice(allocator, "<w:tbl><w:tblPr>\n  <w:tblStyle w:val=\"TableGrid\"/>\n");

    if (t.col_widths.len > 0) {
        var total: u32 = 0;
        for (t.col_widths) |w| total += w;
        var tmp: [64]u8 = undefined;
        const s = try std.fmt.bufPrint(&tmp, "  <w:tblW w:w=\"{d}\" w:type=\"dxa\"/>\n", .{total});
        try buf.appendSlice(allocator, s);
    } else {
        try buf.appendSlice(allocator, "  <w:tblW w:w=\"0\" w:type=\"auto\"/>\n");
    }

    try buf.appendSlice(allocator,
        \\  <w:jc w:val="center"/>
        \\  <w:tblLook w:val="04A0" w:firstRow="1" w:lastRow="0" w:firstColumn="1" w:lastColumn="0" w:noHBand="0" w:noVBand="1"/>
        \\  <w:tblBorders>
        \\    <w:top w:val="single" w:sz="4" w:space="0" w:color="auto"/>
        \\    <w:left w:val="single" w:sz="4" w:space="0" w:color="auto"/>
        \\    <w:bottom w:val="single" w:sz="4" w:space="0" w:color="auto"/>
        \\    <w:right w:val="single" w:sz="4" w:space="0" w:color="auto"/>
        \\    <w:insideH w:val="single" w:sz="4" w:space="0" w:color="auto"/>
        \\    <w:insideV w:val="single" w:sz="4" w:space="0" w:color="auto"/>
        \\  </w:tblBorders>
        \\</w:tblPr>
        \\
    );

    if (t.col_widths.len > 0) {
        try buf.appendSlice(allocator, "<w:tblGrid>");
        for (t.col_widths) |w| {
            var tmp: [32]u8 = undefined;
            const s = try std.fmt.bufPrint(&tmp, "<w:gridCol w:w=\"{d}\"/>", .{w});
            try buf.appendSlice(allocator, s);
        }
        try buf.appendSlice(allocator, "</w:tblGrid>\n");
    }

    for (t.rows) |row| {
        try buf.appendSlice(allocator, "<w:tr>");
        for (row.cells, 0..) |cell, ci| {
            try buf.appendSlice(allocator, "<w:tc><w:tcPr>");
            if (ci < t.col_widths.len) {
                var tmp: [64]u8 = undefined;
                const s = try std.fmt.bufPrint(&tmp, "<w:tcW w:w=\"{d}\" w:type=\"dxa\"/>", .{t.col_widths[ci]});
                try buf.appendSlice(allocator, s);
            } else {
                try buf.appendSlice(allocator, "<w:tcW w:w=\"0\" w:type=\"auto\"/>");
            }
            try buf.appendSlice(allocator, "</w:tcPr>");
            for (cell.paragraphs) |p| {
                try writeParagraph(allocator, buf, &p, hyperlinks, images, drawing_id);
            }
            try buf.appendSlice(allocator, "</w:tc>");
        }
        try buf.appendSlice(allocator, "</w:tr>\n");
    }

    try buf.appendSlice(allocator, "</w:tbl>\n");
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

fn genHeaderXml(allocator: std.mem.Allocator, img_rid: []const u8, width_px: u32, height_px: u32) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    const emu = pixelsToEmu(width_px, height_px, DEFAULT_IMAGE_CX, DEFAULT_HEADER_CY);
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

fn appendXmlEscaped(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), text: []const u8) !void {
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
