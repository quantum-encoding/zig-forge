//! Rendering of documents whose lines carry their own tax rate, checked on
//! the text the extractor reads back from each theme's PDF: the per-line
//! rate column and the per-rate tax rows appear only when more than one rate
//! is in play, and a document whose lines all share one rate renders exactly
//! as it does without line rates.

const std = @import("std");
const invoice = @import("invoice.zig");
const json = @import("json.zig");
const pdf_extract = @import("pdf_extract.zig");

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

/// `{"theme": <theme>, <members>}`; `members` is a JSON member list.
fn withTheme(a: std.mem.Allocator, theme: invoice.Theme, members: []const u8) ![]u8 {
    return std.mem.concat(a, u8, &.{ "{\"theme\": \"", @tagName(theme), "\", ", members, "}" });
}

/// A themed £ invoice at a 20% document rate.
fn payload(a: std.mem.Allocator, theme: invoice.Theme, body: []const u8) ![]u8 {
    const members = try std.mem.concat(a, u8, &.{ "\"currency_symbol\": \"£\", \"tax_rate\": 0.2, ", body });
    defer a.free(members);
    return withTheme(a, theme, members);
}

fn expectContains(text: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, text, needle) == null) {
        std.debug.print("extracted text lacks \"{s}\":\n{s}\n", .{ needle, text });
        return error.MissingText;
    }
}

/// A per-rate row: `label` ("VAT 20%") followed by `net` ("on £1,000.00"),
/// with only spaces or table-cell bars between them (the extractor may put
/// the two runs in adjacent cells).
fn expectRateRow(text: []const u8, label: []const u8, net: []const u8) !void {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, text, from, label)) |at| : (from = at + 1) {
        var i = at + label.len;
        while (i < text.len and (text[i] == ' ' or text[i] == '|')) i += 1;
        if (std.mem.startsWith(u8, text[i..], net)) return;
    }
    std.debug.print("extracted text lacks the row \"{s} {s}\":\n{s}\n", .{ label, net, text });
    return error.MissingText;
}

fn expectLacks(text: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, text, needle) != null) {
        std.debug.print("extracted text has \"{s}\":\n{s}\n", .{ needle, text });
        return error.UnexpectedText;
    }
}

const mixed_items =
    \\"labels": {"tax_prefix": "VAT", "vat_column": "Rate"},
    \\"items": [
    \\  {"description": "Solar panels", "quantity": 1, "unit_price": 4160, "tax_rate": 0},
    \\  {"description": "Battery", "quantity": 1, "unit_price": 3800, "tax_rate": 0},
    \\  {"description": "EV charger", "quantity": 1, "unit_price": 1000, "tax_rate": 0.2}]
;

test "a 0% + 20% invoice shows the rate column and one VAT row per rate in every theme" {
    const a = testing.allocator;
    for (themes) |theme| {
        const p = try payload(a, theme, mixed_items);
        defer a.free(p);
        const pdf = try renderJson(a, p);
        defer a.free(pdf);
        const text = try extractedText(a, pdf);
        defer a.free(text);

        // Column header (caps in the typographic themes) and the line rates.
        if (std.mem.indexOf(u8, text, "Rate") == null) try expectContains(text, "RATE");
        try expectContains(text, "20%");
        // Per-rate rows, ascending, then the VAT total; no single "VAT (x%)" row.
        try expectRateRow(text, "VAT 0%", "on £7,960.00");
        try expectRateRow(text, "VAT 20%", "on £1,000.00");
        try expectContains(text, "Total VAT");
        try expectContains(text, "£200.00");
        try expectContains(text, "£9,160.00");
        try expectLacks(text, "VAT (");
        const zero = std.mem.indexOf(u8, text, "VAT 0%").?;
        const twenty = std.mem.indexOf(u8, text, "VAT 20%").?;
        try testing.expect(zero < twenty);
    }
}

test "a 0% + 5% + 20% invoice with a delivery charge lists three rates in every theme" {
    const a = testing.allocator;
    const body =
        \\"labels": {"tax_prefix": "VAT"},
        \\"adjustments": [{"label": "Delivery", "amount": 50}],
        \\"items": [
        \\  {"description": "EV charger", "quantity": 1, "unit_price": 1000, "tax_rate": 0.2},
        \\  {"description": "Insulation", "quantity": 1, "unit_price": 20.70, "tax_rate": 0.05},
        \\  {"description": "Solar panels", "quantity": 1, "unit_price": 7960, "tax_rate": 0}]
    ;
    for (themes) |theme| {
        const p = try payload(a, theme, body);
        defer a.free(p);
        const pdf = try renderJson(a, p);
        defer a.free(pdf);
        const text = try extractedText(a, pdf);
        defer a.free(text);
        // 20.70 x 5% = 1.035 -> 1.04; (1000 + 50 delivery) x 20% = 210.00.
        try expectRateRow(text, "VAT 0%", "on £7,960.00");
        try expectRateRow(text, "VAT 5%", "on £20.70");
        try expectContains(text, "£1.04");
        try expectRateRow(text, "VAT 20%", "on £1,050.00");
        try expectContains(text, "£210.00");
        try expectContains(text, "£211.04");
        try expectContains(text, "Delivery");
        const five = std.mem.indexOf(u8, text, "VAT 5%").?;
        try testing.expect(std.mem.indexOf(u8, text, "VAT 0%").? < five);
        try testing.expect(five < std.mem.indexOf(u8, text, "VAT 20%").?);
    }
}

