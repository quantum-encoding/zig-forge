const std = @import("std");

/// FlateDecode filter - zlib/deflate decompression
/// Uses Zig's built-in std.compress for zero external dependencies (Zig 0.16+ API)
/// Used by most PDF streams (images, content streams, etc.)
pub const FlateDecode = struct {
    /// Decompress FlateDecode data
    /// Returns decompressed data (caller owns memory)
    pub fn decode(allocator: std.mem.Allocator, compressed: []const u8) ![]u8 {
        if (compressed.len == 0) return allocator.alloc(u8, 0) catch unreachable;

        // Try zlib format first (with header), then raw deflate
        return decodeZlib(allocator, compressed) catch {
            // Try raw deflate (no zlib header)
            return decodeRaw(allocator, compressed);
        };
    }

    /// Decode zlib format (with header) - Zig 0.16+ API
    fn decodeZlib(allocator: std.mem.Allocator, compressed: []const u8) ![]u8 {
        var in: std.Io.Reader = .fixed(compressed);
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();

        var decompress: std.compress.flate.Decompress = .init(&in, .zlib, &.{});
        _ = decompress.reader.streamRemaining(&aw.writer) catch {
            return error.ZlibDecompressFailed;
        };

        const written = aw.written();
        if (written.len == 0) return error.ZlibDecompressFailed;

        return allocator.dupe(u8, written);
    }

    /// Decode raw deflate (no zlib header) - Zig 0.16+ API
    fn decodeRaw(allocator: std.mem.Allocator, compressed: []const u8) ![]u8 {
        var in: std.Io.Reader = .fixed(compressed);
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();

        var decompress: std.compress.flate.Decompress = .init(&in, .raw, &.{});
        _ = decompress.reader.streamRemaining(&aw.writer) catch {
            return error.ZlibDecompressFailed;
        };

        const written = aw.written();
        if (written.len == 0) return error.ZlibDecompressFailed;

        return allocator.dupe(u8, written);
    }
};

/// ASCII85 decoder (base-85 encoding)
pub const Ascii85Decode = struct {
    pub fn decode(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(allocator);

        var i: usize = 0;
        while (i < encoded.len) {
            // Skip whitespace
            while (i < encoded.len and isWhitespace(encoded[i])) : (i += 1) {}
            if (i >= encoded.len) break;

            // Check for end marker ~>
            if (encoded[i] == '~') break;

            // Special case: 'z' = 4 zero bytes
            if (encoded[i] == 'z') {
                try result.appendNTimes(allocator, 4, 0);
                i += 1;
                continue;
            }

            // Read up to 5 characters
            var group: [5]u8 = .{ 'u', 'u', 'u', 'u', 'u' }; // 'u' = 117, padding
            var count: usize = 0;

            while (count < 5 and i < encoded.len) {
                if (encoded[i] == '~') break;
                if (!isWhitespace(encoded[i])) {
                    group[count] = encoded[i];
                    count += 1;
                }
                i += 1;
            }

            if (count < 2) break;

            // Decode group
            var value: u32 = 0;
            for (group) |ch| {
                value = value * 85 + (ch - 33);
            }

            // Output bytes (count-1 bytes for count input chars)
            const output_count = count - 1;
            var bytes: [4]u8 = undefined;
            bytes[0] = @intCast((value >> 24) & 0xFF);
            bytes[1] = @intCast((value >> 16) & 0xFF);
            bytes[2] = @intCast((value >> 8) & 0xFF);
            bytes[3] = @intCast(value & 0xFF);

            try result.appendSlice(allocator, bytes[0..output_count]);
        }

        return result.toOwnedSlice(allocator);
    }

    fn isWhitespace(ch: u8) bool {
        return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r';
    }
};

/// ASCIIHex decoder
pub const AsciiHexDecode = struct {
    pub fn decode(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(allocator);

        var i: usize = 0;
        while (i < encoded.len) {
            // Skip whitespace
            while (i < encoded.len and isWhitespace(encoded[i])) : (i += 1) {}
            if (i >= encoded.len) break;

            // Check for end marker >
            if (encoded[i] == '>') break;

            // Read two hex digits
            const high = hexValue(encoded[i]) orelse break;
            i += 1;

            // Skip whitespace
            while (i < encoded.len and isWhitespace(encoded[i])) : (i += 1) {}

            var low: u8 = 0;
            if (i < encoded.len and encoded[i] != '>') {
                low = hexValue(encoded[i]) orelse 0;
                i += 1;
            }

            try result.append(allocator, (high << 4) | low);
        }

        return result.toOwnedSlice(allocator);
    }

    fn hexValue(ch: u8) ?u8 {
        return switch (ch) {
            '0'...'9' => ch - '0',
            'a'...'f' => ch - 'a' + 10,
            'A'...'F' => ch - 'A' + 10,
            else => null,
        };
    }

    fn isWhitespace(ch: u8) bool {
        return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r';
    }
};

