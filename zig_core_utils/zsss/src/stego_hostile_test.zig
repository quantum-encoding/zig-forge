//! Hostile-input tests for the PNG decoder behind `zsss_stego_embed` / `zsss_stego_extract`.
//!
//! Crypto test campaign 2026-10-11, track E (findings #8 / E-2, E-3, E-4, E-5). Track E ran
//! these from a scratch copy because a file added here changes the program's source identity
//! and stales every stamped libzsss archive; the fixes landed with them, so they live in the
//! tree now and the archives were rebuilt.
//!
//! External anchors (inputs and expected outputs the decoder's author did not write):
//!
//!   - the canonical 67-byte 1x1 transparent PNG that circulates as "the smallest PNG"
//!     (IHDR CRC 1F15C489, IDAT CRC 0D0A2DB4, IEND CRC AE426082 — all three re-verified with
//!     CPython's zlib.crc32, and its IDAT inflated by zlib to 00 00 00 00 00: one filter byte
//!     and one transparent RGBA pixel);
//!   - tests/png-gradient-64x64-filtered.png, a 64x64 RGB gradient whose rows carry every
//!     filter type (None, Sub, Up, Average, Paeth) and whose stream, CRCs and Adler-32 were
//!     produced by CPython's zlib (tests/make_png_fixtures.py). The expected pixels are
//!     recomputed here from the formula, so the unfilter is checked against that encoder;
//!   - tests/zlib-bomb-64mib.zlib, 64 MiB of zeros deflated by CPython's zlib at level 9
//!     (65,238 bytes): the campaign's exact bomb;
//!   - the chunk layout and IHDR rules of PNG 1.2 §3.2 / §4.1.1 and the zlib framing of
//!     RFC 1950, which every crafted negative below violates in one stated way.
//!
//! Each crafted input is built by `buildPng` from the spec's layout, never by `encodePng`,
//! so a decoder that merely accepts its own encoder's output does not pass.

const std = @import("std");
const testing = std.testing;
const stego = @import("stego.zig");

const zlib_bomb = @embedFile("zlib_bomb");
const png_gradient = @embedFile("png_gradient");

// =============================================================================
// A peak-tracking allocator, to measure what a crafted PNG makes the decoder allocate.
// =============================================================================

const Peak = struct {
    live: usize = 0,
    peak: usize = 0,
    backing: std.mem.Allocator = std.heap.page_allocator,

    fn allocator(self: *Peak) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(ctx: *anyopaque, len: usize, al: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Peak = @ptrCast(@alignCast(ctx));
        const p = self.backing.rawAlloc(len, al, ra) orelse return null;
        self.live += len;
        self.peak = @max(self.peak, self.live);
        return p;
    }
    fn resize(ctx: *anyopaque, mem: []u8, al: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *Peak = @ptrCast(@alignCast(ctx));
        if (!self.backing.rawResize(mem, al, new_len, ra)) return false;
        self.live = self.live - mem.len + new_len;
        self.peak = @max(self.peak, self.live);
        return true;
    }
    fn remap(ctx: *anyopaque, mem: []u8, al: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *Peak = @ptrCast(@alignCast(ctx));
        const p = self.backing.rawRemap(mem, al, new_len, ra) orelse return null;
        self.live = self.live - mem.len + new_len;
        self.peak = @max(self.peak, self.live);
        return p;
    }
    fn free(ctx: *anyopaque, mem: []u8, al: std.mem.Alignment, ra: usize) void {
        const self: *Peak = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(mem, al, ra);
        self.live -= mem.len;
    }
};

/// Decode under a peak-tracking allocator; returns the error (or null on success) and the peak.
fn decodeMeasured(png: []const u8) struct { err: ?anyerror, peak: usize } {
    var peak = Peak{};
    if (stego.decodePng(peak.allocator(), png)) |img| {
        var m = img;
        m.deinit();
        return .{ .err = null, .peak = peak.peak };
    } else |e| {
        return .{ .err = e, .peak = peak.peak };
    }
}

