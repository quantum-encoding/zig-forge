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
const lib = @import("lib.zig");

/// The C ABI as a consumer sees it. lib.zig's `export fn`s are not `pub`, so they are
/// reached here exactly as Swift and Rust reach them: by symbol.
const c = struct {
    extern fn zsss_init() void;
    extern fn zsss_free(buf: lib.ZsssBuffer) void;
    extern fn zsss_stego_embed(png: [*]const u8, pl: usize, d: [*]const u8, dl: usize, pw: ?[*]const u8, pwl: usize, layer: i16) lib.ZsssBuffer;
    extern fn zsss_stego_extract(png: [*]const u8, pl: usize, pw: ?[*]const u8, pwl: usize, layer: i16) lib.ZsssBuffer;
};

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
    var out: [13]u8 = @splat(0);
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
    // In bounds, so the CRC is the check that fires: it no longer sits where the length says.
    try testing.expectError(stego.StegoError.PngCrcMismatch, stego.decodePng(a, over));
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
    var hdr: [stego.HEADER_SIZE]u8 = @splat(0);
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

// =============================================================================
// E-4 / E-5: distinct error codes at the C ABI; CRC, Adler-32, bit depth and interlace
// =============================================================================

fn extractCode(png: []const u8, password: ?[]const u8, layer: i16) i32 {
    const pw_ptr: ?[*]const u8 = if (password) |p| p.ptr else null;
    const pw_len: usize = if (password) |p| p.len else 0;
    const r = c.zsss_stego_extract(png.ptr, png.len, pw_ptr, pw_len, layer);
    defer c.zsss_free(r);
    return r.error_code;
}

fn embedCode(png: []const u8, data: []const u8, password: ?[]const u8, layer: i16) i32 {
    const pw_ptr: ?[*]const u8 = if (password) |p| p.ptr else null;
    const pw_len: usize = if (password) |p| p.len else 0;
    const r = c.zsss_stego_embed(png.ptr, png.len, data.ptr, data.len, pw_ptr, pw_len, layer);
    defer c.zsss_free(r);
    return r.error_code;
}

test "E-4: embed/extract round-trip through the C ABI, plain, with password, and on a layer" {
    c.zsss_init();
    const a = testing.allocator;
    // A layer uses every 256th pixel byte, so the layered case needs a 512x512 carrier
    // (786,432 / 256 = 3072 bits for a 448-bit header + payload).
    const png = try plainPng(a, 64, 128);
    defer a.free(png);
    const png512 = try plainPng(a, 512, 128);
    defer a.free(png512);
    const payload = "campaign 2026-10-11";
    const cases = [_]struct { pw: ?[]const u8, layer: i16, carrier: []const u8 }{
        .{ .pw = null, .layer = -1, .carrier = png },
        .{ .pw = "correct horse", .layer = -1, .carrier = png },
        .{ .pw = "correct horse", .layer = 0, .carrier = png512 },
        .{ .pw = null, .layer = 255, .carrier = png512 },
    };
    for (cases) |cs| {
        const pw_ptr: ?[*]const u8 = if (cs.pw) |p| p.ptr else null;
        const pw_len: usize = if (cs.pw) |p| p.len else 0;
        const emb = c.zsss_stego_embed(cs.carrier.ptr, cs.carrier.len, payload, payload.len, pw_ptr, pw_len, cs.layer);
        defer c.zsss_free(emb);
        try testing.expectEqual(lib.ZSSS_OK, emb.error_code);
        const out = c.zsss_stego_extract(emb.data.?, emb.len, pw_ptr, pw_len, cs.layer);
        defer c.zsss_free(out);
        try testing.expectEqual(lib.ZSSS_OK, out.error_code);
        try testing.expectEqualStrings(payload, out.data.?[0..out.len]);
    }
}

