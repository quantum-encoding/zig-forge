//! Steganography module for hiding data in images
//!
//! Embeds secret data in the Least Significant Bits (LSB) of image pixels.
//! Supports PNG images with optional AES-256-GCM encryption.
//!
//! Security features:
//! - LSB embedding (1 bit per color channel)
//! - AES-256-GCM encryption of payload
//! - Password-seeded pixel position scrambling
//! - Magic header for detection
//!
//! Capacity: 1 bit per RGB channel = 3 bits per pixel
//! A 256x256 image can hide 256*256*3/8 = 24KB of data

const std = @import("std");
const mem = std.mem;
const crypto = std.crypto;
const Allocator = mem.Allocator;
const flate = std.compress.flate;
const builtin = @import("builtin");

/// Cross-platform cryptographic random bytes. SYS_getrandom on Linux
/// (works for both gnu/musl and Android-Bionic without an API-level
/// gate); arc4random on Darwin/BSD; /dev/urandom otherwise.
fn fillRandomBytes(buf: []u8) void {
    switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .freebsd, .netbsd, .openbsd, .dragonfly => {
            std.c.arc4random_buf(buf.ptr, buf.len);
        },
        .linux => {
            var filled: usize = 0;
            while (filled < buf.len) {
                const rc = std.os.linux.getrandom(buf.ptr + filled, buf.len - filled, 0);
                if (rc == 0) break;
                if (@as(isize, @bitCast(rc)) < 0) break;
                filled += rc;
            }
        },
        else => {
            const fd = std.c.open("/dev/urandom", .{ .ACCMODE = .RDONLY }, 0);
            if (fd >= 0) {
                defer _ = std.c.close(fd);
                var filled: usize = 0;
                while (filled < buf.len) {
                    const n = std.c.read(fd, buf.ptr + filled, buf.len - filled);
                    if (n <= 0) break;
                    filled += @intCast(n);
                }
            }
        },
    }
}

/// Magic header to identify steganographic content
const STEGO_MAGIC: [4]u8 = .{ 'Z', 'S', 'S', 'S' };

/// Version for format compatibility
const STEGO_VERSION: u8 = 1;

/// Header structure embedded in image
/// Total: 4 + 1 + 4 + 12 + 16 = 37 bytes minimum
const StegoHeader = struct {
    magic: [4]u8 = STEGO_MAGIC,
    version: u8 = STEGO_VERSION,
    data_len: u32, // Length of encrypted payload
    nonce: [12]u8, // AES-GCM nonce
    tag: [16]u8, // AES-GCM authentication tag
};

pub const HEADER_SIZE = 37;

/// Errors for steganography operations
pub const StegoError = error{
    ImageTooSmall,
    InvalidMagic,
    UnsupportedVersion,
    DecryptionFailed,
    InvalidPng,
    PngDecompressError,
    PngCompressError,
    InvalidPassword,
    CorruptedData,
};

/// Derive encryption key from password using HKDF-SHA256
/// Uses only MSBs from pixel salt to ensure consistency (LSBs are modified during embed)
fn deriveKey(password: []const u8, pixel_salt: []const u8) [32]u8 {
    const Kdf = crypto.kdf.hkdf.HkdfSha256;
    // Create MSB-only salt (clear LSBs to ensure same salt for embed/extract)
    var msb_salt: [32]u8 = undefined;
    const salt_len = @min(pixel_salt.len, 32);
    for (msb_salt[0..salt_len], pixel_salt[0..salt_len]) |*msb, pixel| {
        msb.* = pixel & 0xFE; // Clear LSB
    }
    @memset(msb_salt[salt_len..], 0);
    // Extract PRK from password with MSB salt
    const prk = Kdf.extract(&msb_salt, password);
    // Expand to derive key
    var key: [32]u8 = undefined;
    Kdf.expand(&key, "zsss-stego-key", prk);
    return key;
}

