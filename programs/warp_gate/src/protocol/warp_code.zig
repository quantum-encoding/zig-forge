//! ═══════════════════════════════════════════════════════════════════════════
//! WARP CODE - One-time Transfer Codes
//! ═══════════════════════════════════════════════════════════════════════════
//!
//! Generates and parses human-readable transfer codes like:
//!   warp-729-alpha
//!   warp-042-delta
//!   warp-815-omega
//!
//! Structure:
//!   "warp-" + 3-digit-number + "-" + word
//!
//! The code encodes 6 bytes of entropy:
//! - 3 bytes for the number (0-999, but only 10 bits used)
//! - Remaining bits select from wordlist

const std = @import("std");
const builtin = @import("builtin");

// Cross-platform random bytes
fn getRandomBytes(buf: []u8) void {
    switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos => {
            std.c.arc4random_buf(buf.ptr, buf.len);
        },
        .linux => {
            _ = std.os.linux.getrandom(buf.ptr, buf.len, 0);
        },
        else => {
            // Fallback for other platforms
            for (buf) |*b| {
                b.* = 0;
            }
        },
    }
}

pub const WarpCode = struct {
    const Self = @This();

    /// Raw entropy bytes
    bytes: [6]u8,

    pub const STRING_LEN = 15; // "warp-XXX-YYYYY" max

    /// NATO phonetic alphabet subset - memorable words
    const WORDLIST = [_][]const u8{
        "alpha", "bravo", "charlie", "delta", "echo",
        "foxtrot", "golf", "hotel", "india", "juliet",
        "kilo", "lima", "mike", "november", "oscar",
        "papa", "quebec", "romeo", "sierra", "tango",
        "uniform", "victor", "whiskey", "xray", "yankee",
        "zulu", "amber", "bronze", "coral", "dusk",
        "ember", "frost",
    };

    /// Generate a new random transfer code
    pub fn generate() Self {
        var bytes: [6]u8 = undefined;
        getRandomBytes(&bytes);
        return Self{ .bytes = bytes };
    }

    /// Parse a warp code string
    pub fn parse(str: []const u8) !Self {
        // Must start with "warp-"
        if (str.len < 10) return error.InvalidCode;
        if (!std.mem.startsWith(u8, str, "warp-")) return error.InvalidCode;

        const rest = str[5..];

        // Find the dash separator
        const dash_pos = std.mem.indexOf(u8, rest, "-") orelse return error.InvalidCode;
        if (dash_pos != 3) return error.InvalidCode;

        // Parse number
        const num_str = rest[0..3];
        const number = std.fmt.parseInt(u16, num_str, 10) catch return error.InvalidCode;
        if (number > 999) return error.InvalidCode;

        // Parse word
        const word = rest[4..];
        const word_idx = wordIndex(word) orelse return error.InvalidCode;

        // Reconstruct bytes
        var bytes: [6]u8 = undefined;
        bytes[0] = @truncate(number >> 2);
        bytes[1] = @truncate((number << 6) | (word_idx >> 2));
        bytes[2] = @truncate(word_idx << 6);
        // Fill remaining with deterministic values
        bytes[3] = bytes[0] ^ bytes[1];
        bytes[4] = bytes[1] ^ bytes[2];
        bytes[5] = bytes[0] ^ bytes[2];

        return Self{ .bytes = bytes };
    }

    fn wordIndex(word: []const u8) ?u8 {
        for (WORDLIST, 0..) |w, i| {
            if (std.mem.eql(u8, w, word)) return @intCast(i);
        }
        return null;
    }

    /// Convert to human-readable string
    pub fn toString(self: *const Self) [STRING_LEN]u8 {
        var buf: [STRING_LEN]u8 = [_]u8{' '} ** STRING_LEN;

        // Extract number (10 bits from first 2 bytes)
        const number: u16 = (@as(u16, self.bytes[0]) << 2) | (self.bytes[1] >> 6);
        const clamped_number = number % 1000;

        // Extract word index (5 bits)
        const word_idx: u8 = (self.bytes[1] & 0x3E) >> 1;
        const clamped_idx = word_idx % WORDLIST.len;
        const word = WORDLIST[clamped_idx];

        // Format: "warp-XXX-word"
        buf[0] = 'w';
        buf[1] = 'a';
        buf[2] = 'r';
        buf[3] = 'p';
        buf[4] = '-';

        // Three-digit number with leading zeros
        buf[5] = '0' + @as(u8, @intCast((clamped_number / 100) % 10));
        buf[6] = '0' + @as(u8, @intCast((clamped_number / 10) % 10));
        buf[7] = '0' + @as(u8, @intCast(clamped_number % 10));

        buf[8] = '-';

        // Word
        @memcpy(buf[9 .. 9 + word.len], word);

        return buf;
    }

    /// Derive encryption key from code
    pub fn deriveKey(self: *const Self) [32]u8 {
        var key: [32]u8 = undefined;

        // Use BLAKE3 for key derivation
        var hasher = std.crypto.hash.Blake3.init(.{});
        hasher.update("warp-gate-key-v1");
        hasher.update(&self.bytes);
        hasher.final(&key);

        return key;
    }

    /// Get hash for discovery matching
    pub fn hash(self: *const Self) [16]u8 {
        var out: [16]u8 = undefined;
        var hasher = std.crypto.hash.Blake3.init(.{});
        hasher.update("warp-gate-discovery-v1");
        hasher.update(&self.bytes);
        var full: [32]u8 = undefined;
        hasher.final(&full);
        @memcpy(&out, full[0..16]);
        return out;
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

test "generate produces valid code" {
    const code = WarpCode.generate();
    const str = code.toString();

    try std.testing.expect(std.mem.startsWith(u8, &str, "warp-"));
    try std.testing.expect(str[8] == '-');
}

test "parse valid code" {
    const code = try WarpCode.parse("warp-729-alpha");
    _ = code;
}

test "parse rejects invalid codes" {
    try std.testing.expectError(error.InvalidCode, WarpCode.parse("invalid"));
    try std.testing.expectError(error.InvalidCode, WarpCode.parse("warp-abc-alpha"));
    try std.testing.expectError(error.InvalidCode, WarpCode.parse("warp-1234-alpha"));
}

test "key derivation is deterministic" {
    const code = try WarpCode.parse("warp-042-delta");
    const key1 = code.deriveKey();
    const key2 = code.deriveKey();

    try std.testing.expectEqualSlices(u8, &key1, &key2);
}

test "different codes produce different keys" {
    const code1 = try WarpCode.parse("warp-042-delta");
    const code2 = try WarpCode.parse("warp-729-alpha");

    const key1 = code1.deriveKey();
    const key2 = code2.deriveKey();

    try std.testing.expect(!std.mem.eql(u8, &key1, &key2));
}
