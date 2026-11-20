//! Tests for fillable form fields: the writer (document.FormField,
//! presentation `text_field` / `checkbox`) and the reader (pdf_form_reader).
//!
//! External anchors (inputs and expected values from software this package
//! did not write) live in tests/fixtures/forms/ and are described in its
//! README. The write-then-read tests here are roundtrips: they check the two
//! halves agree, not that either is right.

const std = @import("std");
const testing = std.testing;
const document = @import("document.zig");
const presentation = @import("presentation.zig");
const reader = @import("pdf_form_reader.zig");

fn readJson(pdf: []const u8) ![]u8 {
    return reader.readFormFieldsJson(testing.allocator, pdf);
}

fn expectJson(pdf: []const u8, expected: []const u8) !void {
    const got = try readJson(pdf);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

/// The object `N 0 obj … endobj` as written (test builds leave streams
/// uncompressed, so appearance streams are readable too).
fn objectText(pdf: []const u8, num: u32) ![]const u8 {
    var head_buf: [24]u8 = undefined;
    const head = try std.fmt.bufPrint(&head_buf, "\n{d} 0 obj\n", .{num});
    const start = std.mem.indexOf(u8, pdf, head) orelse return error.ObjectMissing;
    const end = std.mem.indexOfPos(u8, pdf, start + head.len, "endobj") orelse return error.ObjectMissing;
    return pdf[start + head.len .. end];
}

fn onePageDoc(allocator: std.mem.Allocator) !document.PdfDocument {
    var doc = document.PdfDocument.init(allocator);
    errdefer doc.deinit();
    _ = doc.addFont(.helvetica);
    var cs = document.ContentStream.init(allocator);
    defer cs.deinit();
    try cs.drawText("Ze:", 72, 700, "F0", 10, document.Color.black);
    try doc.addPage(&cs);
    return doc;
}

// -----------------------------------------------------------------------------
// Writer: structure
// -----------------------------------------------------------------------------

test "a document without form fields writes no AcroForm and the same catalog as before" {
    var doc = try onePageDoc(testing.allocator);
    defer doc.deinit();
    const pdf = try doc.build();
    try testing.expectEqualStrings("<< /Type /Catalog /Pages 2 0 R >>\n", try objectText(pdf, 1));
    try testing.expect(std.mem.indexOf(u8, pdf, "/AcroForm") == null);
    try testing.expect(std.mem.indexOf(u8, pdf, "/Widget") == null);
}

test "a text field is a widget on its page, listed in /AcroForm /Fields, with an appearance stream" {
    var doc = try onePageDoc(testing.allocator);
    defer doc.deinit();
    try doc.addFormField(.{ .name = "ze", .x = 100, .y = 690, .width = 80, .height = 18, .tooltip = "Ze (ohms)" });
    const pdf = try doc.build();

    try testing.expectEqualStrings("<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>\n", try objectText(pdf, 1));
    const acro = try objectText(pdf, 3);
    try testing.expect(std.mem.indexOf(u8, acro, "/Fields [ ") != null);
    try testing.expect(std.mem.indexOf(u8, acro, "/DA (/Helv 0 Tf 0 g)") != null);
    try testing.expect(std.mem.indexOf(u8, acro, "/DR << /Font << /Helv ") != null);

    // Object layout: 1 catalog, 2 pages, 3 AcroForm, 4 font F0, 5 page,
    // 6 content, 7 /Helv, 8 /ZaDb, 9 widget, 10 appearance.
    try testing.expect(std.mem.indexOf(u8, acro, "/Fields [ 9 0 R ]") != null);
    try testing.expect(std.mem.indexOf(u8, try objectText(pdf, 5), "/Annots [ 9 0 R ]") != null);
    const w = try objectText(pdf, 9);
    for ([_][]const u8{
        "/Type /Annot", "/Subtype /Widget",          "/FT /Tx",                     "/T (ze)",
        "/TU (Ze \\(ohms\\))", "/Rect [100.00 690.00 180.00 708.00]", "/F 4", "/P 5 0 R",
        "/MK << /BC [0.400 0.400 0.400] >>",         "/DA (/Helv 10.00 Tf 0.000 0.000 0.000 rg)", "/AP << /N 10 0 R >>",
    }) |needle| {
        if (std.mem.indexOf(u8, w, needle) == null) {
            std.debug.print("widget lacks {s}:\n{s}\n", .{ needle, w });
            return error.TestExpectedEqual;
        }
    }
    // No value: no /V, so a reader reports nothing for it.
    try testing.expect(std.mem.indexOf(u8, w, "/V ") == null);

    const ap = try objectText(pdf, 10);
    try testing.expect(std.mem.indexOf(u8, ap, "/Subtype /Form /BBox [0 0 80.00 18.00]") != null);
    // The outline is drawn even with no value, so the box shows in a viewer
    // that never builds appearances of its own.
    try testing.expect(std.mem.indexOf(u8, ap, "0.50 0.50 79.00 17.00 re\nS\n") != null);
    try testing.expect(std.mem.indexOf(u8, ap, "/Tx BMC\nEMC\n") != null);
}

test "names, values and tooltips are escaped, and non-ASCII text is UTF-16BE" {
    var doc = try onePageDoc(testing.allocator);
    defer doc.deinit();
    try doc.addFormField(.{ .name = "a(b)\\c", .x = 10, .y = 10, .width = 50, .height = 12, .value = "line1\nline2\r)" });
    try doc.addFormField(.{ .name = "caf\u{e9}", .x = 10, .y = 30, .width = 50, .height = 12, .value = "\u{a3}5 \u{1F600}" });
    const pdf = try doc.build();
    try testing.expect(std.mem.indexOf(u8, pdf, "/T (a\\(b\\)\\\\c)") != null);
    try testing.expect(std.mem.indexOf(u8, pdf, "/V (line1\\nline2\\r\\))") != null);
    // "café" = FE FF 0063 0061 0066 00E9; "£5 😀" has a surrogate pair.
    try testing.expect(std.mem.indexOf(u8, pdf, "/T <feff00630061006600e9>") != null);
    try testing.expect(std.mem.indexOf(u8, pdf, "/V <feff00a300350020d83dde00>") != null);
}

test "a checkbox has /Yes and /Off appearances and its state in /V and /AS" {
    var doc = try onePageDoc(testing.allocator);
    defer doc.deinit();
    try doc.addFormField(.{ .kind = .checkbox, .name = "on", .x = 10, .y = 10, .width = 12, .height = 12, .checked = true });
    try doc.addFormField(.{ .kind = .checkbox, .name = "off", .x = 30, .y = 10, .width = 12, .height = 12 });
    const pdf = try doc.build();
    // 7 /Helv, 8 /ZaDb, 9 widget "on" (10 /Yes, 11 /Off), 12 widget "off".
    const on = try objectText(pdf, 9);
    try testing.expect(std.mem.indexOf(u8, on, "/FT /Btn") != null);
    try testing.expect(std.mem.indexOf(u8, on, "/V /Yes /AS /Yes") != null);
    try testing.expect(std.mem.indexOf(u8, on, "/MK << /BC [0.400 0.400 0.400] /CA (4) >>") != null);
    try testing.expect(std.mem.indexOf(u8, on, "/AP << /N << /Yes 10 0 R /Off 11 0 R >> >>") != null);
    try testing.expect(std.mem.indexOf(u8, try objectText(pdf, 12), "/V /Off /AS /Off") != null);
    try testing.expect(std.mem.indexOf(u8, try objectText(pdf, 10), "(4) Tj") != null);
    try testing.expect(std.mem.indexOf(u8, try objectText(pdf, 11), "Tj") == null);
    try testing.expect(std.mem.indexOf(u8, try objectText(pdf, 3), "/Fields [ 9 0 R 12 0 R ]") != null);
}

test "fields attach to their own page, after that page's links" {
    var doc = document.PdfDocument.init(testing.allocator);
    defer doc.deinit();
    _ = doc.addFont(.helvetica);
    for (0..2) |_| {
        var cs = document.ContentStream.init(testing.allocator);
        defer cs.deinit();
        try doc.addPage(&cs);
    }
    doc.setAnnotationPage(1);
    try doc.addLinkAnnotation(10, 10, 50, 20, "https://example.com");
    try doc.addFormField(.{ .name = "p0", .page = 0, .x = 10, .y = 40, .width = 40, .height = 12 });
    try doc.addFormField(.{ .name = "p1", .page = 1, .x = 10, .y = 40, .width = 40, .height = 12 });
    const pdf = try doc.build();
    // 1 catalog, 2 pages, 3 AcroForm, 4 F0, 5/6 page 0, 7/8 page 1, 9 link,
    // 10 /Helv, 11 /ZaDb, 12 widget p0, 13 its AP, 14 widget p1, 15 its AP.
    try testing.expect(std.mem.indexOf(u8, try objectText(pdf, 5), "/Annots [ 12 0 R ]") != null);
    try testing.expect(std.mem.indexOf(u8, try objectText(pdf, 7), "/Annots [ 9 0 R 14 0 R ]") != null);
    try testing.expect(std.mem.indexOf(u8, try objectText(pdf, 14), "/P 7 0 R") != null);
}

test "a page with many fields (a long /Annots array) is still written" {
    var doc = try onePageDoc(testing.allocator);
    defer doc.deinit();
    var name_buf: [16]u8 = undefined;
    for (0..120) |k| {
        const name = try std.fmt.bufPrint(&name_buf, "f{d}", .{k});
        const row: f32 = @floatFromInt(k % 40);
        const col: f32 = @floatFromInt(k / 40);
        try doc.addFormField(.{ .name = name, .x = 40 + col * 150, .y = 40 + row * 18, .width = 120, .height = 14 });
    }
    const pdf = try doc.build();
    // Object 5 is the page: its /Annots lists all 120 widgets.
    const page = try objectText(pdf, 5);
    try testing.expect(std.mem.startsWith(u8, page, "<< /Type /Page "));
    try testing.expectEqual(@as(usize, 120), std.mem.count(u8, page[std.mem.indexOf(u8, page, "/Annots").?..], " 0 R"));
    const got = try readJson(pdf);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("{}", got);
}

test "addFormField refuses bad names and rectangles; build refuses a missing page" {
    var doc = try onePageDoc(testing.allocator);
    defer doc.deinit();
    try testing.expectError(error.FormFieldNameEmpty, doc.addFormField(.{ .name = "", .x = 0, .y = 0, .width = 10, .height = 10 }));
    try testing.expectError(error.FormFieldNameHasPeriod, doc.addFormField(.{ .name = "a.b", .x = 0, .y = 0, .width = 10, .height = 10 }));
    try testing.expectError(error.FormFieldTextNotUtf8, doc.addFormField(.{ .name = "a", .value = "\xff", .x = 0, .y = 0, .width = 10, .height = 10 }));
    try testing.expectError(error.FormFieldRectInvalid, doc.addFormField(.{ .name = "a", .x = 0, .y = 0, .width = 0, .height = 10 }));
    try testing.expectError(error.FormFieldRectInvalid, doc.addFormField(.{ .name = "a", .x = std.math.nan(f32), .y = 0, .width = 5, .height = 10 }));
    try doc.addFormField(.{ .name = "a", .x = 0, .y = 0, .width = 10, .height = 10 });
    try testing.expectError(error.DuplicateFormFieldName, doc.addFormField(.{ .name = "a", .x = 0, .y = 0, .width = 10, .height = 10 }));

    var two = try onePageDoc(testing.allocator);
    defer two.deinit();
    try two.addFormField(.{ .name = "late", .page = 1, .x = 0, .y = 0, .width = 10, .height = 10 });
    try testing.expectError(error.FormFieldPageOutOfRange, two.build());
}

test "an encrypted document encrypts field strings and appearance streams" {
    var doc = try onePageDoc(testing.allocator);
    defer doc.deinit();
    try doc.addFormField(.{ .name = "secret_name", .x = 10, .y = 10, .width = 60, .height = 14, .value = "secret value" });
    var seed: [32]u8 = undefined;
    for (&seed, 1..) |*b, i| b.* = @truncate(i);
    try doc.enableEncryption("", "owner", document.DEFAULT_PERMS, seed);
    const pdf = try doc.build();
    try testing.expect(std.mem.indexOf(u8, pdf, "secret") == null);
    try testing.expect(std.mem.indexOf(u8, pdf, "Helv 10") == null);
    // The empty user password opens it, and the reader decrypts the values.
    try expectJson(pdf, "{\"secret_name\":\"secret value\"}");
}

// -----------------------------------------------------------------------------
// Roundtrips (the writer and reader agree; not anchors)
// -----------------------------------------------------------------------------

test "roundtrip: values, blanks and checkboxes read back in document order" {
    var doc = try onePageDoc(testing.allocator);
    defer doc.deinit();
    try doc.addFormField(.{ .name = "blank", .x = 10, .y = 10, .width = 60, .height = 14 });
    try doc.addFormField(.{ .name = "filled", .x = 10, .y = 30, .width = 60, .height = 14, .value = "0.35" });
    try doc.addFormField(.{ .name = "unicode", .x = 10, .y = 50, .width = 60, .height = 14, .value = "Caf\u{e9} \u{a3}5 \u{1F600}" });
    try doc.addFormField(.{ .name = "notes", .x = 10, .y = 70, .width = 60, .height = 40, .multiline = true, .value = "a (b)\nc\\d" });
    try doc.addFormField(.{ .kind = .checkbox, .name = "ticked", .x = 80, .y = 10, .width = 12, .height = 12, .checked = true });
    try doc.addFormField(.{ .kind = .checkbox, .name = "unticked", .x = 80, .y = 30, .width = 12, .height = 12 });
    const pdf = try doc.build();
    try expectJson(pdf,
        \\{"filled":"0.35","unicode":"Café £5 😀","notes":"a (b)\nc\\d","ticked":true,"unticked":false}
    );
}

test "roundtrip: presentation text_field and checkbox elements" {
    const json =
        \\{ "page_size": { "width": 595, "height": 842 },
        \\  "pages": [
        \\    { "elements": [
        \\      { "type": "text", "content": "Ze (ohms)", "x": 40, "y": 60, "font_size": 10 },
        \\      { "type": "text_field", "name": "ze", "x": 120, "y": 50, "width": 60, "height": 16,
        \\        "value": "0.21", "align": "right", "border_color": "#d32f2f", "background_color": "#fff5f5" },
        \\      { "type": "checkbox", "name": "rcd_ok", "x": 200, "y": 50, "checked": true }
        \\    ] },
        \\    { "elements": [
        \\      { "type": "text_field", "name": "remarks", "x": 40, "y": 100, "width": 300, "height": 60,
        \\        "multiline": true, "border_color": null, "tooltip": "Remarks" }
        \\    ] }
        \\  ] }
    ;
    const pdf = try presentation.generatePresentationFromJson(testing.allocator, json);
    defer testing.allocator.free(pdf);
    try expectJson(pdf, "{\"ze\":\"0.21\",\"rcd_ok\":true}");

    // y is the top edge from the top of the page: 842 - 50 - 16 = 776.
    try testing.expect(std.mem.indexOf(u8, pdf, "/Rect [120.00 776.00 180.00 792.00]") != null);
    try testing.expect(std.mem.indexOf(u8, pdf, "/Rect [200.00 780.00 212.00 792.00]") != null);
    try testing.expect(std.mem.indexOf(u8, pdf, "/Q 2") != null);
    try testing.expect(std.mem.indexOf(u8, pdf, "/MK << /BC [0.827 0.184 0.184] /BG [1.000 0.961 0.961] >>") != null);
    // border_color null: no /BC and a zero-width border style.
    try testing.expect(std.mem.indexOf(u8, pdf, "/MK << >> /BS << /W 0.00 /S /S >>") != null);
    try testing.expect(std.mem.indexOf(u8, pdf, "/Ff 4096") != null);
}

test "presentation refuses a wrong-typed or nameless form field element" {
    const bad = [_][]const u8{
        \\{ "pages": [ { "elements": [ { "type": "text_field", "x": 1, "y": 1 } ] } ] }
        ,
        \\{ "pages": [ { "elements": [ { "type": "text_field", "name": 7 } ] } ] }
        ,
        \\{ "pages": [ { "elements": [ { "type": "checkbox", "name": "c", "checked": "yes" } ] } ] }
        ,
        \\{ "pages": [ { "elements": [ { "type": "text_field", "name": "t", "align": "middle" } ] } ] }
        ,
        \\{ "pages": [ { "elements": [ { "type": "text_field", "name": "t" }, { "type": "text_field", "name": "t" } ] } ] }
    };
    for (bad) |json| {
        if (presentation.generatePresentationFromJson(testing.allocator, json)) |pdf| {
            testing.allocator.free(pdf);
            std.debug.print("accepted: {s}\n", .{json});
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

// -----------------------------------------------------------------------------
// External anchors: PDFs filled by other software, with the values that
// software set (tests/fixtures/forms/README.md says how each was made)
// -----------------------------------------------------------------------------

const fixture_dir = "tests/fixtures/forms/";

fn readFixture(a: std.mem.Allocator, name: []const u8) ![]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, fixture_dir ++ "{s}", .{name});
    return std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1024 * 1024)) catch |err| {
        std.debug.print("pdf_form_tests: cannot read '{s}': {s} (run from the package root)\n", .{ path, @errorName(err) });
        return err;
    };
}