/// Generate scrambled pixel positions using password as seed
/// Uses only the MSB (top 7 bits) of pixels for seeding to ensure
/// consistency between embed and extract (since LSBs are modified)
/// When layer_slot is specified (0-255), only uses every 256th pixel starting at that offset
/// to allow multiple non-overlapping layers in the same image
fn generatePixelPositions(
    allocator: Allocator,
    password: []const u8,
    image_pixels: []const u8,
    total_pixels: usize,
    num_positions: usize,
    layer_slot: ?u8,
) ![]usize {
    // Calculate effective pixel count based on layer partitioning
    const effective_pixels = if (layer_slot != null) total_pixels / 256 else total_pixels;
    if (num_positions > effective_pixels) return StegoError.ImageTooSmall;

    // Create seed from password and image MSBs (not LSBs which are modified)
    // Extract MSBs from first 64 pixels for the image seed
    var msb_seed: [64]u8 = undefined;
    const seed_len = @min(image_pixels.len, 64);
    for (msb_seed[0..seed_len], image_pixels[0..seed_len]) |*msb, pixel| {
        msb.* = pixel & 0xFE; // Clear LSB
    }
    @memset(msb_seed[seed_len..], 0);

    var seed_data: [64]u8 = undefined;
    crypto.hash.sha2.Sha256.hash(password, seed_data[0..32], .{});
    crypto.hash.sha2.Sha256.hash(&msb_seed, seed_data[32..64], .{});

    // Initialize positions array
    // If layer_slot is set, only include pixels at indices where (index % 256) == slot
    var positions = try allocator.alloc(usize, effective_pixels);
    errdefer allocator.free(positions);

    if (layer_slot) |slot| {
        // Only use every 256th pixel starting at slot offset
        var pos_idx: usize = 0;
        var pixel_idx: usize = slot;
        while (pixel_idx < total_pixels and pos_idx < effective_pixels) : (pixel_idx += 256) {
            positions[pos_idx] = pixel_idx;
            pos_idx += 1;
        }
    } else {
        // Use all pixels
        for (positions, 0..) |*p, i| p.* = i;
    }

    // Fisher-Yates shuffle using deterministic PRNG
    var prng_state: u64 = 0;
    for (seed_data) |b| {
        prng_state = prng_state *% 31 +% b;
    }

    var i = effective_pixels - 1;
    while (i > 0) : (i -= 1) {
        // Simple LCG PRNG
        prng_state = prng_state *% 6364136223846793005 +% 1442695040888963407;
        const j = @as(usize, @truncate(prng_state)) % (i + 1);
        const tmp = positions[i];
        positions[i] = positions[j];
        positions[j] = tmp;
    }

    // Return only the positions we need
    const result = try allocator.alloc(usize, num_positions);
    @memcpy(result, positions[0..num_positions]);
    allocator.free(positions);

    return result;
}

/// Embed a single bit into a pixel value
inline fn embedBit(pixel: u8, bit: u1) u8 {
    return (pixel & 0xFE) | bit;
}

/// Extract a single bit from a pixel value
inline fn extractBit(pixel: u8) u1 {
    return @truncate(pixel & 1);
}

/// Encrypt data with AES-256-GCM
fn encryptData(
    allocator: Allocator,
    plaintext: []const u8,
    key: [32]u8,
) !struct { ciphertext: []u8, nonce: [12]u8, tag: [16]u8 } {
    var nonce: [12]u8 = undefined;
    fillRandomBytes(&nonce);

    const ciphertext = try allocator.alloc(u8, plaintext.len);
    var tag: [16]u8 = undefined;

    crypto.aead.aes_gcm.Aes256Gcm.encrypt(
        ciphertext,
        &tag,
        plaintext,
        "",
        nonce,
        key,
    );

    return .{ .ciphertext = ciphertext, .nonce = nonce, .tag = tag };
}

/// Decrypt data with AES-256-GCM
fn decryptData(
    allocator: Allocator,
    ciphertext: []const u8,
    key: [32]u8,
    nonce: [12]u8,
    tag: [16]u8,
) ![]u8 {
    const plaintext = try allocator.alloc(u8, ciphertext.len);
    errdefer allocator.free(plaintext);

    crypto.aead.aes_gcm.Aes256Gcm.decrypt(
        plaintext,
        ciphertext,
        tag,
        "",
        nonce,
        key,
    ) catch {
        return StegoError.DecryptionFailed;
    };

    return plaintext;
}

