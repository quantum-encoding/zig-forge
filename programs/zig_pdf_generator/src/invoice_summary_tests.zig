//! The payment summary block (`payment_summary`): what the parser accepts and
//! refuses, that every style draws its title, labels and amounts (read back
//! from the PDF with the extractor), that a long label wraps short of its
//! amount, that the block is never split across pages, that it never moves a
//! total, and that an invoice without it renders exactly as it did before the
//! block existed.

const std = @import("std");
const invoice = @import("invoice.zig");
const json = @import("json.zig");
const pdf_extract = @import("pdf_extract.zig");
const document = @import("document.zig");

const testing = std.testing;
const themes = [_]invoice.Theme{ .classic, .squircle, .glass, .minimal, .letterhead };

fn renderJson(a: std.mem.Allocator, body: []const u8) ![]u8 {
    const data = try json.parseInvoiceJson(a, body);
    defer json.freeInvoiceData(a, &data);
    return invoice.generateInvoice(a, data);
}

fn extractedText(a: std.mem.Allocator, pdf: []const u8) ![]u8 {
    var result = try pdf_extract.extractToMdx(a, pdf, .{});
    defer result.deinit(a);
    return a.dupe(u8, result.mdx);
}

fn expectContains(text: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, text, needle) == null) {
        std.debug.print("extracted text lacks \"{s}\":\n{s}\n", .{ needle, text });
        return error.MissingText;
    }
}

fn expectLacks(text: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, text, needle) != null) {
        std.debug.print("extracted text has \"{s}\":\n{s}\n", .{ needle, text });
        return error.UnexpectedText;
    }
}

/// `{"style": <theme>, <members>}`; `members` is a JSON member list.
fn withTheme(a: std.mem.Allocator, theme: invoice.Theme, members: []const u8) ![]u8 {
    return std.mem.concat(a, u8, &.{ "{\"style\": \"", @tagName(theme), "\", ", members, "}" });
}

/// A stage invoice in the shape the CRG Direct site sends: one 0% line, £,
/// VAT labels, bank details, notes. Each summary amount is distinct so every
/// row can be found on its own.
const stage_invoice =
    \\"preset": "invoice", "invoice_number": "INV-0042", "invoice_date": "20 Nov 2026",
    \\"company_name": "CRG Direct", "client_name": "Jane Customer", "client_address": "12 Acacia Avenue\nWinchester",
    \\"currency_symbol": "£", "labels": {"tax_prefix": "VAT"}, "show_branding": false,
    \\"items": [{"description": "Second payment (30%)", "quantity": 1, "unit_price": 2700, "total": 2700}],
    \\"subtotal": 2700, "tax_rate": 0, "tax_amount": 0, "total": 2700,
    \\"bank_details": {"account_name": "CRG Direct Ltd", "sort_code": "12-34-56", "account_number": "12345678"},
    \\"notes": "Thank you.",
    \\"payment_summary": {"title": "Stage payment 2 of 3: Second payment", "rows": [
    \\  {"label": "Contract total", "amount": 9000},
    \\  {"label": "Invoiced before", "amount": 3600},
    \\  {"label": "Paid before", "amount": 3500},
    \\  {"label": "This invoice: Second payment (30%)", "amount": 2700, "bold": true},
    \\  {"label": "Balance after this invoice", "amount": 2800}]}
;

