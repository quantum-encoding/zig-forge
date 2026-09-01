// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! Tier-1 external anchors for zig_docx.
//!
//! Per the zig-forge golden rule, a library is only trustworthy when its tests
//! compare against inputs *and* expected outputs that this library did not
//! produce. Every assertion in this file is anchored to something external:
//!
//!  * `testdata/libreoffice_writer.docx` was authored by **LibreOffice Writer
//!    26.2.1.2** (`soffice --headless --convert-to docx:"MS Word 2007 XML"`).
//!    Neither the file nor its expected contents came from this codebase.
//!  * The expected text, paragraph split, and table shape for that fixture were
//!    read out with **CPython's `xml.etree.ElementTree`**, and the per-entry
//!    CRC-32 / uncompressed sizes with **CPython's `zipfile`** — two
//!    independent implementations of the formats under test.
//!  * The ZIP structural constants are from the PKWARE **APPNOTE.TXT** record
//!    signatures; the OOXML part names are from **ECMA-376** Part 2 (OPC).
//!  * The generated-document assertions check that output this library writes
//!    is accepted by that same external reading: `zipfile.testzip()` returned
//!    clean and `ElementTree.fromstring` parsed `word/document.xml`, including
//!    for the hostile-input case below.
//!
//! Roundtrip-only checks live in the per-module test blocks; nothing here
//! depends on this library agreeing with itself.

const std = @import("std");
const docx = @import("docx.zig");
const zip = @import("zip.zig");
const docx_writer = @import("docx_writer.zig");
const md_parser = @import("md_parser.zig");

/// LibreOffice Writer 26.2.1.2 output. Regenerate with `soffice --headless
/// --convert-to docx:"MS Word 2007 XML"` only if the anchors below are
/// re-derived from an external reader at the same time.
const libreoffice_docx = @embedFile("testdata/libreoffice_writer.docx");

// PKWARE APPNOTE.TXT §4.3 record signatures.
const APPNOTE_LOCAL_HEADER_SIG: u32 = 0x04034b50;
const APPNOTE_CENTRAL_DIR_SIG: u32 = 0x02014b50;
const APPNOTE_EOCD_SIG: u32 = 0x06054b50;

fn readU32Le(data: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, data[offset..][0..4], .little);
}

// =============================================================================
// Anchor 1 — a LibreOffice-authored .docx parses to what ElementTree reports
// =============================================================================

test "anchor: LibreOffice-authored DOCX central directory matches CPython zipfile" {
    const allocator = std.testing.allocator;

    // Exact values printed by CPython zipfile's ZipInfo for this fixture:
    //   for i in zipfile.ZipFile(p).infolist(): (i.filename, i.CRC, i.file_size)
    const Expected = struct { name: []const u8, crc: u32, size: u32 };
    const expected = [_]Expected{
        .{ .name = "docProps/core.xml", .crc = 0x948ccb2d, .size = 567 },
        .{ .name = "docProps/app.xml", .crc = 0xcc77d09b, .size = 443 },
        .{ .name = "_rels/.rels", .crc = 0x2301d0e8, .size = 573 },
        .{ .name = "word/_rels/document.xml.rels", .crc = 0x6daa6476, .size = 663 },
        .{ .name = "word/styles.xml", .crc = 0xfb5cd2d3, .size = 4118 },
        .{ .name = "word/fontTable.xml", .crc = 0x08d9c7c1, .size = 853 },
        .{ .name = "word/theme/theme1.xml", .crc = 0x8055ffe4, .size = 2257 },
        .{ .name = "word/settings.xml", .crc = 0x6b309c70, .size = 683 },
        .{ .name = "word/document.xml", .crc = 0xd5b54de0, .size = 4789 },
        .{ .name = "[Content_Types].xml", .crc = 0x4aef1556, .size = 1327 },
    };

    const data = try allocator.dupe(u8, libreoffice_docx);
    var archive = try zip.ZipArchive.openFromMemory(allocator, data);
    defer archive.close();

    // Same entries, same order, same CRC-32s and sizes as CPython read them.
    try std.testing.expectEqual(expected.len, archive.entries.len);
    for (expected, archive.entries) |want, got| {
        try std.testing.expectEqualStrings(want.name, got.filename);
        try std.testing.expectEqual(want.crc, got.crc32);
        try std.testing.expectEqual(want.size, got.uncompressed_size);
    }

    // And extraction reproduces those exact bytes — `extract` verifies the
    // CRC-32 itself (H6), so a silent mismatch would surface as an error here.
    const doc_xml = try archive.extract(archive.findEntry("word/document.xml").?);
    defer allocator.free(doc_xml);
    try std.testing.expectEqual(@as(usize, 4789), doc_xml.len);
    try std.testing.expectEqual(
        @as(u32, 0xd5b54de0),
        std.hash.crc.Crc32.hash(doc_xml),
    );
}