/// Embed data into image pixels using LSB with layer partitioning
/// layer_slot: 0-255 assigns this data to a specific layer (uses every 256th pixel starting at slot)
///             null uses all pixels (default behavior)
pub fn embedInPixelsWithLayer(
    allocator: Allocator,
    pixels: []u8,
    data: []const u8,
    password: ?[]const u8,
    layer_slot: ?u8,
) !void {
    // Encrypt if password provided
    var payload: []u8 = undefined;
    var header = StegoHeader{
        .data_len = 0,
        .nonce = undefined,
        .tag = undefined,
    };

    if (password) |pwd| {
        const key = deriveKey(pwd, pixels[0..@min(pixels.len, 64)]);
        const encrypted = try encryptData(allocator, data, key);
        payload = encrypted.ciphertext;
        header.nonce = encrypted.nonce;
        header.tag = encrypted.tag;
        header.data_len = @intCast(encrypted.ciphertext.len);
    } else {
        payload = try allocator.dupe(u8, data);
        header.data_len = @intCast(data.len);
        @memset(&header.nonce, 0);
        @memset(&header.tag, 0);
    }
    defer allocator.free(payload);

    // Calculate total bits needed
    const total_bytes = HEADER_SIZE + payload.len;
    const total_bits = total_bytes * 8;

    // Check capacity (3 bits per pixel for RGB)
    // If layer partitioning is active, we only have 1/256th of the pixels available
    const effective_pixels = if (layer_slot != null) pixels.len / 256 else pixels.len;
    const available_bits = (effective_pixels / 3) * 3; // Round down to pixel boundary
    if (total_bits > available_bits) return StegoError.ImageTooSmall;

    // Get scrambled pixel positions if password provided
    var bit_positions: ?[]usize = null;
    defer if (bit_positions) |p| allocator.free(p);

    if (password) |pwd| {
        bit_positions = try generatePixelPositions(
            allocator,
            pwd,
            pixels[0..@min(pixels.len, 256)],
            pixels.len,
            total_bits,
            layer_slot,
        );
    } else if (layer_slot) |slot| {
        // Even without password, need to map to layer-specific positions
        bit_positions = try generatePixelPositions(
            allocator,
            "", // Empty password = no scrambling, just layer partitioning
            pixels[0..@min(pixels.len, 256)],
            pixels.len,
            total_bits,
            slot,
        );
    }

    // Serialize header
    var header_buf: [HEADER_SIZE]u8 = undefined;
    @memcpy(header_buf[0..4], &header.magic);
    header_buf[4] = header.version;
    header_buf[5] = @truncate(header.data_len & 0xFF);
    header_buf[6] = @truncate((header.data_len >> 8) & 0xFF);
    header_buf[7] = @truncate((header.data_len >> 16) & 0xFF);
    header_buf[8] = @truncate((header.data_len >> 24) & 0xFF);
    @memcpy(header_buf[9..21], &header.nonce);
    @memcpy(header_buf[21..37], &header.tag);

    // Combine header and payload
    var full_data = try allocator.alloc(u8, total_bytes);
    defer allocator.free(full_data);
    @memcpy(full_data[0..HEADER_SIZE], &header_buf);
    @memcpy(full_data[HEADER_SIZE..], payload);

    // Embed bits
    var bit_idx: usize = 0;
    for (full_data) |byte| {
        for (0..8) |bit_offset| {
            const bit: u1 = @truncate((byte >> @intCast(7 - bit_offset)) & 1);
            const pixel_idx = if (bit_positions) |pos| pos[bit_idx] else bit_idx;
            pixels[pixel_idx] = embedBit(pixels[pixel_idx], bit);
            bit_idx += 1;
        }
    }
}

/// Embed data into image pixels using LSB (backwards-compatible wrapper)
pub fn embedInPixels(
    allocator: Allocator,
    pixels: []u8,
    data: []const u8,
    password: ?[]const u8,
) !void {
    return embedInPixelsWithLayer(allocator, pixels, data, password, null);
}