test "payment_summary: the title is optional, bold defaults to false, null is no summary" {
    const a = testing.allocator;
    const plain = try json.parseInvoiceJson(a,
        \\{"payment_summary": {"rows": [
        \\  {"label": "Contract total", "amount": 9000},
        \\  {"label": "This invoice", "amount": 2700.5, "bold": true},
        \\  {"label": "Balance after", "amount": -1, "bold": null}]}}
    );
    defer json.freeInvoiceData(a, &plain);
    const ps = plain.payment_summary.?;
    try testing.expectEqualStrings("", ps.title);
    try testing.expectEqual(@as(usize, 3), ps.rows.len);
    try testing.expectEqualStrings("Contract total", ps.rows[0].label);
    try testing.expectEqual(@as(f64, 9000), ps.rows[0].amount);
    try testing.expect(!ps.rows[0].bold);
    try testing.expectEqual(@as(f64, 2700.5), ps.rows[1].amount);
    try testing.expect(ps.rows[1].bold);
    try testing.expect(!ps.rows[2].bold);

    const titled = try json.parseInvoiceJson(a,
        \\{"payment_summary": {"title": "Stage payment 2 of 3", "rows": [{"label": "Contract total", "amount": 9000}]}}
    );
    defer json.freeInvoiceData(a, &titled);
    try testing.expectEqualStrings("Stage payment 2 of 3", titled.payment_summary.?.title);

    const null_title = try json.parseInvoiceJson(a,
        \\{"payment_summary": {"title": null, "rows": [{"label": "A", "amount": 1}]}}
    );
    defer json.freeInvoiceData(a, &null_title);
    try testing.expectEqualStrings("", null_title.payment_summary.?.title);

    const absent = try json.parseInvoiceJson(a, "{}");
    defer json.freeInvoiceData(a, &absent);
    try testing.expect(absent.payment_summary == null);

    const explicit_null = try json.parseInvoiceJson(a, "{\"payment_summary\": null}");
    defer json.freeInvoiceData(a, &explicit_null);
    try testing.expect(explicit_null.payment_summary == null);
}

fn rowsPayload(a: std.mem.Allocator, n: usize) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(a);
    try buf.appendSlice(a, "{\"payment_summary\": {\"rows\": [");
    for (0..n) |i| {
        if (i > 0) try buf.append(a, ',');
        try buf.appendSlice(a, "{\"label\": \"Row\", \"amount\": 1}");
    }
    try buf.appendSlice(a, "]}}");
    return buf.toOwnedSlice(a);
}

test "payment_summary: 12 rows are accepted, 13 are refused by the parser and the renderer" {
    const a = testing.allocator;
    const twelve = try rowsPayload(a, invoice.MAX_SUMMARY_ROWS);
    defer a.free(twelve);
    const ok = try json.parseInvoiceJson(a, twelve);
    defer json.freeInvoiceData(a, &ok);
    try testing.expectEqual(@as(usize, 12), ok.payment_summary.?.rows.len);

    const thirteen = try rowsPayload(a, invoice.MAX_SUMMARY_ROWS + 1);
    defer a.free(thirteen);
    try testing.expectError(error.TooManyPaymentSummaryRows, json.parseInvoiceJson(a, thirteen));

    // A caller building InvoiceData directly meets the same cap.
    var rows: [invoice.MAX_SUMMARY_ROWS + 1]invoice.SummaryRow = @splat(.{ .label = "Row", .amount = 1 });
    try testing.expectError(error.TooManyPaymentSummaryRows, invoice.generateInvoice(a, .{ .payment_summary = .{ .rows = &rows } }));
    const pdf = try invoice.generateInvoice(a, .{ .payment_summary = .{ .rows = rows[0..invoice.MAX_SUMMARY_ROWS] } });
    a.free(pdf);
}

test "payment_summary: a malformed block is refused with InvalidPaymentSummary" {
    const a = testing.allocator;
    const bad = [_][]const u8{
        \\{"payment_summary": []}
        ,
        \\{"payment_summary": "Stage 2"}
        ,
        \\{"payment_summary": {}}
        ,
        \\{"payment_summary": {"title": "Stage 2"}}
        ,
        \\{"payment_summary": {"rows": []}}
        ,
        \\{"payment_summary": {"rows": {"label": "A", "amount": 1}}}
        ,
        \\{"payment_summary": {"title": 2, "rows": [{"label": "A", "amount": 1}]}}
        ,
        \\{"payment_summary": {"rows": [1]}}
        ,
        \\{"payment_summary": {"rows": [{"amount": 1}]}}
        ,
        \\{"payment_summary": {"rows": [{"label": 5, "amount": 1}]}}
        ,
        \\{"payment_summary": {"rows": [{"label": "A"}]}}
        ,
        \\{"payment_summary": {"rows": [{"label": "A", "amount": "9000"}]}}
        ,
        \\{"payment_summary": {"rows": [{"label": "A", "amount": null}]}}
        ,
        \\{"payment_summary": {"rows": [{"label": "A", "amount": 1e13}]}}
        ,
        \\{"payment_summary": {"rows": [{"label": "A", "amount": 1, "bold": "yes"}]}}
        ,
        \\{"payment_summary": {"rows": [{"label": "A", "amount": 1}, {"label": "B"}]}}
    };
    for (bad) |body| {
        if (json.parseInvoiceJson(a, body)) |data| {
            json.freeInvoiceData(a, &data);
            std.debug.print("accepted: {s}\n", .{body});
            return error.TestUnexpectedResult;
        } else |err| try testing.expectEqual(error.InvalidPaymentSummary, err);
    }
    for ([_]anyerror{ error.InvalidPaymentSummary, error.TooManyPaymentSummaryRows }) |e| {
        const msg = json.describeInvoiceError(e).?;
        // Fits the 128-byte "JSON parse error: <detail>" buffer of the C/WASM exports.
        try testing.expect(msg.len + "JSON parse error: ".len <= 128);
    }
}