test "lines that all share the document rate render byte-identically to no line rates" {
    const a = testing.allocator;
    const plain =
        \\"labels": {"tax_prefix": "VAT"}, "adjustments": [{"label": "Delivery", "amount": 12.5}],
        \\"items": [{"description": "Panels", "quantity": 2, "unit_price": 180, "discount": 10},
        \\  {"description": "Charger", "quantity": 1, "unit_price": 1000}]
    ;
    const rated =
        \\"labels": {"tax_prefix": "VAT"}, "adjustments": [{"label": "Delivery", "amount": 12.5}],
        \\"items": [{"description": "Panels", "quantity": 2, "unit_price": 180, "discount": 10, "tax_rate": 0.2},
        \\  {"description": "Charger", "quantity": 1, "unit_price": 1000, "tax_rate": 0.2}]
    ;
    for (themes) |theme| {
        const p1 = try payload(a, theme, plain);
        defer a.free(p1);
        const p2 = try payload(a, theme, rated);
        defer a.free(p2);
        const pdf1 = try renderJson(a, p1);
        defer a.free(pdf1);
        const pdf2 = try renderJson(a, p2);
        defer a.free(pdf2);
        try testing.expectEqualSlices(u8, pdf1, pdf2);
        const text = try extractedText(a, pdf1);
        defer a.free(text);
        try expectContains(text, "VAT (20%)");
        try expectLacks(text, "Total VAT");
    }
}

test "one shared line rate other than the document rate names that rate" {
    const a = testing.allocator;
    for (themes) |theme| {
        const p1 = try withTheme(a, theme,
            \\"tax_rate": 0.05, "items": [{"description": "Insulation", "quantity": 1, "unit_price": 20.70}]
        );
        defer a.free(p1);
        const p2 = try withTheme(a, theme,
            \\"items": [{"description": "Insulation", "quantity": 1, "unit_price": 20.70, "tax_rate": 0.05}]
        );
        defer a.free(p2);
        const pdf1 = try renderJson(a, p1);
        defer a.free(pdf1);
        const pdf2 = try renderJson(a, p2);
        defer a.free(pdf2);
        try testing.expectEqualSlices(u8, pdf1, pdf2);
    }
}

test "show_tax:false and blackbox keep their tax behaviour on a mixed-rate document" {
    const a = testing.allocator;
    for (themes) |theme| {
        const hidden_body = try std.mem.concat(a, u8, &.{ "\"show_tax\": false, ", mixed_items });
        defer a.free(hidden_body);
        const p = try payload(a, theme, hidden_body);
        defer a.free(p);
        const pdf = try renderJson(a, p);
        defer a.free(pdf);
        const text = try extractedText(a, pdf);
        defer a.free(text);
        try expectLacks(text, "VAT 0%");
        try expectLacks(text, "Total VAT");
        try expectLacks(text, "Rate");
        try expectLacks(text, "RATE");
        try expectContains(text, "£8,960.00");

        // Blackbox: one summary line, so no rate column, but the rows per rate.
        const bb_body = try std.mem.concat(a, u8, &.{ "\"display_mode\": \"blackbox\", \"blackbox_description\": \"Installation\", ", mixed_items });
        defer a.free(bb_body);
        const pb = try payload(a, theme, bb_body);
        defer a.free(pb);
        const bb = try renderJson(a, pb);
        defer a.free(bb);
        const bt = try extractedText(a, bb);
        defer a.free(bt);
        try expectLacks(bt, "Rate");
        try expectLacks(bt, "RATE");
        try expectRateRow(bt, "VAT 0%", "on £7,960.00");
        try expectRateRow(bt, "VAT 20%", "on £1,000.00");
    }
}

test "a VAT total that disagrees with the per-rate rows is refused, not drawn" {
    const a = testing.allocator;
    const body = try std.mem.concat(a, u8, &.{ "\"tax_amount\": 210, ", mixed_items });
    defer a.free(body);
    const p = try payload(a, .classic, body);
    defer a.free(p);
    try testing.expectError(error.TaxAmountMismatch, renderJson(a, p));
}
