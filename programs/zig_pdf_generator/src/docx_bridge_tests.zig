//! Tests for the Word bridges. The Word documents are built here: one from
//! zig_docx's own writer, and one from hand-written WordprocessingML shaped
//! like Word's output (revision ids, proofing marks, placeholders split
//! across runs, autocorrected quotes).

const std = @import("std");
const zdocx = @import("zig_docx");
const zl = @import("zig_legend");
const bridge = @import("docx_bridge.zig");
const legend_letter = @import("legend_letter.zig");
const ffi = @import("ffi.zig");

const testing = std.testing;

/// A 1x1 red PNG.
pub const tiny_png = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x02\x00\x00\x00\x90\x77\x53\xde\x00\x00\x00\x0cIDAT\x08\xd7\x63\xf8\xcf\xc0\x00\x00\x03\x01\x01\x00\x18\xdd\x8d\xb0\x00\x00\x00\x00IEND\xae\x42\x60\x82";

/// A minimal DOCX around `body_xml` (the children of `w:body`), optionally
/// with one image part referenced as r:embed="rIdImg1".
pub fn buildDocx(a: std.mem.Allocator, body_xml: []const u8, png: ?[]const u8) ![]u8 {
    var zw = zdocx.zip_writer.ZipWriter.init(a);
    defer zw.deinit();
    try zw.addFile("[Content_Types].xml",
        \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        \\<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="png" ContentType="image/png"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>
    );
    try zw.addFile("_rels/.rels",
        \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        \\<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
    );
    try zw.addFile("word/_rels/document.xml.rels",
        \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        \\<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rIdImg1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/image1.png"/></Relationships>
    );
    if (png) |p| try zw.addFile("word/media/image1.png", p);
    const doc = try std.fmt.allocPrint(a,
        \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        \\<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">
        \\<w:body>{s}<w:sectPr/></w:body></w:document>
    , .{body_xml});
    defer a.free(doc);
    try zw.addFile("word/document.xml", doc);
    return zw.finish();
}

/// A letter as Word writes it: runs split mid-placeholder by proofing and
/// revision marks, half a placeholder in bold, curly quotes in a condition,
/// a no-break space and a zero-width space inside tags, full-width braces,
/// a space-only run, a tracked deletion, a table, and a picture.
pub const word_style_body =
    \\<w:p w:rsidR="00A1" w:rsidRDefault="00A1"><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Account statement</w:t></w:r></w:p>
    \\<w:p w:rsidR="00A1"><w:r w:rsidRPr="00B2"><w:rPr><w:lang w:val="en-GB"/></w:rPr><w:t>Dear</w:t></w:r><w:r><w:t xml:space="preserve"> </w:t></w:r><w:r><w:t>{CLI</w:t></w:r><w:proofErr w:type="spellStart"/><w:r w:rsidR="00C3"><w:rPr><w:b/></w:rPr><w:t>ENT_NA</w:t></w:r><w:proofErr w:type="spellEnd"/><w:bookmarkStart w:id="0" w:name="_GoBack"/><w:bookmarkEnd w:id="0"/><w:r><w:t>ME},</w:t></w:r></w:p>
    \\<w:p><w:r><w:t xml:space="preserve">Invoice </w:t></w:r><w:r><w:t xml:space="preserve">{ INVOICE_NO }</w:t></w:r><w:r><w:t xml:space="preserve"> is </w:t></w:r><w:r><w:rPr><w:b/></w:rPr><w:t>overdue</w:t></w:r><w:del w:id="1" w:author="A. Clerk"><w:r><w:delText>very</w:delText></w:r></w:del><w:r><w:t>.</w:t></w:r></w:p>
    \\<w:p><w:r><w:t>{?STATUS=</w:t></w:r><w:r><w:t>“part_paid”}</w:t></w:r></w:p>
    \\<w:p><w:r><w:t xml:space="preserve">Thank you for your payment. The balance is </w:t></w:r><w:r><w:t>{AMOUNT|pl</w:t></w:r><w:r><w:t>ain}.</w:t></w:r></w:p>
    \\<w:p><w:r><w:t>{:}</w:t></w:r></w:p>
    \\<w:p><w:r><w:t xml:space="preserve">Please pay by </w:t></w:r><w:r><w:t>｛DUE_&#x200B;DATE|long｝</w:t></w:r><w:r><w:t>.</w:t></w:r></w:p>
    \\<w:p><w:r><w:t>{/}</w:t></w:r></w:p>
    \\<w:tbl><w:tr><w:tc><w:p><w:r><w:t>Item</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>Amount</w:t></w:r></w:p></w:tc></w:tr><w:tr><w:tc><w:p><w:r><w:t>Balance</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>{AMOUNT}</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
    \\<w:p><w:r><w:drawing><wp:inline><wp:extent cx="95250" cy="95250"/><a:graphic><a:graphicData><pic:pic><pic:blipFill><a:blip r:embed="rIdImg1"/></pic:blipFill></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>
    \\<w:p><w:r><w:t>Yours sincerely,</w:t></w:r></w:p>
