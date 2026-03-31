//! UUID Generation Library (Zig 0.16)
//!
//! Implements RFC 4122 UUID versions 1, 4, and 7:
//! - v1: Time-based with MAC address (or random node)
//! - v4: Purely random
//! - v7: Unix timestamp-based (sortable)
//!
//! Example:
//! ```zig
//! const uuid = @import("uuid");
//!
//! // Generate random UUID (v4)
//! const id = uuid.v4();
//! std.debug.print("{}\n", .{id});
//!
//! // Generate sortable timestamp UUID (v7)
//! const sortable_id = uuid.v7();
//! ```

const std = @import("std");
const mem = std.mem;
const fmt = std.fmt;

/// UUID representation as 128 bits
pub const UUID = struct {
    bytes: [16]u8,

    pub const nil: UUID = .{ .bytes = .{0} ** 16 };

    /// UUID variant (RFC 4122)
    pub const Variant = enum {
        ncs, // Reserved for NCS backward compatibility
        rfc4122, // The variant specified in RFC 4122
        microsoft, // Reserved for Microsoft backward compatibility
        future, // Reserved for future definition
    };

    /// UUID version
    pub const Version = enum(u4) {
        unknown = 0,
        v1 = 1, // Time-based
        v2 = 2, // DCE Security
        v3 = 3, // MD5 hash
        v4 = 4, // Random
        v5 = 5, // SHA-1 hash
        v6 = 6, // Reordered time-based
        v7 = 7, // Unix timestamp
        v8 = 8, // Custom
    };

    /// Get the variant of this UUID
    pub fn getVariant(self: UUID) Variant {
        const byte = self.bytes[8];
        if ((byte & 0x80) == 0) return .ncs;
        if ((byte & 0xC0) == 0x80) return .rfc4122;
        if ((byte & 0xE0) == 0xC0) return .microsoft;
        return .future;
    }

    /// Get the version of this UUID
    pub fn getVersion(self: UUID) Version {
        const version_nibble = self.bytes[6] >> 4;
        return @enumFromInt(version_nibble);
    }

    /// Check if this UUID is nil (all zeros)
    pub fn isNil(self: UUID) bool {
        return mem.eql(u8, &self.bytes, &nil.bytes);
    }

    /// Convert to standard string format (lowercase)
    pub fn format(
        self: UUID,
        comptime _: []const u8,
        _: fmt.FormatOptions,
        writer: anytype,
    ) !void {
        const hex = "0123456789abcdef";
        var buf: [36]u8 = undefined;
        var i: usize = 0;
        var j: usize = 0;

        while (i < 16) : (i += 1) {
            if (i == 4 or i == 6 or i == 8 or i == 10) {
                buf[j] = '-';
                j += 1;
            }
            buf[j] = hex[self.bytes[i] >> 4];
            buf[j + 1] = hex[self.bytes[i] & 0x0F];
            j += 2;
        }

        try writer.writeAll(&buf);
    }

    /// Convert to string
    pub fn toString(self: UUID) [36]u8 {
        const hex = "0123456789abcdef";
        var buf: [36]u8 = undefined;
        var i: usize = 0;
        var j: usize = 0;

        while (i < 16) : (i += 1) {
            if (i == 4 or i == 6 or i == 8 or i == 10) {
                buf[j] = '-';
                j += 1;
            }
            buf[j] = hex[self.bytes[i] >> 4];
            buf[j + 1] = hex[self.bytes[i] & 0x0F];
            j += 2;
        }
        return buf;
    }

    /// Convert to uppercase string
    pub fn toStringUpper(self: UUID) [36]u8 {
        var buf = self.toString();
        for (&buf) |*c| {
            if (c.* >= 'a' and c.* <= 'f') {
                c.* = c.* - 'a' + 'A';
            }
        }
        return buf;
    }

    /// Convert to URN format
    pub fn toUrn(self: UUID) [45]u8 {
        var buf: [45]u8 = undefined;
        @memcpy(buf[0..9], "urn:uuid:");
        const uuid_str = self.toString();
        @memcpy(buf[9..45], &uuid_str);
        return buf;
    }

    /// Get timestamp from v1 or v7 UUID
    pub fn getTimestamp(self: UUID) ?u64 {
        return switch (self.getVersion()) {
            .v1 => blk: {
                const time_low = mem.readInt(u32, self.bytes[0..4], .big);
                const time_mid = mem.readInt(u16, self.bytes[4..6], .big);
                const time_hi = mem.readInt(u16, self.bytes[6..8], .big) & 0x0FFF;
                break :blk (@as(u64, time_hi) << 48) | (@as(u64, time_mid) << 32) | time_low;
            },
            .v7 => blk: {
                const ms = mem.readInt(u48, self.bytes[0..6], .big);
                break :blk @as(u64, ms) * 1_000_000;
            },
            else => null,
        };
    }

    /// Compare two UUIDs
    pub fn compare(a: UUID, b: UUID) std.math.Order {
        return mem.order(u8, &a.bytes, &b.bytes);
    }

    /// Check equality
    pub fn eql(self: UUID, other: UUID) bool {
        return mem.eql(u8, &self.bytes, &other.bytes);
    }

    /// Hash for use in hash maps
    pub fn hash(self: UUID) u64 {
        return std.hash.Wyhash.hash(0, &self.bytes);
    }
};

