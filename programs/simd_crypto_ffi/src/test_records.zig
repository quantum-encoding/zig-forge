//! Reader for the vector files under testdata/ (test-only).
//!
//! Two textual formats, both "records separated by blank lines":
//!   * this repo's extracts: `key=value` lines, `#` comments;
//!   * NIST CAVP `.rsp` files, copied verbatim: `Key = Value` lines, CRLF endings, `#` comments
//!     and `[L=32]`-style section headers, which apply to every record after them.
//! The reader only splits text; it computes nothing.

const std = @import("std");

pub const Record = struct {
    lines: []const u8,
    /// The most recent `[...]` header before this record (`.rsp` files), without brackets.
    section: []const u8,

    pub fn get(self: Record, key: []const u8) ?[]const u8 {
        var it = std.mem.splitScalar(u8, self.lines, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            if (std.mem.eql(u8, std.mem.trim(u8, line[0..eq], " "), key))
                return std.mem.trim(u8, line[eq + 1 ..], " ");
        }
        return null;
    }

    pub fn str(self: Record, key: []const u8) []const u8 {
        return self.get(key) orelse std.debug.panic("record lacks key '{s}':\n{s}", .{ key, self.lines });
    }

    pub fn int(self: Record, comptime T: type, key: []const u8) T {
        return std.fmt.parseInt(T, self.str(key), 10) catch std.debug.panic("bad integer '{s}'", .{self.str(key)});
    }

    pub fn fixed(self: Record, comptime n: usize, key: []const u8) ![n]u8 {
        const h = self.str(key);
        if (h.len != 2 * n) return error.WrongVectorLength;
        var out: [n]u8 = undefined;
        _ = try std.fmt.hexToBytes(&out, h);
        return out;
    }

    /// Decode a hex field of any length; caller frees.
    pub fn bytes(self: Record, a: std.mem.Allocator, key: []const u8) ![]u8 {
        const h = self.str(key);
        if (h.len % 2 != 0) return error.OddHexLength;
        const out = try a.alloc(u8, h.len / 2);
        errdefer a.free(out);
        _ = try std.fmt.hexToBytes(out, h);
        return out;
    }
};

pub const Iterator = struct {
    text: []const u8,
    pos: usize = 0,
    section: []const u8 = "",

    pub fn next(self: *Iterator) ?Record {
        while (self.pos < self.text.len) {
            const end = std.mem.indexOfScalarPos(u8, self.text, self.pos, '\n') orelse self.text.len;
            const line = std.mem.trimEnd(u8, self.text[self.pos..end], "\r");
            if (line.len != 0 and line[0] != '#' and line[0] != '[') break;
            if (line.len > 1 and line[0] == '[') self.section = std.mem.trim(u8, line[1 .. line.len - 1], " ");
            self.pos = @min(end + 1, self.text.len);
        }
        if (self.pos >= self.text.len) return null;
        const start = self.pos;
        // A record ends at the first empty (or CR-only) line.
        var p = start;
        while (p < self.text.len) {
            const end = std.mem.indexOfScalarPos(u8, self.text, p, '\n') orelse self.text.len;
            if (std.mem.trimEnd(u8, self.text[p..end], "\r").len == 0) break;
            p = @min(end + 1, self.text.len);
        }
        self.pos = p;
        return .{ .lines = self.text[start..p], .section = self.section };
    }
};

pub fn iterate(text: []const u8) Iterator {
    return .{ .text = text };
}

/// SplitMix64 input expansion, identical to `expand` in tools/crypto-refgen/src/main.rs: the
/// differential corpus stores seeds, and both sides regenerate the same input bytes.
pub fn expand(a: std.mem.Allocator, seed: u64, len: usize) ![]u8 {
    const out = try a.alloc(u8, len);
    var state = seed;
    var i: usize = 0;
    while (i < len) : (i += 8) {
        state +%= 0x9E3779B97F4A7C15;
        var z = state;
        z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
        z ^= z >> 31;
        const le = std.mem.toBytes(std.mem.nativeToLittle(u64, z));
        const n = @min(8, len - i);
        @memcpy(out[i .. i + n], le[0..n]);
    }
    return out;
}

pub fn expandFixed(comptime n: usize, seed: u64) [n]u8 {
    var buf: [n]u8 = undefined;
    var state = seed;
    var i: usize = 0;
    while (i < n) : (i += 8) {
        state +%= 0x9E3779B97F4A7C15;
        var z = state;
        z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
        z ^= z >> 31;
        const le = std.mem.toBytes(std.mem.nativeToLittle(u64, z));
        const m = @min(8, n - i);
        @memcpy(buf[i .. i + m], le[0..m]);
    }
    return buf;
}

/// Base58Check decode (test-only, to compare against published xprv/xpub strings). Returns the
/// payload including its 4-byte checksum; the caller compares all of it, so the checksum is
/// checked by comparison rather than recomputed here.
pub fn base58Decode(out: []u8, s: []const u8) ![]u8 {
    const alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
    @memset(out, 0);
    var len: usize = 0; // significant bytes, stored big-endian at the end of `out`
    for (s) |c| {
        var carry: u32 = @intCast(std.mem.indexOfScalar(u8, alphabet, c) orelse return error.InvalidBase58);
        var i: usize = 0;
        while (i < len or carry != 0) : (i += 1) {
            if (i >= out.len) return error.Overflow;
            const idx = out.len - 1 - i;
            carry += @as(u32, out[idx]) * 58;
            out[idx] = @truncate(carry);
            carry >>= 8;
        }
        len = i;
    }
    var zeros: usize = 0;
    while (zeros < s.len and s[zeros] == '1') zeros += 1;
    const total = len + zeros;
    return out[out.len - total ..];
}