;

fn has(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

test "docx bridge: placeholders split across Word runs survive" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const docx_bytes = try buildDocx(a, word_style_body, tiny_png);

    var diag = bridge.Diagnostic{};
    const r = bridge.docxToLegendTemplate(a, docx_bytes, &diag) catch |err| {
        std.debug.print("refused: {s}\n", .{diag.text()});
        return err;
    };
    // Split, bolded half, and the space-only run.
    try testing.expect(has(r.template, "Dear {CLIENT_NAME},"));
    try testing.expect(!has(r.template, "{CLI**"));
    // NBSP-free trim inside braces; tracked deletion dropped; bold kept outside tags.
    try testing.expect(has(r.template, "Invoice {INVOICE_NO} is **overdue**."));
    try testing.expect(!has(r.template, "very"));
    // Curly quotes straightened, full-width braces and zero-width space repaired.
    try testing.expect(has(r.template, "{?STATUS=\"part_paid\"}"));
    try testing.expect(has(r.template, "{DUE_DATE|long}"));
    try testing.expect(has(r.template, "{AMOUNT|plain}"));
    try testing.expect(has(r.template, "| Balance | {AMOUNT} |"));
    try testing.expect(has(r.template, "![Image 1](1-image1.png)"));
    try testing.expectEqual(@as(usize, 1), r.images.len);

    const want = [_][]const u8{ "CLIENT_NAME", "INVOICE_NO", "STATUS", "AMOUNT", "DUE_DATE" };
    try testing.expectEqual(want.len, r.placeholders.len);
    for (want, r.placeholders) |w, got| try testing.expectEqualStrings(w, got);

    // The drafted legend loads and types the placeholders from their use.
    var ld = zl.Diag{};
    const legend = zl.Legend.load(a, r.legend_toml, &ld) catch |err| {
        std.debug.print("legend: {s}\n{s}\n", .{ ld.text(), r.legend_toml });
        return err;
    };
    try testing.expect(legend.find("STATUS").?.kind == .enum_);
    try testing.expectEqualStrings("part_paid", legend.find("STATUS").?.values[0]);
    try testing.expect(legend.find("AMOUNT").?.kind == .money);
    try testing.expect(legend.find("DUE_DATE").?.kind == .date);
    try testing.expect(legend.find("CLIENT_NAME").?.kind == .string);
}