/// Parse a UUID from string
pub fn parse(str: []const u8) !UUID {
    if (str.len < 32) return error.InvalidLength;

    var uuid: UUID = undefined;
    var byte_idx: usize = 0;
    var i: usize = 0;

    while (i < str.len and byte_idx < 16) {
        if (str[i] == '-' or str[i] == '{' or str[i] == '}') {
            i += 1;
            continue;
        }

        if (i + 1 >= str.len) return error.InvalidLength;

        const high = try parseHexDigit(str[i]);
        const low = try parseHexDigit(str[i + 1]);
        uuid.bytes[byte_idx] = (@as(u8, high) << 4) | @as(u8, low);

        byte_idx += 1;
        i += 2;
    }

    if (byte_idx != 16) return error.InvalidLength;
    return uuid;
}

fn parseHexDigit(c: u8) !u4 {
    return switch (c) {
        '0'...'9' => @intCast(c - '0'),
        'a'...'f' => @intCast(c - 'a' + 10),
        'A'...'F' => @intCast(c - 'A' + 10),
        else => error.InvalidHexDigit,
    };
}

// ============================================================================
// Random Number Generator (Thread-local PRNG)
// ============================================================================

var prng: std.Random.Xoshiro256 = undefined;
var prng_initialized = false;

fn getRandom() std.Random {
    if (!prng_initialized) {
        // Seed from memory addresses (simple entropy source)
        const addr = @intFromPtr(&prng);
        const addr2 = @intFromPtr(&prng_initialized);
        const seed: u64 = addr ^ (addr2 << 32) ^ 0xDEADBEEFCAFEBABE;
        prng = std.Random.Xoshiro256.init(seed);
        prng_initialized = true;
    }
    return prng.random();
}

fn fillRandom(buf: []u8) void {
    getRandom().bytes(buf);
}

fn getTimestampNs() i128 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.REALTIME, &ts) == 0) {
        return @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
    }
    return 0;
}

fn getTimestampMs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.REALTIME, &ts) == 0) {
        return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
    }
    return 0;
}

// ============================================================================
// UUID Generation Functions
// ============================================================================

/// Generate a v1 UUID (time-based with random node)
pub fn v1() UUID {
    return v1WithNode(null);
}

/// Generate a v1 UUID with specific node ID
pub fn v1WithNode(node: ?[6]u8) UUID {
    var uuid: UUID = undefined;

    // Get current time
    const now_ns = getTimestampNs();
    const uuid_epoch_offset: i128 = 122192928000000000;
    const timestamp: u60 = @intCast(@as(u128, @intCast(now_ns)) / 100 + @as(u128, @intCast(uuid_epoch_offset)));

    mem.writeInt(u32, uuid.bytes[0..4], @truncate(timestamp), .big);
    mem.writeInt(u16, uuid.bytes[4..6], @truncate(timestamp >> 32), .big);
    mem.writeInt(u16, uuid.bytes[6..8], @as(u16, 0x1000) | @as(u12, @truncate(timestamp >> 48)), .big);

    var clock_seq: [2]u8 = undefined;
    fillRandom(&clock_seq);
    uuid.bytes[8] = (clock_seq[0] & 0x3F) | 0x80;
    uuid.bytes[9] = clock_seq[1];

    if (node) |n| {
        @memcpy(uuid.bytes[10..16], &n);
    } else {
        fillRandom(uuid.bytes[10..16]);
        uuid.bytes[10] |= 0x01;
    }

    return uuid;
}