fn jsonEqual(a: std.json.Value, b: std.json.Value) bool {
    return switch (a) {
        .string => |s| b == .string and std.mem.eql(u8, s, b.string),
        .bool => |x| b == .bool and x == b.bool,
        .array => |arr| blk: {
            if (b != .array or b.array.items.len != arr.items.len) break :blk false;
            for (arr.items, b.array.items) |x, y| {
                if (!jsonEqual(x, y)) break :blk false;
            }
            break :blk true;
        },
        .object => |obj| blk: {
            if (b != .object or b.object.count() != obj.count()) break :blk false;
            var it = obj.iterator();
            while (it.next()) |e| {
                const other = b.object.get(e.key_ptr.*) orelse break :blk false;
                if (!jsonEqual(e.value_ptr.*, other)) break :blk false;
            }
            break :blk true;
        },
        else => false,
    };
}

/// Read `<stem>.pdf` and compare the fields, in any order, with
/// `<stem>.expected.json`.
fn expectFixture(stem: []const u8) !void {
    const a = testing.allocator;
    var name_buf: [128]u8 = undefined;
    const pdf = try readFixture(a, try std.fmt.bufPrint(&name_buf, "{s}.pdf", .{stem}));
    defer a.free(pdf);
    const want_text = try readFixture(a, try std.fmt.bufPrint(&name_buf, "{s}.expected.json", .{stem}));
    defer a.free(want_text);
    const got_text = try readJson(pdf);
    defer a.free(got_text);

    const want = try std.json.parseFromSlice(std.json.Value, a, want_text, .{});
    defer want.deinit();
    const got = try std.json.parseFromSlice(std.json.Value, a, got_text, .{});
    defer got.deinit();
    if (!jsonEqual(want.value, got.value)) {
        std.debug.print("{s}: expected\n{s}\ngot\n{s}\n", .{ stem, want_text, got_text });
        return error.TestExpectedEqual;
    }
}

