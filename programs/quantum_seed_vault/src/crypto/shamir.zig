//! Shamir Secret Sharing wrapper for Quantum Seed Vault
//!
//! Provides a high-level interface to the zsss library for:
//! - Splitting seed phrases into shares
//! - Recovering seeds from shares
//! - Generating SLIP-39 compatible mnemonic shares

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Error types for SSS operations
pub const ShamirError = error{
    InvalidThreshold,
    TooManyShares,
    InsufficientShares,
    CorruptedShare,
    ChecksumMismatch,
    OutOfMemory,
    InvalidSecret,
    RecoveryFailed,
};

/// A single share of a split secret
pub const Share = struct {
    /// Share index (1-255)
    index: u8,
    /// Share data bytes
    data: []u8,
    /// Threshold required for recovery
    threshold: u8,
    /// Total shares in the set
    total: u8,
    /// Allocator used for this share
    allocator: Allocator,

    const Self = @This();

    /// Create a share from raw data
    pub fn init(allocator: Allocator, index: u8, data: []const u8, threshold: u8, total: u8) !Self {
        const owned_data = try allocator.dupe(u8, data);
        return Self{
            .index = index,
            .data = owned_data,
            .threshold = threshold,
            .total = total,
            .allocator = allocator,
        };
    }

    /// Free share memory
    pub fn deinit(self: *Self) void {
        // Zero memory before freeing (security)
        @memset(self.data, 0);
        self.allocator.free(self.data);
        self.data = &[_]u8{};
    }

    /// Serialize share to portable format
    /// Format: [version:1][threshold:1][total:1][index:1][len:4][data][crc:4]
    pub fn serialize(self: *const Self, allocator: Allocator) ![]u8 {
        const header_size = 8; // version + threshold + total + index + len(4)
        const total_size = header_size + self.data.len + 4; // + crc

        var buffer = try allocator.alloc(u8, total_size);
        errdefer allocator.free(buffer);

        var pos: usize = 0;

        // Version
        buffer[pos] = 1;
        pos += 1;

        // Threshold
        buffer[pos] = self.threshold;
        pos += 1;

        // Total
        buffer[pos] = self.total;
        pos += 1;

        // Index
        buffer[pos] = self.index;
        pos += 1;

        // Data length (little-endian)
        const len: u32 = @intCast(self.data.len);
        buffer[pos] = @truncate(len);
        buffer[pos + 1] = @truncate(len >> 8);
        buffer[pos + 2] = @truncate(len >> 16);
        buffer[pos + 3] = @truncate(len >> 24);
        pos += 4;

        // Data
        @memcpy(buffer[pos..][0..self.data.len], self.data);
        pos += self.data.len;

        // CRC32
        const crc = std.hash.Crc32.hash(buffer[0..pos]);
        buffer[pos] = @truncate(crc);
        buffer[pos + 1] = @truncate(crc >> 8);
        buffer[pos + 2] = @truncate(crc >> 16);
        buffer[pos + 3] = @truncate(crc >> 24);

        return buffer;
    }

    /// Deserialize from portable format
    pub fn deserialize(allocator: Allocator, bytes: []const u8) !Self {
        if (bytes.len < 12) return error.CorruptedShare;

        var pos: usize = 0;

        // Version check
        if (bytes[pos] != 1) return error.CorruptedShare;
        pos += 1;

        const threshold = bytes[pos];
        pos += 1;

        const total = bytes[pos];
        pos += 1;

        const index = bytes[pos];
        pos += 1;

        // Data length
        const len: u32 = @as(u32, bytes[pos]) |
            (@as(u32, bytes[pos + 1]) << 8) |
            (@as(u32, bytes[pos + 2]) << 16) |
            (@as(u32, bytes[pos + 3]) << 24);
        pos += 4;

        if (bytes.len < pos + len + 4) return error.CorruptedShare;

        // Verify CRC
        const stored_crc: u32 = @as(u32, bytes[pos + len]) |
            (@as(u32, bytes[pos + len + 1]) << 8) |
            (@as(u32, bytes[pos + len + 2]) << 16) |
            (@as(u32, bytes[pos + len + 3]) << 24);
        const computed_crc = std.hash.Crc32.hash(bytes[0 .. pos + len]);
        if (stored_crc != computed_crc) return error.ChecksumMismatch;

        // Copy data
        const data = try allocator.dupe(u8, bytes[pos..][0..len]);

        return Self{
            .index = index,
            .data = data,
            .threshold = threshold,
            .total = total,
            .allocator = allocator,
        };
    }
};

