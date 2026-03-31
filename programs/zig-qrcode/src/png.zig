//! Minimal PNG Encoder
//! Generates valid PNG files from raw RGB pixel data.
//! Uses zlib stored blocks (no compression) for simplicity.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Crc32 = std.hash.crc.Crc32IsoHdlc;

const PNG_SIGNATURE = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };

/// Encode raw RGB pixel data as a PNG file.
/// `pixels` must be `width * height * 3` bytes (RGB, row-major).
/// Returns owned slice; caller must free with `allocator.free()`.
pub fn encodePng(allocator: Allocator, pixels: []const u8, width: u32, height: u32) ![]u8 {
    const expected_len = @as(usize, width) * height * 3;
    if (pixels.len != expected_len) return error.InvalidPixelData;
    if (width == 0 or height == 0) return error.InvalidPixelData;

    // Calculate sizes
    const row_bytes = @as(usize, width) * 3;
    const filtered_row = 1 + row_bytes; // filter byte + RGB data
    const raw_data_len = filtered_row * height;

    // Zlib stored blocks: header(2) + blocks + adler32(4)
    const max_block = 65535;
    const num_full_blocks = raw_data_len / max_block;
    const last_block_size = raw_data_len % max_block;
    const num_blocks = num_full_blocks + @as(usize, if (last_block_size > 0) 1 else 0);
    const zlib_len = 2 + num_blocks * 5 + raw_data_len + 4;

    // Total PNG: signature + IHDR chunk + IDAT chunk + IEND chunk
    // Chunk format: length(4) + type(4) + data + crc(4) = 12 + data
    const ihdr_chunk_len = 12 + 13;
    const idat_chunk_len = 12 + zlib_len;
    const iend_chunk_len = 12;
    const total_len = PNG_SIGNATURE.len + ihdr_chunk_len + idat_chunk_len + iend_chunk_len;

    var buf = try allocator.alloc(u8, total_len);
    errdefer allocator.free(buf);
    var pos: usize = 0;

    // PNG signature
    @memcpy(buf[pos..][0..8], &PNG_SIGNATURE);
    pos += 8;

    // IHDR chunk
    pos = writeChunk(buf, pos, "IHDR", blk: {
        var ihdr: [13]u8 = undefined;
        writeU32BE(ihdr[0..4], width);
        writeU32BE(ihdr[4..8], height);
        ihdr[8] = 8; // bit depth
        ihdr[9] = 2; // color type: RGB
        ihdr[10] = 0; // compression
        ihdr[11] = 0; // filter
        ihdr[12] = 0; // interlace
        break :blk &ihdr;
    });

    // IDAT chunk — zlib stored blocks containing filtered scanlines
    writeU32BE(buf[pos..][0..4], @intCast(zlib_len));
    pos += 4;
    const idat_type_start = pos;
    @memcpy(buf[pos..][0..4], "IDAT");
    pos += 4;

    // Zlib header (no compression)
    buf[pos] = 0x78; // CMF: deflate, window size 32K
    buf[pos + 1] = 0x01; // FLG: check bits (0x7801 % 31 == 0)
    pos += 2;

    // Write filtered scanlines as deflate stored blocks
    var adler = Adler32{};
    var data_offset: usize = 0;

    for (0..num_blocks) |block_idx| {
        const remaining = raw_data_len - data_offset;
        const block_size: u16 = @intCast(@min(remaining, max_block));
        const is_final: u8 = if (block_idx == num_blocks - 1) 1 else 0;

        buf[pos] = is_final; // BFINAL=is_final, BTYPE=00 (stored)
        pos += 1;
        buf[pos] = @intCast(block_size & 0xFF);
        buf[pos + 1] = @intCast((block_size >> 8) & 0xFF);
        pos += 2;
        buf[pos] = @intCast(~block_size & 0xFF);
        buf[pos + 1] = @intCast((~block_size >> 8) & 0xFF);
        pos += 2;

        // Write filtered scanline data for this block
        var written: usize = 0;
        while (written < block_size) {
            const row = (data_offset + written) / filtered_row;
            const col = (data_offset + written) % filtered_row;

            if (col == 0) {
                // Filter byte (None)
                buf[pos] = 0;
                adler.update(&[_]u8{0});
                pos += 1;
                written += 1;
            } else {
                // RGB pixel data
                const src_row_start = row * row_bytes;
                const src_col = col - 1;
                const remaining_in_row = row_bytes - src_col;
                const remaining_in_block = block_size - written;
                const copy_len = @min(remaining_in_row, remaining_in_block);
                const src = pixels[src_row_start + src_col ..][0..copy_len];
                @memcpy(buf[pos..][0..copy_len], src);
                adler.update(src);
                pos += copy_len;
                written += @intCast(copy_len);
            }
        }
        data_offset += block_size;
    }

    // Adler32 checksum
    const adler_val = adler.finish();
    writeU32BE(buf[pos..][0..4], adler_val);
    pos += 4;

    // IDAT CRC (over type + data)
    const idat_crc = Crc32.hash(buf[idat_type_start..pos]);
    writeU32BE(buf[pos..][0..4], idat_crc);
    pos += 4;

    // IEND chunk
    pos = writeChunk(buf, pos, "IEND", &[_]u8{});

    std.debug.assert(pos == total_len);
    return buf;
}