test "E-4: each distinct stego failure has its own code at the C ABI" {
    c.zsss_init();
    const a = testing.allocator;
    const good = try plainPng(a, 64, 128);
    defer a.free(good);
    const z = try zlibStored(a, &[_]u8{ 0, 1, 2, 3 });
    defer a.free(z);

    // Not a PNG: bad signature, truncated file, corrupt zlib stream -> INVALID_PNG.
    var bad_sig = try a.dupe(u8, good);
    defer a.free(bad_sig);
    bad_sig[0] = 0x88;
    try testing.expectEqual(lib.ZSSS_ERR_INVALID_PNG, extractCode(bad_sig, null, -1));
    try testing.expectEqual(lib.ZSSS_ERR_INVALID_PNG, embedCode(bad_sig, "x", null, -1));
    try testing.expectEqual(lib.ZSSS_ERR_INVALID_PNG, extractCode(good[0 .. good.len - 5], null, -1));
    const cut = try buildPng(a, &ihdr(64, 64, 8, 2), z, true); // stream far too short
    defer a.free(cut);
    try testing.expectEqual(lib.ZSSS_ERR_INVALID_PNG, extractCode(cut, null, -1));
    try testing.expectEqual(lib.ZSSS_ERR_INVALID_PNG, embedCode(cut, "x", null, -1));

    // Unsupported: 16-bit samples, Adam7 interlace -> PNG_UNSUPPORTED, on both sides.
    const deep = try buildPng(a, &ihdr(64, 64, 16, 2), z, true);
    defer a.free(deep);
    try testing.expectEqual(lib.ZSSS_ERR_PNG_UNSUPPORTED, extractCode(deep, null, -1));
    try testing.expectEqual(lib.ZSSS_ERR_PNG_UNSUPPORTED, embedCode(deep, "x", null, -1));
    const adam7 = try buildPng(a, &ihdrFull(64, 64, 8, 2, 1), z, true);
    defer a.free(adam7);
    try testing.expectEqual(lib.ZSSS_ERR_PNG_UNSUPPORTED, extractCode(adam7, null, -1));
    try testing.expectEqual(lib.ZSSS_ERR_PNG_UNSUPPORTED, embedCode(adam7, "x", null, -1));

    // Too small: 4x4 RGB holds 48 pixel bytes, a header needs 296 -> IMAGE_TOO_SMALL.
    const tiny = try plainPng(a, 4, 128);
    defer a.free(tiny);
    try testing.expectEqual(lib.ZSSS_ERR_IMAGE_TOO_SMALL, extractCode(tiny, null, -1));
    try testing.expectEqual(lib.ZSSS_ERR_IMAGE_TOO_SMALL, embedCode(tiny, "x", null, -1));
    // A 64x64 RGB carrier holds (12288/3*3)/8 - 37 = 1499 bytes; 1500 is one too many.
    const too_much = try a.alloc(u8, 1500);
    defer a.free(too_much);
    @memset(too_much, 'x');
    try testing.expectEqual(lib.ZSSS_ERR_IMAGE_TOO_SMALL, embedCode(good, too_much, null, -1));
    try testing.expectEqual(lib.ZSSS_OK, embedCode(good, too_much[0..1499], null, -1));

    // No hidden data: a clean, valid carrier -> INVALID_MAGIC.
    try testing.expectEqual(lib.ZSSS_ERR_INVALID_MAGIC, extractCode(good, null, -1));
    try testing.expectEqual(lib.ZSSS_ERR_INVALID_MAGIC, extractCode(good, "pw", -1));
    // On a layer the same 64x64 carrier has 48 usable pixel bytes: too small, not "no data".
    try testing.expectEqual(lib.ZSSS_ERR_IMAGE_TOO_SMALL, extractCode(good, "pw", 3));
    const good512 = try plainPng(a, 512, 128);
    defer a.free(good512);
    try testing.expectEqual(lib.ZSSS_ERR_INVALID_MAGIC, extractCode(good512, "pw", 3));

    // Integrity: a flipped chunk CRC, a flipped Adler-32 -> PNG_CRC_MISMATCH.
    var bad_crc = try a.dupe(u8, good);
    defer a.free(bad_crc);
    bad_crc[8 + 8 + 13] ^= 0x01; // IHDR CRC, first byte
    try testing.expectEqual(lib.ZSSS_ERR_PNG_CRC_MISMATCH, extractCode(bad_crc, null, -1));
    try testing.expectEqual(lib.ZSSS_ERR_PNG_CRC_MISMATCH, embedCode(bad_crc, "x", null, -1));
    const raw = try filteredRows(a, 16, 3, 128);
    defer a.free(raw);
    var zz = try zlibStored(a, raw);
    defer a.free(zz);
    zz[zz.len - 1] ^= 0xff; // Adler-32 trailer; the chunk CRC is recomputed by buildPng
    const bad_adler = try buildPng(a, &ihdr(16, 16, 8, 2), zz, true);
    defer a.free(bad_adler);
    try testing.expectEqual(lib.ZSSS_ERR_PNG_CRC_MISMATCH, extractCode(bad_adler, null, -1));
    try testing.expectEqual(lib.ZSSS_ERR_PNG_CRC_MISMATCH, embedCode(bad_adler, "x", null, -1));

    // Over the decode budget -> PNG_TOO_LARGE.
    const huge = try buildPng(a, &ihdr(65536, 65536, 8, 6), z, true);
    defer a.free(huge);
    try testing.expectEqual(lib.ZSSS_ERR_PNG_TOO_LARGE, extractCode(huge, null, -1));
    try testing.expectEqual(lib.ZSSS_ERR_PNG_TOO_LARGE, embedCode(huge, "x", null, -1));

    // Header found but impossible: magic + version 1 + data_len 2^32-1, and magic + version 2
    // -> STEGO_CORRUPTED, not "no hidden data".
    const header_variants = [_]struct { version: u8, len: u32 }{ .{ .version = 1, .len = 0xFFFFFFFF }, .{ .version = 2, .len = 1 } };
    for (header_variants) |hv| {
        var hdr: [stego.HEADER_SIZE]u8 = @splat(0);
        @memcpy(hdr[0..4], "ZSSS");
        hdr[4] = hv.version;
        std.mem.writeInt(u32, hdr[5..9], hv.len, .little);
        // No password, no layer: bit i of the header is pixel byte i. Rows of the
        // 16x16 RGB stream are 1 filter byte + 48 pixel bytes, so map p to row and column.
        var fixed = try filteredRows(a, 16, 3, 0x80);
        defer a.free(fixed);
        for (hdr, 0..) |byte, i| {
            for (0..8) |b| {
                const bit: u8 = (byte >> @intCast(7 - b)) & 1;
                const p = i * 8 + b;
                fixed[(p / 48) * 49 + 1 + (p % 48)] = 0x80 | bit;
            }
        }
        const zc = try zlibStored(a, fixed);
        defer a.free(zc);
        const corrupt = try buildPng(a, &ihdr(16, 16, 8, 2), zc, true);
        defer a.free(corrupt);
        try testing.expectEqual(lib.ZSSS_ERR_STEGO_CORRUPTED, extractCode(corrupt, null, -1));
    }

    // Tampered ciphertext: the header survives, AES-GCM refuses -> DECRYPTION_FAILED.
    const big = try plainPng(a, 128, 128);
    defer a.free(big);
    const secret = try a.alloc(u8, 2000);
    defer a.free(secret);
    @memset(secret, 's');
    const emb = c.zsss_stego_embed(big.ptr, big.len, secret.ptr, secret.len, "pw", 2, -1);
    defer c.zsss_free(emb);
    try testing.expectEqual(lib.ZSSS_OK, emb.error_code);
    var img = try stego.decodePng(a, emb.data.?[0..emb.len]);
    defer img.deinit();
    var saw_decrypt_failed = false;
    var k: usize = 0;
    while (k < 64 and !saw_decrypt_failed) : (k += 1) {
        img.pixels[k] ^= 1;
        const re = try stego.encodePng(a, &img);
        defer a.free(re);
        const code = extractCode(re, "pw", -1);
        img.pixels[k] ^= 1;
        switch (code) {
            lib.ZSSS_ERR_DECRYPTION_FAILED => saw_decrypt_failed = true,
            lib.ZSSS_ERR_INVALID_MAGIC, lib.ZSSS_ERR_STEGO_CORRUPTED, lib.ZSSS_OK => {}, // hit the header, or an unused pixel
            else => return error.UnexpectedCode,
        }
    }
    try testing.expect(saw_decrypt_failed);
}

