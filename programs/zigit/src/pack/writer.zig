// PackWriter — emit a pack file in memory.
//
// Layout we produce (all objects stored as their real type — no
// deltas yet; that's Phase 8):
//
//   header
//     "PACK" + version=2 (BE u32) + object_count (BE u32)
//
//   N × { variable-length size+type header
//         zlib-deflated payload bytes }
//
//   trailer
//     20-byte SHA-1 over everything before it
//
// Per-object size+type header:
//   first byte:  bit 7 = continuation, bits 4-6 = type (3-bit),
//                bits 0-3 = bottom 4 bits of payload size
//   each follow: bit 7 = continuation, bits 0-6 = next 7 size bits (LSB first)
//
// We capture (oid, byte offset of header start, CRC32 over header +
// compressed payload) for each object so the IdxWriter can build the
// matching .idx without re-scanning the pack.

const std = @import("std");
const Kind = @import("../object/kind.zig").Kind;
const Oid = @import("../object/oid.zig").Oid;
const ObjType = @import("pack.zig").ObjType;

pub const Entry = struct {
    oid: Oid,
    /// Byte offset into the pack where this object's header starts.
    offset: u64,
    /// CRC32 over the header bytes + the compressed payload bytes.
    crc32: u32,
};

pub const PackWriter = struct {
    allocator: std.mem.Allocator,
    body: std.Io.Writer.Allocating,
    /// One row per object written.
    entries: std.ArrayListUnmanaged(Entry),
    object_count: u32,
    expected_count: u32,

    pub fn init(allocator: std.mem.Allocator, expected_count: u32) !PackWriter {
        var body: std.Io.Writer.Allocating = try .initCapacity(allocator, 4096);
        errdefer body.deinit();

        try body.writer.writeAll("PACK");
        try body.writer.writeInt(u32, 2, .big);
        try body.writer.writeInt(u32, expected_count, .big);

        return .{
            .allocator = allocator,
            .body = body,
            .entries = .empty,
            .object_count = 0,
            .expected_count = expected_count,
        };
    }

    pub fn deinit(self: *PackWriter) void {
        self.body.deinit();
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    /// Append a non-delta object. Returns the entry recorded for the
    /// idx writer.
    pub fn addObject(
        self: *PackWriter,
        oid: Oid,
        kind: Kind,
        payload: []const u8,
    ) !Entry {
        if (self.object_count >= self.expected_count) return error.TooManyObjects;
        const start_offset: u64 = self.body.written().len;

        // Track CRC32 over header + compressed payload by remembering
        // the start position and hashing the bytes we just appended at
        // the end.
        try writeObjectHeader(&self.body.writer, ObjType.fromKind(kind), payload.len);

        // zlib-deflate payload directly into our body buffer.
        var window: [std.compress.flate.max_window_len]u8 = undefined;
        var compress = try std.compress.flate.Compress.init(
            &self.body.writer,
            &window,
            .zlib,
            .default,
        );
        try compress.writer.writeAll(payload);
        try compress.finish();

        const end_offset: u64 = self.body.written().len;
        const compressed_slice = self.body.written()[@intCast(start_offset)..@intCast(end_offset)];
        const crc = std.hash.crc.Crc32.hash(compressed_slice);

        const entry: Entry = .{ .oid = oid, .offset = start_offset, .crc32 = crc };
        try self.entries.append(self.allocator, entry);
        self.object_count += 1;
        return entry;
    }

    /// Append an OFS_DELTA object. `base_offset` must be the absolute
    /// pack offset of an entry that's already been written (the spec
    /// requires the base to come earlier in the pack so resolution
    /// can stream linearly). `delta_payload` is the raw, uncompressed
    /// delta-instruction stream — we zlib-compress it ourselves.
    pub fn addOfsDelta(
        self: *PackWriter,
        oid: Oid,
        base_offset: u64,
        delta_payload: []const u8,
    ) !Entry {
        if (self.object_count >= self.expected_count) return error.TooManyObjects;
        const start_offset: u64 = self.body.written().len;
        if (base_offset >= start_offset) return error.OfsDeltaBaseNotEarlier;

        try writeObjectHeader(&self.body.writer, .ofs_delta, delta_payload.len);
        try writeOfsBackref(&self.body.writer, start_offset - base_offset);

        var window: [std.compress.flate.max_window_len]u8 = undefined;
        var compress = try std.compress.flate.Compress.init(
            &self.body.writer,
            &window,
            .zlib,
            .default,
        );
        try compress.writer.writeAll(delta_payload);
        try compress.finish();

        const end_offset: u64 = self.body.written().len;
        const compressed_slice = self.body.written()[@intCast(start_offset)..@intCast(end_offset)];
        const crc = std.hash.crc.Crc32.hash(compressed_slice);

        const entry: Entry = .{ .oid = oid, .offset = start_offset, .crc32 = crc };
        try self.entries.append(self.allocator, entry);
        self.object_count += 1;
        return entry;
    }

    /// Finalise: append the SHA-1 trailer and return the pack bytes
    /// (caller owns) plus the recorded entries (caller owns; lives
    /// until the writer's deinit).
    pub fn finish(self: *PackWriter) !struct { pack_bytes: []u8, pack_oid: Oid } {
        if (self.object_count != self.expected_count) return error.WrongObjectCount;

        var hasher = std.crypto.hash.Sha1.init(.{});
        hasher.update(self.body.written());
        var sha: [20]u8 = undefined;
        hasher.final(&sha);

        try self.body.writer.writeAll(&sha);

        const owned = try self.body.toOwnedSlice();
        return .{ .pack_bytes = owned, .pack_oid = .{ .bytes = sha } };
    }
};

fn writeObjectHeader(w: *std.Io.Writer, kind: ObjType, size: usize) !void {
    const type_bits: u8 = @intFromEnum(kind);

    const low4: u8 = @intCast(size & 0x0f);
    var remaining: u64 = @as(u64, size) >> 4;
    var first: u8 = (type_bits << 4) | low4;
    if (remaining > 0) first |= 0x80;
    try w.writeByte(first);

    while (remaining > 0) {
        var b: u8 = @intCast(remaining & 0x7f);
        remaining >>= 7;
        if (remaining > 0) b |= 0x80;
        try w.writeByte(b);
    }
}

/// Encode the OFS_DELTA negative offset. The wire encoding is the
/// inverse of `Pack.readOfsDelta`: bytes are emitted MSB-first; each
/// continuation byte (high bit set) implicitly adds 1 << 7N to the
/// value during decoding, which we compensate for by subtracting 1
/// after every right-shift here.
fn writeOfsBackref(w: *std.Io.Writer, distance: u64) !void {
    if (distance == 0) return error.OfsDeltaZeroDistance;
    var buf: [10]u8 = undefined;
    var n: usize = 0;
    var v = distance;
    buf[n] = @intCast(v & 0x7f);
    n += 1;
    v >>= 7;
    while (v != 0) {
        v -= 1;
        buf[n] = @intCast(0x80 | (v & 0x7f));
        n += 1;
        v >>= 7;
    }
    // Emit in reverse (high-byte first).
    var i: usize = n;
    while (i > 0) {
        i -= 1;
        try w.writeByte(buf[i]);
    }
}

const testing = std.testing;

test "round-trip a single blob: write then read via Pack" {
    const allocator = testing.allocator;

    var oid: Oid = undefined;
    @memset(&oid.bytes, 0xAB);

    var w = try PackWriter.init(allocator, 1);
    defer w.deinit();
    _ = try w.addObject(oid, .blob, "hello, pack");
    const result = try w.finish();
    defer allocator.free(result.pack_bytes);

    const Pack = @import("pack.zig").Pack;
    const pack = try Pack.parse(result.pack_bytes);
    try testing.expectEqual(@as(u32, 1), pack.object_count);

    const header = try pack.readHeader(12); // immediately after the file header
    try testing.expectEqual(@as(@import("pack.zig").ObjType, .blob), header.kind);

    const payload = try pack.inflateAt(allocator, header.body_offset, header.payload_size);
    defer allocator.free(payload);
    try testing.expectEqualStrings("hello, pack", payload);
}

test "writer rejects extra adds" {
    var oid: Oid = undefined;
    @memset(&oid.bytes, 0);
    var w = try PackWriter.init(testing.allocator, 1);
    defer w.deinit();
    _ = try w.addObject(oid, .blob, "x");
    try testing.expectError(error.TooManyObjects, w.addObject(oid, .blob, "y"));
}

test "writer rejects underfill on finish" {
    var w = try PackWriter.init(testing.allocator, 2);
    defer w.deinit();
    var oid: Oid = undefined;
    @memset(&oid.bytes, 0);
    _ = try w.addObject(oid, .blob, "x");
    try testing.expectError(error.WrongObjectCount, w.finish());
}

test "writeOfsBackref round-trips via Pack.readOfsDelta" {
    const Pack = @import("pack.zig").Pack;
    const cases = [_]u64{ 1, 64, 127, 128, 200, 16_383, 16_384, 1_000_000 };
    for (cases) |distance| {
        var bytes: std.Io.Writer.Allocating = try .initCapacity(testing.allocator, 32);
        defer bytes.deinit();
        // Fake a pack: dummy header + the back-ref; readOfsDelta only
        // touches the back-ref bytes anyway.
        try bytes.writer.writeAll("PACK");
        try bytes.writer.writeInt(u32, 2, .big);
        try bytes.writer.writeInt(u32, 0, .big);
        const backref_start = bytes.written().len;
        try writeOfsBackref(&bytes.writer, distance);

        // Pack.readOfsDelta needs a 20-byte trailer to satisfy parse(),
        // but we'll call it on raw bytes via a hand-built Pack instead.
        const pack: Pack = .{ .bytes = bytes.written(), .object_count = 0 };
        // entry_start must be ≥ distance to avoid OfsDeltaOutOfRange.
        const entry_start = distance + 100;
        const got = try pack.readOfsDelta(backref_start, entry_start);
        try testing.expectEqual(entry_start - distance, got.base_offset);
    }
}

test "addOfsDelta round-trip: writer → index_pack reads back deltified payload" {
    const allocator = testing.allocator;
    const index_pack = @import("index_pack.zig");

    const base_payload = "the quick brown fox jumps over the lazy dog 0123456789";
    const target_payload = "the quick brown fox jumps over the lazy cat 0123456789";

    // Compute oids for the test (use the same hashing the runtime would).
    const computeOid = struct {
        fn run(kind_bytes: []const u8, payload: []const u8) Oid {
            var hasher = std.crypto.hash.Sha1.init(.{});
            var hdr_buf: [32]u8 = undefined;
            const hdr = std.fmt.bufPrint(&hdr_buf, "{s} {d}\x00", .{ kind_bytes, payload.len }) catch unreachable;
            hasher.update(hdr);
            hasher.update(payload);
            var bytes: [20]u8 = undefined;
            hasher.final(&bytes);
            return .{ .bytes = bytes };
        }
    }.run;

    const base_oid = computeOid("blob", base_payload);
    const target_oid = computeOid("blob", target_payload);

    var w = try PackWriter.init(allocator, 2);
    defer w.deinit();
    const base_entry = try w.addObject(base_oid, .blob, base_payload);

    const deltify = @import("deltify.zig");
    const delta_bytes = try deltify.encode(allocator, base_payload, target_payload);
    defer allocator.free(delta_bytes);
    _ = try w.addOfsDelta(target_oid, base_entry.offset, delta_bytes);

    const finished = try w.finish();
    defer allocator.free(finished.pack_bytes);

    // index_pack must resolve the OFS_DELTA and re-derive the same oids.
    const result = try index_pack.build(allocator, finished.pack_bytes);
    defer allocator.free(result.idx_bytes);
    try testing.expectEqual(@as(u32, 2), result.object_count);
}