fn writeChunk(buf: []u8, start: usize, chunk_type: *const [4]u8, data: []const u8) usize {
    var pos = start;
    writeU32BE(buf[pos..][0..4], @intCast(data.len));
    pos += 4;
    @memcpy(buf[pos..][0..4], chunk_type);
    pos += 4;
    if (data.len > 0) {
        @memcpy(buf[pos..][0..data.len], data);
        pos += data.len;
    }
    // CRC over type + data
    var crc = Crc32.init();
    crc.update(chunk_type);
    crc.update(data);
    writeU32BE(buf[pos..][0..4], crc.final());
    pos += 4;
    return pos;
}

fn writeU32BE(dst: *[4]u8, val: u32) void {
    dst[0] = @intCast((val >> 24) & 0xFF);
    dst[1] = @intCast((val >> 16) & 0xFF);
    dst[2] = @intCast((val >> 8) & 0xFF);
    dst[3] = @intCast(val & 0xFF);
}

/// Adler-32 checksum (used by zlib)
const Adler32 = struct {
    a: u32 = 1,
    b: u32 = 0,

    fn update(self: *Adler32, data: []const u8) void {
        for (data) |byte| {
            self.a = (self.a + byte) % 65521;
            self.b = (self.b + self.a) % 65521;
        }
    }

    fn finish(self: *const Adler32) u32 {
        return (self.b << 16) | self.a;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "PNG signature" {
    const allocator = std.testing.allocator;
    // 1x1 red pixel
    const pixels = [_]u8{ 255, 0, 0 };
    const png = try encodePng(allocator, &pixels, 1, 1);
    defer allocator.free(png);

    // Check PNG signature
    try std.testing.expectEqualSlices(u8, &PNG_SIGNATURE, png[0..8]);
    // Check IHDR chunk type
    try std.testing.expectEqualSlices(u8, "IHDR", png[12..16]);
    try std.testing.expect(png.len > 50);
}

test "PNG 2x2 image" {
    const allocator = std.testing.allocator;
    // 2x2: red, green, blue, white
    const pixels = [_]u8{
        255, 0,   0,   0, 255, 0,
        0,   0,   255, 255, 255, 255,
    };
    const png = try encodePng(allocator, &pixels, 2, 2);
    defer allocator.free(png);

    try std.testing.expectEqualSlices(u8, &PNG_SIGNATURE, png[0..8]);
    try std.testing.expect(png.len > 50);
}

test "PNG invalid size" {
    const allocator = std.testing.allocator;
    const pixels = [_]u8{ 255, 0, 0 };
    // Wrong dimensions
    try std.testing.expectError(error.InvalidPixelData, encodePng(allocator, &pixels, 2, 2));
    try std.testing.expectError(error.InvalidPixelData, encodePng(allocator, &pixels, 0, 1));
}

test "Adler32" {
    var a = Adler32{};
    a.update("Wikipedia");
    try std.testing.expectEqual(@as(u32, 0x11E60398), a.finish());
}
