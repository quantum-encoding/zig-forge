/// Lightweight zero-copy JSON key-value extractor for market data.
///
/// Designed for the hot path: no allocations, no recursion, no full parse tree.
/// Returns slices into the original buffer — perfect for mbuf data.
///
/// Handles the common exchange message format:
///   {"e":"depthUpdate","s":"BTCUSDT","b":[["50000.00","1.5"]],"a":[...]}
///
/// For full SIMD-accelerated parsing, swap this with market_data_parser.
/// This module provides the minimum viable parser for the pipeline.

const std = @import("std");

/// Find the value for a given key in a JSON object. Returns a slice into
/// the input buffer pointing to the value (string contents without quotes,
/// or the raw value for numbers/arrays/objects).
///
/// Zero-copy: no allocation, no string building.
pub fn findValue(buf: []const u8, key: []const u8) ?[]const u8 {
    // Scan for "key": pattern
    var i: usize = 0;
    while (i + key.len + 3 < buf.len) {
        // Find opening quote of key
        if (buf[i] == '"') {
            const key_start = i + 1;
            if (key_start + key.len < buf.len and
                std.mem.eql(u8, buf[key_start .. key_start + key.len], key))
            {
                const after_key = key_start + key.len;
                if (after_key < buf.len and buf[after_key] == '"') {
                    // Found "key" — skip to colon and value
                    var j = after_key + 1;
                    while (j < buf.len and (buf[j] == ' ' or buf[j] == ':' or buf[j] == '\t')) : (j += 1) {}
                    if (j >= buf.len) return null;
                    return extractValue(buf, j);
                }
            }
        }
        i += 1;
    }
    return null;
}

/// Extract a JSON value starting at position i. Returns the value slice.
fn extractValue(buf: []const u8, start: usize) ?[]const u8 {
    if (start >= buf.len) return null;

    switch (buf[start]) {
        '"' => {
            // String value — return contents without quotes
            const str_start = start + 1;
            var j = str_start;
            while (j < buf.len) : (j += 1) {
                if (buf[j] == '"' and (j == str_start or buf[j - 1] != '\\')) {
                    return buf[str_start..j];
                }
            }
            return null;
        },
        '[' => {
            // Array — return including brackets
            var depth: u32 = 1;
            var j = start + 1;
            while (j < buf.len and depth > 0) : (j += 1) {
                if (buf[j] == '[') depth += 1;
                if (buf[j] == ']') depth -= 1;
            }
            return buf[start..j];
        },
        '{' => {
            // Object — return including braces
            var depth: u32 = 1;
            var j = start + 1;
            while (j < buf.len and depth > 0) : (j += 1) {
                if (buf[j] == '{') depth += 1;
                if (buf[j] == '}') depth -= 1;
            }
            return buf[start..j];
        },
        else => {
            // Number, bool, null — scan to next delimiter
            var j = start;
            while (j < buf.len and buf[j] != ',' and buf[j] != '}' and
                buf[j] != ']' and buf[j] != ' ' and buf[j] != '\n') : (j += 1)
            {}
            if (j > start) return buf[start..j];
            return null;
        },
    }
}

/// Parse a JSON array of [price, quantity] pairs from order book data.
/// Calls the callback for each pair. Format: [["50000.00","1.5"],["49999.00","0.8"]]
pub fn iteratePriceLevels(
    arr: []const u8,
    comptime callback: fn (price: []const u8, qty: []const u8) void,
) void {
    if (arr.len < 4) return; // minimum: [[]]
    var i: usize = 1; // skip outer [

    while (i < arr.len) {
        // Find inner array start
        if (arr[i] == '[') {
            i += 1;
            // Find price string
            if (i < arr.len and arr[i] == '"') {
                const price_start = i + 1;
                i = price_start;
                while (i < arr.len and arr[i] != '"') : (i += 1) {}
                const price = arr[price_start..i];
                i += 1; // skip closing quote

                // Skip comma
                while (i < arr.len and (arr[i] == ',' or arr[i] == ' ')) : (i += 1) {}

                // Find quantity string
                if (i < arr.len and arr[i] == '"') {
                    const qty_start = i + 1;
                    i = qty_start;
                    while (i < arr.len and arr[i] != '"') : (i += 1) {}
                    const qty = arr[qty_start..i];
                    i += 1; // skip closing quote

                    callback(price, qty);
                }
            }
        }
        i += 1;
    }
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "json_kv: find string value" {
    const json = "{\"e\":\"depthUpdate\",\"s\":\"BTCUSDT\"}";
    const event = findValue(json, "e").?;
    try testing.expectEqualStrings("depthUpdate", event);
    const symbol = findValue(json, "s").?;
    try testing.expectEqualStrings("BTCUSDT", symbol);
}

test "json_kv: find number value" {
    const json = "{\"id\":12345,\"price\":50000.50}";
    const id = findValue(json, "id").?;
    try testing.expectEqualStrings("12345", id);
    const price = findValue(json, "price").?;
    try testing.expectEqualStrings("50000.50", price);
}

test "json_kv: find array value" {
    const json = "{\"b\":[[\"50000\",\"1.5\"],[\"49999\",\"0.8\"]],\"a\":[]}";
    const bids = findValue(json, "b").?;
    try testing.expect(bids[0] == '[');
    try testing.expect(bids[bids.len - 1] == ']');
    const asks = findValue(json, "a").?;
    try testing.expectEqualStrings("[]", asks);
}

test "json_kv: missing key returns null" {
    const json = "{\"e\":\"trade\"}";
    try testing.expect(findValue(json, "missing") == null);
}

test "json_kv: empty input" {
    try testing.expect(findValue("", "key") == null);
    try testing.expect(findValue("{}", "key") == null);
}

test "json_kv: iterate price levels" {
    const arr = "[[\"50000.00\",\"1.5\"],[\"49999.00\",\"0.8\"]]";
    var count: u32 = 0;
    const Counter = struct {
        var c: u32 = 0;
        fn cb(_: []const u8, _: []const u8) void {
            c += 1;
        }
    };
    Counter.c = 0;
    iteratePriceLevels(arr, Counter.cb);
    count = Counter.c;
    try testing.expectEqual(@as(u32, 2), count);
}