test "docx bridge: a Word template renders as a legend letter, both branches" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag = bridge.Diagnostic{};
    const r = try bridge.docxToLegendTemplate(a, try buildDocx(a, word_style_body, tiny_png), &diag);

    for ([_][]const u8{ "part_paid", "unpaid" }) |status| {
        // Legend: the draft, with the STATUS enum widened to both outcomes.
        const legend_src = try std.mem.replaceOwned(u8, a, r.legend_toml, "values = [\"part_paid\"]", "values = [\"part_paid\", \"unpaid\"]");
        var root = std.json.ObjectMap.empty;
        var bindings = std.json.ObjectMap.empty;
        try bindings.put(a, "CLIENT_NAME", .{ .string = "Ms Alex Morgan" });
        try bindings.put(a, "INVOICE_NO", .{ .string = "INV-1043" });
        try bindings.put(a, "STATUS", .{ .string = status });
        try bindings.put(a, "AMOUNT", .{ .string = "480.00" });
        try bindings.put(a, "DUE_DATE", .{ .string = "2026-10-15" });
        var images = std.json.Array.init(a);
        var img = std.json.ObjectMap.empty;
        try img.put(a, "name", .{ .string = r.images[0].name });
        const enc = std.base64.standard.Encoder;
        const b64 = try a.alloc(u8, enc.calcSize(r.images[0].bytes.len));
        _ = enc.encode(b64, r.images[0].bytes);
        try img.put(a, "data", .{ .string = b64 });
        try images.append(.{ .object = img });
        var frame = std.json.ObjectMap.empty;
        try frame.put(a, "company_name", .{ .string = "Harbourlight Joinery Ltd" });
        try frame.put(a, "images", .{ .array = images });
        try root.put(a, "legend_toml", .{ .string = legend_src });
        try root.put(a, "template", .{ .string = r.template });
        try root.put(a, "bindings", .{ .object = bindings });
        try root.put(a, "letter", .{ .object = frame });
        const input = try std.json.Stringify.valueAlloc(a, std.json.Value{ .object = root }, .{});

        var ldiag = legend_letter.Diagnostic{};
        const rendered = legend_letter.renderText(a, input, &ldiag) catch |err| {
            std.debug.print("{s}\n", .{ldiag.text()});
            return err;
        };
        try testing.expect(has(rendered.body_markdown, "Dear Ms Alex Morgan,"));
        if (std.mem.eql(u8, status, "part_paid")) {
            try testing.expect(has(rendered.body_markdown, "The balance is 480.00."));
        } else {
            try testing.expect(has(rendered.body_markdown, "Please pay by 15 October 2026."));
        }
        const pdf = try legend_letter.generate(testing.allocator, input, &ldiag);
        defer testing.allocator.free(pdf);
        try testing.expect(has(pdf, "/Subtype /Image"));
    }
}

test "docx bridge: a docx from zig_docx's writer round-trips its placeholders" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const md = "# Reminder\n\nDear {CLIENT_NAME},\n\nYour balance of **{AMOUNT|plain}** is due on {DUE_DATE|long}.\n\n{?PLAN}We can offer instalments.{/}\n";
    const res = zdocx.ffi.zig_docx_md_to_docx_with_images(md.ptr, md.len, null, null, 0);
    try testing.expect(res.data != null);
    defer zdocx.ffi.zig_docx_free(res.data, res.len);

    var diag = bridge.Diagnostic{};
    const r = bridge.docxToLegendTemplate(a, res.data.?[0..res.len], &diag) catch |err| {
        std.debug.print("refused: {s}\n", .{diag.text()});
        return err;
    };
    try testing.expect(has(r.template, "Dear {CLIENT_NAME},"));
    try testing.expect(has(r.template, "**{AMOUNT|plain}**"));
    const want = [_][]const u8{ "CLIENT_NAME", "AMOUNT", "DUE_DATE", "PLAN" };
    try testing.expectEqual(want.len, r.placeholders.len);
    for (want, r.placeholders) |w, got| try testing.expectEqualStrings(w, got);
    try testing.expect(has(r.legend_toml, "name = \"PLAN\"\ntype = \"bool\""));
}

test "docx bridge: non-DOCX input and broken templates are refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag = bridge.Diagnostic{};
    try testing.expectError(error.NotDocx, bridge.docxToLegendTemplate(a, "%PDF-1.4 not a docx", &diag));
    try testing.expect(has(diag.text(), "not a DOCX"));
    try testing.expectError(error.NotDocx, bridge.docxToLetter(testing.allocator, "", "", &diag));

    // A ZIP that is not a Word document.
    var zw = zdocx.zip_writer.ZipWriter.init(a);
    try zw.addFile("hello.txt", "hi");
    const zip_only = try zw.finish();
    try testing.expectError(error.NotDocx, bridge.docxToLegendTemplate(a, zip_only, &diag));
    try testing.expect(has(diag.text(), "word/document.xml"));

    // An unclosed block in the Word text.
    const broken = try buildDocx(a, "<w:p><w:r><w:t>{?PAID}Thanks.</w:t></w:r></w:p>", null);
    try testing.expectError(error.TemplateInvalid, bridge.docxToLegendTemplate(a, broken, &diag));
    try testing.expect(has(diag.text(), "not a valid template"));

    // Through the C API: NULL and the reason.
    var len: usize = 0;
    const junk = "PK\x03\x04 truncated";
    try testing.expect(ffi.zigpdf_docx_to_legend_template(junk.ptr, junk.len, &len) == null);
    try testing.expect(std.mem.startsWith(u8, std.mem.span(ffi.zigpdf_get_error()), "DOCX: "));
}