// =============================================================================
// PNG builders, from the spec's layout (PNG 1.2 §3.2: length, type, data, CRC over type+data)
// =============================================================================

pub const png_sig = [_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' };

pub fn chunk(a: std.mem.Allocator, out: *std.ArrayList(u8), typ: []const u8, data: []const u8, crc_ok: bool) !void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(data.len), .big);
    try out.appendSlice(a, &len);
    try out.appendSlice(a, typ);
    try out.appendSlice(a, data);
    var h = std.hash.Crc32.init();
    h.update(typ);
    h.update(data);
    var crc: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc, if (crc_ok) h.final() else h.final() ^ 0xdeadbeef, .big);
    try out.appendSlice(a, &crc);
}

/// A 13-byte IHDR: width, height, bit depth, colour type, compression 0, filter 0, interlace.
pub fn ihdr(w: u32, h: u32, depth: u8, color: u8) [13]u8 {
    return ihdrFull(w, h, depth, color, 0);
}

pub fn ihdrFull(w: u32, h: u32, depth: u8, color: u8, interlace: u8) [13]u8 {
    var out: [13]u8 = .{0} ** 13;
    std.mem.writeInt(u32, out[0..4], w, .big);
    std.mem.writeInt(u32, out[4..8], h, .big);
    out[8] = depth;
    out[9] = color;
    out[12] = interlace;
    return out;
}

/// A stored-block zlib stream (RFC 1950 framing, RFC 1951 BTYPE=00 blocks) of `payload`.
pub fn zlibStored(a: std.mem.Allocator, payload: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, &[_]u8{ 0x78, 0x01 });
    var pos: usize = 0;
    while (pos < payload.len) {
        const n = @min(payload.len - pos, 65535);
        const final: u8 = if (pos + n >= payload.len) 1 else 0;
        try out.append(a, final);
        try out.append(a, @truncate(n & 0xff));
        try out.append(a, @truncate(n >> 8));
        const nlen = ~@as(u16, @intCast(n));
        try out.append(a, @truncate(nlen & 0xff));
        try out.append(a, @truncate(nlen >> 8));
        try out.appendSlice(a, payload[pos..][0..n]);
        pos += n;
    }
    if (payload.len == 0) try out.appendSlice(a, &[_]u8{ 1, 0, 0, 0xff, 0xff });
    const adler = std.hash.Adler32.hash(payload);
    var ad: [4]u8 = undefined;
    std.mem.writeInt(u32, &ad, adler, .big);
    try out.appendSlice(a, &ad);
    return out.toOwnedSlice(a);
}

pub fn buildPng(a: std.mem.Allocator, header: []const u8, idat: []const u8, crc_ok: bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, &png_sig);
    try chunk(a, &out, "IHDR", header, crc_ok);
    try chunk(a, &out, "IDAT", idat, crc_ok);
    try chunk(a, &out, "IEND", "", crc_ok);
    return out.toOwnedSlice(a);
}

/// The filtered stream (filter byte 0 + `w*bpp` bytes of `fill` per row) for a w x w image.
fn filteredRows(a: std.mem.Allocator, w: usize, bpp: usize, fill: u8) ![]u8 {
    const raw = try a.alloc(u8, w * (1 + w * bpp));
    @memset(raw, fill);
    var y: usize = 0;
    while (y < w) : (y += 1) raw[y * (1 + w * bpp)] = 0;
    return raw;
}

/// A valid w x w RGB PNG (8-bit, filter None, stored deflate) with every sample = `fill`.
pub fn plainPng(a: std.mem.Allocator, w: usize, fill: u8) ![]u8 {
    const raw = try filteredRows(a, w, 3, fill);
    defer a.free(raw);
    const z = try zlibStored(a, raw);
    defer a.free(z);
    return buildPng(a, &ihdr(@intCast(w), @intCast(w), 8, 2), z, true);
}

// =============================================================================
// External anchors: PNGs this library did not encode
// =============================================================================

