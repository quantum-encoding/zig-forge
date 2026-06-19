//! JSON entry point for the "letter" document type.
//!
//! A letter is a Markdown body flowed through the multi-page engine in
//! `markdown.zig`, framed by an optional letterhead + signature, painted on top
//! of an optional full-page background image. This module only does JSON →
//! `markdown.LetterInput`; all rendering lives in `markdown.zig`.
//!
//! Input shape:
//! ```json
//! {
//!   "body_markdown": "Dear Sir,\n\nThank you for...\n\n| Item | Qty |\n|---|---|\n| A | 1 |",
//!   "background_image": "data:image/jpeg;base64,...",  // or a file path, or raw base64
//!   "background_opacity": 1.0,                          // <1 => faint/watermark
//!   "background_fit": "cover",                          // cover | contain | stretch
//!   "company_name": "Quantum Encoding Ltd",
//!   "company_address": "33 Oxford Street\nCoalville, LE67 3GS",
//!   "sender_contact": "hello@quantumencoding.io · +44 ...",
//!   "date": "19 June 2026",
//!   "reference": "QE-2026-014",
//!   "recipient_name": "Richard Tune",
//!   "recipient_address": "Calle Arquímedes 60\n29100 Coín, Málaga",
//!   "subject": "Domain recovery",
//!   "closing": "Yours sincerely,",
//!   "signature_name": "R. A. Tune",
//!   "signature_title": "Director",
//!   "accent_hex": "#1f6feb",
//!   "margin": 64
//! }
//! ```

const std = @import("std");
const markdown = @import("markdown.zig");

pub const Error = error{ InvalidJson, OutOfMemory };

/// Parse the letter JSON and render a PDF. Caller owns the returned bytes.
/// String fields are borrowed from the parsed document, which is kept alive
/// until `generateLetter` returns (it copies everything it needs synchronously).
pub fn generateLetterFromJson(allocator: std.mem.Allocator, json_str: []const u8) Error![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch {
        return error.InvalidJson;
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidJson;
    const o = parsed.value.object;

    var in = markdown.LetterInput{};
    in.body_markdown = getStr(o, "body_markdown");
    in.background_image = getStr(o, "background_image");
    in.background_opacity = getF32(o, "background_opacity", 1.0);
    in.background_fit = parseFit(getStr(o, "background_fit"));
    in.company_name = getStr(o, "company_name");
    in.company_address = getStr(o, "company_address");
    in.sender_contact = getStr(o, "sender_contact");
    in.date = getStr(o, "date");
    in.reference = getStr(o, "reference");
    in.recipient_name = getStr(o, "recipient_name");
    in.recipient_address = getStr(o, "recipient_address");
    in.subject = getStr(o, "subject");
    in.closing = getStr(o, "closing");
    in.signature_name = getStr(o, "signature_name");
    in.signature_title = getStr(o, "signature_title");
    const accent = getStr(o, "accent_hex");
    if (accent.len > 0) in.accent_hex = accent;
    in.margin = getF32(o, "margin", 64);

    return markdown.generateLetter(allocator, in) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidJson,
    };
}

fn parseFit(s: []const u8) markdown.BackgroundFit {
    if (std.mem.eql(u8, s, "contain")) return .contain;
    if (std.mem.eql(u8, s, "stretch")) return .stretch;
    return .cover;
}

fn getStr(obj: std.json.ObjectMap, key: []const u8) []const u8 {
    if (obj.get(key)) |v| if (v == .string) return v.string;
    return "";
}

fn getF32(obj: std.json.ObjectMap, key: []const u8, default: f32) f32 {
    if (obj.get(key)) |v| switch (v) {
        .float => return @floatCast(v.float),
        .integer => return @floatFromInt(v.integer),
        else => {},
    };
    return default;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "letter: markdown body + letterhead renders a valid multi-page PDF" {
    const a = testing.allocator;
    // A body long enough to force a page break, plus a table.
    const input =
        \\{"company_name":"Quantum Encoding Ltd",
        \\ "company_address":"33 Oxford Street\nCoalville, LE67 3GS",
        \\ "date":"19 June 2026","recipient_name":"Richard Tune",
        \\ "recipient_address":"Calle Arquimedes 60\n29100 Coin, Malaga",
        \\ "subject":"Domain recovery","closing":"Yours sincerely,",
        \\ "signature_name":"R. A. Tune","signature_title":"Director",
        \\ "body_markdown":"Dear Richard,\n\nThank you for your instruction. This letter confirms the recovery of the domain.\n\n## Summary\n\n| Item | Amount |\n|---|---|\n| Recovery | 12.99 |\n| Admin | 25.00 |\n\nParagraph one is here with enough words to take up space on the page so that we can exercise the flowing layout engine across more than a single line and ideally across a page boundary when repeated. Paragraph one is here with enough words to take up space.\n\nParagraph two continues the prose. Paragraph two continues the prose. Paragraph two continues the prose. Paragraph two continues the prose. Paragraph two continues the prose. Paragraph two continues the prose.\n\n- Point one\n- Point two\n- Point three\n\nWe trust this is in order."}
    ;
    const pdf = try generateLetterFromJson(a, input);
    defer a.free(pdf);
    try testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4"));
    try testing.expect(std.mem.endsWith(u8, pdf, "%%EOF\n"));
    try testing.expect(pdf.len > 1000);
}

test "letter: missing background source still renders" {
    const a = testing.allocator;
    const input =
        \\{"company_name":"Acme","body_markdown":"Hello world.","background_image":"/nonexistent/path.png"}
    ;
    // A bad background must NOT fail the document — it renders without one.
    const pdf = try generateLetterFromJson(a, input);
    defer a.free(pdf);
    try testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4"));
}

test "letter: invalid json errors" {
    const a = testing.allocator;
    try testing.expectError(error.InvalidJson, generateLetterFromJson(a, "not json"));
    try testing.expectError(error.InvalidJson, generateLetterFromJson(a, "[1,2,3]"));
}
