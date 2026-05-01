// Index a pack we just received off the wire.
//
// Equivalent to `git index-pack`: walk every object in the pack,
// resolve any OFS_DELTA / REF_DELTA chains so we can compute each
// object's true SHA-1, and emit a v2 .idx the rest of zigit can
// query.
//
// Workflow:
//
//   Pass 1 — walk the pack header-by-header, recording for every
//   object: (start_offset, end_offset, kind | delta_kind, base_info).
//   We track the end offset by inflating each object once and asking
//   the underlying fixed Reader for its consumed-bytes count.
//
//   Pass 2 — for every recorded object, materialise its real payload
//   (resolving deltas via an offset-keyed cache populated lazily),
//   compute its oid, accumulate (oid, offset, crc32) entries.
//
//   Finally — sort by oid, hand off to idx_writer.build.
//
// The pack we receive carries an empty REF_DELTA-base case only when
// the server sends a thin pack — we asked for non-thin, so REF_DELTA
// bases here always live in the same pack. (If we ever ask for thin
// packs, we'll need to fan out to LooseStore the way PackStore.readAt
// does for serving; the indexer would refuse since the base isn't in
// the pack we're indexing.)

const std = @import("std");
const Io = std.Io;
const Pack = @import("pack.zig").Pack;
const ObjType = @import("pack.zig").ObjType;
const writer_mod = @import("writer.zig");
const idx_writer = @import("idx_writer.zig");
const delta_mod = @import("delta.zig");
const Oid = @import("../object/oid.zig").Oid;
const Kind = @import("../object/kind.zig").Kind;

pub const Result = struct {
    /// SHA-1 of the pack (same as the trailer in `pack_bytes`).
    pack_oid: Oid,
    /// Built v2 .idx bytes — caller owns.
    idx_bytes: []u8,
    /// Object count (matches the pack header).
    object_count: u32,
};

const RawObject = struct {
    /// Byte offset of the size+type header in the pack.
    start_offset: u64,
    /// One past the last byte of the zlib payload (where the next
    /// object starts).
    end_offset: u64,
    /// As decoded from the size+type header.
    kind: ObjType,
    /// For OFS_DELTA: absolute offset of the base object.
    /// For REF_DELTA: 20-byte oid of the base.
    /// For non-delta: zero/undefined.
    delta_base_offset: u64 = 0,
    delta_base_oid: [20]u8 = @splat(0),
};

const Resolved = struct {
    kind: Kind,
    payload: []u8,
};

/// Explicit error set so the mutual recursion between resolveAt and
/// findRefDeltaBase doesn't trip Zig's inferred-error-set check.
pub const BuildError = error{
    OutOfMemory,
    PackTooShort,
    PackChecksumMismatch,
    NotAPack,
    UnsupportedPackVersion,
    BadPackObjectType,
    UnexpectedEof,
    OffsetOutOfRange,
    OfsDeltaOutOfRange,
    PayloadSizeMismatch,
    UnknownOffset,
    RefDeltaBaseMissingInPack,
    DeltaSourceSizeMismatch,
    DeltaTargetSizeMismatch,
    DeltaCopyOutOfBounds,
    DeltaInsertOverrun,
    DeltaReservedOpcode,
    UnexpectedEofInVarint,
    VarintTooLarge,
    IdxEntriesNotSorted,
    WriteFailed,
} || std.compress.flate.Decompress.Error || std.Io.Reader.Error;

