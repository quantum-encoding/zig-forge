//! Bloom Filter Implementation
//!
//! A space-efficient probabilistic data structure for membership testing.
//! Supports: may be in set (with false positive rate) or definitely not in set.
//!
//! Features:
//! - Configurable false positive rate
//! - Automatic optimal sizing
//! - Union and intersection operations
//! - Versioned serialization (`encodeAlloc` / `decodeAlloc`, little-endian,
//!   self-describing header) plus a raw `rawBits()` view of the bit words
//!
//! Not thread-safe: concurrent `add` on one filter races. Guard externally.
//!
//! Example:
//! ```zig
//! // Create bloom filter for 10000 items with 1% false positive rate
//! var bf = try BloomFilter.initCapacity(allocator, 10000, 0.01);
//! defer bf.deinit();
//!
//! bf.add("hello");
//! if (bf.contains("hello")) { ... }
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const math = std.math;

/// On-disk / on-wire container for a serialized filter.
///
/// The pre-0.2 `serialize()` returned a bare `sliceAsBytes(bits)` dump with no
/// parameter header — two filters with different `num_bits`/`num_hashes`
/// produced byte streams that were indistinguishable, so a decoder could not
/// tell whether a blob was compatible with the filter it was being loaded
/// into. This header makes the format self-describing and versioned; the raw
/// word view is still available as `rawBits()` / `rawCounters()`.
///
/// Layout (all integers little-endian, so the byte stream is identical on
/// big-endian hosts):
///
///     off  size  field
///     0    4     magic "ZBLM"
///     4    1     format version (currently 1)
///     5    1     kind: 0 = BloomFilter (u64 words), 1 = CountingBloomFilter (u8 counters)
///     6    2     reserved, must be 0
///     8    8     num_bits (BloomFilter) / num_counters (CountingBloomFilter)
///     16   4     num_hashes
///     20   8     count (items inserted)
///     28   ...   payload: ceil(num_bits/64) u64 words, or num_counters u8 bytes
pub const format = struct {
    pub const magic = [4]u8{ 'Z', 'B', 'L', 'M' };
    pub const version: u8 = 1;
    pub const header_len: usize = 28;

    pub const Kind = enum(u8) { bloom = 0, counting = 1 };

    pub const Header = struct {
        kind: Kind,
        len: u64, // num_bits or num_counters
        num_hashes: u32,
        count: u64,
    };

    pub fn writeHeader(buf: []u8, h: Header) void {
        std.debug.assert(buf.len >= header_len);
        @memcpy(buf[0..4], &magic);
        buf[4] = version;
        buf[5] = @intFromEnum(h.kind);
        buf[6] = 0;
        buf[7] = 0;
        std.mem.writeInt(u64, buf[8..16], h.len, .little);
        std.mem.writeInt(u32, buf[16..20], h.num_hashes, .little);
        std.mem.writeInt(u64, buf[20..28], h.count, .little);
    }

    pub fn readHeader(data: []const u8, expected: Kind) !Header {
        if (data.len < header_len) return error.TruncatedData;
        if (!std.mem.eql(u8, data[0..4], &magic)) return error.BadMagic;
        if (data[4] != version) return error.UnsupportedVersion;
        if (data[5] != @intFromEnum(expected)) return error.KindMismatch;
        if (data[6] != 0 or data[7] != 0) return error.ReservedNotZero;

        const h = Header{
            .kind = expected,
            .len = std.mem.readInt(u64, data[8..16], .little),
            .num_hashes = std.mem.readInt(u32, data[16..20], .little),
            .count = std.mem.readInt(u64, data[20..28], .little),
        };
        // A zero length would make the `% num_bits` in addHashed a division by
        // zero; a zero hash count makes `contains` vacuously true for every
        // input. Both are attacker-useful in a decoded blob, so refuse them.
        if (h.len == 0) return error.InvalidLength;
        if (h.num_hashes == 0) return error.InvalidHashCount;
        return h;
    }

    /// Narrow a header field to `usize`. On a 32-bit target a blob can declare
    /// a length or count larger than `usize` holds; refuse rather than
    /// truncating (a truncated length would size the allocation from one value
    /// and index it with another).
    pub fn toUsize(v: u64) !usize {
        return std.math.cast(usize, v) orelse error.ValueTooLarge;
    }
};