test "payment_summary never changes the subtotal, tax, total or balance" {
    const a = testing.allocator;
    const base =
        \\"tax_rate": 0.2, "amount_paid": 100,
        \\"items": [{"description": "Charger", "quantity": 1, "unit_price": 1000}]
    ;
    const summary =
        \\, "payment_summary": {"rows": [{"label": "Contract total", "amount": 50000}, {"label": "Balance after", "amount": -7}]}
    ;
    const without = try json.parseInvoiceJson(a, "{" ++ base ++ "}");
    defer json.freeInvoiceData(a, &without);
    const with = try json.parseInvoiceJson(a, "{" ++ base ++ summary ++ "}");
    defer json.freeInvoiceData(a, &with);
    try testing.expectEqual(without.subtotal, with.subtotal);
    try testing.expectEqual(without.tax_amount, with.tax_amount);
    try testing.expectEqual(without.total, with.total);
    try testing.expectEqual(without.amount_paid, with.amount_paid);
    try testing.expectEqual(@as(f64, 1200), with.total);

    for (themes) |theme| {
        const p = try withTheme(a, theme, "\"currency_symbol\": \"£\", " ++ base ++ summary);
        defer a.free(p);
        const pdf = try renderJson(a, p);
        defer a.free(pdf);
        const text = try extractedText(a, pdf);
        defer a.free(text);
        try expectContains(text, "£1,200.00"); // TOTAL
        try expectContains(text, "£1,100.00"); // Balance Due
        try expectContains(text, "£50,000.00");
        try expectContains(text, "-£7.00");
    }
}

test "every style draws the summary's title, labels and amounts" {
    const a = testing.allocator;
    for (themes) |theme| {
        const p = try withTheme(a, theme, stage_invoice);
        defer a.free(p);
        const pdf = try renderJson(a, p);
        defer a.free(pdf);
        const text = try extractedText(a, pdf);
        defer a.free(text);
        // The classic styles' label column wraps the two longest strings; the
        // first line of each is whole in every style.
        try expectContains(text, "Stage payment 2 of 3: Second");
        try expectContains(text, "Contract total");
        try expectContains(text, "Invoiced before");
        try expectContains(text, "Paid before");
        try expectContains(text, "This invoice: Second");
        try expectContains(text, "payment (30%)");
        try expectContains(text, "Balance after this invoice");
        try expectContains(text, "£9,000.00");
        try expectContains(text, "£3,600.00");
        try expectContains(text, "£3,500.00");
        try expectContains(text, "£2,800.00");
        try expectContains(text, "£2,700.00");
        // The bank details and notes still follow.
        try expectContains(text, "12345678");
        try expectContains(text, "Thank you.");
    }
}

test "the summary's amounts follow the document's currency and number format" {
    const a = testing.allocator;
    for (themes) |theme| {
        const p = try withTheme(a, theme,
            \\"currency_symbol": "€", "number_format": {"thousands": ".", "decimal": ","},
            \\"items": [{"description": "Pago", "quantity": 1, "unit_price": 100}],
            \\"payment_summary": {"title": "Pago 2 de 3", "rows": [{"label": "Total del contrato", "amount": 12345.6}]}
        );
        defer a.free(p);
        const pdf = try renderJson(a, p);
        defer a.free(pdf);
        const text = try extractedText(a, pdf);
        defer a.free(text);
        try expectContains(text, "Pago 2 de 3");
        try expectContains(text, "Total del contrato");
        try expectContains(text, "€12.345,60");
    }
}