test "PNG anchor: the canonical 67-byte 1x1 transparent PNG decodes to one transparent RGBA pixel" {
    // Bytes as they circulate; CRCs re-verified with CPython zlib.crc32 (see file header).
    const canon = [_]u8{
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // signature
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, // IHDR, 13 bytes
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, // 1 x 1
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, // 8-bit RGBA, no interlace, CRC
        0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, 0x54, // IDAT, 10 bytes
        0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, 0x05, 0x00, 0x01, // zlib: 5 zero bytes
        0x0D, 0x0A, 0x2D, 0xB4, // CRC
        0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82, // IEND
    };
    var img = try stego.decodePng(testing.allocator, &canon);
    defer img.deinit();
    try testing.expectEqual(@as(u32, 1), img.width);
    try testing.expectEqual(@as(u32, 1), img.height);
    try testing.expectEqual(@as(u8, 8), img.bit_depth);
    try testing.expectEqual(@as(u8, 6), img.color_type);
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0 }, img.pixels);
}

test "PNG anchor: a zlib-encoded 64x64 gradient with Sub/Up/Average/Paeth rows unfilters to the formula" {
    var img = try stego.decodePng(testing.allocator, png_gradient);
    defer img.deinit();
    try testing.expectEqual(@as(u32, 64), img.width);
    try testing.expectEqual(@as(u32, 64), img.height);
    try testing.expectEqual(@as(usize, 64 * 64 * 3), img.pixels.len);
    var y: usize = 0;
    while (y < 64) : (y += 1) {
        var x: usize = 0;
        while (x < 64) : (x += 1) {
            const p = img.pixels[(y * 64 + x) * 3 ..][0..3];
            try testing.expectEqual(@as(u8, @truncate(x * 4)), p[0]);
            try testing.expectEqual(@as(u8, @truncate(y * 4)), p[1]);
            try testing.expectEqual(@as(u8, @truncate(x + y)), p[2]);
        }
    }
}

// =============================================================================
// Finding #8 / E-2: the decode budget
// =============================================================================

test "E-2: the 65 KB zlib bomb under a 1x1 IHDR is refused after one declared row, not after 64 MiB" {
    const a = testing.allocator;
    const png = try buildPng(a, &ihdr(1, 1, 8, 2), zlib_bomb, true);
    defer a.free(png);
    try testing.expect(png.len < 70_000);

    const r = decodeMeasured(png);
    // Refused: the stream holds more than the 4 bytes a 1x1 RGB image declares.
    try testing.expectEqual(@as(?anyerror, stego.StegoError.InvalidPng), r.err);
    // Cost: the IDAT copy plus the 4-byte declared stream, nothing the file chose.
    // Before the budget this input cost 130,883,736 bytes (track E, 2004x the file).
    try testing.expect(r.peak < png.len + 4096);
}

test "E-2: the bomb under the largest admissible IHDR costs exactly the declared stream, then is refused as short" {
    // 4096 x 4096 RGBA is the budget's edge (MAX_PIXELS). The declared stream is
    // 4096 * (1 + 16384) = 67,112,960 bytes; the bomb inflates to 67,108,864, so it ends
    // 4096 bytes early and is refused — after inflating only what the header allowed.
    const a = testing.allocator;
    const png = try buildPng(a, &ihdr(4096, 4096, 8, 6), zlib_bomb, true);
    defer a.free(png);
    const declared: usize = 4096 * (1 + 4096 * 4);

    const r = decodeMeasured(png);
    try testing.expectEqual(@as(?anyerror, stego.StegoError.PngDecompressError), r.err);
    try testing.expect(r.peak >= declared);
    try testing.expect(r.peak <= declared + png.len + 4096);
}

