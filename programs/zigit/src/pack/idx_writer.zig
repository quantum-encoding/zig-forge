// IdxWriter — emit a v2 pack index.
//
// Layout (mirror of idx.zig's reader):
//
//   header
//     4 bytes  magic = \xff t O c
//     4 bytes  version = 2 (BE)
//
//   fanout
//     256 × 4 bytes (BE)   running count of oids whose first byte ≤ N
//
//   oids        N × 20 bytes (sorted)
//   crc32s      N × 4 bytes (BE)
//   small_offs  N × 4 bytes (BE)  high bit set = index into big_offs
//   big_offs    K × 8 bytes (BE)  for offsets ≥ 2^31
//
//   trailer
//     20 bytes  pack file's SHA-1
//     20 bytes  SHA-1 over everything before it in the .idx
//
// We require the input entries to already be sorted by oid (the
// PackWriter's record order is write-order; gc.zig sorts before
// passing them in).

const std = @import("std");
const writer_mod = @import("writer.zig");
const Oid = @import("../object/oid.zig").Oid;
const idx_mod = @import("idx.zig");

pub const big_offset_threshold: u64 = 1 << 31;

/// Build the .idx bytes for a pack containing `entries` (sorted by
/// oid) and SHA-1'd as `pack_oid`. Caller owns the returned slice.
pub fn build(
    allocator: std.mem.Allocator,
    entries: []const writer_mod.Entry,
    pack_oid: Oid,
) ![]u8 {
    // Validate sort order.
    var i: usize = 1;
    while (i < entries.len) : (i += 1) {
        if (std.mem.order(u8, &entries[i - 1].oid.bytes, &entries[i].oid.bytes) != .lt) {
            return error.IdxEntriesNotSorted;
        }
    }

    var allocating: std.Io.Writer.Allocating = try .initCapacity(allocator, 8 + 256 * 4 + entries.len * 28 + 40);
    defer allocating.deinit();
    const w = &allocating.writer;

    // Header.
    try w.writeAll(&idx_mod.magic);
    try w.writeInt(u32, 2, .big);

    // Fanout: fanout[N] = number of oids whose first byte ≤ N.
    var fanout: [256]u32 = @splat(0);
    for (entries) |e| fanout[e.oid.bytes[0]] += 1;
    var running: u32 = 0;
    var b: usize = 0;
    while (b < 256) : (b += 1) {
        running += fanout[b];
        fanout[b] = running;
    }
    for (fanout) |count| try w.writeInt(u32, count, .big);

    // Sorted oids.
    for (entries) |e| try w.writeAll(&e.oid.bytes);

    // CRC32s (network-order u32).
    for (entries) |e| try w.writeInt(u32, e.crc32, .big);

    // Small offsets (32-bit) + collect overflow values.
    var big_offsets: std.ArrayListUnmanaged(u64) = .empty;
    defer big_offsets.deinit(allocator);
    for (entries) |e| {
        if (e.offset < big_offset_threshold) {
            try w.writeInt(u32, @intCast(e.offset), .big);
        } else {
            const overflow_idx: u32 = @intCast(big_offsets.items.len);
            try w.writeInt(u32, overflow_idx | 0x80000000, .big);
            try big_offsets.append(allocator, e.offset);
        }
    }

    // Big offsets.
    for (big_offsets.items) |off| try w.writeInt(u64, off, .big);

    // Pack-file SHA-1 trailer.
    try w.writeAll(&pack_oid.bytes);

    // Idx-file SHA-1 over everything written so far.
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(allocating.written());
    var sha: [20]u8 = undefined;
    hasher.final(&sha);
    try w.writeAll(&sha);

    return try allocating.toOwnedSlice();
}

const testing = std.testing;

test "build then parse: round-trips through Idx reader" {
    const allocator = testing.allocator;

    var oid_a: Oid = undefined; @memset(&oid_a.bytes, 0x10);
    var oid_b: Oid = undefined; @memset(&oid_b.bytes, 0x20);
    var oid_c: Oid = undefined; @memset(&oid_c.bytes, 0xa0);

    const entries = [_]writer_mod.Entry{
        .{ .oid = oid_a, .offset = 12, .crc32 = 0xdeadbeef },
        .{ .oid = oid_b, .offset = 100, .crc32 = 0xfeedface },
        .{ .oid = oid_c, .offset = 200, .crc32 = 0x12345678 },
    };

    var pack_oid: Oid = undefined;
    @memset(&pack_oid.bytes, 0xff);

    const bytes = try build(allocator, &entries, pack_oid);
    defer allocator.free(bytes);

    const idx = try idx_mod.Idx.parse(bytes);
    try testing.expectEqual(@as(u32, 3), idx.object_count);
    try testing.expectEqual(@as(?u64, 12), idx.findOffset(oid_a));
    try testing.expectEqual(@as(?u64, 100), idx.findOffset(oid_b));
    try testing.expectEqual(@as(?u64, 200), idx.findOffset(oid_c));

    var unknown: Oid = undefined; @memset(&unknown.bytes, 0x55);
    try testing.expectEqual(@as(?u64, null), idx.findOffset(unknown));
}

test "build rejects unsorted input" {
    var oid_a: Oid = undefined; @memset(&oid_a.bytes, 0x20);
    var oid_b: Oid = undefined; @memset(&oid_b.bytes, 0x10);
    const entries = [_]writer_mod.Entry{
        .{ .oid = oid_a, .offset = 12, .crc32 = 0 },
        .{ .oid = oid_b, .offset = 100, .crc32 = 0 },
    };
    var pack_oid: Oid = undefined;
    @memset(&pack_oid.bytes, 0);
    try testing.expectError(error.IdxEntriesNotSorted, build(testing.allocator, &entries, pack_oid));
}