/// Extract data from image pixels using LSB with layer partitioning
/// layer_slot: 0-255 extracts from a specific layer
///             null extracts from all pixels (default behavior)
pub fn extractFromPixelsWithLayer(
    allocator: Allocator,
    pixels: []const u8,
    password: ?[]const u8,
    layer_slot: ?u8,
) ![]u8 {
    // First extract header (always at known positions for detection)
    // But if password provided, positions are scrambled
    const header_bits = HEADER_SIZE * 8;

    if (pixels.len < header_bits) return StegoError.ImageTooSmall;

    // Get scrambled positions for header if password provided
    var header_positions: ?[]usize = null;
    defer if (header_positions) |p| allocator.free(p);

    if (password) |pwd| {
        // We need to extract enough to read the header first
        header_positions = try generatePixelPositions(
            allocator,
            pwd,
            pixels[0..@min(pixels.len, 256)],
            pixels.len,
            header_bits,
            layer_slot,
        );
    } else if (layer_slot) |slot| {
        // No password but layer-specific extraction
        header_positions = try generatePixelPositions(
            allocator,
            "", // Empty password = no scrambling, just layer partitioning
            pixels[0..@min(pixels.len, 256)],
            pixels.len,
            header_bits,
            slot,
        );
    }

    // Extract header bytes
    var header_buf: [HEADER_SIZE]u8 = undefined;
    var bit_idx: usize = 0;
    for (&header_buf) |*byte| {
        var b: u8 = 0;
        for (0..8) |_| {
            const pixel_idx = if (header_positions) |pos| pos[bit_idx] else bit_idx;
            const bit = extractBit(pixels[pixel_idx]);
            b = (b << 1) | bit;
            bit_idx += 1;
        }
        byte.* = b;
    }

    // Verify magic
    if (!mem.eql(u8, header_buf[0..4], &STEGO_MAGIC)) {
        return StegoError.InvalidMagic;
    }

    // Check version
    if (header_buf[4] != STEGO_VERSION) {
        return StegoError.UnsupportedVersion;
    }

    // Parse header
    const data_len: u32 = @as(u32, header_buf[5]) |
        (@as(u32, header_buf[6]) << 8) |
        (@as(u32, header_buf[7]) << 16) |
        (@as(u32, header_buf[8]) << 24);
    var nonce: [12]u8 = undefined;
    var tag: [16]u8 = undefined;
    @memcpy(&nonce, header_buf[9..21]);
    @memcpy(&tag, header_buf[21..37]);

    // Now extract the payload
    const total_bits = (HEADER_SIZE + data_len) * 8;
    if (total_bits > pixels.len) return StegoError.CorruptedData;

    // Get full scrambled positions if password provided
    var payload_positions: ?[]usize = null;
    defer if (payload_positions) |p| allocator.free(p);

    if (password) |pwd| {
        payload_positions = try generatePixelPositions(
            allocator,
            pwd,
            pixels[0..@min(pixels.len, 256)],
            pixels.len,
            total_bits,
            layer_slot,
        );
    } else if (layer_slot) |slot| {
        // No password but layer-specific extraction
        payload_positions = try generatePixelPositions(
            allocator,
            "", // Empty password = no scrambling, just layer partitioning
            pixels[0..@min(pixels.len, 256)],
            pixels.len,
            total_bits,
            slot,
        );
    }

    // Extract payload
    const payload = try allocator.alloc(u8, data_len);
    errdefer allocator.free(payload);

    bit_idx = HEADER_SIZE * 8; // Skip header
    for (payload) |*byte| {
        var b: u8 = 0;
        for (0..8) |_| {
            const pixel_idx = if (payload_positions) |pos| pos[bit_idx] else bit_idx;
            const bit = extractBit(pixels[pixel_idx]);
            b = (b << 1) | bit;
            bit_idx += 1;
        }
        byte.* = b;
    }

    // Decrypt if password provided and nonce is non-zero
    var has_encryption = false;
    for (nonce) |b| {
        if (b != 0) {
            has_encryption = true;
            break;
        }
    }

    if (has_encryption) {
        if (password) |pwd| {
            const key = deriveKey(pwd, pixels[0..@min(pixels.len, 64)]);
            const decrypted = try decryptData(allocator, payload, key, nonce, tag);
            allocator.free(payload);
            return decrypted;
        } else {
            return StegoError.InvalidPassword;
        }
    }

    return payload;
}