test "anchor: our form, filled and saved by PDFKit (the macOS Preview engine)" {
    // PDFKit rewrites the whole file, stores text as UTF-16BE inside literal
    // strings, a ticked checkbox's /V as the string (Yes), and an unticked one
    // by removing /V while leaving the widget's /AS at /Yes.
    try expectFixture("pdfkit-filled");
}

test "anchor: our form, filled by pypdf as an incremental update" {
    const a = testing.allocator;
    const original = try readFixture(a, "review.pdf");
    defer a.free(original);
    const updated = try readFixture(a, "pypdf-incremental.pdf");
    defer a.free(updated);
    // The fixture is what it claims: the original bytes, then an appended
    // revision whose objects replace the originals.
    try testing.expect(std.mem.startsWith(u8, updated, original));
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, updated, "startxref"));
    // pypdf writes the en dash and pound sign in PDFDocEncoding (\205, \243).
    try testing.expect(std.mem.indexOf(u8, updated, "(Filled by pypdf \\205 \\2437)") != null);
    try expectFixture("pypdf-incremental");
}

test "anchor: our form, filled by pypdf and AES-256 encrypted with an empty user password" {
    const a = testing.allocator;
    const pdf = try readFixture(a, "pypdf-aes256.pdf");
    defer a.free(pdf);
    try testing.expect(std.mem.indexOf(u8, pdf, "/AESV3") != null);
    try testing.expect(std.mem.indexOf(u8, pdf, "Filled by") == null);
    try expectFixture("pypdf-aes256");
}

