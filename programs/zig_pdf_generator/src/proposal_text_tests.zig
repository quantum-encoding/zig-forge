//! The proposal template draws non-ASCII text as the WinAnsi standard fonts
//! can show it: £, dashes, curly quotes and bullets as their own glyphs,
//! a tick as a stroked check mark, and nothing as "?". Checked on the text
//! the extractor reads back from the PDF.

const std = @import("std");
const proposal = @import("proposal.zig");
const pdf_extract = @import("pdf_extract.zig");

const testing = std.testing;

const sample =
    \\{
    \\  "company_name": "Example Energy Ltd",
    \\  "company_address": "1 Sample Street, Exampletown",
    \\  "client_name": "A. Customer",
    \\  "client_address": "2 Test Road\nExampletown",
    \\  "reference": "EX-2026-0001",
    \\  "footer": { "phone": "0300 000 0000", "email": "hello@example.com", "website": "www.example.com",
    \\              "dashboard_text": "Your dashboard – quotes and progress" },
    \\  "sections": [
    \\    { "type": "text", "heading": "Why choose us – in brief",
    \\      "content": "We’re “local”.\n- MCS Certified installer — required for grants\n✓ Approved installer for the scheme\nDone in 2–4 weeks." },
    \\    { "type": "metrics", "heading": "Your system",
    \\      "metric_items": [ { "label": "CO₂ Offset", "value": "1.2 t/yr" }, { "label": "Savings", "value": "£1,240/yr" } ] },
    \\    { "type": "table", "heading": "System pricing",
    \\      "table_items": [ { "description": "Solar panel 455 W — all black", "quantity": 10, "unit_price": 75.60, "total": 756.00 } ],
    \\      "subtotal": 756.00, "total": 756.00, "notes": "VAT is 0% on qualifying materials — see the guidance." },
    \\    { "type": "chart", "heading": "Energy use",
    \\      "chart_spec": { "chart_type": "progress", "segments": [ { "label": "Self-use ≥ 60%", "value": 62 } ] } }
    \\  ]
    \\}
;

fn render(a: std.mem.Allocator, json: []const u8) ![]u8 {
    return proposal.generateProposalFromJson(a, json);
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

test "proposal text: pounds, dashes, quotes and bullets draw as themselves, never as ?" {
    const a = testing.allocator;
    const pdf = try render(a, sample);
    defer a.free(pdf);
    const text = try extractedText(a, pdf);
    defer a.free(text);

    try expectContains(text, "£75.60");
    try expectContains(text, "£756.00");
    try expectContains(text, "£1,240/yr");
    try expectContains(text, "•");
    try expectContains(text, "MCS Certified installer — required for grants");
    try expectContains(text, "Solar panel 455 W — all black");
    try expectContains(text, "We’re “local”.");
    try expectContains(text, "2–4 weeks");
    try expectContains(text, "Why choose us – in brief");
    try expectContains(text, "Your dashboard – quotes and progress");
    // Outside WinAnsi: the subscript becomes its digit, ≥ becomes ">=".
    try expectContains(text, "CO2 Offset");
    try expectContains(text, "Self-use >= 60%");
    try expectContains(text, "Approved installer for the scheme");
    if (std.mem.indexOfScalar(u8, text, '?')) |at| {
        std.debug.print("a '?' was drawn near \"{s}\"\n", .{text[at -| 40..@min(text.len, at + 40)]});
        return error.QuestionMarkDrawn;
    }
    // The tick is a stroked path with round caps and joins.
    try testing.expect(std.mem.indexOf(u8, pdf, "1 J 1 j") != null);
    // £ is WinAnsi byte 0xA3, the bullet 0x95, the em dash 0x97.
    try testing.expect(std.mem.indexOf(u8, pdf, "(\xa375.60)") != null);
    try testing.expect(std.mem.indexOf(u8, pdf, "(\x95)") != null);
}

test "drawableText keeps WinAnsi text, folds what it lacks, drops the rest" {
    const a = testing.allocator;
    const cases = [_][2][]const u8{
        .{ "plain ASCII, even a ?", "plain ASCII, even a ?" },
        .{ "£75.60 – “quoted” — €5 •", "£75.60 – “quoted” — €5 •" },
        .{ "\u{2714} done \u{2713}", "\u{2713} done \u{2713}" },
        .{ "CO\u{2082} \u{2265} 2 \u{2192} x", "CO2 >= 2 -> x" },
        .{ "a\u{2009}b\u{200B}c", "a bc" },
        .{ "emoji \u{1F600} gone", "emoji  gone" },
        .{ "bad \xff\xfe bytes", "bad  bytes" },
        .{ "cut \xe2\x80", "cut " },
    };
    for (cases) |c| {
        const got = try proposal.drawableText(a, c[0]);
        defer a.free(got);
        try testing.expectEqualStrings(c[1], got);
    }
}