/// Extract data from image pixels using LSB (backwards-compatible wrapper)
pub fn extractFromPixels(
    allocator: Allocator,
    pixels: []const u8,
    password: ?[]const u8,
) ![]u8 {
    return extractFromPixelsWithLayer(allocator, pixels, password, null);
}

// =============================================================================
// PNG Support
// =============================================================================

const PNG_SIGNATURE: [8]u8 = .{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' };

/// PNG Image structure
pub const PngImage = struct {
    width: u32,
    height: u32,
    bit_depth: u8,
    color_type: u8,
    pixels: []u8, // Raw RGBA or RGB pixels
    allocator: Allocator,

    pub fn deinit(self: *PngImage) void {
        self.allocator.free(self.pixels);
    }

    /// Get bytes per pixel based on color type
    pub fn bytesPerPixel(self: *const PngImage) usize {
        return switch (self.color_type) {
            0 => 1, // Grayscale
            2 => 3, // RGB
            3 => 1, // Indexed
            4 => 2, // Grayscale + Alpha
            6 => 4, // RGBA
            else => 3,
        };
    }
};

/// Read a 4-byte big-endian unsigned integer
fn readU32BE(data: []const u8) u32 {
    return (@as(u32, data[0]) << 24) |
        (@as(u32, data[1]) << 16) |
        (@as(u32, data[2]) << 8) |
        @as(u32, data[3]);
}

/// Write a 4-byte big-endian unsigned integer
fn writeU32BE(buf: []u8, val: u32) void {
    buf[0] = @truncate((val >> 24) & 0xFF);
    buf[1] = @truncate((val >> 16) & 0xFF);
    buf[2] = @truncate((val >> 8) & 0xFF);
    buf[3] = @truncate(val & 0xFF);
}

/// CRC32 for PNG chunks
fn crc32(data: []const u8) u32 {
    return std.hash.Crc32.hash(data);
}

/// PNG dimensions result
pub const PngDimensions = struct {
    width: usize,
    height: usize,
};

/// Get PNG image dimensions without fully decoding
pub fn getPngDimensions(data: []const u8) !PngDimensions {
    if (data.len < 8 or !mem.eql(u8, data[0..8], &PNG_SIGNATURE)) {
        return StegoError.InvalidPng;
    }

    var pos: usize = 8;
    while (pos + 12 <= data.len) {
        const chunk_len = readU32BE(data[pos..][0..4]);
        const chunk_type = data[pos + 4 ..][0..4];
        const chunk_data = data[pos + 8 ..][0..chunk_len];

        if (mem.eql(u8, chunk_type, "IHDR")) {
            const width = readU32BE(chunk_data[0..4]);
            const height = readU32BE(chunk_data[4..8]);
            return PngDimensions{
                .width = width,
                .height = height,
            };
        }

        pos += 12 + chunk_len;
    }

    return StegoError.InvalidPng;
}

/// Paeth predictor for PNG filtering
fn paethPredictor(a: i16, b: i16, c: i16) u8 {
    const p = a + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return @intCast(@as(u16, @bitCast(a)) & 0xFF);
    if (pb <= pc) return @intCast(@as(u16, @bitCast(b)) & 0xFF);
    return @intCast(@as(u16, @bitCast(c)) & 0xFF);
}

/// Decode PNG image
pub fn decodePng(allocator: Allocator, data: []const u8) !PngImage {
    if (data.len < 8 or !mem.eql(u8, data[0..8], &PNG_SIGNATURE)) {
        return StegoError.InvalidPng;
    }

    var width: u32 = 0;
    var height: u32 = 0;
    var bit_depth: u8 = 0;
    var color_type: u8 = 0;

    // Collect all IDAT chunks
    var idat_data: std.ArrayList(u8) = .empty;
    defer idat_data.deinit(allocator);

    var pos: usize = 8;
    while (pos + 12 <= data.len) {
        const chunk_len = readU32BE(data[pos..][0..4]);
        const chunk_type = data[pos + 4 ..][0..4];
        const chunk_data = data[pos + 8 ..][0..chunk_len];

        if (mem.eql(u8, chunk_type, "IHDR")) {
            width = readU32BE(chunk_data[0..4]);
            height = readU32BE(chunk_data[4..8]);
            bit_depth = chunk_data[8];
            color_type = chunk_data[9];
        } else if (mem.eql(u8, chunk_type, "IDAT")) {
            try idat_data.appendSlice(allocator, chunk_data);
        } else if (mem.eql(u8, chunk_type, "IEND")) {
            break;
        }

        pos += 12 + chunk_len;
    }

    if (width == 0 or height == 0) return StegoError.InvalidPng;

    // Decompress IDAT data using flate decompressor
    var decompressed: std.ArrayList(u8) = .empty;
    defer decompressed.deinit(allocator);

    const zlib_data = idat_data.items;
    if (zlib_data.len < 6) return StegoError.PngDecompressError;

    // Check zlib header (CMF, FLG)
    const cmf: u16 = zlib_data[0];
    const flg: u16 = zlib_data[1];
    if ((cmf & 0x0F) != 8) return StegoError.PngDecompressError; // Must be deflate
    if (((cmf * 256 + flg) % 31) != 0) return StegoError.PngDecompressError; // Header checksum

    // Use the flate decompressor with proper streaming
    var input_reader = std.Io.Reader.fixed(idat_data.items);
    var decomp_buffer: [flate.max_window_len]u8 = undefined;
    var decompress_state: flate.Decompress = .init(&input_reader, .zlib, &decomp_buffer);

    // Read decompressed data by peeking and consuming from the decompressor's reader
    while (true) {
        // Try to get buffered data first
        const buffered = decompress_state.reader.buffered();
        if (buffered.len > 0) {
            try decompressed.appendSlice(allocator, buffered);
            decompress_state.reader.seek += buffered.len;
            continue;
        }

        // Try to decompress more data
        const peek_result = decompress_state.reader.peekGreedy(1);
        if (peek_result) |bytes| {
            if (bytes.len == 0) break;
            try decompressed.appendSlice(allocator, bytes);
            decompress_state.reader.seek += bytes.len;
        } else |err| {
            if (err == error.EndOfStream) break;
            return StegoError.PngDecompressError;
        }
    }

    // Calculate bytes per pixel and scanline
    const bpp: usize = switch (color_type) {
        0 => 1,
        2 => 3,
        3 => 1,
        4 => 2,
        6 => 4,
        else => 3,
    };
    const scanline_len = width * bpp;
    const expected_len = height * (1 + scanline_len);

    if (decompressed.items.len < expected_len) return StegoError.InvalidPng;

    // Allocate pixel buffer
    const pixels = try allocator.alloc(u8, width * height * bpp);
    errdefer allocator.free(pixels);

    // Unfilter scanlines
    var prev_scanline: ?[]const u8 = null;
    var y: usize = 0;
    while (y < height) : (y += 1) {
        const scanline_start = y * (1 + scanline_len);
        const filter_type = decompressed.items[scanline_start];
        const raw_scanline = decompressed.items[scanline_start + 1 ..][0..scanline_len];
        const pixel_row = pixels[y * scanline_len ..][0..scanline_len];

        for (0..scanline_len) |x| {
            const raw = raw_scanline[x];
            const a: i16 = if (x >= bpp) @as(i16, pixel_row[x - bpp]) else 0;
            const b: i16 = if (prev_scanline) |prev| @as(i16, prev[x]) else 0;
            const c: i16 = if (prev_scanline != null and x >= bpp)
                @as(i16, prev_scanline.?[x - bpp])
            else
                0;

            pixel_row[x] = switch (filter_type) {
                0 => raw, // None
                1 => raw +% @as(u8, @intCast(@as(u16, @bitCast(a)) & 0xFF)), // Sub
                2 => raw +% @as(u8, @intCast(@as(u16, @bitCast(b)) & 0xFF)), // Up
                3 => raw +% @as(u8, @intCast((@as(u16, @bitCast(a)) + @as(u16, @bitCast(b))) / 2)), // Average
                4 => raw +% paethPredictor(a, b, c), // Paeth
                else => raw,
            };
        }

        prev_scanline = pixel_row;
    }

    return PngImage{
        .width = width,
        .height = height,
        .bit_depth = bit_depth,
        .color_type = color_type,
        .pixels = pixels,
        .allocator = allocator,
    };
}

/// ArrayList-backed Writer for compression output
const ArrayListWriter = struct {
    list: *std.ArrayList(u8),
    allocator: Allocator,
    err: ?anyerror = null,

    fn drain(w: *std.Io.Writer, data: []const u8) std.Io.Writer.Error!usize {
        const self: *ArrayListWriter = @alignCast(@fieldParentPtr("writer", w));
        self.list.appendSlice(self.allocator, data) catch |e| {
            self.err = e;
            return error.WriteFailed;
        };
        return data.len;
    }
};

/// Encode PNG image
pub fn encodePng(allocator: Allocator, image: *const PngImage) ![]u8 {
    const bpp = image.bytesPerPixel();
    const scanline_len = image.width * bpp;

    // Create filtered scanlines (using filter type 0 = None for simplicity)
    var filtered: std.ArrayList(u8) = .empty;
    defer filtered.deinit(allocator);

    var y: usize = 0;
    while (y < image.height) : (y += 1) {
        try filtered.append(allocator, 0); // Filter type: None
        const row_start = y * scanline_len;
        try filtered.appendSlice(allocator, image.pixels[row_start..][0..scanline_len]);
    }

    // Compress with zlib using new flate API
    var compressed: std.ArrayList(u8) = .empty;
    defer compressed.deinit(allocator);

    // Use a simple store compression (no compression) for simplicity
    // This avoids the complex Compress API but still produces valid zlib output
    // Format: 2-byte zlib header + stored deflate blocks + 4-byte adler32

    // Zlib header (78 01 = no compression / fastest)
    try compressed.append(allocator, 0x78);
    try compressed.append(allocator, 0x01);

    // Store filtered data as uncompressed deflate blocks
    var data_pos: usize = 0;
    while (data_pos < filtered.items.len) {
        const remaining = filtered.items.len - data_pos;
        const block_size = @min(remaining, 65535);
        const is_final: u8 = if (data_pos + block_size >= filtered.items.len) 1 else 0;

        // Deflate stored block header: BFINAL (1 bit) + BTYPE=00 (2 bits) = 0x00 or 0x01
        try compressed.append(allocator, is_final);

        // LEN (2 bytes little-endian)
        try compressed.append(allocator, @truncate(block_size & 0xFF));
        try compressed.append(allocator, @truncate((block_size >> 8) & 0xFF));

        // NLEN (one's complement of LEN)
        const nlen = ~@as(u16, @intCast(block_size));
        try compressed.append(allocator, @truncate(nlen & 0xFF));
        try compressed.append(allocator, @truncate((nlen >> 8) & 0xFF));

        // Data
        try compressed.appendSlice(allocator, filtered.items[data_pos..][0..block_size]);
        data_pos += block_size;
    }

    // Adler-32 checksum (big-endian)
    const adler = std.hash.Adler32.hash(filtered.items);
    try compressed.append(allocator, @truncate((adler >> 24) & 0xFF));
    try compressed.append(allocator, @truncate((adler >> 16) & 0xFF));
    try compressed.append(allocator, @truncate((adler >> 8) & 0xFF));
    try compressed.append(allocator, @truncate(adler & 0xFF));

    // Build PNG file
    var png: std.ArrayList(u8) = .empty;
    errdefer png.deinit(allocator);

    // Signature
    try png.appendSlice(allocator, &PNG_SIGNATURE);

    // IHDR chunk
    var ihdr: [13]u8 = undefined;
    writeU32BE(ihdr[0..4], image.width);
    writeU32BE(ihdr[4..8], image.height);
    ihdr[8] = image.bit_depth;
    ihdr[9] = image.color_type;
    ihdr[10] = 0; // Compression method
    ihdr[11] = 0; // Filter method
    ihdr[12] = 0; // Interlace method

    try writeChunk(allocator, &png, "IHDR", &ihdr);

    // IDAT chunk(s)
    var idat_pos: usize = 0;
    while (idat_pos < compressed.items.len) {
        const chunk_size = @min(compressed.items.len - idat_pos, 32768);
        try writeChunk(allocator, &png, "IDAT", compressed.items[idat_pos..][0..chunk_size]);
        idat_pos += chunk_size;
    }

    // IEND chunk
    try writeChunk(allocator, &png, "IEND", "");

    return png.toOwnedSlice(allocator);
}

fn writeChunk(allocator: Allocator, output: *std.ArrayList(u8), chunk_type: []const u8, data: []const u8) !void {
    var len_buf: [4]u8 = undefined;
    writeU32BE(&len_buf, @intCast(data.len));
    try output.appendSlice(allocator, &len_buf);
    try output.appendSlice(allocator, chunk_type);
    try output.appendSlice(allocator, data);

    // CRC over type + data
    var crc_data: std.ArrayList(u8) = .empty;
    defer crc_data.deinit(allocator);
    try crc_data.appendSlice(allocator, chunk_type);
    try crc_data.appendSlice(allocator, data);

    var crc_buf: [4]u8 = undefined;
    writeU32BE(&crc_buf, crc32(crc_data.items));
    try output.appendSlice(allocator, &crc_buf);
}

// =============================================================================
// High-level API
// =============================================================================

/// Embed data into a PNG image with layer partitioning
pub fn embedInPngWithLayer(
    allocator: Allocator,
    png_data: []const u8,
    secret: []const u8,
    password: ?[]const u8,
    layer_slot: ?u8,
) ![]u8 {
    // Decode PNG
    var image = try decodePng(allocator, png_data);
    defer image.deinit();

    // Embed data
    try embedInPixelsWithLayer(allocator, image.pixels, secret, password, layer_slot);

    // Re-encode PNG
    return encodePng(allocator, &image);
}

/// Embed data into a PNG image (backwards-compatible wrapper)
pub fn embedInPng(
    allocator: Allocator,
    png_data: []const u8,
    secret: []const u8,
    password: ?[]const u8,
) ![]u8 {
    return embedInPngWithLayer(allocator, png_data, secret, password, null);
}

/// Extract data from a PNG image with layer partitioning
pub fn extractFromPngWithLayer(
    allocator: Allocator,
    png_data: []const u8,
    password: ?[]const u8,
    layer_slot: ?u8,
) ![]u8 {
    // Decode PNG
    var image = try decodePng(allocator, png_data);
    defer image.deinit();

    // Extract data
    return extractFromPixelsWithLayer(allocator, image.pixels, password, layer_slot);
}

/// Extract data from a PNG image (backwards-compatible wrapper)
pub fn extractFromPng(
    allocator: Allocator,
    png_data: []const u8,
    password: ?[]const u8,
) ![]u8 {
    return extractFromPngWithLayer(allocator, png_data, password, null);
}

// =============================================================================
// Tests
// =============================================================================

test "LSB embed/extract roundtrip" {
    const allocator = std.testing.allocator;

    // Create fake pixel data
    const pixels = try allocator.alloc(u8, 10000);
    defer allocator.free(pixels);
    @memset(pixels, 128);

    const secret = "Hello, Steganography!";

    // Embed without password
    try embedInPixels(allocator, pixels, secret, null);

    // Extract
    const recovered = try extractFromPixels(allocator, pixels, null);
    defer allocator.free(recovered);

    try std.testing.expectEqualStrings(secret, recovered);
}

test "LSB embed/extract with password" {
    const allocator = std.testing.allocator;

    const pixels = try allocator.alloc(u8, 10000);
    defer allocator.free(pixels);
    @memset(pixels, 128);

    const secret = "Secret message with encryption!";
    const password = "correct horse battery staple";

    // Embed with password
    try embedInPixels(allocator, pixels, secret, password);

    // Extract with correct password
    const recovered = try extractFromPixels(allocator, pixels, password);
    defer allocator.free(recovered);

    try std.testing.expectEqualStrings(secret, recovered);
}

test "LSB wrong password fails" {
    const allocator = std.testing.allocator;

    const pixels = try allocator.alloc(u8, 10000);
    defer allocator.free(pixels);
    @memset(pixels, 128);

    const secret = "Secret data";
    const password = "correct password";

    try embedInPixels(allocator, pixels, secret, password);

    // Try to extract with wrong password - wrong password causes different pixel positions,
    // resulting in garbage data that fails magic number check before decryption
    const result = extractFromPixels(allocator, pixels, "wrong password");
    try std.testing.expectError(StegoError.InvalidMagic, result);
}
