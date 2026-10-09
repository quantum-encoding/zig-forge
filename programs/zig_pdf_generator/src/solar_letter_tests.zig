//! Tests for solar letters, driven by the samples in templates/solar-letter/
//! (read at run time; `zig build test` pins the cwd to the package root).

const std = @import("std");
const solar_letter = @import("solar_letter.zig");

const testing = std.testing;
const sample_dir = "templates/solar-letter/";

fn readSample(a: std.mem.Allocator, name: []const u8) ![]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const path = try std.fmt.allocPrint(a, sample_dir ++ "{s}.json", .{name});
    defer a.free(path);
    return std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1024 * 1024));
}

/// A sample with one edit applied: `path` is a list of object keys (or array
/// indexes as decimal strings); the last step is set to `value`, or removed
/// when `value` is null.
fn edited(a: std.mem.Allocator, name: []const u8, path: []const []const u8, value: ?std.json.Value) ![]u8 {
    const src = try readSample(a, name);
    var root = try std.json.parseFromSliceLeaky(std.json.Value, a, src, .{});
    var node = &root;
    for (path[0 .. path.len - 1]) |step| {
        node = switch (node.*) {
            .object => |*o| o.getPtr(step).?,
            .array => |*arr| &arr.items[try std.fmt.parseInt(usize, step, 10)],
            else => unreachable,
        };
    }
    const last = path[path.len - 1];
    if (value) |v| {
        try node.object.put(a, last, v);
    } else {
        _ = node.object.orderedRemove(last);
    }
    return std.json.Stringify.valueAlloc(a, root, .{});
}

fn expectRefusal(json: []const u8, want: solar_letter.Error, needle: []const u8) !void {
    var diag = solar_letter.Diagnostic{};
    const result = solar_letter.generate(testing.allocator, json, &diag);
    if (result) |pdf| {
        testing.allocator.free(pdf);
        std.debug.print("expected {s} mentioning '{s}', got a PDF\n", .{ @errorName(want), needle });
        return error.TestExpectedError;
    } else |err| {
        try testing.expectEqual(want, err);
        if (std.mem.indexOf(u8, diag.text(), needle) == null) {
            std.debug.print("diagnostic '{s}' does not mention '{s}'\n", .{ diag.text(), needle });
            return error.TestUnexpectedDiagnostic;
        }
    }
}

test "every sample renders a one-page PDF" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "price", "finance", "grant" }) |name| {
        const json = try readSample(arena.allocator(), name);
        var diag = solar_letter.Diagnostic{};
        const pdf = solar_letter.generate(testing.allocator, json, &diag) catch |err| {
            std.debug.print("{s}: {s}: {s}\n", .{ name, @errorName(err), diag.text() });
            return err;
        };
        defer testing.allocator.free(pdf);
        try testing.expect(std.mem.startsWith(u8, pdf, "%PDF-"));
        try testing.expectEqual(@as(usize, 1), std.mem.count(u8, pdf, "/Type /Page /"));
    }
}

test "a missing field is named" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectRefusal(try edited(a, "price", &.{ "letter", "headline" }, null), error.InvalidInput, "letter.headline is required");
    try expectRefusal(try edited(a, "price", &.{ "installer", "logo" }, null), error.InvalidInput, "installer.logo is required");
    try expectRefusal(try edited(a, "price", &.{"image"}, null), error.InvalidInput, "input.image is required");
}

test "a finance offer needs every part of the representative example" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "apr", "total_payable", "credit", "term_months", "interest_rate", "cash_price", "deposit", "lender" }) |field| {
        try expectRefusal(try edited(a, "finance", &.{ "offer", field }, null), error.InvalidInput, field);
    }
}

test "unknown fields are refused, including a price on a grant letter" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectRefusal(try edited(a, "grant", &.{ "offer", "price" }, .{ .string = "£0" }), error.InvalidInput, "unknown field 'price'");
    try expectRefusal(try edited(a, "price", &.{ "letter", "headlin" }, .{ .string = "typo" }), error.InvalidInput, "unknown field 'headlin'");
}

test "values the letter can't print or use are refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectRefusal(try edited(a, "price", &.{ "letter", "headline" }, .{ .string = "Sunny days \u{2600}" }), error.InvalidInput, "can't print");
    try expectRefusal(try edited(a, "price", &.{ "letter", "qr_url" }, .{ .string = "http://example.com" }), error.InvalidInput, "https://");
    try expectRefusal(try edited(a, "price", &.{ "installer", "theme", "primary_hex" }, .{ .string = "blue" }), error.InvalidInput, "primary_hex");
    try expectRefusal(try edited(a, "price", &.{ "letter", "headline_highlight" }, .{ .string = "seventeen panels" }), error.InvalidInput, "not part of the headline");
    try expectRefusal(try edited(a, "price", &.{ "offer", "kind" }, .{ .string = "loan" }), error.InvalidInput, "price, finance or grant");
    try expectRefusal(try edited(a, "price", &.{ "image", "src" }, .{ .string = "bm90IGFuIGltYWdl" }), error.ImageInvalid, "image.src");
}

test "text too long for its space is refused, not squeezed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const long = "Your roof has room for 16 solar panels and a battery, and it faces the right way to make the most of the sun all year round, every year.";
    try expectRefusal(try edited(a, "price", &.{ "letter", "headline" }, .{ .string = long }), error.TooLong, "letter.headline");
}
