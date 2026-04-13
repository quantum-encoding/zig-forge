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

pub const DocxWriterOptions = struct {
    title: []const u8 = "",
    author: []const u8 = "",
    description: []const u8 = "",
    date: []const u8 = "",
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

    const content_types = try genContentTypes(allocator, has_lists);
    defer allocator.free(content_types);
    try zip.addFile("[Content_Types].xml", content_types);

    try zip.addFile("_rels/.rels", rels_xml);

    const document_xml = try genDocumentXml(allocator, doc);
    defer allocator.free(document_xml);
    try zip.addFile("word/document.xml", document_xml);

    try zip.addFile("word/styles.xml", styles_xml);

    const doc_rels = try genDocumentRels(allocator, has_lists);
    defer allocator.free(doc_rels);
    try zip.addFile("word/_rels/document.xml.rels", doc_rels);

    if (has_lists) {
        try zip.addFile("word/numbering.xml", numbering_xml);
    }

    if (options.title.len > 0 or options.author.len > 0) {
        const core_xml = try genCoreProps(allocator, options);
        defer allocator.free(core_xml);
        try zip.addFile("docProps/core.xml", core_xml);
    }

    return zip.finish();
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
    \\      <w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:cs="Calibri"/>
    \\      <w:sz w:val="22"/><w:szCs w:val="22"/>
    \\    </w:rPr></w:rPrDefault>
    \\    <w:pPrDefault><w:pPr>
    \\      <w:spacing w:after="160" w:line="259" w:lineRule="auto"/>
    \\    </w:pPr></w:pPrDefault>
    \\  </w:docDefaults>
    \\  <w:style w:type="paragraph" w:styleId="Normal"><w:name w:val="Normal"/></w:style>
    \\  <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:pPr><w:spacing w:before="360" w:after="80"/></w:pPr><w:rPr><w:b/><w:sz w:val="48"/><w:szCs w:val="48"/><w:color w:val="1F3864"/></w:rPr></w:style>
    \\  <w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:pPr><w:spacing w:before="240" w:after="80"/></w:pPr><w:rPr><w:b/><w:sz w:val="36"/><w:szCs w:val="36"/><w:color w:val="1F3864"/></w:rPr></w:style>
    \\  <w:style w:type="paragraph" w:styleId="Heading3"><w:name w:val="heading 3"/><w:pPr><w:spacing w:before="200" w:after="60"/></w:pPr><w:rPr><w:b/><w:sz w:val="28"/><w:szCs w:val="28"/><w:color w:val="1F3864"/></w:rPr></w:style>
    \\  <w:style w:type="paragraph" w:styleId="Heading4"><w:name w:val="heading 4"/><w:pPr><w:spacing w:before="160" w:after="40"/></w:pPr><w:rPr><w:b/><w:i/><w:sz w:val="24"/><w:szCs w:val="24"/></w:rPr></w:style>
    \\  <w:style w:type="paragraph" w:styleId="Heading5"><w:name w:val="heading 5"/><w:pPr><w:spacing w:before="120" w:after="40"/></w:pPr><w:rPr><w:b/><w:sz w:val="22"/><w:szCs w:val="22"/></w:rPr></w:style>
    \\  <w:style w:type="paragraph" w:styleId="Heading6"><w:name w:val="heading 6"/><w:pPr><w:spacing w:before="120" w:after="40"/></w:pPr><w:rPr><w:b/><w:i/><w:sz w:val="22"/><w:szCs w:val="22"/><w:color w:val="666666"/></w:rPr></w:style>
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

fn genContentTypes(allocator: std.mem.Allocator, has_numbering: bool) ![]u8 {
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
    try buf.appendSlice(allocator,
        \\  <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
        \\</Types>
    );
    return allocator.dupe(u8, buf.items);
}

fn genDocumentRels(allocator: std.mem.Allocator, has_numbering: bool) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator,
        \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        \\<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        \\  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
        \\
    );
    if (has_numbering) {
        try buf.appendSlice(allocator,
            \\  <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/>
            \\
        );
    }
    try buf.appendSlice(allocator, "</Relationships>");
    return allocator.dupe(u8, buf.items);
}

fn genDocumentXml(allocator: std.mem.Allocator, doc: *const docx.Document) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator,
        \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        \\<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
        \\            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        \\<w:body>
        \\
    );

    for (doc.elements) |elem| {
        switch (elem) {
            .paragraph => |p| try writeParagraph(allocator, &buf, &p),
            .table => |t| try writeTable(allocator, &buf, &t),
        }
    }

    try buf.appendSlice(allocator, "</w:body>\n</w:document>");
    return allocator.dupe(u8, buf.items);
}

fn writeParagraph(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), p: *const docx.Paragraph) !void {
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
        const s = std.fmt.bufPrint(&tmp, "<w:numPr><w:ilvl w:val=\"{d}\"/><w:numId w:val=\"{d}\"/></w:numPr>", .{ p.numbering_level, num_id }) catch "";
        try buf.appendSlice(allocator, s);
    }

    try buf.appendSlice(allocator, "</w:pPr>");

    for (p.runs) |run| {
        try writeRun(allocator, buf, &run);
    }

    try buf.appendSlice(allocator, "</w:p>\n");
}

fn writeRun(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), run: *const docx.Run) !void {
    try buf.appendSlice(allocator, "<w:r><w:rPr>");
    if (run.bold) try buf.appendSlice(allocator, "<w:b/>");
    if (run.italic) try buf.appendSlice(allocator, "<w:i/>");
    if (run.underline) try buf.appendSlice(allocator, "<w:u w:val=\"single\"/>");
    if (run.is_code) try buf.appendSlice(allocator, "<w:rStyle w:val=\"InlineCode\"/>");
    try buf.appendSlice(allocator, "</w:rPr><w:t xml:space=\"preserve\">");
    try appendXmlEscaped(allocator, buf, run.text);
    try buf.appendSlice(allocator, "</w:t></w:r>");
}

fn writeTable(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), t: *const docx.Table) !void {
    try buf.appendSlice(allocator,
        \\<w:tbl><w:tblPr>
        \\  <w:tblStyle w:val="TableGrid"/>
        \\  <w:tblW w:w="0" w:type="auto"/>
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

    for (t.rows) |row| {
        try buf.appendSlice(allocator, "<w:tr>");
        for (row.cells) |cell| {
            try buf.appendSlice(allocator, "<w:tc><w:tcPr><w:tcW w:w=\"0\" w:type=\"auto\"/></w:tcPr>");
            for (cell.paragraphs) |p| {
                try writeParagraph(allocator, buf, &p);
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

// ── XML escaping ────────────────────────────────────────────────

fn appendXmlEscaped(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '&' => try buf.appendSlice(allocator, "&amp;"),
            '<' => try buf.appendSlice(allocator, "&lt;"),
            '>' => try buf.appendSlice(allocator, "&gt;"),
            '"' => try buf.appendSlice(allocator, "&quot;"),
            else => try buf.append(allocator, c),
        }
    }
}