test "anchor: LibreOffice-authored DOCX parses to the text ElementTree reports" {
    const allocator = std.testing.allocator;

    const data = try allocator.dupe(u8, libreoffice_docx);
    var archive = try zip.ZipArchive.openFromMemory(allocator, data);
    defer archive.close();

    var doc = try docx.parseDocument(allocator, &archive);
    defer doc.deinit();

    // Paragraph text as CPython reported it, joining each <w:p>'s <w:t> nodes.
    // (ElementTree also reports a trailing empty paragraph, which our model
    // drops — asserted explicitly below rather than glossed over.)
    const expected_paragraphs = [_][]const u8{
        "External Anchor Heading",
        // The `&` and `<tag>` were written by LibreOffice as &amp; / &lt;&gt;
        // — this is the entity decoder checked against an external decoder.
        "Plain paragraph with an ampersand & and a less-than <tag>.",
        "Bold run then italic run.",
    };

    var para_index: usize = 0;
    var table_count: usize = 0;
    for (doc.elements) |elem| switch (elem) {
        .paragraph => |p| {
            var text: std.ArrayListUnmanaged(u8) = .empty;
            defer text.deinit(allocator);
            for (p.runs) |run| try text.appendSlice(allocator, run.text);
            if (text.items.len == 0) continue; // the trailing empty <w:p>
            try std.testing.expect(para_index < expected_paragraphs.len);
            try std.testing.expectEqualStrings(expected_paragraphs[para_index], text.items);
            para_index += 1;
        },
        .table => |t| {
            table_count += 1;
            // ElementTree: 1 table, 2 rows, 2 cells per row.
            try std.testing.expectEqual(@as(usize, 2), t.rows.len);
            for (t.rows) |row| try std.testing.expectEqual(@as(usize, 2), row.cells.len);

            const cell_text = [_][]const u8{ "R1C1", "R1C2", "R2C1", "R2C2" };
            var n: usize = 0;
            for (t.rows) |row| for (row.cells) |cell| {
                var text: std.ArrayListUnmanaged(u8) = .empty;
                defer text.deinit(allocator);
                for (cell.paragraphs) |p| for (p.runs) |run|
                    try text.appendSlice(allocator, run.text);
                try std.testing.expectEqualStrings(cell_text[n], text.items);
                n += 1;
            };
        },
    };

    try std.testing.expectEqual(expected_paragraphs.len, para_index);
    try std.testing.expectEqual(@as(usize, 1), table_count);
    // LibreOffice emitted the <h1> as a heading style, not body text.
    try std.testing.expect(doc.elements[0].paragraph.style == .heading1);
}

// =============================================================================
// Anchor 2 — generated .docx files satisfy the external container contracts
// =============================================================================

/// Build a .docx from markdown the way the CLI/FFI do.
fn generateFromMarkdown(allocator: std.mem.Allocator, markdown: []const u8) ![]u8 {
    var parsed = try md_parser.parseMarkdown(allocator, markdown);
    defer parsed.deinit();
    return docx_writer.generateDocx(allocator, &parsed.document, .{});
}

