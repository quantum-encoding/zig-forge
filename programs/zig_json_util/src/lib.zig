//! zig_json_util — shared helpers for safely building JSON payloads.
//!
//! This package exists because two separate in-tree projects (zig_ai_server
//! and electrum_ffi) had `std.fmt.allocPrint("…{s}…", .{user_string})`
//! patterns that interpolate user-controlled strings into JSON without
//! escaping — a textbook JSON-injection vector. The canonical fix lived in
//! `gcp_auth/src/jwt.zig::jsonEscape`; this module is the shared home so
//! every JSON-building site can call the same audited primitive.
//!
//! ## API
//!
//!   - `jsonEscape(allocator, input) ![]u8` — allocator-owned escaped slice.
//!     Drop-in replacement for `gcp_auth.jwt.jsonEscape`.
//!
//!   - `appendEscaped(allocator, list, input) !void` — append escaped
//!     bytes directly to an `ArrayListUnmanaged(u8)`. Use this when
//!     building a larger JSON document incrementally; avoids the
//!     dupe-and-copy of `jsonEscape`.
//!
//!   - `appendQuotedString(allocator, list, input) !void` — same as
//!     `appendEscaped`, but wraps the result in `"…"`. The most common
//!     call shape for JSON value position.
//!
//! ## What it escapes
//!
//! Per RFC 8259 §7:
//!   * `"`  → `\"`
//!   * `\`  → `\\`
//!   * `\n` → `\n`, `\r` → `\r`, `\t` → `\t`
//!   * other U+0000..U+001F control chars → `\u00XX`
//!
//! All other bytes (including bytes ≥ 0x80, which form UTF-8 sequences)
//! are passed through unchanged. UTF-8 validity is the caller's
//! responsibility — the JSON spec allows raw UTF-8 in string values and
//! many JSON parsers reject lone surrogates / overlong sequences anyway.

const std = @import("std");

const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

/// Return a fresh allocator-owned slice containing `input` with all bytes
/// that JSON string-value syntax requires escaped per RFC 8259 §7.
///
/// Identical to `gcp_auth/src/jwt.zig::jsonEscape` — the two have been
/// kept bit-for-bit compatible during the consolidation. If you find a
/// behavioral difference, prefer THIS version and patch gcp_auth.
pub fn jsonEscape(allocator: Allocator, input: []const u8) ![]u8 {
    var list: ArrayListUnmanaged(u8) = .empty;
    errdefer list.deinit(allocator);
    try appendEscaped(allocator, &list, input);
    return list.toOwnedSlice(allocator);
}

/// Append the JSON-escaped bytes of `input` to `list`. Does NOT add
/// surrounding quotes — use `appendQuotedString` for that.
pub fn appendEscaped(
    allocator: Allocator,
    list: *ArrayListUnmanaged(u8),
    input: []const u8,
) !void {
    for (input) |c| {
        switch (c) {
            '"' => try list.appendSlice(allocator, "\\\""),
            '\\' => try list.appendSlice(allocator, "\\\\"),
            '\n' => try list.appendSlice(allocator, "\\n"),
            '\r' => try list.appendSlice(allocator, "\\r"),
            '\t' => try list.appendSlice(allocator, "\\t"),
            0x08 => try list.appendSlice(allocator, "\\b"),
            0x0c => try list.appendSlice(allocator, "\\f"),
            0x00...0x07, 0x0b, 0x0e...0x1f => {
                // Remaining U+0000..U+001F control characters — \u00XX
                const hex = "0123456789abcdef";
                const buf = [_]u8{ '\\', 'u', '0', '0', hex[c >> 4], hex[c & 0x0f] };
                try list.appendSlice(allocator, &buf);
            },
            else => try list.append(allocator, c),
        }
    }
}

/// Append `"`, then the JSON-escaped bytes of `input`, then `"`. The most
/// common call shape — produces a complete JSON string-value literal in
/// one call.
pub fn appendQuotedString(
    allocator: Allocator,
    list: *ArrayListUnmanaged(u8),
    input: []const u8,
) !void {
    try list.append(allocator, '"');
    try appendEscaped(allocator, list, input);
    try list.append(allocator, '"');
}

// ============================================================================
// Tests
//
// Three tiers per the in-tree audit rule:
//   Tier 1 — externally-anchored vectors (RFC 8259 §7 example strings)
//   Tier 2 — failure / injection-attempt cases
//   Tier 3 — internal-consistency roundtrips via std.json
// ============================================================================

const testing = std.testing;

// ----- Tier 1: RFC 8259 §7 mandatory escapes -----

test "tier1: standard escapes — quote, backslash, newline, tab, CR, BS, FF" {
    const out = try jsonEscape(testing.allocator, "\"\\\n\t\r\x08\x0c");
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u8, "\\\"\\\\\\n\\t\\r\\b\\f", out);
}

