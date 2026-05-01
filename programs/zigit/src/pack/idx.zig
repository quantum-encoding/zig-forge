// Pack index v2 reader.
//
// On-disk layout (gitformat-pack(5)):
//
//   header
//     4 bytes   magic   \xff t O c
//     4 bytes   version 2 (big-endian)
//
//   fanout
//     256 × 4 bytes (big-endian)
//       fanout[N] = number of objects whose first SHA byte is ≤ N
//       fanout[255] = total number of objects
//
//   sorted oid table   N × 20 bytes
//   crc32 table        N × 4 bytes  (big-endian, of compressed pack data)
//   small offsets      N × 4 bytes  (big-endian)
//                      MSB unset → direct 31-bit pack offset
//                      MSB set   → low 31 bits index into the overflow table
//   big offsets        K × 8 bytes  (big-endian) — only present if any
//                                                   object lives ≥ 2 GiB into the pack
//   trailer
//     20 bytes   pack file's SHA-1 (the trailer of the .pack)
//     20 bytes   SHA-1 of all preceding bytes of this .idx
//
// We borrow the file bytes — the caller (PackStore) keeps them
// alive. Lookups don't allocate; matchPrefix is O(log N) via binary
// search over the relevant fanout bucket.

const std = @import("std");
const oid_mod = @import("../object/oid.zig");
const Oid = oid_mod.Oid;
const OidPrefix = oid_mod.OidPrefix;

pub const magic: [4]u8 = .{ 0xff, 0x74, 0x4f, 0x63 };

pub const Idx = struct {
    bytes: []const u8,
    object_count: u32,
    /// Offsets into `bytes` for each section, computed once at parse.
    oid_table_offset: usize,
    crc_table_offset: usize,
    small_offset_table_offset: usize,
    big_offset_table_offset: usize,

    pub fn parse(bytes: []const u8) !Idx {
        if (bytes.len < 8 + 256 * 4 + 40) return error.IdxTooShort;
        if (!std.mem.eql(u8, bytes[0..4], &magic)) return error.NotAPackIdx;
        const version = std.mem.readInt(u32, bytes[4..8], .big);
        if (version != 2) return error.UnsupportedIdxVersion;

        const fanout_off: usize = 8;
        const object_count = std.mem.readInt(u32, bytes[fanout_off + 255 * 4 ..][0..4], .big);

        const oid_table = fanout_off + 256 * 4;
        const crc_table = oid_table + @as(usize, object_count) * 20;
        const small_off = crc_table + @as(usize, object_count) * 4;
        const big_off = small_off + @as(usize, object_count) * 4;

        // Trailer is two SHA-1s = 40 bytes.
        if (bytes.len < big_off + 40) return error.IdxTooShort;

        return .{
            .bytes = bytes,
            .object_count = object_count,
            .oid_table_offset = oid_table,
            .crc_table_offset = crc_table,
            .small_offset_table_offset = small_off,
            .big_offset_table_offset = big_off,
        };
    }

    /// Look up the pack offset of `oid`, or null if it isn't in this idx.
    pub fn findOffset(self: Idx, oid: Oid) ?u64 {
        const range = self.fanoutRange(oid.bytes[0]);
        const idx = self.binarySearchOid(range.start, range.end, oid) orelse return null;
        return self.offsetAt(idx);
    }

    /// Return any oid in this index matching `prefix`. If multiple
    /// match, returns one of them and sets `ambiguous` to true.
    pub fn matchPrefix(self: Idx, prefix: OidPrefix, ambiguous: *bool) ?Oid {
        const range = self.fanoutRange(prefix.bytes[0]);
        // Linear scan within the bucket — buckets are tiny.
        var found: ?Oid = null;
        var i = range.start;
        while (i < range.end) : (i += 1) {
            const candidate = self.oidAt(i);
            if (!prefix.matches(candidate)) continue;
            if (found != null) {
                ambiguous.* = true;
                return found;
            }
            found = candidate;
        }
        return found;
    }

    fn fanoutRange(self: Idx, first_byte: u8) struct { start: u32, end: u32 } {
        const fanout_off: usize = 8;
        const start: u32 = if (first_byte == 0) 0 else std.mem.readInt(
            u32,
            self.bytes[fanout_off + (@as(usize, first_byte) - 1) * 4 ..][0..4],
            .big,
        );
        const end: u32 = std.mem.readInt(
            u32,
            self.bytes[fanout_off + @as(usize, first_byte) * 4 ..][0..4],
            .big,
        );
        return .{ .start = start, .end = end };
    }

    fn oidAt(self: Idx, i: u32) Oid {
        var oid: Oid = undefined;
        const off = self.oid_table_offset + @as(usize, i) * 20;
        @memcpy(&oid.bytes, self.bytes[off .. off + 20]);
        return oid;
    }

    fn offsetAt(self: Idx, i: u32) u64 {
        const small = std.mem.readInt(
            u32,
            self.bytes[self.small_offset_table_offset + @as(usize, i) * 4 ..][0..4],
            .big,
        );
        if ((small & 0x80000000) == 0) return small;

        // High bit set → low 31 bits are an index into the big-offset table.
        const overflow_idx = small & 0x7fffffff;
        return std.mem.readInt(
            u64,
            self.bytes[self.big_offset_table_offset + @as(usize, overflow_idx) * 8 ..][0..8],
            .big,
        );
    }

    fn binarySearchOid(self: Idx, start: u32, end: u32, target: Oid) ?u32 {
        var lo = start;
        var hi = end;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const probe = self.oidAt(mid);
            const cmp = std.mem.order(u8, &probe.bytes, &target.bytes);
            switch (cmp) {
                .eq => return mid,
                .lt => lo = mid + 1,
                .gt => hi = mid,
            }
        }
        return null;
    }
};
