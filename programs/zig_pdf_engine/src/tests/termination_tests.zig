// Termination tests against whole PDF files.
//
// Every fixture here made `pdf-text` spin forever before the parse was made to
// terminate; docs/pdf-text-hang-classification.md has the constructs and how
// often each occurred. The fixtures are synthetic (the documents the hangs were
// found in are a client's accounts), written by
// tests/fixtures/termination/make_fixtures.py, which also checks that poppler's
// pdftotext reads the same words out of them: the expected text below is
// anchored on an independent implementation, not on this engine's output.
//
// Each test runs under a watchdog, so a regression is a failed test and not a
// build that never finishes.

const std = @import("std");
const testing = std.testing;
const pdf = @import("pdf-engine");

const Document = pdf.Document;
const Watchdog = pdf.test_watchdog.Watchdog;

const fixtures = "tests/fixtures/termination/";

fn expectText(comptime name: []const u8, expected: []const u8) !void {
    // Seconds. These files extract in milliseconds; the limit only has to
    // separate "returns" from "never returns".
    const dog = Watchdog.arm(20);
    defer dog.disarm();

    var doc = try Document.open(testing.allocator, fixtures ++ name);
    defer doc.close();

    const text = try doc.extractAllText();
    defer testing.allocator.free(text);

    try testing.expectEqualStrings(expected, std.mem.trim(u8, text, " \r\n"));
}

// 264 of the 629 hung documents. A ToUnicode bfrange whose destination array
// holds exactly one entry per code, as Qt, Skia and wkhtmltopdf write it.
test "ToUnicode bfrange array filling its range" {
    try expectText("cmap_bfrange_array.pdf", "BFRANGE ARRAY TERMINATES");
}

// 342 of the 629. /Filter written as a one-element array (iText): the filter
// was not applied and the compressed bytes were lexed as PDF syntax, where a
// ')' that closes nothing stalled the lexer. The body's compressed form also
// ends in 0x0D, which a reader trimming EOLs off stream data cuts away.
test "/Filter as an array, stream ending in a CR byte" {
    try expectText("filter_array.pdf", "FILTER ARRAY BODY FN");
}

// 23 of the 629. The same defect through a two-filter chain (Oracle's PDF
// driver, ReportLab).
test "/Filter chain ASCII85 then Flate" {
    try expectText("filter_chain_a85_flate.pdf", "FILTER CHAIN ASCII85 THEN FLATE");
}

// Not seen in the 629, found while reading the page loop: /Count claims four
// billion pages and /Kids loops back on itself.
test "page tree that lies about /Count and cycles" {
    try expectText("page_tree_lies.pdf", "ONE REAL PAGE");

    const dog = Watchdog.arm(20);
    defer dog.disarm();
    var doc = try Document.open(testing.allocator, fixtures ++ "page_tree_lies.pdf");
    defer doc.close();
    try testing.expectError(error.PageNotFound, doc.extractPageText(1));
}

// Not seen in the 629: a cross-reference stream with zero-width entries, whose
// entry loop is bounded only by the four billion entries /Index declares.
test "xref stream with zero-width entries is refused" {
    const dog = Watchdog.arm(20);
    defer dog.disarm();

    try testing.expectError(
        error.InvalidXrefStreamW,
        Document.open(testing.allocator, fixtures ++ "xref_stream_zero_width.pdf"),
    );
}