pub fn build(
    allocator: std.mem.Allocator,
    pack_bytes: []const u8,
) !Result {
    const pack = try Pack.parse(pack_bytes);

    // Verify the SHA-1 trailer.
    if (pack_bytes.len < 20 + 12) return error.PackTooShort;
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack_bytes[0 .. pack_bytes.len - 20]);
    var pack_sha: [20]u8 = undefined;
    hasher.final(&pack_sha);
    if (!std.mem.eql(u8, &pack_sha, pack_bytes[pack_bytes.len - 20 ..])) return error.PackChecksumMismatch;

    // Pass 1: walk every object, record its byte range.
    var raws: std.ArrayListUnmanaged(RawObject) = .empty;
    defer raws.deinit(allocator);
    try raws.ensureTotalCapacityPrecise(allocator, pack.object_count);

    // Map from start_offset → index in `raws`. Used during pass 2 to
    // jump to OFS_DELTA bases without re-walking.
    var offset_to_index: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    defer offset_to_index.deinit(allocator);

    var cursor: u64 = 12; // immediately after PACK header
    var i: u32 = 0;
    while (i < pack.object_count) : (i += 1) {
        const start = cursor;
        const header = try pack.readHeader(cursor);
        cursor = header.body_offset;

        var raw: RawObject = .{
            .start_offset = start,
            .end_offset = 0,
            .kind = header.kind,
        };

        switch (header.kind) {
            .ofs_delta => {
                const ofs = try pack.readOfsDelta(cursor, start);
                raw.delta_base_offset = ofs.base_offset;
                cursor = ofs.payload_offset;
            },
            .ref_delta => {
                const ref = try pack.readRefDelta(cursor);
                raw.delta_base_oid = ref.base;
                cursor = ref.payload_offset;
            },
            else => {},
        }

        // Inflate the payload to learn how many compressed bytes were
        // consumed. We don't keep the bytes — pass 2 reads them again
        // when it builds the idx entry. (Simple and correct; a future
        // optimisation is to cache.)
        const consumed = try inflateConsumed(allocator, pack_bytes, cursor, header.payload_size);
        cursor += consumed;
        raw.end_offset = cursor;

        try offset_to_index.put(allocator, raw.start_offset, i);
        raws.appendAssumeCapacity(raw);
    }

    // Pass 2: resolve every object and accumulate idx entries.
    var resolved_cache: std.AutoHashMapUnmanaged(u64, Resolved) = .empty;
    defer {
        var it = resolved_cache.valueIterator();
        while (it.next()) |v| allocator.free(v.payload);
        resolved_cache.deinit(allocator);
    }

    var entries: std.ArrayListUnmanaged(writer_mod.Entry) = .empty;
    defer entries.deinit(allocator);
    try entries.ensureTotalCapacityPrecise(allocator, pack.object_count);

    for (raws.items) |raw| {
        const resolved = try resolveAt(allocator, pack_bytes, raws.items, &offset_to_index, &resolved_cache, raw.start_offset);
        defer allocator.free(resolved.payload);
        const oid = computeOid(resolved.kind, resolved.payload);
        const crc = std.hash.crc.Crc32.hash(pack_bytes[@intCast(raw.start_offset)..@intCast(raw.end_offset)]);
        entries.appendAssumeCapacity(.{ .oid = oid, .offset = raw.start_offset, .crc32 = crc });
    }

    // Sort by oid for the idx.
    std.mem.sort(writer_mod.Entry, entries.items, {}, struct {
        fn lt(_: void, a: writer_mod.Entry, b: writer_mod.Entry) bool {
            return std.mem.order(u8, &a.oid.bytes, &b.oid.bytes) == .lt;
        }
    }.lt);

    const pack_oid: Oid = .{ .bytes = pack_sha };
    const idx_bytes = try idx_writer.build(allocator, entries.items, pack_oid);
    return .{ .pack_oid = pack_oid, .idx_bytes = idx_bytes, .object_count = pack.object_count };
}

/// Inflate the zlib stream starting at `start_offset` in `pack_bytes`,
/// expecting `expected_size` decompressed bytes. Returns the number
/// of *compressed* input bytes consumed. We discard the inflated
/// output — pass 2 calls inflateAt to actually grab it.
fn inflateConsumed(
    _: std.mem.Allocator,
    pack_bytes: []const u8,
    start_offset: u64,
    expected_size: u64,
) !u64 {
    var src_reader: std.Io.Reader = .fixed(pack_bytes[@intCast(start_offset)..]);
    var inflate_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress = std.compress.flate.Decompress.init(&src_reader, .zlib, &inflate_buf);

    var sink_buf: [4096]u8 = undefined;
    var remaining = expected_size;
    while (remaining > 0) {
        const want: usize = @intCast(@min(remaining, sink_buf.len));
        const slice = sink_buf[0..want];
        try decompress.reader.readSliceAll(slice);
        remaining -= slice.len;
    }
    return src_reader.seek;
}