/// Standard Bloom Filter
pub fn BloomFilter(comptime T: type) type {
    return struct {
        bits: []u64,
        num_bits: usize,
        num_hashes: u32,
        count: usize,
        allocator: Allocator,

        const Self = @This();
        const BITS_PER_WORD: usize = 64;

        /// Initialize with specific bit count and hash count
        pub fn init(allocator: Allocator, num_bits: usize, num_hashes: u32) !Self {
            const num_words = (num_bits + BITS_PER_WORD - 1) / BITS_PER_WORD;
            const bits = try allocator.alloc(u64, num_words);
            @memset(bits, 0);

            return Self{
                .bits = bits,
                .num_bits = num_bits,
                .num_hashes = num_hashes,
                .count = 0,
                .allocator = allocator,
            };
        }

        /// Initialize with expected capacity and desired false positive rate
        pub fn initCapacity(allocator: Allocator, expected_items: usize, fp_rate: f64) !Self {
            // Guard against degenerate inputs before any @intFromFloat: a zero
            // item count makes k = (m/n)*ln2 a 0/0 NaN, and an out-of-range
            // fp_rate makes m infinite (<=0) or zero-or-negative (>=1). Feeding
            // NaN/inf into @intFromFloat below is illegal behavior. The
            // `!(x > 0 ...)` form also rejects NaN (all NaN comparisons are false).
            if (expected_items == 0) return error.InvalidCapacity;
            if (!(fp_rate > 0.0 and fp_rate < 1.0)) return error.InvalidFPRate;

            // Optimal number of bits: m = -n * ln(p) / (ln(2)^2)
            const n = @as(f64, @floatFromInt(expected_items));
            const ln2_sq = @log(@as(f64, 2.0)) * @log(@as(f64, 2.0));
            const m = @as(usize, @intFromFloat(-n * @log(fp_rate) / ln2_sq));

            // Optimal number of hash functions: k = (m/n) * ln(2)
            const k = @as(u32, @intFromFloat(@as(f64, @floatFromInt(m)) / n * @log(@as(f64, 2.0))));

            return init(allocator, @max(m, 64), @max(k, 1));
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.bits);
        }

        /// Add an item to the filter
        pub fn add(self: *Self, item: T) void {
            var h1: u64 = undefined;
            var h2: u64 = undefined;
            hashItem(item, &h1, &h2);
            self.addHashed(h1, h2);
        }

        /// Add raw bytes to the filter
        pub fn addBytes(self: *Self, data: []const u8) void {
            var h1: u64 = undefined;
            var h2: u64 = undefined;
            doubleHash(data, &h1, &h2);
            self.addHashed(h1, h2);
        }

        fn addHashed(self: *Self, h1: u64, h2: u64) void {
            var i: u32 = 0;
            while (i < self.num_hashes) : (i += 1) {
                const combined = h1 +% @as(u64, i) *% h2;
                const bit_idx = combined % self.num_bits;
                self.setBit(bit_idx);
            }
            self.count += 1;
        }

        /// Check if an item may be in the filter
        /// Returns true if item may be present, false if definitely not present
        pub fn contains(self: *const Self, item: T) bool {
            var h1: u64 = undefined;
            var h2: u64 = undefined;
            hashItem(item, &h1, &h2);
            return self.containsHashed(h1, h2);
        }

        /// Check if raw bytes may be in the filter
        pub fn containsBytes(self: *const Self, data: []const u8) bool {
            var h1: u64 = undefined;
            var h2: u64 = undefined;
            doubleHash(data, &h1, &h2);
            return self.containsHashed(h1, h2);
        }

        fn containsHashed(self: *const Self, h1: u64, h2: u64) bool {
            var i: u32 = 0;
            while (i < self.num_hashes) : (i += 1) {
                const combined = h1 +% @as(u64, i) *% h2;
                const bit_idx = combined % self.num_bits;
                if (!self.getBit(bit_idx)) return false;
            }
            return true;
        }

        /// Get the current estimated false positive rate
        pub fn estimatedFPRate(self: *const Self) f64 {
            const m = @as(f64, @floatFromInt(self.num_bits));
            const n = @as(f64, @floatFromInt(self.count));
            const k = @as(f64, @floatFromInt(self.num_hashes));

            // FP rate ≈ (1 - e^(-kn/m))^k
            const exponent = -k * n / m;
            return math.pow(f64, 1.0 - @exp(exponent), k);
        }

        /// Get fill ratio (bits set / total bits)
        pub fn fillRatio(self: *const Self) f64 {
            var set_bits: usize = 0;
            for (self.bits) |word| {
                set_bits += @popCount(word);
            }
            return @as(f64, @floatFromInt(set_bits)) / @as(f64, @floatFromInt(self.num_bits));
        }

        /// Union of two bloom filters (modifies self)
        pub fn unionWith(self: *Self, other: *const Self) !void {
            if (self.num_bits != other.num_bits or self.num_hashes != other.num_hashes) {
                return error.IncompatibleFilters;
            }
            for (self.bits, other.bits) |*a, b| {
                a.* |= b;
            }
        }

        /// Intersection of two bloom filters (modifies self)
        pub fn intersectWith(self: *Self, other: *const Self) !void {
            if (self.num_bits != other.num_bits or self.num_hashes != other.num_hashes) {
                return error.IncompatibleFilters;
            }
            for (self.bits, other.bits) |*a, b| {
                a.* &= b;
            }
        }

        /// Clear the filter
        pub fn clear(self: *Self) void {
            @memset(self.bits, 0);
            self.count = 0;
        }

        /// Raw view of the backing bit words, in host byte order. Not a
        /// portable serialization format — use `encodeAlloc` for that.
        pub fn rawBits(self: *const Self) []const u64 {
            return self.bits;
        }

        /// Serialize to a versioned, self-describing, little-endian blob.
        /// Caller owns the returned memory.
        pub fn encodeAlloc(self: *const Self, allocator: Allocator) ![]u8 {
            const out = try allocator.alloc(u8, format.header_len + self.bits.len * 8);
            errdefer allocator.free(out);

            format.writeHeader(out, .{
                .kind = .bloom,
                .len = self.num_bits,
                .num_hashes = self.num_hashes,
                .count = self.count,
            });
            for (self.bits, 0..) |word, i| {
                const off = format.header_len + i * 8;
                std.mem.writeInt(u64, out[off..][0..8], word, .little);
            }
            return out;
        }

        /// Reconstruct a filter from `encodeAlloc` output. The result owns its
        /// own memory; `deinit` it as usual.
        pub fn decodeAlloc(allocator: Allocator, data: []const u8) !Self {
            const h = try format.readHeader(data, .bloom);

            const num_bits = try format.toUsize(h.len);
            const count = try format.toUsize(h.count);
            const num_words = (num_bits + BITS_PER_WORD - 1) / BITS_PER_WORD;
            if (data.len != format.header_len + num_words * 8) return error.LengthMismatch;

            var self = try init(allocator, num_bits, h.num_hashes);
            errdefer self.deinit();

            for (self.bits, 0..) |*word, i| {
                const off = format.header_len + i * 8;
                word.* = std.mem.readInt(u64, data[off..][0..8], .little);
            }
            self.count = count;
            return self;
        }

        // Internal helpers
        fn setBit(self: *Self, bit_idx: usize) void {
            const word_idx = bit_idx / BITS_PER_WORD;
            const bit_offset: u6 = @intCast(bit_idx % BITS_PER_WORD);
            self.bits[word_idx] |= @as(u64, 1) << bit_offset;
        }

        fn getBit(self: *const Self, bit_idx: usize) bool {
            const word_idx = bit_idx / BITS_PER_WORD;
            const bit_offset: u6 = @intCast(bit_idx % BITS_PER_WORD);
            return (self.bits[word_idx] & (@as(u64, 1) << bit_offset)) != 0;
        }

        /// Compute both hashes for an item. For non-slice types the bytes are
        /// hashed *inside* this frame while the by-value `item` copy is still
        /// live — returning `std.mem.asBytes(&item)` to a caller would dangle
        /// into this function's dead stack frame (the same fix already applied
        /// to HyperLogLog.hashItem).
        fn hashItem(item: T, h1: *u64, h2: *u64) void {
            if (T == []const u8) {
                doubleHash(item, h1, h2);
                return;
            } else if (@typeInfo(T) == .pointer) {
                const child = @typeInfo(T).pointer.child;
                if (child == u8) {
                    doubleHash(item, h1, h2);
                    return;
                }
            }
            doubleHash(std.mem.asBytes(&item), h1, h2);
        }

        fn doubleHash(data: []const u8, h1: *u64, h2: *u64) void {
            // Use two different hash functions
            h1.* = std.hash.Wyhash.hash(0, data);
            h2.* = std.hash.Wyhash.hash(0x517cc1b727220a95, data);
        }
    };
}