test "a long label wraps short of its amount and is cut with ... past three lines" {
    const a = testing.allocator;
    const font = document.Font.helvetica;
    const width: f32 = 100;

    var tail: [256]u8 = undefined;
    var two = try invoice.wrapCapped(a, "This invoice: Second payment (30%)", font, 9.5, width, invoice.SUMMARY_LABEL_LINES, &tail);
    defer two.deinit();
    try testing.expectEqual(@as(usize, 2), two.len);
    for (two.lines()) |line| try testing.expect(font.measureText(line, 9.5) <= width);
    try testing.expectEqualStrings("This invoice: Second", two.lines()[0]);
    try testing.expectEqualStrings("payment (30%)", two.lines()[1]);

    // Over three lines even in the typographic styles' wider label column.
    const long = "Balance carried forward from the deposit invoice and the scaffold hire " ++
        "agreed on site with the customer, the roof survey and the extra isolator " ++
        "requested by the network operator before the second fix began";
    var cut = try invoice.wrapCapped(a, long, font, 9.5, width, invoice.SUMMARY_LABEL_LINES, &tail);
    defer cut.deinit();
    try testing.expectEqual(invoice.SUMMARY_LABEL_LINES, cut.len);
    for (cut.lines()) |line| try testing.expect(font.measureText(line, 9.5) <= width);
    try testing.expect(std.mem.endsWith(u8, cut.lines()[2], "..."));

    // Drawn: the cut line is in the PDF, the words after it are not.
    for (themes) |theme| {
        const p = try withTheme(a, theme, "\"payment_summary\": {\"rows\": [{\"label\": \"" ++ long ++ "\", \"amount\": 1}]}");
        defer a.free(p);
        const pdf = try renderJson(a, p);
        defer a.free(pdf);
        const text = try extractedText(a, pdf);
        defer a.free(text);
        try expectContains(text, "Balance carried");
        try expectContains(text, "...");
        try expectLacks(text, "second fix began");
    }
}

/// The page content streams of an uncompressed (test-build) PDF, in order.
fn contentStreams(a: std.mem.Allocator, pdf: []const u8) ![][]const u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer list.deinit(a);
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, pdf, at, "stream\n")) |s| {
        const start = s + "stream\n".len;
        const end = std.mem.indexOfPos(u8, pdf, start, "endstream") orelse break;
        try list.append(a, pdf[start..end]);
        at = end + "endstream".len;
    }
    return list.toOwnedSlice(a);
}

fn streamWith(streams: []const []const u8, needle: []const u8) ?usize {
    for (streams, 0..) |s, i| {
        if (std.mem.indexOf(u8, s, needle) != null) return i;
    }
    return null;
}

test "the summary is never split across pages and opens the next page when it does not fit" {
    const a = testing.allocator;
    for (themes) |theme| {
        var moved = false;
        var n: usize = 1;
        while (n <= 40) : (n += 1) {
            var items: std.ArrayListUnmanaged(u8) = .empty;
            defer items.deinit(a);
            for (0..n) |i| {
                if (i > 0) try items.append(a, ',');
                try items.appendSlice(a, "{\"description\": \"Line\", \"quantity\": 1, \"unit_price\": 10}");
            }
            // Eight rows: taller than the room every style keeps under its
            // totals, so some item count leaves the totals on a page the
            // summary does not fit.
            const summary =
                \\], "payment_summary": {"title": "Stage summary", "rows": [
                \\  {"label": "Row 1", "amount": 1}, {"label": "Row 2", "amount": 2},
                \\  {"label": "Row 3", "amount": 3}, {"label": "Row 4", "amount": 4},
                \\  {"label": "Row 5", "amount": 5}, {"label": "Row 6", "amount": 6},
                \\  {"label": "Row 7", "amount": 7}, {"label": "Last row", "amount": 8}]}
            ;
            const members = try std.mem.concat(a, u8, &.{ "\"amount_paid\": 5, \"items\": [", items.items, summary });
            defer a.free(members);
            const p = try withTheme(a, theme, members);
            defer a.free(p);
            const pdf = try renderJson(a, p);
            defer a.free(pdf);
            const streams = try contentStreams(a, pdf);
            defer a.free(streams);
            const title = streamWith(streams, "(Stage summary)").?;
            try testing.expectEqual(title, streamWith(streams, "(Last row)").?);
            if (title != streamWith(streams, "(Balance Due").?) moved = true;
        }
        if (!moved) {
            std.debug.print("{s}: no item count moved the summary to its own page\n", .{@tagName(theme)});
            return error.TestUnexpectedResult;
        }
    }
}

