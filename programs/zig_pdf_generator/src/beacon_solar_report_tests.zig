//! Tests for the Beacon solar proposal: the rendered text carries the quote's
//! own figures and none of the template's leftovers.

const std = @import("std");
const report = @import("beacon_solar_report.zig");
const pdf_extract = @import("pdf_extract.zig");

const testing = std.testing;

/// Render a quote and return its extracted text (caller frees).
fn renderedText(a: std.mem.Allocator, q: report.CrgQuote) ![]u8 {
    const pdf = try report.generateCrgSolarReport(a, q);
    defer a.free(pdf);
    var result = try pdf_extract.extractToMdx(a, pdf, .{});
    defer result.deinit(a);
    return a.dupe(u8, result.mdx);
}

test "the report has 20 pages" {
    const a = testing.allocator;
    const pdf = try report.generateCrgSolarReport(a, .{});
    defer a.free(pdf);
    try testing.expectEqual(@as(usize, 20), std.mem.count(u8, pdf, "/Type /Page\n") + std.mem.count(u8, pdf, "/Type /Page "));
}

test "no template placeholder or survey-visit wording reaches the customer" {
    const a = testing.allocator;
    const text = try renderedText(a, .{});
    defer a.free(text);
    const banned = [_][]const u8{
        "{%",
        "idiot",
        "Surveyor was",
        "Really nice to meet you",
        "Having visited your property",
        "approx’",
        "5.5p per kWh",
    };
    for (banned) |s| {
        if (std.mem.indexOf(u8, text, s) != null) {
            std.debug.print("rendered text contains \"{s}\"\n", .{s});
            return error.BannedText;
        }
    }
}

test "the figures come from the quote" {
    const a = testing.allocator;
    const text = try renderedText(a, .{
        .total_price = "9,523",
        .self_use_pct = "85",
        .seg_rate = "0.15",
        .company_name = "Acme Solar Ltd",
        .bank_account_no = "12345678",
    });
    defer a.free(text);
    for ([_][]const u8{ "£9,523", "85%", "£0.15", "Acme Solar Ltd", "12345678" }) |s| {
        if (std.mem.indexOf(u8, text, s) == null) {
            std.debug.print("rendered text is missing \"{s}\"\n", .{s});
            return error.MissingText;
        }
    }
}

test "a quote without a battery offers none" {
    const a = testing.allocator;
    const text = try renderedText(a, .{ .has_battery = false });
    defer a.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "Battery Storage System") == null);
    try testing.expect(std.mem.indexOf(u8, text, "N/A (no battery)") != null);
}

test "the VAT rate follows the quote date" {
    try testing.expectEqualStrings("0%", report.vatRate("2026-10-23"));
    try testing.expectEqualStrings("0%", report.vatRate("2027-03-31"));
    try testing.expectEqualStrings("5%", report.vatRate("2027-04-01"));
    try testing.expectEqualStrings("5%", report.vatRate("2028-01-15"));
}