test "tier1: control characters U+0000..U+001F become \\u00XX" {
    const out = try jsonEscape(testing.allocator, "\x00\x01\x07\x0b\x1f");
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u8, "\\u0000\\u0001\\u0007\\u000b\\u001f", out);
}

test "tier1: ASCII passes through unchanged" {
    const out = try jsonEscape(testing.allocator, "Hello, World! 123 abc");
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u8, "Hello, World! 123 abc", out);
}

test "tier1: UTF-8 multi-byte sequences pass through" {
    // "café 🎉" — bytes ≥ 0x80 form valid UTF-8 and must not be touched.
    const input = "caf\xC3\xA9 \xF0\x9F\x8E\x89";
    const out = try jsonEscape(testing.allocator, input);
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u8, input, out);
}

test "tier1: empty input returns empty slice" {
    const out = try jsonEscape(testing.allocator, "");
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u8, "", out);
}

// ----- Tier 2: JSON-injection attempts -----

test "tier2: quote-injection cannot break out of a string value" {
    // Pre-audit: pasting this into `"name":"{s}"` produced
    //     "name":"","admin":true,"x":""
    // — the consumer parses "admin":true as a SEPARATE key, granting
    //   admin privileges via the user-supplied name.
    const attack = "\",\"admin\":true,\"x\":\"";
    const out = try jsonEscape(testing.allocator, attack);
    defer testing.allocator.free(out);

    // After escaping, every quote is preceded by a backslash; the entire
    // attack payload is harmless content inside one string.
    try testing.expectEqualSlices(
        u8,
        "\\\",\\\"admin\\\":true,\\\"x\\\":\\\"",
        out,
    );

    // Wrap in quotes and parse — must round-trip as a single string field.
    var buf: ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try buf.appendSlice(testing.allocator, "{\"name\":");
    try appendQuotedString(testing.allocator, &buf, attack);
    try buf.append(testing.allocator, '}');

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, buf.items, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
    // Should have exactly ONE field: "name". No injected "admin", no "x".
    try testing.expectEqual(@as(u32, 1), parsed.value.object.count());
    try testing.expectEqualSlices(u8, attack, parsed.value.object.get("name").?.string);
}

test "tier2: backslash-injection cannot create an escape sequence" {
    // If we only escape quotes, a payload of `\"` would still break out
    // (the consumer sees `\"` as the literal escape `"` in JSON).
    // Escaping the backslash to `\\` and the quote to `\"` produces `\\"`
    // — a backslash followed by an end-of-string quote? Let me think again.
    // Actually escape order: input "\\" → output "\\\\"; input "\"" → "\\\"".
    // So input `\"` → output `\\\"` — interpreted by JSON as the literal
    // two-character string `\"`. Safe.
    const attack = "\\\"";
    const out = try jsonEscape(testing.allocator, attack);
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u8, "\\\\\\\"", out);

    // Round-trip through std.json to prove it parses as the literal input.
    var buf: ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try appendQuotedString(testing.allocator, &buf, attack);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, buf.items, .{});
    defer parsed.deinit();
    try testing.expectEqualSlices(u8, attack, parsed.value.string);
}

test "tier2: newline-injection cannot terminate a string" {
    // Some JSON consumers (notably older parsers) treat a literal newline
    // inside a string as a terminator. Per spec these must be \n-escaped.
    const attack = "line1\nline2";
    const out = try jsonEscape(testing.allocator, attack);
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u8, "line1\\nline2", out);
}

test "tier2: every byte in 0x00..0x1F gets escaped (no raw control bytes)" {
    var input: [32]u8 = undefined;
    for (0..32) |i| input[i] = @intCast(i);

    const out = try jsonEscape(testing.allocator, &input);
    defer testing.allocator.free(out);

    // Every byte in the output must be in the printable-ASCII set:
    // alnum, backslash, double quote, n/t/r/b/f/u, or hex digits. No
    // raw control bytes can survive.
    for (out) |c| {
        try testing.expect(c >= 0x20 and c < 0x7f);
    }
}

// ----- Tier 3: std.json roundtrip on a built object -----

test "tier3: a full object built with appendQuotedString round-trips" {
    var buf: ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(testing.allocator);

    try buf.appendSlice(testing.allocator, "{");
    try appendQuotedString(testing.allocator, &buf, "name");
    try buf.append(testing.allocator, ':');
    try appendQuotedString(testing.allocator, &buf, "Alice \"the boss\" Smith\nLine 2\t\\path");
    try buf.appendSlice(testing.allocator, ",");
    try appendQuotedString(testing.allocator, &buf, "age");
    try buf.appendSlice(testing.allocator, ":30}");

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, buf.items, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
    try testing.expectEqualSlices(
        u8,
        "Alice \"the boss\" Smith\nLine 2\t\\path",
        parsed.value.object.get("name").?.string,
    );
    try testing.expectEqual(@as(i64, 30), parsed.value.object.get("age").?.integer);
}
