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
        try writeObjectHeader(&self.body.writer, kind, payload.len);

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

fn writeObjectHeader(w: *std.Io.Writer, kind: Kind, size: usize) !void {
    const type_bits: u8 = switch (kind) {
        .commit => 1,
        .tree => 2,
        .blob => 3,
        .tag => 4,
    };

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
