// Multi-pack-index reader.
//
// MIDX is git's optimisation for repos with many pack files: a
// single index file at .git/objects/pack/multi-pack-index covers
// every (oid → pack, offset) lookup that would otherwise require
// touching N .idx files.
//
// On-disk layout (gitformat-pack-format(5), abridged):
//
//   header (12 bytes):
//     "MIDX"             — magic
//     version (u8)        — must be 1
//     oid_version (u8)    — 1 = sha-1, 2 = sha-256 (we only handle 1)
//     num_chunks (u8)
//     num_base_files (u8) — always 0 for the formats git actually emits
//     num_packs (u32 BE)
//
//   chunk lookup table (12 bytes per entry, num_chunks+1 entries):
//     chunk_id [4]u8, offset u64 BE
//     The trailing sentinel (id = 0) marks one-past-the-end.
//
//   chunk data, indexed by id:
//     "PNAM" — packed null-terminated pack filenames in lex order
//     "OIDF" — 256 × u32 BE fanout (oids[] count where leading byte ≤ i)
//     "OIDL" — oid_count × 20-byte oids, sorted ascending
//     "OOFF" — oid_count × { pack_index u32 BE, offset u32 BE }
//                offset's high bit set → LOFF index instead of inline
//     "LOFF" — large offsets, u64 BE
//     "RIDX" — reverse index (we don't use it; skip)
//
//   trailer: 20-byte SHA-1 over everything before it.
//
// We deliberately don't:
//   * Verify the trailing SHA-1 (perf-sensitive read path; tests cover
//     correctness end-to-end via real-git-produced fixtures).
//   * Handle MIDX bitmaps or RIDX — both are bonus indexes we don't
//     need for the pack-resolve happy path.
//   * Write a MIDX. Real git can; zigit can't yet (`gc` consolidates
//     into one pack so the optimisation is moot for our own writes).

const std = @import("std");

pub const magic: [4]u8 = .{ 'M', 'I', 'D', 'X' };

pub const Lookup = struct {
    /// Index into `pack_names` — caller resolves the .pack file name
    /// via that slice and reads bytes at `offset`.
    pack_index: u32,
    /// Absolute byte offset into the .pack file.
    offset: u64,
};