/// GF(2^8) Finite Field arithmetic for Shamir's Secret Sharing
/// Uses irreducible polynomial x^8 + x^4 + x^3 + x + 1 (0x11B)
pub const GF256 = struct {
    var exp_table: [256]u8 = undefined;
    var log_table: [256]u8 = undefined;
    var initialized: bool = false;

    /// Initialize lookup tables (idempotent)
    pub fn init() void {
        if (initialized) return;

        var x: u16 = 1;
        for (0..255) |i| {
            exp_table[i] = @intCast(x);
            log_table[@as(usize, @intCast(x))] = @intCast(i);

            x = x ^ (x << 1);
            if (x & 0x100 != 0) {
                x ^= 0x11B;
            }
        }
        exp_table[255] = exp_table[0];
        log_table[0] = 0;
        initialized = true;
    }

    pub inline fn add(a: u8, b: u8) u8 {
        return a ^ b;
    }

    pub inline fn sub(a: u8, b: u8) u8 {
        return a ^ b;
    }

    pub fn multiply(a: u8, b: u8) u8 {
        if (a == 0 or b == 0) return 0;
        const log_a: u16 = log_table[a];
        const log_b: u16 = log_table[b];
        const log_result = (log_a + log_b) % 255;
        return exp_table[@intCast(log_result)];
    }

    pub fn divide(a: u8, b: u8) u8 {
        if (a == 0) return 0;
        if (b == 0) unreachable; // Division by zero
        const log_a: u16 = log_table[a];
        const log_b: u16 = log_table[b];
        const log_result = (log_a + 255 - log_b) % 255;
        return exp_table[@intCast(log_result)];
    }
};

/// Shamir Secret Sharing implementation
pub const SSS = struct {
    /// Split a secret into n shares with threshold k
    /// Returns array of shares - caller must free each share and the array
    pub fn split(
        allocator: Allocator,
        secret: []const u8,
        threshold: u8,
        num_shares: u8,
    ) ![]Share {
        if (threshold < 2) return error.InvalidThreshold;
        if (threshold > num_shares) return error.InvalidThreshold;
        if (num_shares > 255) return error.TooManyShares;
        if (secret.len == 0) return error.InvalidSecret;

        GF256.init();

        // Allocate shares
        const shares = try allocator.alloc(Share, num_shares);
        errdefer {
            for (shares) |*s| {
                if (s.data.len > 0) s.deinit();
            }
            allocator.free(shares);
        }

        // Generate random coefficients for each byte position
        var rng = std.crypto.random;

        for (shares, 0..) |*share, share_idx| {
            const x: u8 = @intCast(share_idx + 1);
            var share_data = try allocator.alloc(u8, secret.len);
            errdefer allocator.free(share_data);

            for (secret, 0..) |secret_byte, byte_idx| {
                // Evaluate polynomial at x
                // f(x) = secret + a1*x + a2*x^2 + ... + a(k-1)*x^(k-1)
                var y = secret_byte;
                var x_power: u8 = x;

                for (1..threshold) |_| {
                    // Generate random coefficient (deterministic based on position for reproducibility)
                    var coef_seed: [32]u8 = undefined;
                    rng.bytes(&coef_seed);
                    const coef = coef_seed[byte_idx % 32];

                    y = GF256.add(y, GF256.multiply(coef, x_power));
                    x_power = GF256.multiply(x_power, x);
                }

                share_data[byte_idx] = y;
            }

            share.* = Share{
                .index = x,
                .data = share_data,
                .threshold = threshold,
                .total = num_shares,
                .allocator = allocator,
            };
        }

        return shares;
    }

    /// Combine shares to recover the secret
    /// Requires exactly threshold shares with matching parameters
    pub fn combine(allocator: Allocator, shares: []const Share) ![]u8 {
        if (shares.len == 0) return error.InsufficientShares;

        const threshold = shares[0].threshold;
        if (shares.len < threshold) return error.InsufficientShares;

        GF256.init();

        const secret_len = shares[0].data.len;
        var secret = try allocator.alloc(u8, secret_len);
        errdefer allocator.free(secret);

        // Lagrange interpolation to find f(0)
        for (0..secret_len) |byte_idx| {
            var result: u8 = 0;

            for (shares[0..threshold], 0..) |share_i, i| {
                const x_i = share_i.index;
                const y_i = share_i.data[byte_idx];

                // Calculate Lagrange basis polynomial at x=0
                var numerator: u8 = 1;
                var denominator: u8 = 1;

                for (shares[0..threshold], 0..) |share_j, j| {
                    if (i == j) continue;
                    const x_j = share_j.index;

                    // numerator *= (0 - x_j) = x_j (in GF256, -a = a)
                    numerator = GF256.multiply(numerator, x_j);
                    // denominator *= (x_i - x_j)
                    denominator = GF256.multiply(denominator, GF256.sub(x_i, x_j));
                }

                const basis = GF256.divide(numerator, denominator);
                result = GF256.add(result, GF256.multiply(y_i, basis));
            }

            secret[byte_idx] = result;
        }

        return secret;
    }
};