fn resolveAt(
    allocator: std.mem.Allocator,
    pack_bytes: []const u8,
    raws: []const RawObject,
    offset_to_index: *const std.AutoHashMapUnmanaged(u64, u32),
    cache: *std.AutoHashMapUnmanaged(u64, Resolved),
    start_offset: u64,
) BuildError!Resolved {
    if (cache.get(start_offset)) |hit| {
        return .{ .kind = hit.kind, .payload = try allocator.dupe(u8, hit.payload) };
    }

    const idx = offset_to_index.get(start_offset) orelse return error.UnknownOffset;
    const raw = raws[idx];
    const pack = try Pack.parse(pack_bytes);
    const header = try pack.readHeader(raw.start_offset);

    var payload_offset: u64 = header.body_offset;
    if (raw.kind == .ofs_delta) {
        payload_offset = (try pack.readOfsDelta(header.body_offset, raw.start_offset)).payload_offset;
    } else if (raw.kind == .ref_delta) {
        payload_offset = (try pack.readRefDelta(header.body_offset)).payload_offset;
    }

    const inflated = try pack.inflateAt(allocator, payload_offset, header.payload_size);
    errdefer allocator.free(inflated);

    var result: Resolved = undefined;
    switch (raw.kind) {
        .commit, .tree, .blob, .tag => {
            result = .{
                .kind = switch (raw.kind) {
                    .commit => .commit,
                    .tree => .tree,
                    .blob => .blob,
                    .tag => .tag,
                    else => unreachable,
                },
                .payload = inflated,
            };
        },
        .ofs_delta => {
            const base = try resolveAt(allocator, pack_bytes, raws, offset_to_index, cache, raw.delta_base_offset);
            defer allocator.free(base.payload);
            const reconstructed = try delta_mod.apply(allocator, base.payload, inflated);
            allocator.free(inflated);
            result = .{ .kind = base.kind, .payload = reconstructed };
        },
        .ref_delta => {
            // Server promised non-thin pack, so the base must be in
            // this pack. Look it up by oid by walking raws (rare path
            // — typically OFS_DELTA dominates).
            const base_oid: Oid = .{ .bytes = raw.delta_base_oid };
            const base = (try findRefDeltaBase(allocator, pack_bytes, raws, offset_to_index, cache, base_oid)) orelse
                return error.RefDeltaBaseMissingInPack;
            defer allocator.free(base.payload);
            const reconstructed = try delta_mod.apply(allocator, base.payload, inflated);
            allocator.free(inflated);
            result = .{ .kind = base.kind, .payload = reconstructed };
        },
    }

    // Cache a copy (so the iterator can free its own when it's done).
    const cached_payload = try allocator.dupe(u8, result.payload);
    try cache.put(allocator, start_offset, .{ .kind = result.kind, .payload = cached_payload });
    return result;
}

fn findRefDeltaBase(
    allocator: std.mem.Allocator,
    pack_bytes: []const u8,
    raws: []const RawObject,
    offset_to_index: *const std.AutoHashMapUnmanaged(u64, u32),
    cache: *std.AutoHashMapUnmanaged(u64, Resolved),
    base_oid: Oid,
) BuildError!?Resolved {
    // Brute-force: resolve each candidate and compare oid. If we
    // ever index real-world packs (instead of test fixtures) and
    // REF_DELTA proves common, build a side-map first.
    for (raws) |raw| {
        const r = try resolveAt(allocator, pack_bytes, raws, offset_to_index, cache, raw.start_offset);
        const oid = computeOid(r.kind, r.payload);
        if (oid.eql(base_oid)) return r;
        allocator.free(r.payload);
    }
    return null;
}

fn computeOid(kind: Kind, payload: []const u8) Oid {
    var hasher = std.crypto.hash.Sha1.init(.{});
    var header_buf: [32]u8 = undefined;
    const header = std.fmt.bufPrint(
        &header_buf,
        "{s} {d}\x00",
        .{ kind.name(), payload.len },
    ) catch unreachable;
    hasher.update(header);
    hasher.update(payload);
    var bytes: [20]u8 = undefined;
    hasher.final(&bytes);
    return .{ .bytes = bytes };
}

const testing = std.testing;

test "build idx for a fresh pack containing two blobs" {
    const allocator = testing.allocator;
    const PackWriter = @import("writer.zig").PackWriter;

    var oid_a: Oid = undefined;
    @memset(&oid_a.bytes, 0); // computed for real by addObject path; we need the oid for the assertion only
    const oid_a_real = computeOid(.blob, "hello");
    const oid_b_real = computeOid(.blob, "world");

    var w = try PackWriter.init(allocator, 2);
    defer w.deinit();
    _ = try w.addObject(oid_a_real, .blob, "hello");
    _ = try w.addObject(oid_b_real, .blob, "world");
    const finished = try w.finish();
    defer allocator.free(finished.pack_bytes);

    const result = try build(allocator, finished.pack_bytes);
    defer allocator.free(result.idx_bytes);
    try testing.expectEqual(@as(u32, 2), result.object_count);

    // Parse the idx back and verify both oids resolve to plausible offsets.
    const Idx = @import("idx.zig").Idx;
    const idx = try Idx.parse(result.idx_bytes);
    try testing.expectEqual(@as(u32, 2), idx.object_count);
    try testing.expect(idx.findOffset(oid_a_real) != null);
    try testing.expect(idx.findOffset(oid_b_real) != null);
}