/// Apply predictor (PNG/TIFF style) to decoded data
pub const Predictor = struct {
    /// PNG predictor types
    pub const PngFilter = enum(u8) {
        none = 0,
        sub = 1,
        up = 2,
        average = 3,
        paeth = 4,
    };

    /// Apply PNG predictor to data
    pub fn decodePng(
        allocator: std.mem.Allocator,
        data: []const u8,
        columns: usize,
        colors: usize,
        bits_per_component: usize,
    ) ![]u8 {
        const bytes_per_pixel = (colors * bits_per_component + 7) / 8;
        const row_bytes = (columns * colors * bits_per_component + 7) / 8;
        const row_with_filter = row_bytes + 1; // +1 for filter byte

        if (data.len % row_with_filter != 0) {
            return error.InvalidPredictorData;
        }

        const num_rows = data.len / row_with_filter;
        var output = try allocator.alloc(u8, num_rows * row_bytes);
        errdefer allocator.free(output);

        var prev_row: ?[]const u8 = null;

        for (0..num_rows) |row| {
            const src_start = row * row_with_filter;
            const filter_type: PngFilter = @enumFromInt(data[src_start]);
            const src_row = data[src_start + 1 .. src_start + row_with_filter];
            const dst_row = output[row * row_bytes .. (row + 1) * row_bytes];

            switch (filter_type) {
                .none => @memcpy(dst_row, src_row),
                .sub => {
                    for (0..row_bytes) |i| {
                        const left: u8 = if (i >= bytes_per_pixel) dst_row[i - bytes_per_pixel] else 0;
                        dst_row[i] = src_row[i] +% left;
                    }
                },
                .up => {
                    for (0..row_bytes) |i| {
                        const up: u8 = if (prev_row) |p| p[i] else 0;
                        dst_row[i] = src_row[i] +% up;
                    }
                },
                .average => {
                    for (0..row_bytes) |i| {
                        const left: u16 = if (i >= bytes_per_pixel) dst_row[i - bytes_per_pixel] else 0;
                        const up: u16 = if (prev_row) |p| p[i] else 0;
                        dst_row[i] = src_row[i] +% @as(u8, @intCast((left + up) / 2));
                    }
                },
                .paeth => {
                    for (0..row_bytes) |i| {
                        const a: i16 = if (i >= bytes_per_pixel) dst_row[i - bytes_per_pixel] else 0;
                        const b: i16 = if (prev_row) |p| p[i] else 0;
                        const cc: i16 = if (i >= bytes_per_pixel and prev_row != null) prev_row.?[i - bytes_per_pixel] else 0;
                        dst_row[i] = src_row[i] +% @as(u8, @intCast(paethPredictor(a, b, cc)));
                    }
                },
            }

            prev_row = dst_row;
        }

        return output;
    }

    fn paethPredictor(a: i16, b: i16, cc: i16) i16 {
        const p = a + b - cc;
        const pa = @abs(p - a);
        const pb = @abs(p - b);
        const pc = @abs(p - cc);

        if (pa <= pb and pa <= pc) return a;
        if (pb <= pc) return b;
        return cc;
    }
};

// === Tests ===

test "ascii hex decode" {
    const encoded = "48454C4C4F>";
    const decoded = try AsciiHexDecode.decode(std.testing.allocator, encoded);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("HELLO", decoded);
}

test "ascii hex decode with whitespace" {
    const encoded = "48 45 4C 4C 4F>";
    const decoded = try AsciiHexDecode.decode(std.testing.allocator, encoded);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("HELLO", decoded);
}

test "ascii85 decode" {
    // Known value: decode produces "test" (lowercase) from "FCfN8"
    const encoded = "FCfN8~>";
    const decoded = try Ascii85Decode.decode(std.testing.allocator, encoded);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("test", decoded);
}

test "flatedecode basic" {
    // zlib compressed "Hello World"
    const compressed = [_]u8{
        0x78, 0x9c, 0xf3, 0x48, 0xcd, 0xc9, 0xc9, 0x57,
        0x08, 0xcf, 0x2f, 0xca, 0x49, 0x01, 0x00, 0x18,
        0x0b, 0x04, 0x1d,
    };

    const decompressed = try FlateDecode.decode(std.testing.allocator, &compressed);
    defer std.testing.allocator.free(decompressed);
    try std.testing.expectEqualStrings("Hello World", decompressed);
}