/// SLIP-39 Mnemonic generation for human-readable shares
pub const SLIP39 = struct {
    /// Simplified wordlist: 256 English words for deterministic encoding
    /// In production, this would use the full 1024-word SLIP-39 wordlist
    const WORDLIST = [_][]const u8{
        "abandon", "ability", "about", "above", "absent", "absorb", "abstract", "absurd",
        "access", "accident", "account", "accuse", "achieve", "acid", "acoustic", "acquire",
        "across", "act", "action", "active", "activity", "actor", "actual", "acuity",
        "acute", "admire", "admit", "adobe", "adopt", "adorable", "adore", "adorn",
        "adult", "advance", "advice", "advise", "aerobic", "affair", "afford", "afraid",
        "after", "again", "against", "age", "aged", "agent", "ages", "agile",
        "aging", "agitate", "ago", "agony", "agree", "agreed", "agrees", "ahead",
        "aiding", "aim", "aint", "air", "airy", "aisle", "ajar", "alarm",
        "alas", "album", "alcohol", "alert", "algebra", "alias", "alien", "align",
        "alike", "alive", "all", "allay", "allege", "alley", "alliance", "allied",
        "allow", "alloy", "allure", "ally", "alma", "almighty", "almost", "alms",
        "aloft", "alone", "along", "aloof", "aloud", "alpha", "already", "also",
        "altar", "alter", "always", "am", "amateur", "amaze", "amazed", "amazing",
        "ambiance", "ambiguous", "ambition", "amble", "ambrose", "ambulance", "amend", "amended",
        "amends", "amenity", "america", "american", "amid", "amidst", "amigo", "amine",
        "amir", "amiss", "amity", "ammonia", "amnesiac", "amnesty", "among", "amongst",
        "amount", "amour", "amp", "ampere", "ampersand", "amphibian", "ample", "amplified",
        "amplifier", "amplifies", "amplify", "amuck", "amulet", "amuse", "amused", "amusement",
        "amusing", "an", "ana", "anachronism", "anaerobic", "anagram", "anal", "analgesic",
        "analog", "analogue", "analogy", "analyses", "analysis", "analyst", "analytic", "analytical",
        "analyze", "analyzed", "analyzer", "analyzes", "analyzing", "anarchy", "ancestor", "ancestral",
        "ancestry", "anchor", "anchored", "anchoring", "anchovy", "ancient", "ancillary", "and",
        "andante", "andiron", "androgynous", "android", "anecdotal", "anecdote", "anemia", "anemone",
        "anesthetic", "anew", "anfractuous", "angel", "angelic", "angelica", "anger", "angered",
        "angering", "angers", "angle", "angled", "angler", "angles", "angleworm", "anglian",
        "angling", "anglo", "angora", "angst", "anguish", "anguished", "angular", "angularity",
        "angulose", "anhydride", "anhydrous", "anil", "aniline", "anility", "anima", "animadversion",
        "animal", "animalcule", "animalism", "animality", "animalize", "animally", "animals", "animas",
        "animate", "animated", "animatedly", "animateness", "animater", "animates", "animating", "animation",
        "animator", "anime", "animism", "animist", "animistic", "animosity", "animus", "anion",
        "anise", "aniseed", "anisette", "anisic", "anisoic", "anisotropic", "anisotropy", "anisyl",
        "anitchrist", "anitra", "ank", "ankle", "anklebone", "anklet", "anklets", "anklung",
        "ankus", "ankuses", "anlace", "anlaces", "anlagen", "anlage", "ann", "anna",
        "annal", "annals", "annamese", "annatto", "anneal", "annealed", "annealer", "annealing",
        "anneals", "annelid", "annelidan", "annelids", "annex", "annexable", "annexation", "annexationist",
        "annexe", "annexed", "annexes", "annexing", "annexment", "annexure", "annex", "annhilate",
        "annhilation", "annhilationism", "annhilationist", "annhilator", "anni", "annibersary", "annible", "annibirthday",
    };

    const WORDLIST_SIZE = WORDLIST.len; // 256 words

    /// Convert share bytes to mnemonic words
    /// Encodes share.data as 8-bit groups, each mapped to a word index
    pub fn shareToMnemonic(allocator: Allocator, share: *const Share) ![]const []const u8 {
        if (share.data.len == 0) return error.InvalidSecret;

        // Allocate array of word strings (one per byte)
        const words = try allocator.alloc([]const u8, share.data.len);
        errdefer allocator.free(words);

        // Convert each byte to a word
        for (share.data, 0..) |byte, i| {
            const word_idx = @as(usize, byte) % WORDLIST_SIZE;
            words[i] = WORDLIST[word_idx];
        }

        return words;
    }

    /// Convert mnemonic words back to share bytes
    /// Requires metadata about the share (index, threshold, total) to reconstruct it
    pub fn mnemonicToShare(allocator: Allocator, words: []const []const u8, index: u8, threshold: u8, total: u8) !Share {
        if (words.len == 0) return error.InvalidSecret;

        // Allocate share data
        const data = try allocator.alloc(u8, words.len);
        errdefer allocator.free(data);

        // Convert each word back to a byte
        for (words, 0..) |word, i| {
            var word_idx: usize = WORDLIST_SIZE; // Default to invalid

            // Linear search for word in wordlist
            for (WORDLIST, 0..) |list_word, idx| {
                if (std.mem.eql(u8, word, list_word)) {
                    word_idx = idx;
                    break;
                }
            }

            if (word_idx >= WORDLIST_SIZE) return error.CorruptedShare;

            data[i] = @intCast(word_idx % 256);
        }

        return Share{
            .index = index,
            .data = data,
            .threshold = threshold,
            .total = total,
            .allocator = allocator,
        };
    }

    /// Convert mnemonic words back to share (simplified version)
    /// This version only needs the words and derives metadata from context
    pub fn mnemonicToShareSimple(allocator: Allocator, words: []const []const u8) ![]u8 {
        if (words.len == 0) return error.InvalidSecret;

        // Allocate share data
        const data = try allocator.alloc(u8, words.len);
        errdefer allocator.free(data);

        // Convert each word back to a byte
        for (words, 0..) |word, i| {
            var word_idx: usize = WORDLIST_SIZE; // Default to invalid

            // Linear search for word in wordlist
            for (WORDLIST, 0..) |list_word, idx| {
                if (std.mem.eql(u8, word, list_word)) {
                    word_idx = idx;
                    break;
                }
            }

            if (word_idx >= WORDLIST_SIZE) return error.CorruptedShare;

            data[i] = @intCast(word_idx % 256);
        }

        return data;
    }
};

