// Pack file random-access reader.
//
// On-disk layout (gitformat-pack(5)):
//
//   header
//     4 bytes  signature = "PACK"
//     4 bytes  version = 2 (or 3 — same on-disk for our purposes)
//     4 bytes  number of objects
//
//   N × object entries
//     variable-length size+type header (see decodeHeader below)
//     payload:
//       commit/tree/blob/tag → zlib-compressed payload bytes
//       OFS_DELTA           → variable-length negative offset to base
//                             (relative to this entry), then zlib-compressed delta
//       REF_DELTA           → 20-byte oid of base, then zlib-compressed delta
//
//   trailer
//     20 bytes  SHA-1 of all preceding bytes
//
// The size+type header packs the 3-bit object type into bits 4-6 of
// the first byte, with bits 0-3 being the bottom 4 bits of the
// payload size. As long as the high bit (bit 7) is set, the next
// byte contributes 7 more size bits (little-endian shifted).

const std = @import("std");

pub const signature: [4]u8 = .{ 'P', 'A', 'C', 'K' };

/// Object type tag as it appears in the pack header.
pub const ObjType = enum(u3) {
    commit = 1,
    tree = 2,
    blob = 3,
    tag = 4,
    /// Bit pattern 5 is reserved.
    ofs_delta = 6,
    ref_delta = 7,

    pub fn isDelta(self: ObjType) bool {
        return self == .ofs_delta or self == .ref_delta;
    }
};

pub const Pack = struct {
    bytes: []const u8,
    object_count: u32,

    pub fn parse(bytes: []const u8) !Pack {
        if (bytes.len < 12 + 20) return error.PackTooShort;
        if (!std.mem.eql(u8, bytes[0..4], &signature)) return error.NotAPack;
        const version = std.mem.readInt(u32, bytes[4..8], .big);
        if (version != 2 and version != 3) return error.UnsupportedPackVersion;
        const count = std.mem.readInt(u32, bytes[8..12], .big);
        return .{ .bytes = bytes, .object_count = count };
    }

    /// Decoded variable-length object header at the given byte offset.
    /// Returns the object type, payload size, and the absolute offset
    /// of the first byte after the header (where the zlib payload or
    /// delta base starts).
    pub const Header = struct {
        kind: ObjType,
        payload_size: u64,
        body_offset: u64,
    };

    pub fn readHeader(self: Pack, offset: u64) !Header {
        if (offset >= self.bytes.len) return error.OffsetOutOfRange;
        var cursor = offset;

        const first = self.bytes[@intCast(cursor)];
        cursor += 1;

        const kind_bits: u3 = @intCast((first >> 4) & 0b111);
        const kind = std.enums.fromInt(ObjType, kind_bits) orelse return error.BadPackObjectType;

        var size: u64 = first & 0x0f;
        var shift: u6 = 4;
        var byte: u8 = first;
        while ((byte & 0x80) != 0) {
            if (cursor >= self.bytes.len) return error.UnexpectedEof;
            byte = self.bytes[@intCast(cursor)];
            cursor += 1;
            size |= (@as(u64, byte) & 0x7f) << shift;
            shift += 7;
        }

        return .{ .kind = kind, .payload_size = size, .body_offset = cursor };
    }

    /// For OFS_DELTA: read the negative offset to the base entry,
    /// returning the absolute base offset and the cursor past the
    /// offset bytes (where the zlib delta starts).
    ///
    /// The encoding (different from the pack-header varint!): each
    /// byte contributes 7 bits, and except for the first byte we
    /// also add 1 << (7 * remaining_bytes).
    pub fn readOfsDelta(self: Pack, body_offset: u64, entry_start: u64) !struct { base_offset: u64, payload_offset: u64 } {
        var cursor = body_offset;
        var byte = self.bytes[@intCast(cursor)];
        cursor += 1;
        var value: u64 = byte & 0x7f;
        while ((byte & 0x80) != 0) {
            value += 1;
            if (cursor >= self.bytes.len) return error.UnexpectedEof;
            byte = self.bytes[@intCast(cursor)];
            cursor += 1;
            value = (value << 7) | (byte & 0x7f);
        }
        if (value > entry_start) return error.OfsDeltaOutOfRange;
        return .{ .base_offset = entry_start - value, .payload_offset = cursor };
    }

    /// For REF_DELTA: read the 20-byte base oid, returning it and
    /// the cursor past it.
    pub fn readRefDelta(self: Pack, body_offset: u64) !struct { base: [20]u8, payload_offset: u64 } {
        if (body_offset + 20 > self.bytes.len) return error.UnexpectedEof;
        const start: usize = @intCast(body_offset);
        var base: [20]u8 = undefined;
        @memcpy(&base, self.bytes[start .. start + 20]);
        return .{ .base = base, .payload_offset = body_offset + 20 };
    }

    /// Inflate `expected_size` bytes of zlib data starting at
    /// `payload_offset`. Caller owns the returned slice.
    pub fn inflateAt(
        self: Pack,
        allocator: std.mem.Allocator,
        payload_offset: u64,
        expected_size: u64,
    ) ![]u8 {
        var src_reader: std.Io.Reader = .fixed(self.bytes[@intCast(payload_offset)..]);
        var inflate_buf: [std.compress.flate.max_window_len]u8 = undefined;
        var decompress = std.compress.flate.Decompress.init(&src_reader, .zlib, &inflate_buf);

        const size_usize: usize = @intCast(expected_size);
        const out = try allocator.alloc(u8, size_usize);
        errdefer allocator.free(out);
        try decompress.reader.readSliceAll(out);
        return out;
    }
};