test "E-2: an IHDR above the pixel budget is refused before any allocation" {
    const a = testing.allocator;
    const z = try zlibStored(a, &[_]u8{ 0, 1, 2, 3 });
    defer a.free(z);
    const over = [_][2]u32{
        .{ 65536, 65536 }, // 4 Gpx, the 17 GiB declaration of finding #8
        .{ 4097, 4096 }, // one column over MAX_PIXELS
        .{ 1, 65536 + 1 }, // one over MAX_DIM, still few pixels
        .{ 0xffffffff, 1 },
        .{ 1 << 31, 1 << 31 },
    };
    for (over) |wh| {
        const png = try buildPng(a, &ihdr(wh[0], wh[1], 8, 6), z, true);
        defer a.free(png);
        const r = decodeMeasured(png);
        try testing.expect(r.err != null);
        try testing.expect(r.err.? == stego.StegoError.ImageTooLarge or r.err.? == stego.StegoError.InvalidPng);
        try testing.expectEqual(@as(usize, 0), r.peak);
    }
    // Exactly MAX_PIXELS is admitted: this short stream fails later, on length, not on budget.
    const edge = try buildPng(a, &ihdr(4096, 4096, 8, 6), z, true);
    defer a.free(edge);
    try testing.expectError(stego.StegoError.PngDecompressError, stego.decodePng(a, edge));
}

test "E-2: a stream longer than the IHDR declares is refused on the first surplus byte" {
    const a = testing.allocator;
    // 2 x 2 RGB declares 2 * (1 + 6) = 14 bytes; give it 14 + 100.
    const raw = try a.alloc(u8, 14 + 100);
    defer a.free(raw);
    @memset(raw, 0);
    const z = try zlibStored(a, raw);
    defer a.free(z);
    const png = try buildPng(a, &ihdr(2, 2, 8, 2), z, true);
    defer a.free(png);
    const r = decodeMeasured(png);
    try testing.expectEqual(@as(?anyerror, stego.StegoError.InvalidPng), r.err);
    try testing.expect(r.peak < png.len + 4096);
}

// =============================================================================
// The malformed-image matrix (track E, E2), at the Zig API: refused, never a crash
// =============================================================================

test "PNG: IHDR not first, not 13 bytes, duplicated, or absent is refused" {
    const a = testing.allocator;
    const z = try zlibStored(a, &[_]u8{ 0, 1, 2, 3 });
    defer a.free(z);

    // IHDR of 9, 10, 12 and 14 bytes (the spec says exactly 13).
    for ([_]usize{ 9, 10, 12 }) |n| {
        const short = try buildPng(a, (&ihdr(1, 1, 8, 2))[0..n], z, true);
        defer a.free(short);
        try testing.expectError(stego.StegoError.InvalidPng, stego.decodePng(a, short));
    }
    const long14 = try buildPng(a, &(ihdr(1, 1, 8, 2) ++ [_]u8{0}), z, true);
    defer a.free(long14);
    try testing.expectError(stego.StegoError.InvalidPng, stego.decodePng(a, long14));

    // A chunk before IHDR, two IHDRs, no IHDR at all.
    var before: std.ArrayList(u8) = .empty;
    defer before.deinit(a);
    try before.appendSlice(a, &png_sig);
    try chunk(a, &before, "tEXt", "", true);
    try chunk(a, &before, "IHDR", &ihdr(1, 1, 8, 2), true);
    try chunk(a, &before, "IDAT", z, true);
    try chunk(a, &before, "IEND", "", true);
    try testing.expectError(stego.StegoError.InvalidPng, stego.decodePng(a, before.items));

    var twice: std.ArrayList(u8) = .empty;
    defer twice.deinit(a);
    try twice.appendSlice(a, &png_sig);
    try chunk(a, &twice, "IHDR", &ihdr(1, 1, 8, 2), true);
    try chunk(a, &twice, "IHDR", &ihdr(1, 1, 8, 2), true);
    try chunk(a, &twice, "IDAT", z, true);
    try chunk(a, &twice, "IEND", "", true);
    try testing.expectError(stego.StegoError.InvalidPng, stego.decodePng(a, twice.items));

    var none: std.ArrayList(u8) = .empty;
    defer none.deinit(a);
    try none.appendSlice(a, &png_sig);
    try chunk(a, &none, "IDAT", z, true);
    try chunk(a, &none, "IEND", "", true);
    try testing.expectError(stego.StegoError.InvalidPng, stego.decodePng(a, none.items));
}