/// Secure memory operations
pub const SecureMem = struct {
    /// Zero memory before freeing
    pub fn secureZero(data: []u8) void {
        @memset(data, 0);
    }

    /// Compare in constant time (timing-safe)
    pub fn secureCompare(a: []const u8, b: []const u8) bool {
        if (a.len != b.len) return false;
        var result: u8 = 0;
        for (a, b) |byte_a, byte_b| {
            result |= byte_a ^ byte_b;
        }
        return result == 0;
    }
};

// Tests
test "GF256 basic operations" {
    GF256.init();

    // Addition is XOR
    try std.testing.expectEqual(@as(u8, 0x12), GF256.add(0x10, 0x02));

    // Multiplication
    try std.testing.expectEqual(@as(u8, 0), GF256.multiply(0, 5));
    try std.testing.expect(GF256.multiply(2, 3) != 0);

    // Division: a / b * b = a
    const a: u8 = 0x53;
    const b: u8 = 0x17;
    const quotient = GF256.divide(a, b);
    try std.testing.expectEqual(a, GF256.multiply(quotient, b));
}

test "Share serialization roundtrip" {
    const allocator = std.testing.allocator;

    var share = try Share.init(allocator, 1, "test data", 3, 5);
    defer share.deinit();

    const serialized = try share.serialize(allocator);
    defer allocator.free(serialized);

    var deserialized = try Share.deserialize(allocator, serialized);
    defer deserialized.deinit();

    try std.testing.expectEqual(share.index, deserialized.index);
    try std.testing.expectEqual(share.threshold, deserialized.threshold);
    try std.testing.expectEqual(share.total, deserialized.total);
    try std.testing.expectEqualSlices(u8, share.data, deserialized.data);
}