test "docx bridge: a Word document becomes a letter PDF with its image" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const docx_bytes = try buildDocx(a, word_style_body, tiny_png);
    var len: usize = 0;
    const frame = "{\"company_name\":\"Harbourlight Joinery Ltd\",\"date\":\"15 September 2026\",\"recipient_name\":\"Ms Alex Morgan\"}";
    const pdf = ffi.zigpdf_docx_to_letter(docx_bytes.ptr, docx_bytes.len, frame, &len) orelse {
        std.debug.print("{s}\n", .{std.mem.span(ffi.zigpdf_get_error())});
        return error.TestUnexpectedNull;
    };
    defer ffi.zigpdf_free(pdf, len);
    const bytes = pdf[0..len];
    try testing.expect(std.mem.startsWith(u8, bytes, "%PDF-"));
    try testing.expect(has(bytes, "/Subtype /Image"));

    // No frame at all is allowed.
    const bare = ffi.zigpdf_docx_to_letter(docx_bytes.ptr, docx_bytes.len, null, &len) orelse return error.TestUnexpectedNull;
    ffi.zigpdf_free(bare, len);
    // A frame that is not JSON is refused.
    try testing.expect(ffi.zigpdf_docx_to_letter(docx_bytes.ptr, docx_bytes.len, "{nope", &len) == null);
}

test "docx bridge: a legend letter becomes an editable Word document" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const enc = std.base64.standard.Encoder;
    const b64 = try a.alloc(u8, enc.calcSize(tiny_png.len));
    _ = enc.encode(b64, tiny_png);
    const input = try std.fmt.allocPrint(a,
        \\{{"legend_toml": "[[var]]\nname = \"NAME\"\nrequired = true\n[[var]]\nname = \"AMOUNT\"\ntype = \"money\"\ncurrency = \"GBP\"\nrequired = true\n",
        \\ "template": "Dear {{NAME}},\n\nYour balance is **{{AMOUNT}}**.\n\n| Item | Amount |\n|---|---|\n| Balance | {{AMOUNT}} |\n",
        \\ "bindings": {{"NAME": "Ms Morgan", "AMOUNT": "960"}},
        \\ "letter": {{"company_name": "Harbourlight Joinery Ltd", "company_address": "Unit 4|Anytown|ZZ9 9ZZ",
        \\   "date": "15 September 2026", "reference": "HJ-1", "recipient_name": "Ms Alex Morgan",
        \\   "recipient_address": "9 Linden Road|Southgate Vale", "subject": "Balance for {{NAME}}",
        \\   "closing": "Yours sincerely,", "signature_name": "Sam Hollis", "signature_title": "Director",
        \\   "letterhead_image": "data:image/png;base64,{s}"}}}}
    , .{b64});
    const z = try a.dupeZ(u8, input);
    var len: usize = 0;
    const docx_ptr = ffi.zigpdf_legend_letter_to_docx(z, &len) orelse {
        std.debug.print("{s}\n", .{std.mem.span(ffi.zigpdf_get_error())});
        return error.TestUnexpectedNull;
    };
    defer ffi.zigpdf_free(docx_ptr, len);
    const bytes = docx_ptr[0..len];
    try testing.expect(std.mem.startsWith(u8, bytes, "PK\x03\x04"));
    try testing.expect(has(bytes, "word/media/"));

    // Read it back with zig_docx: the letter text is there.
    var diag = bridge.Diagnostic{};
    const conv = try bridge.docxToMarkdown(a, bytes, .letter, &diag);
    for ([_][]const u8{ "15 September 2026", "Ref: HJ-1", "Ms Alex Morgan", "Re: Balance for Ms Morgan", "Dear Ms Morgan,", "£960.00", "| Balance | £960.00 |", "Yours sincerely,", "Sam Hollis" }) |want| {
        if (!has(conv.markdown, want)) {
            std.debug.print("missing '{s}' in:\n{s}\n", .{ want, conv.markdown });
            return error.TestExpectedText;
        }
    }
    // A bad binding is refused before any .docx is written.
    const bad = try std.mem.replaceOwned(u8, a, z, "\"960\"", "\"9,60\"");
    const bad_z = try a.dupeZ(u8, bad);
    try testing.expect(ffi.zigpdf_legend_letter_to_docx(bad_z, &len) == null);
    try testing.expect(has(std.mem.span(ffi.zigpdf_get_error()), "not an amount"));
}