test "E-5: an external encoder's CRCs and Adler-32 are accepted; each flipped one is refused" {
    // Positive anchor: the CPython-zlib gradient (every CRC and the Adler-32 computed by zlib).
    var img = try stego.decodePng(testing.allocator, png_gradient);
    img.deinit();
    const a = testing.allocator;
    // IHDR CRC, IDAT CRC, IEND CRC: one bit each.
    const ihdr_crc = 8 + 8 + 13;
    const idat_len = std.mem.readInt(u32, png_gradient[33..37], .big);
    const idat_crc = 33 + 8 + idat_len;
    const iend_crc = idat_crc + 4 + 8;
    try testing.expectEqual(png_gradient.len, iend_crc + 4);
    for ([_]usize{ ihdr_crc, idat_crc, iend_crc }) |off| {
        var bad = try a.dupe(u8, png_gradient);
        defer a.free(bad);
        bad[off + 3] ^= 0x80;
        try testing.expectError(stego.StegoError.PngCrcMismatch, stego.decodePng(a, bad));
    }
    // Adler-32 alone (the chunk CRC re-sealed over the damaged trailer).
    var bad_adler = try a.dupe(u8, png_gradient);
    defer a.free(bad_adler);
    bad_adler[idat_crc - 1] ^= 0x01;
    std.mem.writeInt(u32, bad_adler[idat_crc..][0..4], std.hash.Crc32.hash(bad_adler[33 + 4 .. idat_crc]), .big);
    try testing.expectError(stego.StegoError.PngCrcMismatch, stego.decodePng(a, bad_adler));
}