/// Counting Bloom Filter (supports deletion)
pub fn CountingBloomFilter(comptime T: type) type {
    return struct {
        counters: []u8,
        num_counters: usize,
        num_hashes: u32,
        count: usize,
        allocator: Allocator,

        const Self = @This();
        const MAX_COUNT: u8 = 255;

        pub fn init(allocator: Allocator, num_counters: usize, num_hashes: u32) !Self {
            const counters = try allocator.alloc(u8, num_counters);
            @memset(counters, 0);

            return Self{
                .counters = counters,
                .num_counters = num_counters,
                .num_hashes = num_hashes,
                .count = 0,
                .allocator = allocator,
            };
        }

        pub fn initCapacity(allocator: Allocator, expected_items: usize, fp_rate: f64) !Self {
            // Guard against degenerate inputs before any @intFromFloat (see the
            // BloomFilter.initCapacity comment above): NaN/inf into @intFromFloat
            // is illegal behavior.
            if (expected_items == 0) return error.InvalidCapacity;
            if (!(fp_rate > 0.0 and fp_rate < 1.0)) return error.InvalidFPRate;

            const n = @as(f64, @floatFromInt(expected_items));
            const ln2_sq = @log(@as(f64, 2.0)) * @log(@as(f64, 2.0));
            const m = @as(usize, @intFromFloat(-n * @log(fp_rate) / ln2_sq));
            const k = @as(u32, @intFromFloat(@as(f64, @floatFromInt(m)) / n * @log(@as(f64, 2.0))));

            return init(allocator, @max(m, 64), @max(k, 1));
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.counters);
        }

        pub fn add(self: *Self, item: T) void {
            var h1: u64 = undefined;
            var h2: u64 = undefined;
            hashItem(item, &h1, &h2);
            self.addHashed(h1, h2);
        }

        pub fn addBytes(self: *Self, data: []const u8) void {
            var h1: u64 = undefined;
            var h2: u64 = undefined;
            doubleHash(data, &h1, &h2);
            self.addHashed(h1, h2);
        }

        fn addHashed(self: *Self, h1: u64, h2: u64) void {
            var i: u32 = 0;
            while (i < self.num_hashes) : (i += 1) {
                const combined = h1 +% @as(u64, i) *% h2;
                const idx = combined % self.num_counters;
                if (self.counters[idx] < MAX_COUNT) {
                    self.counters[idx] += 1;
                }
            }
            self.count += 1;
        }

        /// Remove an item (may cause false negatives if counter saturated)
        pub fn remove(self: *Self, item: T) void {
            var h1: u64 = undefined;
            var h2: u64 = undefined;
            hashItem(item, &h1, &h2);
            self.removeHashed(h1, h2);
        }

        pub fn removeBytes(self: *Self, data: []const u8) void {
            var h1: u64 = undefined;
            var h2: u64 = undefined;
            doubleHash(data, &h1, &h2);
            self.removeHashed(h1, h2);
        }

        fn removeHashed(self: *Self, h1: u64, h2: u64) void {
            var i: u32 = 0;
            while (i < self.num_hashes) : (i += 1) {
                const combined = h1 +% @as(u64, i) *% h2;
                const idx = combined % self.num_counters;
                if (self.counters[idx] > 0) {
                    self.counters[idx] -= 1;
                }
            }
            if (self.count > 0) self.count -= 1;
        }

        pub fn contains(self: *const Self, item: T) bool {
            var h1: u64 = undefined;
            var h2: u64 = undefined;
            hashItem(item, &h1, &h2);
            return self.containsHashed(h1, h2);
        }

        pub fn containsBytes(self: *const Self, data: []const u8) bool {
            var h1: u64 = undefined;
            var h2: u64 = undefined;
            doubleHash(data, &h1, &h2);
            return self.containsHashed(h1, h2);
        }

        fn containsHashed(self: *const Self, h1: u64, h2: u64) bool {
            var i: u32 = 0;
            while (i < self.num_hashes) : (i += 1) {
                const combined = h1 +% @as(u64, i) *% h2;
                const idx = combined % self.num_counters;
                if (self.counters[idx] == 0) return false;
            }
            return true;
        }

        pub fn clear(self: *Self) void {
            @memset(self.counters, 0);
            self.count = 0;
        }

        /// Raw view of the backing counters. Not a portable serialization
        /// format — use `encodeAlloc` for that.
        pub fn rawCounters(self: *const Self) []const u8 {
            return self.counters;
        }

        /// Serialize to a versioned, self-describing blob (see `format`).
        /// Caller owns the returned memory.
        pub fn encodeAlloc(self: *const Self, allocator: Allocator) ![]u8 {
            const out = try allocator.alloc(u8, format.header_len + self.counters.len);
            errdefer allocator.free(out);

            format.writeHeader(out, .{
                .kind = .counting,
                .len = self.num_counters,
                .num_hashes = self.num_hashes,
                .count = self.count,
            });
            @memcpy(out[format.header_len..], self.counters);
            return out;
        }

        /// Reconstruct a counting filter from `encodeAlloc` output.
        pub fn decodeAlloc(allocator: Allocator, data: []const u8) !Self {
            const h = try format.readHeader(data, .counting);

            const num_counters = try format.toUsize(h.len);
            const count = try format.toUsize(h.count);
            if (data.len != format.header_len + num_counters) return error.LengthMismatch;

            var self = try init(allocator, num_counters, h.num_hashes);
            errdefer self.deinit();

            @memcpy(self.counters, data[format.header_len..]);
            self.count = count;
            return self;
        }

        /// Compute both hashes for an item, hashing non-slice bytes inside this
        /// frame while the by-value copy is live (see BloomFilter.hashItem).
        fn hashItem(item: T, h1: *u64, h2: *u64) void {
            if (T == []const u8) {
                doubleHash(item, h1, h2);
                return;
            } else if (@typeInfo(T) == .pointer) {
                const child = @typeInfo(T).pointer.child;
                if (child == u8) {
                    doubleHash(item, h1, h2);
                    return;
                }
            }
            doubleHash(std.mem.asBytes(&item), h1, h2);
        }

        fn doubleHash(data: []const u8, h1: *u64, h2: *u64) void {
            h1.* = std.hash.Wyhash.hash(0, data);
            h2.* = std.hash.Wyhash.hash(0x517cc1b727220a95, data);
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "bloom filter basic operations" {
    const allocator = std.testing.allocator;
    var bf = try BloomFilter([]const u8).initCapacity(allocator, 1000, 0.01);
    defer bf.deinit();

    bf.add("hello");
    bf.add("world");

    try std.testing.expect(bf.contains("hello"));
    try std.testing.expect(bf.contains("world"));
    try std.testing.expect(!bf.contains("nothere"));
}

test "bloom filter false positive rate" {
    const allocator = std.testing.allocator;
    var bf = try BloomFilter(u64).initCapacity(allocator, 10000, 0.01);
    defer bf.deinit();

    // Add items
    var i: u64 = 0;
    while (i < 10000) : (i += 1) {
        bf.add(i);
    }

    // Check false positive rate
    var false_positives: usize = 0;
    i = 10000;
    while (i < 20000) : (i += 1) {
        if (bf.contains(i)) false_positives += 1;
    }

    const actual_fp_rate = @as(f64, @floatFromInt(false_positives)) / 10000.0;
    // Allow some margin for statistical variance
    try std.testing.expect(actual_fp_rate < 0.03);
}

test "counting bloom filter deletion" {
    const allocator = std.testing.allocator;
    var cbf = try CountingBloomFilter([]const u8).initCapacity(allocator, 1000, 0.01);
    defer cbf.deinit();

    cbf.add("hello");
    try std.testing.expect(cbf.contains("hello"));

    cbf.remove("hello");
    try std.testing.expect(!cbf.contains("hello"));
}

test "initCapacity rejects degenerate inputs (no NaN/inf @intFromFloat)" {
    const allocator = std.testing.allocator;

    // expected_items == 0 -> k = (m/n)*ln2 is 0/0 NaN
    try std.testing.expectError(error.InvalidCapacity, BloomFilter(u64).initCapacity(allocator, 0, 0.01));
    try std.testing.expectError(error.InvalidCapacity, CountingBloomFilter(u64).initCapacity(allocator, 0, 0.01));

    // fp_rate <= 0 -> m infinite; fp_rate >= 1 -> m zero-or-negative; NaN rejected too
    try std.testing.expectError(error.InvalidFPRate, BloomFilter(u64).initCapacity(allocator, 1000, 0.0));
    try std.testing.expectError(error.InvalidFPRate, BloomFilter(u64).initCapacity(allocator, 1000, 1.0));
    try std.testing.expectError(error.InvalidFPRate, BloomFilter(u64).initCapacity(allocator, 1000, -0.5));
    try std.testing.expectError(error.InvalidFPRate, BloomFilter(u64).initCapacity(allocator, 1000, std.math.nan(f64)));
    try std.testing.expectError(error.InvalidFPRate, CountingBloomFilter(u64).initCapacity(allocator, 1000, 2.0));
}

test "bloom filter integer keys (non-slice branch, no dangling toBytes)" {
    const allocator = std.testing.allocator;
    var bf = try BloomFilter(u64).initCapacity(allocator, 1000, 0.01);
    defer bf.deinit();

    bf.add(@as(u64, 42));
    bf.add(@as(u64, 7));
    try std.testing.expect(bf.contains(@as(u64, 42)));
    try std.testing.expect(bf.contains(@as(u64, 7)));
    try std.testing.expect(!bf.contains(@as(u64, 99999)));
}
