//! RFC 8785 (JSON Canonicalization Scheme) encoder.
//!
//! Why this exists: the ledger's tamper-evidence is a hash chain. A hash is only
//! stable across languages (Zig sink, Go proxy, Swift app) if every implementation
//! serialises the *same* JSON object to the *same* bytes. RFC 8785 pins that:
//!   - object keys sorted by their UTF-16 code units (NOT Unicode code points —
//!     astral chars sort by their leading surrogate, e.g. U+1F600 < U+FB33),
//!   - no insignificant whitespace,
//!   - strings escaped exactly per ECMAScript JSON.stringify (only U+0000–U+001F,
//!     '"' and '\\' escaped; everything else, including non-ASCII, emitted raw UTF-8),
//!   - numbers serialised deterministically.
//!
//! Deliberate scope decision (a guardrail, not a gap): this `Value` has NO float
//! variant. RFC 8785 number serialisation for floats requires the ECMAScript
//! shortest-round-trip (Ryū) algorithm, which is the single biggest source of
//! cross-language hash divergence. The ledger schema is float-free by design —
//! all magnitudes (seq, nanosecond timestamps, byte counts) are carried as
//! decimal *strings* so they are never subject to IEEE-754 ambiguity, and are
//! also exact above 2^53 (which JSON numbers are not). Small bounded counts use
//! `.int`. If a float is ever genuinely needed, add the variant *with* a
//! conformant ECMAScript serialiser and test vectors — do not hand-wave it.

const std = @import("std");

pub const Value = union(enum) {
    null,
    bool: bool,
    /// JSON integer. Only use for small, bounded values (e.g. schema version).
    /// Anything that can exceed 2^53 MUST be carried as `.string` decimal.
    int: i64,
    /// Raw UTF-8. Emitted with JCS escaping; non-ASCII passes through unescaped.
    string: []const u8,
    array: []const Value,
    object: []const Member,
};

pub const Member = struct {
    key: []const u8,
    value: Value,
};

const Buf = std.ArrayList(u8);

/// Append the RFC 8785 canonical serialisation of `v` to `out`.
pub fn encode(allocator: std.mem.Allocator, out: *Buf, v: Value) (std.mem.Allocator.Error || error{InvalidUtf8})!void {
    switch (v) {
        .null => try out.appendSlice(allocator, "null"),
        .bool => |b| try out.appendSlice(allocator, if (b) "true" else "false"),
        .int => |n| {
            var buf: [24]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch unreachable;
            try out.appendSlice(allocator, s);
        },
        .string => |s| try writeString(allocator, out, s),
        .array => |arr| {
            try out.append(allocator, '[');
            for (arr, 0..) |elem, i| {
                if (i != 0) try out.append(allocator, ',');
                try encode(allocator, out, elem);
            }
            try out.append(allocator, ']');
        },
        .object => |members| {
            // Sort member indices by UTF-16 code-unit order of their keys.
            const idx = try allocator.alloc(usize, members.len);
            defer allocator.free(idx);
            for (idx, 0..) |*p, i| p.* = i;
            std.mem.sort(usize, idx, members, lessThanByKey);

            try out.append(allocator, '{');
            for (idx, 0..) |mi, i| {
                if (i != 0) try out.append(allocator, ',');
                try writeString(allocator, out, members[mi].key);
                try out.append(allocator, ':');
                try encode(allocator, out, members[mi].value);
            }
            try out.append(allocator, '}');
        },
    }
}

/// Convenience: canonicalise into a freshly-allocated, caller-owned slice.
pub fn encodeAlloc(allocator: std.mem.Allocator, v: Value) ![]u8 {
    var out: Buf = .empty;
    errdefer out.deinit(allocator);
    try encode(allocator, &out, v);
    return out.toOwnedSlice(allocator);
}

fn lessThanByKey(members: []const Member, a: usize, b: usize) bool {
    return compareUtf16(members[a].key, members[b].key) == .lt;
}

/// RFC 8785 string production (ECMAScript JSON.stringify escaping).
fn writeString(allocator: std.mem.Allocator, out: *Buf, s: []const u8) !void {
    try out.append(allocator, '"');
    for (s) |b| {
        switch (b) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            0x08 => try out.appendSlice(allocator, "\\b"),
            0x09 => try out.appendSlice(allocator, "\\t"),
            0x0A => try out.appendSlice(allocator, "\\n"),
            0x0C => try out.appendSlice(allocator, "\\f"),
            0x0D => try out.appendSlice(allocator, "\\r"),
            else => {
                if (b < 0x20) {
                    // Remaining C0 controls have no short escape → \u00XX (lowercase).
                    const hex = "0123456789abcdef";
                    try out.appendSlice(allocator, "\\u00");
                    try out.append(allocator, hex[b >> 4]);
                    try out.append(allocator, hex[b & 0x0F]);
                } else {
                    // Printable ASCII and every byte of a multi-byte UTF-8 sequence
                    // (all >= 0x80) pass through verbatim — JCS does NOT \u-escape
                    // non-ASCII.
                    try out.append(allocator, b);
                }
            },
        }
    }
    try out.append(allocator, '"');
}