test "E-5: 16-bit, interlaced and indexed carriers are refused on embed instead of re-encoded as garbage" {
    const a = testing.allocator;
    // 8x8, 16-bit RGB: 8 rows of 1 + 8*6 bytes. Refused on the IHDR, so the stream is never read.
    const raw16 = try a.alloc(u8, 8 * (1 + 8 * 6));
    defer a.free(raw16);
    @memset(raw16, 0);
    const z16 = try zlibStored(a, raw16);
    defer a.free(z16);
    const deep = try buildPng(a, &ihdr(8, 8, 16, 2), z16, true);
    defer a.free(deep);
    try testing.expectError(stego.StegoError.UnsupportedPng, stego.embedInPng(a, deep, "x", null));
    try testing.expectError(stego.StegoError.UnsupportedPng, stego.decodePng(a, deep));

    const raw8 = try filteredRows(a, 16, 3, 0);
    defer a.free(raw8);
    const z8 = try zlibStored(a, raw8);
    defer a.free(z8);
    const adam7 = try buildPng(a, &ihdrFull(16, 16, 8, 2, 1), z8, true);
    defer a.free(adam7);
    try testing.expectError(stego.StegoError.UnsupportedPng, stego.embedInPng(a, adam7, "x", null));
    const bad_interlace = try buildPng(a, &ihdrFull(16, 16, 8, 2, 2), z8, true);
    defer a.free(bad_interlace);
    try testing.expectError(stego.StegoError.InvalidPng, stego.decodePng(a, bad_interlace));

    // Indexed (colour type 3): decodes (one byte per pixel) but cannot carry data, since
    // encodePng would drop its PLTE.
    const rawi = try filteredRows(a, 32, 1, 7);
    defer a.free(rawi);
    const zi = try zlibStored(a, rawi);
    defer a.free(zi);
    const indexed = try buildPng(a, &ihdr(32, 32, 8, 3), zi, true);
    defer a.free(indexed);
    var img = try stego.decodePng(a, indexed);
    defer img.deinit();
    try testing.expectEqual(@as(usize, 32 * 32), img.pixels.len);
    try testing.expectError(stego.StegoError.UnsupportedPng, stego.embedInPng(a, indexed, "x", null));

    // Colour type 7 does not exist; compression or filter method 1 are undefined.
    const ct7 = try buildPng(a, &ihdr(16, 16, 8, 7), z8, true);
    defer a.free(ct7);
    try testing.expectError(stego.StegoError.UnsupportedPng, stego.decodePng(a, ct7));
    var h = ihdr(16, 16, 8, 2);
    h[10] = 1;
    const comp1 = try buildPng(a, &h, z8, true);
    defer a.free(comp1);
    try testing.expectError(stego.StegoError.InvalidPng, stego.decodePng(a, comp1));
    h[10] = 0;
    h[11] = 1;
    const filt1 = try buildPng(a, &h, z8, true);
    defer a.free(filt1);
    try testing.expectError(stego.StegoError.InvalidPng, stego.decodePng(a, filt1));
    // A scanline filter type outside 0..4 (PNG 1.2 §6.2).
    var raw_f5 = try filteredRows(a, 16, 3, 0);
    defer a.free(raw_f5);
    raw_f5[0] = 5;
    const zf5 = try zlibStored(a, raw_f5);
    defer a.free(zf5);
    const f5 = try buildPng(a, &ihdr(16, 16, 8, 2), zf5, true);
    defer a.free(f5);
    try testing.expectError(stego.StegoError.InvalidPng, stego.decodePng(a, f5));
}