test "anchor: a form built and filled entirely by pdf-lib (object streams, nested names, radio, choice)" {
    const a = testing.allocator;
    const pdf = try readFixture(a, "pdflib-form.pdf");
    defer a.free(pdf);
    try testing.expect(std.mem.indexOf(u8, pdf, "/Type /ObjStm") != null);
    try testing.expect(std.mem.indexOf(u8, pdf, "/Type /XRef") != null);
    try expectFixture("pdflib-form");
}

// -----------------------------------------------------------------------------
// Reader: hand-written field trees (shapes the writer never produces)
// -----------------------------------------------------------------------------

test "reader: nested names, inherited /FT and /V, widget kids, radio, choice, push button" {
    const pdf =
        "%PDF-1.7\n" ++
        "1 0 obj\n<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [4 0 R 7 0 R 9 0 R 10 0 R 11 0 R] >> >>\nendobj\n" ++
        "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n" ++
        "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [5 0 R 6 0 R 8 0 R 12 0 R] >>\nendobj\n" ++
        // A parent "circuit" with two text kids that inherit /FT /Tx.
        "4 0 obj\n<< /T (circuit) /FT /Tx /Kids [5 0 R 6 0 R] >>\nendobj\n" ++
        "5 0 obj\n<< /Type /Annot /Subtype /Widget /Parent 4 0 R /T (zs) /V (0.42) /Rect [0 0 1 1] >>\nendobj\n" ++
        "6 0 obj\n<< /Type /Annot /Subtype /Widget /Parent 4 0 R /T (r1) /Rect [0 0 1 1] >>\nendobj\n" ++
        // A checkbox with no /V is off, whatever its widget's /AS says.
        "7 0 obj\n<< /T (agree) /FT /Btn /Kids [8 0 R] >>\nendobj\n" ++
        "8 0 obj\n<< /Type /Annot /Subtype /Widget /Parent 7 0 R /AS /On /Rect [0 0 1 1] >>\nendobj\n" ++
        // A radio group (Ff bit 16), a multi-select list, a push button (bit 17).
        "9 0 obj\n<< /T (phase) /FT /Btn /Ff 32768 /V /Three >>\nendobj\n" ++
        "10 0 obj\n<< /T (tests) /FT /Ch /V [(IR) (Zs)] >>\nendobj\n" ++
        "11 0 obj\n<< /T (submit) /FT /Btn /Ff 65536 /V /On >>\nendobj\n" ++
        // A widget field missing from /Fields, found through the page.
        "12 0 obj\n<< /Type /Annot /Subtype /Widget /T (orphan) /FT /Tx /V <FEFF00E9> /Rect [0 0 1 1] >>\nendobj\n" ++
        "trailer\n<< /Root 1 0 R /Size 13 >>\nstartxref\n0\n%%EOF\n";
    try expectJson(pdf,
        \\{"circuit.zs":"0.42","agree":false,"phase":"Three","tests":["IR","Zs"],"orphan":"é"}
    );
}