test "PNG: zero dimensions, empty IDATs, no IDAT, bad signature are refused" {
    const a = testing.allocator;
    const z = try zlibStored(a, &[_]u8{ 0, 1, 2, 3 });
    defer a.free(z);

    const zero_w = try buildPng(a, &ihdr(0, 10, 8, 2), z, true);
    defer a.free(zero_w);
    try testing.expectError(stego.StegoError.InvalidPng, stego.decodePng(a, zero_w));
    const zero_h = try buildPng(a, &ihdr(10, 0, 8, 2), z, true);
    defer a.free(zero_h);
    try testing.expectError(stego.StegoError.InvalidPng, stego.decodePng(a, zero_h));

    var empties: std.ArrayList(u8) = .empty;
    defer empties.deinit(a);
    try empties.appendSlice(a, &png_sig);
    try chunk(a, &empties, "IHDR", &ihdr(1, 1, 8, 2), true);
    try chunk(a, &empties, "IDAT", "", true);
    try chunk(a, &empties, "IDAT", "", true);
    try chunk(a, &empties, "IEND", "", true);
    try testing.expectError(stego.StegoError.PngDecompressError, stego.decodePng(a, empties.items));

    const no_idat = try buildPng(a, &ihdr(1, 1, 8, 2), "", true);
    defer a.free(no_idat);
    try testing.expectError(stego.StegoError.PngDecompressError, stego.decodePng(a, no_idat));

    var bad_sig = try plainPng(a, 4, 128);
    defer a.free(bad_sig);
    bad_sig[0] = 0x88;
    try testing.expectError(stego.StegoError.InvalidPng, stego.decodePng(a, bad_sig));
}

test "PNG: truncation at every offset of a valid file refuses without crashing" {
    const a = testing.allocator;
    const good = try plainPng(a, 16, 128);
    defer a.free(good);
    var img = try stego.decodePng(a, good);
    img.deinit();
    var cut: usize = 0;
    while (cut < good.len) : (cut += 1) {
        if (stego.decodePng(a, good[0..cut])) |decoded| {
            var leaked = decoded;
            leaked.deinit();
            std.debug.print("decoded a file truncated to {d} of {d} bytes\n", .{ cut, good.len });
            return error.TruncatedFileAccepted;
        } else |_| {}
    }
}

test "PNG: a chunk length overrunning the file by one byte or by 2^32-1 is refused" {
    const a = testing.allocator;
    var over = try plainPng(a, 16, 128);
    defer a.free(over);
    std.mem.writeInt(u32, over[8..12], 14, .big); // IHDR claims 14 bytes, file holds 13
    try testing.expectError(stego.StegoError.InvalidPng, stego.decodePng(a, over));
    std.mem.writeInt(u32, over[8..12], 0xffffffff, .big);
    try testing.expectError(stego.StegoError.InvalidPng, stego.decodePng(a, over));
    try testing.expectError(stego.StegoError.InvalidPng, stego.getPngDimensions(over));
}

test "PNG: truncated or corrupt zlib stream (mid-block cut, bad FCHECK, bad CM, wrong NLEN) is refused" {
    const a = testing.allocator;
    const w = 16;
    const raw = try filteredRows(a, w, 3, 0);
    defer a.free(raw);
    const z = try zlibStored(a, raw);
    defer a.free(z);

    const cut = try buildPng(a, &ihdr(w, w, 8, 2), z[0 .. z.len / 2], true);
    defer a.free(cut);
    try testing.expectError(stego.StegoError.PngDecompressError, stego.decodePng(a, cut));

    var hdr_bad = try a.dupe(u8, z);
    defer a.free(hdr_bad);
    hdr_bad[1] = 0x02; // FCHECK wrong
    const hb = try buildPng(a, &ihdr(w, w, 8, 2), hdr_bad, true);
    defer a.free(hb);
    try testing.expectError(stego.StegoError.PngDecompressError, stego.decodePng(a, hb));
    hdr_bad[0] = 0x79; // CM != 8
    hdr_bad[1] = 0x01;
    const hc = try buildPng(a, &ihdr(w, w, 8, 2), hdr_bad, true);
    defer a.free(hc);
    try testing.expectError(stego.StegoError.PngDecompressError, stego.decodePng(a, hc));

    var nlen_bad = try a.dupe(u8, z);
    defer a.free(nlen_bad);
    nlen_bad[5] ^= 0xff;
    const nb = try buildPng(a, &ihdr(w, w, 8, 2), nlen_bad, true);
    defer a.free(nb);
    try testing.expectError(stego.StegoError.PngDecompressError, stego.decodePng(a, nb));
}