/// Generate a v4 UUID (random)
pub fn v4() UUID {
    var uuid: UUID = undefined;
    fillRandom(&uuid.bytes);

    uuid.bytes[6] = (uuid.bytes[6] & 0x0F) | 0x40;
    uuid.bytes[8] = (uuid.bytes[8] & 0x3F) | 0x80;

    return uuid;
}

/// Generate a v7 UUID (Unix timestamp-based)
pub fn v7() UUID {
    return v7WithTimestamp(null);
}

/// Generate a v7 UUID with specific timestamp
pub fn v7WithTimestamp(timestamp_ms: ?u48) UUID {
    var uuid: UUID = undefined;

    const ms: u48 = timestamp_ms orelse @intCast(getTimestampMs());

    mem.writeInt(u48, uuid.bytes[0..6], ms, .big);
    fillRandom(uuid.bytes[6..16]);

    uuid.bytes[6] = (uuid.bytes[6] & 0x0F) | 0x70;
    uuid.bytes[8] = (uuid.bytes[8] & 0x3F) | 0x80;

    return uuid;
}

/// Generate multiple v4 UUIDs efficiently
pub fn v4Batch(uuids: []UUID) void {
    const bytes: [*]u8 = @ptrCast(uuids.ptr);
    fillRandom(bytes[0 .. uuids.len * 16]);

    for (uuids) |*uuid| {
        uuid.bytes[6] = (uuid.bytes[6] & 0x0F) | 0x40;
        uuid.bytes[8] = (uuid.bytes[8] & 0x3F) | 0x80;
    }
}

/// Generate multiple v7 UUIDs efficiently
pub fn v7Batch(uuids: []UUID) void {
    var ms: u48 = @intCast(getTimestampMs());

    for (uuids) |*uuid| {
        mem.writeInt(u48, uuid.bytes[0..6], ms, .big);
        fillRandom(uuid.bytes[6..16]);
        uuid.bytes[6] = (uuid.bytes[6] & 0x0F) | 0x70;
        uuid.bytes[8] = (uuid.bytes[8] & 0x3F) | 0x80;
        ms +%= 1; // Increment to ensure uniqueness
    }
}

/// Generate a v3 UUID (MD5 name-based)
pub fn v3(namespace: UUID, name: []const u8) UUID {
    var uuid: UUID = undefined;

    var hasher = std.crypto.hash.Md5.init(.{});
    hasher.update(&namespace.bytes);
    hasher.update(name);
    var digest: [16]u8 = undefined;
    hasher.final(&digest);

    @memcpy(&uuid.bytes, &digest);

    // Set version to 3
    uuid.bytes[6] = (uuid.bytes[6] & 0x0F) | 0x30;
    // Set variant to RFC 4122
    uuid.bytes[8] = (uuid.bytes[8] & 0x3F) | 0x80;

    return uuid;
}

/// Generate a v5 UUID (SHA-1 name-based)
pub fn v5(namespace: UUID, name: []const u8) UUID {
    var uuid: UUID = undefined;

    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(&namespace.bytes);
    hasher.update(name);
    var digest: [20]u8 = undefined;
    hasher.final(&digest);

    // Take first 16 bytes of SHA-1 hash
    @memcpy(&uuid.bytes, digest[0..16]);

    // Set version to 5
    uuid.bytes[6] = (uuid.bytes[6] & 0x0F) | 0x50;
    // Set variant to RFC 4122
    uuid.bytes[8] = (uuid.bytes[8] & 0x3F) | 0x80;

    return uuid;
}

// ============================================================================
// Namespace UUIDs (for v3/v5)
// ============================================================================

pub const namespace_dns = parse("6ba7b810-9dad-11d1-80b4-00c04fd430c8") catch unreachable;
pub const namespace_url = parse("6ba7b811-9dad-11d1-80b4-00c04fd430c8") catch unreachable;
pub const namespace_oid = parse("6ba7b812-9dad-11d1-80b4-00c04fd430c8") catch unreachable;
pub const namespace_x500 = parse("6ba7b814-9dad-11d1-80b4-00c04fd430c8") catch unreachable;

// ============================================================================
// Tests
// ============================================================================