/// Lazily yields the UTF-16 code units of a UTF-8 string. Invalid bytes are
/// surfaced as their raw value so sorting is still total (canonicalisation of a
/// validated event never hits this path).
const Utf16Iter = struct {
    bytes: []const u8,
    i: usize = 0,
    pending: ?u16 = null,

    fn next(self: *Utf16Iter) ?u16 {
        if (self.pending) |lo| {
            self.pending = null;
            return lo;
        }
        if (self.i >= self.bytes.len) return null;
        const len = std.unicode.utf8ByteSequenceLength(self.bytes[self.i]) catch {
            const b = self.bytes[self.i];
            self.i += 1;
            return b;
        };
        if (self.i + len > self.bytes.len) {
            const b = self.bytes[self.i];
            self.i += 1;
            return b;
        }
        const cp = std.unicode.utf8Decode(self.bytes[self.i .. self.i + len]) catch {
            const b = self.bytes[self.i];
            self.i += 1;
            return b;
        };
        self.i += len;
        if (cp <= 0xFFFF) return @intCast(cp);
        const c = cp - 0x10000;
        const hi: u16 = @intCast(0xD800 + (c >> 10));
        const lo: u16 = @intCast(0xDC00 + (c & 0x3FF));
        self.pending = lo;
        return hi;
    }
};

/// Compare two UTF-8 strings as RFC 8785 requires: by their UTF-16 code units.
pub fn compareUtf16(a: []const u8, b: []const u8) std.math.Order {
    var ia: Utf16Iter = .{ .bytes = a };
    var ib: Utf16Iter = .{ .bytes = b };
    while (true) {
        const ua = ia.next();
        const ub = ib.next();
        if (ua == null and ub == null) return .eq;
        if (ua == null) return .lt;
        if (ub == null) return .gt;
        if (ua.? < ub.?) return .lt;
        if (ua.? > ub.?) return .gt;
    }
}

// ───────────────────────────── tests ─────────────────────────────

const testing = std.testing;

test "RFC 8785 §3.2.3 object-key sorting (UTF-16, incl. surrogate ordering)" {
    // External anchor: the property-sorting example from RFC 8785. Keys given in
    // scrambled order; expected output sorted by UTF-16 code unit. The critical
    // case is U+1F600 (😀, leading surrogate 0xD83D) sorting BEFORE U+FB33
    // (דּ, 0xFB33) — a code-point sort would put it after.
    const v = Value{ .object = &[_]Member{
        .{ .key = "\u{20ac}", .value = .{ .string = "Euro Sign" } },
        .{ .key = "\r", .value = .{ .string = "Carriage Return" } },
        .{ .key = "\u{fb33}", .value = .{ .string = "Hebrew Letter Dalet With Dagesh" } },
        .{ .key = "1", .value = .{ .string = "One" } },
        .{ .key = "\u{1f600}", .value = .{ .string = "Emoji: Grinning Face" } },
        .{ .key = "\u{0080}", .value = .{ .string = "Control" } },
        .{ .key = "\u{00f6}", .value = .{ .string = "Latin Small Letter O With Diaeresis" } },
    } };
    const out = try encodeAlloc(testing.allocator, v);
    defer testing.allocator.free(out);

    const expected =
        "{\"\\r\":\"Carriage Return\"," ++
        "\"1\":\"One\"," ++
        "\"\u{0080}\":\"Control\"," ++
        "\"\u{00f6}\":\"Latin Small Letter O With Diaeresis\"," ++
        "\"\u{20ac}\":\"Euro Sign\"," ++
        "\"\u{1f600}\":\"Emoji: Grinning Face\"," ++
        "\"\u{fb33}\":\"Hebrew Letter Dalet With Dagesh\"}";
    try testing.expectEqualStrings(expected, out);
}

test "JCS string escaping of control chars, quote and backslash" {
    const v = Value{ .string = "a\"b\\c\n\t\r\x00\x07\x1f\u{00e9}" };
    const out = try encodeAlloc(testing.allocator, v);
    defer testing.allocator.free(out);
    // NUL/bell/US escape to lower-hex \u00XX; e-acute passes raw as UTF-8.
    try testing.expectEqualStrings("\"a\\\"b\\\\c\\n\\t\\r\\u0000\\u0007\\u001f\u{00e9}\"", out);
}

test "key order is irrelevant to canonical bytes" {
    const a = Value{ .object = &[_]Member{
        .{ .key = "b", .value = .{ .int = 2 } },
        .{ .key = "a", .value = .{ .int = 1 } },
        .{ .key = "c", .value = .{ .array = &[_]Value{ .{ .bool = true }, .null } } },
    } };
    const b = Value{ .object = &[_]Member{
        .{ .key = "c", .value = .{ .array = &[_]Value{ .{ .bool = true }, .null } } },
        .{ .key = "a", .value = .{ .int = 1 } },
        .{ .key = "b", .value = .{ .int = 2 } },
    } };
    const oa = try encodeAlloc(testing.allocator, a);
    defer testing.allocator.free(oa);
    const ob = try encodeAlloc(testing.allocator, b);
    defer testing.allocator.free(ob);
    try testing.expectEqualStrings("{\"a\":1,\"b\":2,\"c\":[true,null]}", oa);
    try testing.expectEqualStrings(oa, ob);
}