/// The drift-lock invoice: no payment_summary, with everything that sits
/// around where the block goes (bank details, amount paid, notes, terms).
const drift_lock_invoice =
    \\"preset": "invoice", "invoice_number": "INV-0042", "invoice_date": "20 Nov 2026", "due_date": "4 Dec 2026",
    \\"company_name": "CRG Direct", "company_address": "Unit 4, Example Park\nSouthampton, SO14 0AA",
    \\"company_vat": "GB 123 4567 89", "client_name": "Jane Customer", "client_address": "12 Acacia Avenue\nWinchester",
    \\"items": [{"description": "Solar PV system, 4.2 kWp, with 5 kWh battery", "quantity": 1, "unit_price": 9000, "total": 9000}],
    \\"subtotal": 9000, "tax_rate": 0, "tax_amount": 0, "total": 9000, "amount_paid": 3600, "payment_method": "Bank transfer",
    \\"currency_symbol": "£", "labels": {"tax_prefix": "VAT"}, "show_branding": false,
    \\"bank_details": {"account_name": "CRG Direct Ltd", "bank_name": "Example Bank", "sort_code": "12-34-56", "account_number": "12345678", "reference": "INV-0042"},
    \\"subject": "Solar PV at 12 Acacia Avenue", "notes": "VAT at 0%: energy-saving materials installed in a home.",
    \\"payment_terms": "Payment due within 14 days.", "primary_color": "#16a34a", "secondary_color": "#1e3a2f", "title_color": "#16a34a"
;

/// SHA-256 of `drift_lock_invoice` rendered (test build, uncompressed
/// streams) in each of `themes`, by zig_pdf_generator at 93ca5231, before
/// payment_summary existed. A drift lock, not an anchor: it holds the
/// engine's own earlier output. A deliberate change to how these invoices
/// render must update the hashes (the failure prints the new one).
const drift_lock_sha256 = [themes.len][]const u8{
    "8a7cd248145700fcc424c34bb04c7c82a9edbb9e33d748da3e4a35856ac219ca", // classic
    "e2aa5cf72e9a38c3476c96b646d5c25416069bd4719f4f926aa3c08730325848", // squircle
    "bb96c2679afd19dccb0f937aa8ec6691c4bb96a3587ebd79f51bf8a63105e7e2", // glass
    "9df67fc44a6f56b4d981f320d404d21445a397ee58669a84add5f579a3bc807a", // minimal
    "8f5ea6b2c671c9e659ccbaeb2e0d4184cb083520da081c5e8e44c20d5b8edd42", // letterhead
};

fn sha256Hex(pdf: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(pdf, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

test "an invoice without payment_summary renders byte-for-byte as before the block existed" {
    const a = testing.allocator;
    for (themes, drift_lock_sha256) |theme, want| {
        const p = try withTheme(a, theme, drift_lock_invoice);
        defer a.free(p);
        const pdf = try renderJson(a, p);
        defer a.free(pdf);
        const got = sha256Hex(pdf);
        if (!std.mem.eql(u8, &got, want)) {
            std.debug.print("{s}: sha256 {s}, locked {s}\n", .{ @tagName(theme), &got, want });
            return error.TestUnexpectedResult;
        }

        // An explicit null is the same document.
        const n = try withTheme(a, theme, drift_lock_invoice ++ ", \"payment_summary\": null");
        defer a.free(n);
        const pdf_null = try renderJson(a, n);
        defer a.free(pdf_null);
        try testing.expectEqualSlices(u8, pdf, pdf_null);
    }
}