test "v4 format" {
    const id = v4();
    try std.testing.expectEqual(UUID.Version.v4, id.getVersion());
    try std.testing.expectEqual(UUID.Variant.rfc4122, id.getVariant());
}

test "v7 format" {
    const id = v7();
    try std.testing.expectEqual(UUID.Version.v7, id.getVersion());
    try std.testing.expectEqual(UUID.Variant.rfc4122, id.getVariant());
}

test "parse valid uuid" {
    const id = try parse("550e8400-e29b-41d4-a716-446655440000");
    try std.testing.expectEqual(UUID.Version.v4, id.getVersion());
}

test "nil uuid" {
    try std.testing.expect(UUID.nil.isNil());
    try std.testing.expect(!v4().isNil());
}

test "v3 deterministic generation" {
    const uuid1 = v3(namespace_dns, "example.com");
    const uuid2 = v3(namespace_dns, "example.com");
    try std.testing.expect(uuid1.eql(uuid2));
}

test "v5 deterministic generation" {
    const uuid1 = v5(namespace_dns, "example.com");
    const uuid2 = v5(namespace_dns, "example.com");
    try std.testing.expect(uuid1.eql(uuid2));
}

test "v3 != v5 for same inputs" {
    const uuid_v3 = v3(namespace_dns, "example.com");
    const uuid_v5 = v5(namespace_dns, "example.com");
    try std.testing.expect(!uuid_v3.eql(uuid_v5));
}

test "v3 version and variant bits" {
    const id = v3(namespace_dns, "test");
    try std.testing.expectEqual(UUID.Version.v3, id.getVersion());
    try std.testing.expectEqual(UUID.Variant.rfc4122, id.getVariant());
}

test "v5 version and variant bits" {
    const id = v5(namespace_dns, "test");
    try std.testing.expectEqual(UUID.Version.v5, id.getVersion());
    try std.testing.expectEqual(UUID.Variant.rfc4122, id.getVariant());
}

test "parse error on invalid hex" {
    const result = parse("550e8400-e29b-41d4-a716-44665544000z");
    try std.testing.expectError(error.InvalidHexDigit, result);
}

test "parse error on wrong length" {
    const result = parse("550e8400-e29b-41d4");
    try std.testing.expectError(error.InvalidLength, result);
}

test "parse error on too short" {
    const result = parse("abc");
    try std.testing.expectError(error.InvalidLength, result);
}

test "v1 generation and timestamp extraction" {
    const id = v1();
    try std.testing.expectEqual(UUID.Version.v1, id.getVersion());
    try std.testing.expectEqual(UUID.Variant.rfc4122, id.getVariant());
    const ts = id.getTimestamp();
    try std.testing.expect(ts != null);
}

test "v7 monotonic ordering" {
    const uuid1 = v7();
    const uuid2 = v7();
    const cmp = UUID.compare(uuid1, uuid2);
    // uuid2 should be >= uuid1 (likely greater due to timestamp increment)
    try std.testing.expect(cmp != .gt);
}

test "batch generation produces unique UUIDs" {
    var batch: [10]UUID = undefined;
    v4Batch(&batch);

    // Check that all UUIDs are unique
    for (0..batch.len) |i| {
        for (i + 1..batch.len) |j| {
            try std.testing.expect(!batch[i].eql(batch[j]));
        }
    }
}

test "toString/toStringUpper/toUrn roundtrip" {
    const id = v4();
    const str = id.toString();
    _ = id.toStringUpper(); // Verify function works without errors
    const urn = id.toUrn();

    // Parse back
    const parsed = try parse(&str);
    try std.testing.expect(id.eql(parsed));

    // Check URN format
    try std.testing.expect(std.mem.startsWith(u8, &urn, "urn:uuid:"));
}

test "compare and equality" {
    const id1 = v4();
    const id2 = v4();
    const cmp = UUID.compare(id1, id2);
    try std.testing.expect(cmp != .eq); // Very unlikely to be equal

    const id_same = id1;
    try std.testing.expect(id1.eql(id_same));
}

test "hash consistency" {
    const id1 = v4();
    const h1 = id1.hash();
    const h2 = id1.hash();
    try std.testing.expectEqual(h1, h2);
}

test "nil UUID string format" {
    const nil_str = UUID.nil.toString();
    try std.testing.expect(std.mem.eql(u8, &nil_str, "00000000-0000-0000-0000-000000000000"));
}