pub const Midx = struct {
    /// Borrowed; callers mmap or read-into-buffer.
    bytes: []const u8,

    num_packs: u32,
    /// Borrowed slices into `bytes`. Each name is one path string
    /// (no trailing NUL — we strip it on parse).
    pack_names: []const []const u8,
    /// 256 entries, fanout[i] = number of oids whose first byte ≤ i.
    fanout: []const u32,
    /// 20 bytes per oid, sorted ascending.
    oids: []const u8,
    /// 8 bytes per entry: u32 pack_index, u32 offset (high bit signals LOFF).
    oof: []const u8,
    /// 8 bytes per entry, BE u64. Empty slice if no LOFF chunk present.
    loff: []const u8,

    /// Parse a MIDX byte buffer. Returns an error if the file isn't
    /// a v1 sha-1 MIDX or any required chunk is missing.
    pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !Midx {
        if (bytes.len < 12 + 20) return error.MidxTooShort;
        if (!std.mem.eql(u8, bytes[0..4], &magic)) return error.NotAMidx;
        if (bytes[4] != 1) return error.UnsupportedMidxVersion;
        if (bytes[5] != 1) return error.UnsupportedOidVersion;
        const num_chunks: usize = bytes[6];
        if (bytes[7] != 0) return error.UnsupportedBaseFiles;
        const num_packs = std.mem.readInt(u32, bytes[8..12], .big);

        // Chunk table starts at offset 12.
        var chunk_id: [256][4]u8 = undefined;
        var chunk_off: [256]u64 = undefined;
        if (num_chunks + 1 > chunk_id.len) return error.TooManyChunks;

        var i: usize = 0;
        while (i < num_chunks + 1) : (i += 1) {
            const base = 12 + i * 12;
            if (base + 12 > bytes.len) return error.MidxTooShort;
            @memcpy(&chunk_id[i], bytes[base .. base + 4]);
            chunk_off[i] = std.mem.readInt(u64, bytes[base + 4 ..][0..8], .big);
        }

        var pnam_off: ?u64 = null;
        var oidf_off: ?u64 = null;
        var oidl_off: ?u64 = null;
        var oof_off: ?u64 = null;
        var loff_off: ?u64 = null;
        var loff_end: ?u64 = null;

        var j: usize = 0;
        while (j < num_chunks) : (j += 1) {
            const id = chunk_id[j];
            const start = chunk_off[j];
            const end = chunk_off[j + 1];
            if (std.mem.eql(u8, &id, "PNAM")) pnam_off = start;
            if (std.mem.eql(u8, &id, "OIDF")) oidf_off = start;
            if (std.mem.eql(u8, &id, "OIDL")) oidl_off = start;
            if (std.mem.eql(u8, &id, "OOFF")) oof_off = start;
            if (std.mem.eql(u8, &id, "LOFF")) {
                loff_off = start;
                loff_end = end;
            }
        }

        const oidf = oidf_off orelse return error.MidxMissingOidf;
        const oidl = oidl_off orelse return error.MidxMissingOidl;
        const oof = oof_off orelse return error.MidxMissingOoff;
        const pnam = pnam_off orelse return error.MidxMissingPnam;

        // Fanout: 256 × u32 BE.
        if (oidf + 256 * 4 > bytes.len) return error.MidxTooShort;
        const fanout_buf = try allocator.alloc(u32, 256);
        errdefer allocator.free(fanout_buf);
        var k: usize = 0;
        while (k < 256) : (k += 1) {
            fanout_buf[k] = std.mem.readInt(u32, bytes[oidf + k * 4 ..][0..4], .big);
        }
        const oid_count = fanout_buf[255];

        // OIDL: oid_count × 20 bytes.
        const oidl_end = oidl + oid_count * 20;
        if (oidl_end > bytes.len) return error.MidxTooShort;
        const oids_slice = bytes[oidl..oidl_end];

        // OOFF: oid_count × 8 bytes.
        const oof_end = oof + oid_count * 8;
        if (oof_end > bytes.len) return error.MidxTooShort;
        const oof_slice = bytes[oof..oof_end];

        // LOFF (optional).
        const loff_slice: []const u8 = if (loff_off) |start|
            bytes[start..(loff_end orelse start)]
        else
            &.{};

        // PNAM: split on NUL bytes into pack filenames.
        const pnam_end = endOfPnam(bytes, pnam, num_packs) orelse return error.MidxBadPnam;
        const names = try allocator.alloc([]const u8, num_packs);
        errdefer allocator.free(names);

        var name_cursor: usize = pnam;
        var n: usize = 0;
        while (n < num_packs) : (n += 1) {
            const nul = std.mem.indexOfScalarPos(u8, bytes, name_cursor, 0) orelse return error.MidxBadPnam;
            names[n] = bytes[name_cursor..nul];
            name_cursor = nul + 1;
        }
        _ = pnam_end;

        return .{
            .bytes = bytes,
            .num_packs = num_packs,
            .pack_names = names,
            .fanout = fanout_buf,
            .oids = oids_slice,
            .oof = oof_slice,
            .loff = loff_slice,
        };
    }

    pub fn deinit(self: *Midx, allocator: std.mem.Allocator) void {
        allocator.free(self.fanout);
        allocator.free(self.pack_names);
        self.* = undefined;
    }

    /// Binary-search for `oid` in the sorted OIDL chunk and, if found,
    /// decode its OOFF entry into a `Lookup`.
    pub fn lookup(self: Midx, oid: [20]u8) ?Lookup {
        const first = oid[0];
        const lo: usize = if (first == 0) 0 else self.fanout[first - 1];
        const hi: usize = self.fanout[first];

        var l: usize = lo;
        var h: usize = hi;
        while (l < h) {
            const mid = (l + h) / 2;
            const cand = self.oids[mid * 20 .. mid * 20 + 20];
            const order = std.mem.order(u8, cand, &oid);
            switch (order) {
                .lt => l = mid + 1,
                .gt => h = mid,
                .eq => return self.decodeOoff(mid),
            }
        }
        return null;
    }

    fn decodeOoff(self: Midx, idx: usize) Lookup {
        const base = idx * 8;
        const pack_index = std.mem.readInt(u32, self.oof[base..][0..4], .big);
        const off_word = std.mem.readInt(u32, self.oof[base + 4 ..][0..4], .big);
        if ((off_word & 0x80000000) != 0 and self.loff.len > 0) {
            const lidx: usize = @intCast(off_word & 0x7fffffff);
            const off = std.mem.readInt(u64, self.loff[lidx * 8 ..][0..8], .big);
            return .{ .pack_index = pack_index, .offset = off };
        }
        return .{ .pack_index = pack_index, .offset = off_word };
    }
};

fn endOfPnam(bytes: []const u8, start: u64, num_packs: u32) ?u64 {
    var cursor: usize = @intCast(start);
    var n: u32 = 0;
    while (n < num_packs) : (n += 1) {
        const nul = std.mem.indexOfScalarPos(u8, bytes, cursor, 0) orelse return null;
        cursor = nul + 1;
    }
    return cursor;
}

// ── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;

// Hand-build a tiny one-pack MIDX so the parser can be exercised
// without invoking real git. Three oids; one's first byte is 0,
// one is in the middle, one is at the high end — exercises the
// fanout boundaries.
test "parse + lookup on a synthetic single-pack MIDX" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const w = &buf;
    const a = testing.allocator;

    // header
    try w.appendSlice(a, "MIDX");
    try w.append(a, 1); // version
    try w.append(a, 1); // oid version
    try w.append(a, 4); // num_chunks: PNAM, OIDF, OIDL, OOFF
    try w.append(a, 0); // num_base_files
    try w.appendNTimes(a, 0, 4);
    std.mem.writeInt(u32, w.items[w.items.len - 4 ..][0..4], 1, .big); // num_packs = 1

    // We'll fill in chunk offsets after we know the layout.
    // 4 chunks + 1 sentinel = 5 chunk-table entries × 12 bytes = 60 bytes.
    const chunks_start = w.items.len;
    try w.appendNTimes(a, 0, 5 * 12);

    // PNAM: "p.idx\0"
    const pnam_off = w.items.len;
    try w.appendSlice(a, "p.idx");
    try w.append(a, 0);

    // OIDF: 256 × u32 BE fanout, count of oids with first byte ≤ i.
    // 3 oids: 0x00..., 0x55..., 0xff...
    const oidf_off = w.items.len;
    var idx: usize = 0;
    while (idx < 256) : (idx += 1) {
        const cnt: u32 = blk: {
            var c: u32 = 0;
            if (0x00 <= idx) c += 1;
            if (0x55 <= idx) c += 1;
            if (0xff <= idx) c += 1;
            break :blk c;
        };
        try w.appendNTimes(a, 0, 4);
        std.mem.writeInt(u32, w.items[w.items.len - 4 ..][0..4], cnt, .big);
    }

    // OIDL: 3 × 20 bytes, sorted ascending.
    const oidl_off = w.items.len;
    var o0: [20]u8 = @splat(0);
    var o1: [20]u8 = @splat(0x55);
    var o2: [20]u8 = @splat(0xff);
    try w.appendSlice(a, &o0);
    try w.appendSlice(a, &o1);
    try w.appendSlice(a, &o2);

    // OOFF: 3 × 8 bytes (pack_index=0 for all; offsets 100/200/300).
    const oof_off = w.items.len;
    inline for (.{ @as(u32, 100), @as(u32, 200), @as(u32, 300) }) |off| {
        try w.appendNTimes(a, 0, 4); // pack_index = 0
        try w.appendNTimes(a, 0, 4);
        std.mem.writeInt(u32, w.items[w.items.len - 4 ..][0..4], off, .big);
    }

    // Sentinel offset: end of OOFF.
    const sentinel_off = w.items.len;

    // 20-byte trailer.
    try w.appendNTimes(a, 0, 20);

    // Patch the chunk-lookup table.
    const chunks: [4]struct { id: [4]u8, off: u64 } = .{
        .{ .id = "PNAM".*, .off = pnam_off },
        .{ .id = "OIDF".*, .off = oidf_off },
        .{ .id = "OIDL".*, .off = oidl_off },
        .{ .id = "OOFF".*, .off = oof_off },
    };
    for (chunks, 0..) |c, ci| {
        const dest = chunks_start + ci * 12;
        @memcpy(w.items[dest .. dest + 4], &c.id);
        std.mem.writeInt(u64, w.items[dest + 4 ..][0..8], c.off, .big);
    }
    // Sentinel: id = 0, off = sentinel_off.
    const sentinel_dest = chunks_start + 4 * 12;
    @memset(w.items[sentinel_dest .. sentinel_dest + 4], 0);
    std.mem.writeInt(u64, w.items[sentinel_dest + 4 ..][0..8], sentinel_off, .big);

    var midx = try Midx.parse(testing.allocator, w.items);
    defer midx.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 1), midx.num_packs);
    try testing.expectEqualStrings("p.idx", midx.pack_names[0]);

    const a0 = midx.lookup(o0) orelse return error.MissingO0;
    try testing.expectEqual(@as(u32, 0), a0.pack_index);
    try testing.expectEqual(@as(u64, 100), a0.offset);

    const a1 = midx.lookup(o1) orelse return error.MissingO1;
    try testing.expectEqual(@as(u64, 200), a1.offset);

    const a2 = midx.lookup(o2) orelse return error.MissingO2;
    try testing.expectEqual(@as(u64, 300), a2.offset);

    const miss: [20]u8 = @splat(0x42);
    try testing.expect(midx.lookup(miss) == null);
}
