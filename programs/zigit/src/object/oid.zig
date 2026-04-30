// 20-byte SHA-1 object identifier.
//
// We always carry the raw bytes; hex is only generated on
// formatting. Prefix lookups (the "≥ 4 chars" thing git supports
// in cat-file etc.) are handled via `prefix_bytes` + `prefix_nibbles`
// so we don't have to convert the whole loose-store contents to hex
// every time someone passes a short id.

const std = @import("std");

pub const Oid = struct {
    bytes: [20]u8,

    pub fn fromHex(hex: []const u8) !Oid {
        if (hex.len != 40) return error.InvalidOidLength;
        var oid: Oid = undefined;
        _ = try std.fmt.hexToBytes(&oid.bytes, hex);
        return oid;
    }

    pub fn toHex(self: Oid, out: *[40]u8) void {
        const charset = "0123456789abcdef";
        for (self.bytes, 0..) |b, i| {
            out[i * 2 + 0] = charset[b >> 4];
            out[i * 2 + 1] = charset[b & 0xf];
        }
    }

    pub fn toHexAlloc(self: Oid, allocator: std.mem.Allocator) ![]u8 {
        const buf = try allocator.alloc(u8, 40);
        self.toHex(buf[0..40]);
        return buf;
    }

    pub fn eql(a: Oid, b: Oid) bool {
        return std.mem.eql(u8, &a.bytes, &b.bytes);
    }
};

/// A user-supplied prefix, ≥ 4 hex characters and ≤ 40.
///
/// Stored as the matching whole-byte prefix plus an optional dangling
/// nibble. `matches(oid)` checks both halves.
pub const OidPrefix = struct {
    bytes: [20]u8,
    bytes_len: u8,
    has_half_byte: bool,

    pub fn fromHex(hex: []const u8) !OidPrefix {
        if (hex.len < 4 or hex.len > 40) return error.OidPrefixOutOfRange;
        var prefix: OidPrefix = .{ .bytes = undefined, .bytes_len = 0, .has_half_byte = false };
        const full_pairs = hex.len / 2;
        _ = try std.fmt.hexToBytes(prefix.bytes[0..full_pairs], hex[0 .. full_pairs * 2]);
        prefix.bytes_len = @intCast(full_pairs);
        if (hex.len % 2 == 1) {
            prefix.has_half_byte = true;
            const last = hex[hex.len - 1];
            const nib = try std.fmt.charToDigit(last, 16);
            // Stash the half-byte in the slot that matches() will read.
            prefix.bytes[prefix.bytes_len] = nib << 4;
        }
        return prefix;
    }

    pub fn matches(self: OidPrefix, oid: Oid) bool {
        if (!std.mem.eql(u8, oid.bytes[0..self.bytes_len], self.bytes[0..self.bytes_len])) return false;
        if (!self.has_half_byte) return true;
        return (oid.bytes[self.bytes_len] & 0xf0) == self.bytes[self.bytes_len];
    }
};

test "Oid round-trip hex" {
    const hex = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391";
    const oid = try Oid.fromHex(hex);
    var buf: [40]u8 = undefined;
    oid.toHex(&buf);
    try std.testing.expectEqualStrings(hex, &buf);
}

test "Oid eql" {
    const a = try Oid.fromHex("0123456789abcdef0123456789abcdef01234567");
    const b = try Oid.fromHex("0123456789abcdef0123456789abcdef01234567");
    const c = try Oid.fromHex("0123456789abcdef0123456789abcdef01234568");
    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
}

test "OidPrefix matches whole-byte prefix" {
    const oid = try Oid.fromHex("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391");
    const p = try OidPrefix.fromHex("e69de29b");
    try std.testing.expect(p.matches(oid));
    const q = try OidPrefix.fromHex("e69de29c");
    try std.testing.expect(!q.matches(oid));
}

test "OidPrefix matches odd-length prefix" {
    const oid = try Oid.fromHex("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391");
    try std.testing.expect((try OidPrefix.fromHex("e69d")).matches(oid));
    try std.testing.expect((try OidPrefix.fromHex("e69de")).matches(oid));
    try std.testing.expect((try OidPrefix.fromHex("e69de2")).matches(oid));
    try std.testing.expect(!(try OidPrefix.fromHex("e69df")).matches(oid));
}

test "OidPrefix rejects too-short / too-long" {
    try std.testing.expectError(error.OidPrefixOutOfRange, OidPrefix.fromHex("abc"));
    try std.testing.expectError(error.OidPrefixOutOfRange, OidPrefix.fromHex("a" ** 41));
}