test "reader: no form, not a PDF, and a cyclic /Parent chain" {
    var doc = try onePageDoc(testing.allocator);
    defer doc.deinit();
    try expectJson(try doc.build(), "{}");
    try testing.expectError(error.NotAPdf, readJson("hello"));

    const cyclic =
        "%PDF-1.7\n" ++
        "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n" ++
        "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n" ++
        "3 0 obj\n<< /Type /Page /Parent 2 0 R /Annots [4 0 R] >>\nendobj\n" ++
        "4 0 obj\n<< /Type /Annot /Subtype /Widget /Parent 5 0 R /T (a) /FT /Tx /V (x) >>\nendobj\n" ++
        "5 0 obj\n<< /T (b) /Parent 4 0 R /Kids [4 0 R] >>\nendobj\n" ++
        "trailer\n<< /Root 1 0 R /Size 6 >>\nstartxref\n0\n%%EOF\n";
    const got = try readJson(cyclic);
    testing.allocator.free(got);
}

test "reader: PDFDocEncoding bytes decode to Unicode" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // 0x80 bullet, 0x92 trade mark, 0xA0 euro, 0xE9 é, 0x18 breve.
    try testing.expectEqualStrings("\u{2022}\u{2122}\u{20AC}\u{e9}\u{2d8}", try reader.decodeTextString(a, "\x80\x92\xA0\xE9\x18"));
    // UTF-16BE with an unpaired surrogate keeps going with U+FFFD.
    try testing.expectEqualStrings("A\u{FFFD}B", try reader.decodeTextString(a, "\xFE\xFF\x00A\xD8\x00\x00B"));
    // PDF 2.0 UTF-8 strings, with a bad byte replaced.
    try testing.expectEqualStrings("\u{e9}\u{FFFD}", try reader.decodeTextString(a, "\xEF\xBB\xBF\xC3\xA9\xFF"));
}