test "anchor: generated DOCX satisfies APPNOTE record layout and ECMA-376 part names" {
    const allocator = std.testing.allocator;

    const bytes = try generateFromMarkdown(allocator, "# Title\n\nBody paragraph.\n");
    defer allocator.free(bytes);

    // APPNOTE.TXT §4.3.6: the file begins with a local file header.
    try std.testing.expectEqual(APPNOTE_LOCAL_HEADER_SIG, readU32Le(bytes, 0));

    // §4.3.16: the EOCD is the last record; with no archive comment it sits
    // exactly 22 bytes from the end.
    const eocd = bytes.len - 22;
    try std.testing.expectEqual(APPNOTE_EOCD_SIG, readU32Le(bytes, eocd));

    // §4.3.16: total entries, central-directory size and offset must describe a
    // central directory that starts with a §4.3.12 record and ends at the EOCD.
    const total_entries = std.mem.readInt(u16, bytes[eocd + 10 ..][0..2], .little);
    const cd_size = readU32Le(bytes, eocd + 12);
    const cd_offset = readU32Le(bytes, eocd + 16);
    try std.testing.expectEqual(APPNOTE_CENTRAL_DIR_SIG, readU32Le(bytes, cd_offset));
    try std.testing.expectEqual(eocd, cd_offset + cd_size);
    try std.testing.expect(total_entries > 0);

    // ECMA-376 Part 2 (OPC) §10: the content-types stream is mandatory, and
    // the package relationship part locates the main document part.
    const data = try allocator.dupe(u8, bytes);
    var archive = try zip.ZipArchive.openFromMemory(allocator, data);
    defer archive.close();
    try std.testing.expectEqual(total_entries, @as(u16, @intCast(archive.entries.len)));
    for ([_][]const u8{
        "[Content_Types].xml",
        "_rels/.rels",
        "word/document.xml",
        "word/_rels/document.xml.rels",
    }) |part| {
        try std.testing.expect(archive.findEntry(part) != null);
    }

    // Every entry's CRC-32 must check out — this is what `zipfile.testzip()`
    // does, and it returned None (clean) for this generator's output.
    for (archive.entries) |*entry| {
        const content = try archive.extract(entry);
        allocator.free(content);
    }
}