// =============================================================================
// E-3: lengths read from the file must never be added to a position (32-bit wrap)
// =============================================================================

test "E-3: a chunk length near 2^32 at a non-zero offset is refused, not wrapped past the end" {
    // On a 32-bit target `pos + 8 + chunk_len + 4` wraps: at pos 33 (after the IHDR)
    // a length of 0xFFFFFFF0 gives 0x100000025 -> 0x25 <= data.len, the old check
    // passed, and the chunk slice ran off the end of the file. The check now compares
    // the length with what remains, which cannot wrap on any target. This test is
    // what the 32-bit build (wasm32 under node's WASI, see the commit) proves.
    const a = testing.allocator;
    const good = try plainPng(a, 4, 128);
    defer a.free(good);
    const idat_pos: usize = 8 + 12 + 13; // after signature and IHDR
    try testing.expectEqualStrings("IDAT", good[idat_pos + 4 ..][0..4]);
    for ([_]u32{ 0xFFFFFFF0, 0xFFFFFFFF, 0xFFFFFFFD, 0x80000000 }) |len| {
        var bad = try a.dupe(u8, good);
        defer a.free(bad);
        std.mem.writeInt(u32, bad[idat_pos..][0..4], len, .big);
        try testing.expectError(stego.StegoError.InvalidPng, stego.decodePng(a, bad));
        // IHDR comes first so dimensions still parse; move the bad length onto IHDR too.
        _ = try stego.getPngDimensions(bad);
        std.mem.writeInt(u32, bad[8..12], len, .big);
        try testing.expectError(stego.StegoError.InvalidPng, stego.getPngDimensions(bad));
        try testing.expectError(stego.StegoError.InvalidPng, stego.decodePng(a, bad));
    }
}

test "E-3: a stego header claiming a payload near 2^32 bytes is refused as corrupted, not wrapped" {
    // The header's data_len is a u32 read out of pixel LSBs; `(HEADER_SIZE + data_len) * 8`
    // wrapped on 32-bit to a small bit count that passed the pixel bound.
    const a = testing.allocator;
    const pixels = try a.alloc(u8, 4096);
    defer a.free(pixels);
    @memset(pixels, 0x80);
    var hdr: [stego.HEADER_SIZE]u8 = .{0} ** stego.HEADER_SIZE;
    @memcpy(hdr[0..4], "ZSSS");
    hdr[4] = 1; // version
    std.mem.writeInt(u32, hdr[5..9], 0xFFFFFFFF, .little);
    // No password, no layer: bit i of the header lands in pixels[i], MSB first.
    for (hdr, 0..) |byte, i| {
        for (0..8) |b| {
            const bit: u8 = (byte >> @intCast(7 - b)) & 1;
            pixels[i * 8 + b] = 0x80 | bit;
        }
    }
    try testing.expectError(stego.StegoError.CorruptedData, stego.extractFromPixels(a, pixels, null));
    // A length that fits the image still reads: 1 byte of payload.
    std.mem.writeInt(u32, hdr[5..9], 1, .little);
    for (hdr[5..9], 5..) |byte, i| {
        for (0..8) |b| {
            const bit: u8 = (byte >> @intCast(7 - b)) & 1;
            pixels[i * 8 + b] = 0x80 | bit;
        }
    }
    const one = try stego.extractFromPixels(a, pixels, null);
    defer a.free(one);
    try testing.expectEqual(@as(usize, 1), one.len);
}