test "anchor: hostile markdown text is XML-escaped, not smuggled into the OOXML" {
    const allocator = std.testing.allocator;

    // Text chosen to break naive emitters: raw markup, an ampersand, quotes,
    // and a CDATA terminator. CPython's ElementTree parses the resulting
    // word/document.xml and reads back exactly `expected_text`.
    const hostile =
        "A \"quoted\" text with an ampersand & and a CDATA end ]]> " ++
        "plus a tag <script>alert(1)</script>.";
    const expected_text =
        "A \"quoted\" text with an ampersand & and a CDATA end ]]> " ++
        "plus a tag <script>alert(1)</script>.";

    const md = try std.fmt.allocPrint(allocator, "# Hostile\n\n{s}\n", .{hostile});
    defer allocator.free(md);

    const bytes = try generateFromMarkdown(allocator, md);
    defer allocator.free(bytes);

    const data = try allocator.dupe(u8, bytes);
    var archive = try zip.ZipArchive.openFromMemory(allocator, data);
    defer archive.close();

    const doc_xml = try archive.extract(archive.findEntry("word/document.xml").?);
    defer allocator.free(doc_xml);

    // The dangerous bytes must not appear as markup anywhere in the part.
    try std.testing.expect(std.mem.indexOf(u8, doc_xml, "<script") == null);
    try std.testing.expect(std.mem.indexOf(u8, doc_xml, "]]>") == null);
    // ...and must be present in escaped form.
    try std.testing.expect(std.mem.indexOf(u8, doc_xml, "&lt;script&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc_xml, "ampersand &amp; and") != null);

    // Reading the document back reproduces the original text verbatim, which
    // is what ElementTree reports for the same file.
    var doc = try docx.parseDocument(allocator, &archive);
    defer doc.deinit();

    var found = false;
    for (doc.elements) |elem| {
        if (elem != .paragraph) continue;
        var text: std.ArrayListUnmanaged(u8) = .empty;
        defer text.deinit(allocator);
        for (elem.paragraph.runs) |run| try text.appendSlice(allocator, run.text);
        if (std.mem.eql(u8, text.items, expected_text)) found = true;
    }
    try std.testing.expect(found);
}

test "anchor: unsafe markdown link schemes never become external relationships" {
    const allocator = std.testing.allocator;

    // H3 on the writer path: a script-bearing destination must not surface in
    // word/_rels/document.xml.rels as a live TargetMode="External" target,
    // while an allowlisted scheme must survive intact.
    const md =
        "A [live link](https://example.com/ok) and " ++
        "an [attack link](javascript:alert(1)) in one paragraph.\n";

    const bytes = try generateFromMarkdown(allocator, md);
    defer allocator.free(bytes);

    const data = try allocator.dupe(u8, bytes);
    var archive = try zip.ZipArchive.openFromMemory(allocator, data);
    defer archive.close();

    const rels_xml = try archive.extract(archive.findEntry("word/_rels/document.xml.rels").?);
    defer allocator.free(rels_xml);
    try std.testing.expect(std.mem.indexOf(u8, rels_xml, "javascript:") == null);
    try std.testing.expect(std.mem.indexOf(u8, rels_xml, "https://example.com/ok") != null);

    // The unsafe link's visible text is kept as plain text, not dropped.
    const doc_xml = try archive.extract(archive.findEntry("word/document.xml").?);
    defer allocator.free(doc_xml);
    try std.testing.expect(std.mem.indexOf(u8, doc_xml, "attack link") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc_xml, "javascript:") == null);
}

// =============================================================================
// Anchor 3 — malformed archives are refused (APPNOTE-shaped negative vectors)
// =============================================================================

/// Rewrite the first central-directory field matching `needle` with `patch`.
fn patchCentralDirectory(bytes: []u8, offset_in_record: usize, value: u32) void {
    const eocd = bytes.len - 22;
    const cd_offset = readU32Le(bytes, eocd + 16);
    std.mem.writeInt(u32, bytes[cd_offset + offset_in_record ..][0..4], value, .little);
}

test "anchor: a tampered entry fails CRC verification" {
    const allocator = std.testing.allocator;

    const bytes = try generateFromMarkdown(allocator, "# T\n\nbody\n");
    defer allocator.free(bytes);

    const data = try allocator.dupe(u8, bytes);
    // APPNOTE §4.3.12: CRC-32 is at offset 16 of a central-directory record.
    patchCentralDirectory(data, 16, 0xDEADBEEF);

    var archive = try zip.ZipArchive.openFromMemory(allocator, data);
    defer archive.close();
    try std.testing.expectError(
        zip.ZipError.ChecksumMismatch,
        archive.extract(&archive.entries[0]),
    );
}

test "anchor: ZIP64 sentinels are refused rather than read literally" {
    const allocator = std.testing.allocator;

    const bytes = try generateFromMarkdown(allocator, "# T\n\nbody\n");
    defer allocator.free(bytes);

    // APPNOTE §4.3.12: uncompressed size at offset 24 of a CD record. 0xFFFFFFFF
    // is the ZIP64 sentinel — the real value lives in a 0x0001 extra field.
    {
        const data = try allocator.dupe(u8, bytes);
        defer allocator.free(data);
        patchCentralDirectory(data, 24, 0xFFFFFFFF);
        try std.testing.expectError(
            zip.ZipError.Zip64Unsupported,
            zip.ZipArchive.openFromMemory(allocator, data),
        );
    }

    // Same for the local-header offset at CD record offset 42.
    {
        const data = try allocator.dupe(u8, bytes);
        defer allocator.free(data);
        patchCentralDirectory(data, 42, 0xFFFFFFFF);
        try std.testing.expectError(
            zip.ZipError.Zip64Unsupported,
            zip.ZipArchive.openFromMemory(allocator, data),
        );
    }
}

test "anchor: a central directory that overruns the archive is refused" {
    const allocator = std.testing.allocator;

    const bytes = try generateFromMarkdown(allocator, "# T\n\nbody\n");
    defer allocator.free(bytes);

    const data = try allocator.dupe(u8, bytes);
    defer allocator.free(data);

    // Grow the declared central-directory size past the EOCD it precedes.
    const eocd = data.len - 22;
    const cd_size = readU32Le(data, eocd + 12);
    std.mem.writeInt(u32, data[eocd + 12 ..][0..4], cd_size + 4096, .little);

    try std.testing.expectError(
        zip.ZipError.CorruptArchive,
        zip.ZipArchive.openFromMemory(allocator, data),
    );
}

test "anchor: duplicate entry names are refused" {
    const allocator = std.testing.allocator;

    // Two central-directory records for the same name, both pointing at the
    // same (valid) local header — the classic OOXML parser-differential trick,
    // where the reader and the consumer disagree on which part is real.
    const name = "word/document.xml";
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    const body = "<x/>";
    const crc = std.hash.crc.Crc32.hash(body);

    // Local file header (APPNOTE §4.3.7), STORED.
    const local_offset: u32 = 0;
    try appendU32(allocator, &buf, APPNOTE_LOCAL_HEADER_SIG);
    try appendU16(allocator, &buf, 20); // version needed
    try appendU16(allocator, &buf, 0); // flags
    try appendU16(allocator, &buf, 0); // method: stored
    try appendU16(allocator, &buf, 0); // time
    try appendU16(allocator, &buf, 0); // date
    try appendU32(allocator, &buf, crc);
    try appendU32(allocator, &buf, body.len);
    try appendU32(allocator, &buf, body.len);
    try appendU16(allocator, &buf, @intCast(name.len));
    try appendU16(allocator, &buf, 0); // extra len
    try buf.appendSlice(allocator, name);
    try buf.appendSlice(allocator, body);

    const cd_offset: u32 = @intCast(buf.items.len);
    for (0..2) |_| {
        try appendU32(allocator, &buf, APPNOTE_CENTRAL_DIR_SIG);
        try appendU16(allocator, &buf, 20); // version made by
        try appendU16(allocator, &buf, 20); // version needed
        try appendU16(allocator, &buf, 0); // flags
        try appendU16(allocator, &buf, 0); // method
        try appendU16(allocator, &buf, 0); // time
        try appendU16(allocator, &buf, 0); // date
        try appendU32(allocator, &buf, crc);
        try appendU32(allocator, &buf, body.len);
        try appendU32(allocator, &buf, body.len);
        try appendU16(allocator, &buf, @intCast(name.len));
        try appendU16(allocator, &buf, 0); // extra len
        try appendU16(allocator, &buf, 0); // comment len
        try appendU16(allocator, &buf, 0); // disk start
        try appendU16(allocator, &buf, 0); // internal attrs
        try appendU32(allocator, &buf, 0); // external attrs
        try appendU32(allocator, &buf, local_offset);
        try buf.appendSlice(allocator, name);
    }
    const cd_size: u32 = @as(u32, @intCast(buf.items.len)) - cd_offset;

    try appendU32(allocator, &buf, APPNOTE_EOCD_SIG);
    try appendU16(allocator, &buf, 0); // disk number
    try appendU16(allocator, &buf, 0); // cd start disk
    try appendU16(allocator, &buf, 2); // entries this disk
    try appendU16(allocator, &buf, 2); // total entries
    try appendU32(allocator, &buf, cd_size);
    try appendU32(allocator, &buf, cd_offset);
    try appendU16(allocator, &buf, 0); // comment len

    const data = try allocator.dupe(u8, buf.items);
    defer allocator.free(data);
    try std.testing.expectError(
        zip.ZipError.DuplicateEntry,
        zip.ZipArchive.openFromMemory(allocator, data),
    );
}

fn appendU16(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), v: u16) !void {
    try buf.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(u16, v)));
}

fn appendU32(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), v: u32) !void {
    try buf.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(u32, v)));
}

// =============================================================================
// Anchor 4 — media names cannot escape an output directory (M7)
// =============================================================================

test "media name sanitizer rejects traversal, separators and control bytes" {
    // Accepted: a plain single component under media/.
    try std.testing.expectEqualStrings(
        "media/image1.png",
        docx.sanitizeMediaName("media/image1.png").?,
    );

    const rejected = [_][]const u8{
        "media/../../../etc/passwd",
        "media/..",
        "media/.",
        "media/sub/dir.png",
        "media/back\\slash.png",
        "media/nul\x00.png",
        "media/\x01ctrl.png",
        "media/",
        "notmedia/image1.png",
        "/media/image1.png",
    };
    for (rejected) |name| {
        try std.testing.expect(docx.sanitizeMediaName(name) == null);
    }

    // A rel target that walks out still matches only on its basename, so the
    // sanitized side and the lookup side stay in sync.
    try std.testing.expect(docx.mediaNameMatches("media/image1.png", "../../media/image1.png"));
    try std.testing.expect(!docx.mediaNameMatches("media/image1.png", "media/image2.png"));
}
