//! SLIP-0039: Shamir's Secret-Sharing for Mnemonic Codes
//!
//! A complete, interoperable implementation of SLIP-0039: the two-level
//! (groups-of-groups) secret sharing scheme, the passphrase-keyed Feistel
//! encryption of the master secret, the RS1024-checksummed mnemonic encoding
//! and the 1024-word wordlist.
//!
//! The archived specification this file implements is in `docs/slip-0039.md`
//! (fetched from the satoshilabs/slips repository). Section names cited in
//! comments below refer to that document. The official test vectors are
//! archived in `tests/slip-0039-vectors.json` and exercised by
//! `src/slip39_vectors_test.zig`.
//!
//! Constant-time discipline (what is and is not achieved):
//!   * GF(256) arithmetic (`gfMul`, `gfInv`, `gfDiv`) is branchless and
//!     table-free, so no secret byte is used as a memory index or as a branch
//!     condition. This is a deliberate divergence from the log/exp-table
//!     approach used by the reference implementation and by `main.GF256`,
//!     both of which index a table with secret data (a cache-timing signal).
//!   * The Feistel round function is PBKDF2-HMAC-SHA256 from std.crypto,
//!     whose SHA-256 core is constant-time.
//!   * NOT constant-time, by nature of the format: mnemonic word lookup
//!     (binary search over the public wordlist), share/group bookkeeping in
//!     `combineShares` (branches on share *metadata*, which is public — it is
//!     written in the clear in the mnemonic), and the digest comparison, which
//!     uses a constant-time compare but whose *outcome* is necessarily
//!     observable as an error.
//!   * Secret material (master secret, EMS, group shares, round-function
//!     output, PBKDF2 password/salt scratch) is zeroized with
//!     `std.crypto.secureZero` before being freed.

const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const Allocator = mem.Allocator;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

// =============================================================================
// Constants (spec: "Format of the share mnemonic", "Design rationale")
// =============================================================================

/// Bits per word: the wordlist has exactly 1024 = 2^10 entries.
pub const BITS_PER_WORD = 10;

/// The RS1024 checksum occupies the last three words of every mnemonic.
pub const CHECKSUM_WORDS = 3;

/// Words holding `id || ext || e` (15 + 1 + 4 = 20 bits).
pub const ID_EXP_WORDS = 2;

/// Words holding `GI || Gt || g || I || t` (5 x 4 = 20 bits).
pub const SHARE_PARAMS_WORDS = 2;

/// Words of a mnemonic that are not part of the padded share value.
pub const METADATA_WORDS = ID_EXP_WORDS + SHARE_PARAMS_WORDS + CHECKSUM_WORDS;

/// Minimum mnemonic length: metadata plus a 128-bit share value (13 words).
pub const MIN_MNEMONIC_WORDS = METADATA_WORDS + 13;

/// Group and member indices/thresholds are 4-bit fields, so at most 16 of each.
pub const MAX_SHARE_COUNT = 16;

/// Length in bytes of the digest stored in the share at index `DIGEST_INDEX`.
pub const DIGEST_LENGTH_BYTES = 4;

/// The master secret must carry at least this much entropy (spec: "Digest").
pub const MIN_STRENGTH_BITS = 128;

/// Total PBKDF2 iterations at iteration exponent 0 (spec: "Choice of KDF").
pub const BASE_ITERATION_COUNT = 10000;

/// Rounds in the Feistel network (spec: "Encryption of the master secret").
pub const ROUND_COUNT = 4;

/// f(255) carries the shared secret (spec: "Index encoding").
pub const SECRET_INDEX = 255;

/// f(254) carries the digest of the shared secret (spec: "Digest").
pub const DIGEST_INDEX = 254;

/// RS1024 customization string for shares with ext = 0. Doubles as the PBKDF2
/// salt prefix in that case (spec: "Encryption of the master secret").
pub const CUSTOMIZATION_STRING_ORIG = "shamir";

/// RS1024 customization string for shares with ext = 1.
pub const CUSTOMIZATION_STRING_EXTENDABLE = "shamir_extendable";

pub const Error = error{
    /// The mnemonic contains a word that is not in the SLIP-39 wordlist.
    UnknownWord,
    /// Fewer than MIN_MNEMONIC_WORDS words.
    MnemonicTooShort,
    /// The RS1024 checksum does not verify.
    InvalidChecksum,
    /// The padded share value length mod 16 exceeds 8 bits, or a padding bit
    /// is not zero.
    InvalidPadding,
    /// A single share declares a group threshold greater than its group count.
    GroupThresholdExceedsCount,
    /// Shares disagree on id / ext / e / group threshold / group count.
    MismatchedShareParameters,
    /// Shares in one group disagree on the member threshold.
    MismatchedMemberThreshold,
    /// Two shares in a group carry the same member index.
    DuplicateMemberIndex,
    /// Two group shares carry the same group index.
    DuplicateGroupIndex,
    /// The number of distinct groups supplied is not exactly the group threshold.
    WrongNumberOfGroups,
    /// A group has a number of shares other than its member threshold.
    WrongNumberOfShares,
    /// Share values differ in length.
    InvalidShareValueLength,
    /// f(254) does not match HMAC-SHA256(key=R, msg=S) — the share set is
    /// inconsistent or fabricated.
    InvalidDigest,
    /// No mnemonics / no shares supplied.
    EmptyShareSet,
    /// Master secret shorter than 128 bits or not a whole number of 16-bit units.
    InvalidMasterSecretLength,
    /// Threshold is zero, exceeds the share count, or the share count exceeds 16.
    InvalidThreshold,
    /// A group requests threshold 1 with more than one member (spec: step 1 of
    /// GenerateShares).
    ThresholdOneWithMultipleMembers,
    /// The group threshold exceeds the number of groups, or there are no groups
    /// / more than 16 groups.
    InvalidGroupConfiguration,
    /// The passphrase contains a byte outside printable ASCII (32-126).
    InvalidPassphrase,
    /// The OS CSPRNG could not supply entropy.
    RandomFailure,
};

// =============================================================================
// GF(256) arithmetic (spec: "Shamir's secret-sharing", "Choice of finite field")
// =============================================================================
//
// Bytes are elements of GF(2^8) modulo the Rijndael polynomial
// x^8 + x^4 + x^3 + x + 1 (0x11B), per AES/FIPS-197 sections 3.2, 4.1, 4.2.
//
// These routines are branchless and table-free: the value of a secret byte
// never selects a branch target or a memory address.

/// Multiplication in GF(256). Constant-time: fixed 8 iterations, arithmetic
/// masks instead of conditionals.
pub fn gfMul(a: u8, b: u8) u8 {
    var product: u8 = 0;
    var x: u8 = a;
    var y: u8 = b;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        // 0xFF when the low bit of y is set, 0x00 otherwise.
        const add_mask: u8 = @as(u8, 0) -% (y & 1);
        product ^= x & add_mask;
        // 0xFF when x is about to overflow degree 7, 0x00 otherwise.
        const reduce_mask: u8 = @as(u8, 0) -% (x >> 7);
        x = (x << 1) ^ (0x1B & reduce_mask);
        y >>= 1;
    }
    return product;
}

/// Multiplicative inverse in GF(256), computed as a^254 by square-and-multiply
/// over a fixed exponent, so the instruction trace does not depend on `a`.
/// gfInv(0) is defined as 0; callers must reject a zero divisor themselves.
pub fn gfInv(a: u8) u8 {
    // 254 = 2 + 4 + 8 + 16 + 32 + 64 + 128, so a^254 is the product of the
    // seven repeated squarings of a.
    var square = gfMul(a, a); // a^2
    var result = square;
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        square = gfMul(square, square); // a^4, a^8, ... , a^128
        result = gfMul(result, square);
    }
    return result;
}

/// Division in GF(256). Returns 0 when `b` is 0 rather than trapping; every
/// call site validates that share x-coordinates are pairwise distinct first,
/// which is what makes the divisor non-zero.
pub fn gfDiv(a: u8, b: u8) u8 {
    return gfMul(a, gfInv(b));
}

// =============================================================================
// RS1024 checksum (spec: "Checksum")
// =============================================================================

/// Generator coefficients of the RS1024 code, transcribed from the `GEN` table
/// in the spec's `rs1024_polymod` snippet.
const RS1024_GEN = [10]u30{
    0x0E0E040, 0x1C1C080, 0x3838100, 0x7070200,  0xE0E0009,
    0x1C0C2412, 0x38086C24, 0x3090FC48, 0x21B1F890, 0x3F3F120,
};

inline fn polymodStep(chk_in: u30, value: u10) u30 {
    const b: u10 = @truncate(chk_in >> 20);
    var chk: u30 = ((chk_in & 0xFFFFF) << 10) ^ @as(u30, value);
    inline for (RS1024_GEN, 0..) |g, i| {
        if ((b >> @intCast(i)) & 1 != 0) chk ^= g;
    }
    return chk;
}

/// The customization string is prepended to the data as US-ASCII code points
/// before the checksum is computed (spec: "Checksum").
pub fn customizationString(extendable: bool) []const u8 {
    return if (extendable) CUSTOMIZATION_STRING_EXTENDABLE else CUSTOMIZATION_STRING_ORIG;
}

/// rs1024_polymod over the customization string followed by `data`.
pub fn rs1024Polymod(customization: []const u8, data: []const u10) u30 {
    var chk: u30 = 1;
    for (customization) |c| chk = polymodStep(chk, @as(u10, c));
    for (data) |v| chk = polymodStep(chk, v);
    return chk;
}

/// True when `words` (data part *including* its three checksum words) carries a
/// valid RS1024 checksum for the given extendable-backup flag.
pub fn verifyChecksum(words: []const u10, extendable: bool) bool {
    if (words.len < CHECKSUM_WORDS) return false;
    return rs1024Polymod(customizationString(extendable), words) == 1;
}

/// The three checksum words for a data part that does not yet include them.
pub fn createChecksum(data: []const u10, extendable: bool) [3]u10 {
    var chk = rs1024Polymod(customizationString(extendable), data);
    chk = polymodStep(chk, 0);
    chk = polymodStep(chk, 0);
    chk = polymodStep(chk, 0);
    chk ^= 1;
    return .{
        @truncate((chk >> 20) & 0x3FF),
        @truncate((chk >> 10) & 0x3FF),
        @truncate(chk & 0x3FF),
    };
}

// =============================================================================
// Big-endian bit packing into / out of 10-bit words
// =============================================================================
//
// "Big-endian bit order is used in all conversions" (spec: "Format of the share
// mnemonic"). Hand-rolled per-field shifting is where bit-layout bugs hide, so
// both directions go through a single stream abstraction.

const WordWriter = struct {
    words: []u10,
    idx: usize = 0,
    acc: u64 = 0,
    pending: u7 = 0,

    /// Append the low `bits` bits of `value`, most significant first.
    /// `bits` must not exceed 40 so that `acc` cannot overflow.
    fn push(self: *WordWriter, value: u64, bits: u7) void {
        std.debug.assert(bits <= 40);
        self.acc = (self.acc << @as(u6, @intCast(bits))) | value;
        self.pending += bits;
        while (self.pending >= BITS_PER_WORD) {
            self.pending -= BITS_PER_WORD;
            self.words[self.idx] = @truncate((self.acc >> @as(u6, @intCast(self.pending))) & 0x3FF);
            self.idx += 1;
        }
        self.acc &= (@as(u64, 1) << @as(u6, @intCast(self.pending))) - 1;
    }
};

const WordReader = struct {
    words: []const u10,
    idx: usize = 0,
    acc: u64 = 0,
    pending: u7 = 0,

    /// Consume the next `bits` bits, most significant first. Callers size their
    /// requests from the word count, so running off the end is a programming
    /// error rather than an input error.
    fn pull(self: *WordReader, bits: u7) u64 {
        std.debug.assert(bits <= 40);
        while (self.pending < bits) {
            self.acc = (self.acc << BITS_PER_WORD) | self.words[self.idx];
            self.idx += 1;
            self.pending += BITS_PER_WORD;
        }
        self.pending -= bits;
        const value = (self.acc >> @as(u6, @intCast(self.pending))) &
            ((@as(u64, 1) << @as(u6, @intCast(bits))) - 1);
        self.acc &= (@as(u64, 1) << @as(u6, @intCast(self.pending))) - 1;
        return value;
    }
};

/// Number of 10-bit words needed to hold `bits` bits, left-padded with zeros.
fn bitsToWords(bits: usize) usize {
    return (bits + BITS_PER_WORD - 1) / BITS_PER_WORD;
}

// =============================================================================
// Share (spec: "Format of the share mnemonic")
// =============================================================================

/// One SLIP-39 member share: the mnemonic's metadata plus its share value.
///
/// Threshold and count fields hold the *actual* values (1-16), not the
/// wire-encoded `value - 1` nibbles; the encoder and decoder do that
/// conversion. They are u5 rather than u4 precisely so that the value 16 is
/// representable and no saturating arithmetic is needed.
pub const Share = struct {
    /// Random 15-bit identifier, identical across all shares of one set.
    identifier: u15,
    /// Extendable backup flag. When false, `id` also salts the encryption.
    extendable: bool,
    /// Iteration exponent; total PBKDF2 iterations are 10000 << e.
    iteration_exponent: u4,
    /// x-coordinate of this share's group share.
    group_index: u4,
    /// Number of groups required to reconstruct the master secret (1-16).
    group_threshold: u5,
    /// Total number of groups (1-16).
    group_count: u5,
    /// x-coordinate of this share within its group.
    member_index: u4,
    /// Number of member shares required to reconstruct the group share (1-16).
    member_threshold: u5,
    /// The share value, i.e. the f_k(x) octets. Owned by the Share.
    value: []u8,

    /// Zeroize and release the share value.
    pub fn deinit(self: *Share, allocator: Allocator) void {
        std.crypto.secureZero(u8, self.value);
        allocator.free(self.value);
        self.value = &.{};
    }

    /// Fields that must agree across every share of one master secret
    /// (spec: "Combining the shares", check 2).
    fn commonParametersEqual(self: Share, other: Share) bool {
        return self.identifier == other.identifier and
            self.extendable == other.extendable and
            self.iteration_exponent == other.iteration_exponent and
            self.group_threshold == other.group_threshold and
            self.group_count == other.group_count;
    }

    /// Encode to word indices, checksum included.
    ///
    /// The returned buffer holds the share value; zeroize it before freeing.
    pub fn toWords(self: Share, allocator: Allocator) ![]u10 {
        // Refuse to emit a mnemonic shorter than the minimum, which no decoder
        // would accept, rather than silently producing an unusable share.
        if (self.value.len * 8 < MIN_STRENGTH_BITS) return Error.InvalidShareValueLength;
        if (self.group_threshold == 0 or self.member_threshold == 0) return Error.InvalidThreshold;
        if (self.group_count < self.group_threshold) return Error.GroupThresholdExceedsCount;

        const value_bits = self.value.len * 8;
        const value_words = bitsToWords(value_bits);
        const padding_bits: u7 = @intCast(value_words * BITS_PER_WORD - value_bits);

        const total = ID_EXP_WORDS + SHARE_PARAMS_WORDS + value_words + CHECKSUM_WORDS;
        const words = try allocator.alloc(u10, total);
        errdefer allocator.free(words);

        var writer = WordWriter{ .words = words };
        // id || ext || e — 15 + 1 + 4 bits, exactly two words.
        writer.push(@as(u64, self.identifier), 15);
        writer.push(@intFromBool(self.extendable), 1);
        writer.push(@as(u64, self.iteration_exponent), 4);
        // GI || Gt || g || I || t — five 4-bit fields, exactly two words.
        // Thresholds and counts are encoded as (value - 1).
        writer.push(@as(u64, self.group_index), 4);
        writer.push(@as(u64, self.group_threshold - 1), 4);
        writer.push(@as(u64, self.group_count - 1), 4);
        writer.push(@as(u64, self.member_index), 4);
        writer.push(@as(u64, self.member_threshold - 1), 4);
        // Padded share value: left-padded with "0" bits to a multiple of 10.
        writer.push(0, padding_bits);
        for (self.value) |byte| writer.push(@as(u64, byte), 8);

        const checksum = createChecksum(words[0 .. total - CHECKSUM_WORDS], self.extendable);
        words[total - 3] = checksum[0];
        words[total - 2] = checksum[1];
        words[total - 1] = checksum[2];

        return words;
    }

    /// Encode to a space-separated mnemonic string. The mnemonic *is* the share,
    /// so callers should zeroize it before freeing.
    pub fn toMnemonic(self: Share, allocator: Allocator) ![]u8 {
        const words = try self.toWords(allocator);
        defer {
            // The word indices carry the share value.
            std.crypto.secureZero(u10, words);
            allocator.free(words);
        }
        return wordsToMnemonic(allocator, words);
    }

    /// Decode from word indices, validating the checksum, the padding and the
    /// per-share group threshold/count relation.
    pub fn fromWords(allocator: Allocator, words: []const u10) !Share {
        if (words.len < MIN_MNEMONIC_WORDS) return Error.MnemonicTooShort;

        const value_words = words.len - METADATA_WORDS;
        const padded_bits = value_words * BITS_PER_WORD;

        // The padding length equals the padded share value length mod 16 and
        // must not exceed 8 bits (spec: "Combining the shares", check 5).
        const padding_bits: u7 = @intCast(padded_bits % 16);
        if (padding_bits > 8) return Error.InvalidPadding;

        // ext lives inside the data, and it selects the customization string,
        // so it has to be read before the checksum can be verified.
        var reader = WordReader{ .words = words };
        const identifier: u15 = @intCast(reader.pull(15));
        const extendable = reader.pull(1) != 0;
        const iteration_exponent: u4 = @intCast(reader.pull(4));

        if (!verifyChecksum(words, extendable)) return Error.InvalidChecksum;

        const group_index: u4 = @intCast(reader.pull(4));
        const group_threshold: u5 = @as(u5, @intCast(reader.pull(4))) + 1;
        const group_count: u5 = @as(u5, @intCast(reader.pull(4))) + 1;
        const member_index: u4 = @intCast(reader.pull(4));
        const member_threshold: u5 = @as(u5, @intCast(reader.pull(4))) + 1;

        // "The value of G MUST be greater than or equal to GT" — rejected here,
        // per share, so a single malformed mnemonic is caught on its own.
        if (group_count < group_threshold) return Error.GroupThresholdExceedsCount;

        // All padding bits MUST be "0" (spec: "Combining the shares", check 6).
        if (reader.pull(padding_bits) != 0) return Error.InvalidPadding;

        const value_bytes = (padded_bits - padding_bits) / 8;
        const value = try allocator.alloc(u8, value_bytes);
        errdefer {
            std.crypto.secureZero(u8, value);
            allocator.free(value);
        }
        for (value) |*byte| byte.* = @intCast(reader.pull(8));

        return Share{
            .identifier = identifier,
            .extendable = extendable,
            .iteration_exponent = iteration_exponent,
            .group_index = group_index,
            .group_threshold = group_threshold,
            .group_count = group_count,
            .member_index = member_index,
            .member_threshold = member_threshold,
            .value = value,
        };
    }

    /// Decode from a mnemonic string.
    pub fn fromMnemonic(allocator: Allocator, mnemonic: []const u8) !Share {
        const words = try mnemonicToWords(allocator, mnemonic);
        defer {
            std.crypto.secureZero(u10, words);
            allocator.free(words);
        }
        return fromWords(allocator, words);
    }
};

/// Release a slice of shares produced by `generateShares` / `decodeMnemonics`.
pub fn freeShares(allocator: Allocator, shares: []Share) void {
    for (shares) |*share| share.deinit(allocator);
    allocator.free(shares);
}

// =============================================================================
// Polynomial interpolation and secret splitting
// (spec: "Polynomial interpolation", "Sharing a secret")
// =============================================================================

/// An (x, y-vector) pair: one point of the n parallel GF(256) polynomials.
pub const RawShare = struct {
    x: u8,
    y: []const u8,
};

/// Interpolate(x, {(x_i, y_i)}): evaluate the interpolating polynomials at `x`.
///
/// Writes n = y-vector length bytes into `out`. All x_i must be pairwise
/// distinct and all y_i the same length; both are checked.
pub fn interpolate(out: []u8, points: []const RawShare, x: u8) !void {
    if (points.len == 0) return Error.EmptyShareSet;
    for (points) |p| {
        if (p.y.len != out.len) return Error.InvalidShareValueLength;
    }
    for (points, 0..) |p, i| {
        for (points[i + 1 ..]) |q| {
            if (p.x == q.x) return Error.DuplicateMemberIndex;
        }
    }

    @memset(out, 0);
    for (points, 0..) |p_i, i| {
        // Lagrange basis polynomial for point i evaluated at x:
        //   prod_{j != i} (x - x_j) / (x_i - x_j)
        // Subtraction in GF(2^8) is XOR.
        var basis: u8 = 1;
        for (points, 0..) |p_j, j| {
            if (i == j) continue;
            basis = gfMul(basis, gfDiv(x ^ p_j.x, p_i.x ^ p_j.x));
        }
        for (out, p_i.y) |*acc, y| acc.* ^= gfMul(y, basis);
    }
}

/// Digest of a shared secret: the first 4 bytes of HMAC-SHA256(key=R, msg=S)
/// (spec: "Digest").
fn createDigest(out: *[DIGEST_LENGTH_BYTES]u8, random_part: []const u8, shared_secret: []const u8) void {
    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, shared_secret, random_part);
    @memcpy(out, mac[0..DIGEST_LENGTH_BYTES]);
    std.crypto.secureZero(u8, &mac);
}

/// SplitSecret(T, N, S) — see spec: "Sharing a secret".
///
/// Returns N share values for x-coordinates 0 .. N-1. Caller owns the returned
/// slice and each value; `freeRawValues` releases both.
pub fn splitSecret(
    allocator: Allocator,
    threshold: u8,
    share_count: u8,
    shared_secret: []const u8,
) ![][]u8 {
    if (threshold == 0 or threshold > share_count) return Error.InvalidThreshold;
    if (share_count > MAX_SHARE_COUNT) return Error.InvalidThreshold;
    if (shared_secret.len * 8 < MIN_STRENGTH_BITS or shared_secret.len % 2 != 0) {
        return Error.InvalidMasterSecretLength;
    }

    const values = try allocator.alloc([]u8, share_count);
    var allocated: usize = 0;
    errdefer {
        for (values[0..allocated]) |v| {
            std.crypto.secureZero(u8, v);
            allocator.free(v);
        }
        allocator.free(values);
    }
    for (values) |*v| {
        v.* = try allocator.alloc(u8, shared_secret.len);
        allocated += 1;
    }

    // With threshold 1 the digest is unused and every share is the secret.
    if (threshold == 1) {
        for (values) |v| @memcpy(v, shared_secret);
        return values;
    }

    // y_1 .. y_{T-2} are random; they become the shares at indices 0 .. T-3.
    const random_share_count: usize = threshold - 2;
    for (values[0..random_share_count]) |v| try fillRandomBytes(v);

    // The digest share D = digest(4) || R sits at index 254, the secret at 255.
    const digest_value = try allocator.alloc(u8, shared_secret.len);
    defer {
        std.crypto.secureZero(u8, digest_value);
        allocator.free(digest_value);
    }
    const random_part = digest_value[DIGEST_LENGTH_BYTES..];
    try fillRandomBytes(random_part);
    createDigest(digest_value[0..DIGEST_LENGTH_BYTES], random_part, shared_secret);

    const base = try allocator.alloc(RawShare, random_share_count + 2);
    defer allocator.free(base);
    for (values[0..random_share_count], 0..) |v, i| {
        base[i] = .{ .x = @intCast(i), .y = v };
    }
    base[random_share_count] = .{ .x = DIGEST_INDEX, .y = digest_value };
    base[random_share_count + 1] = .{ .x = SECRET_INDEX, .y = shared_secret };

    var i: usize = random_share_count;
    while (i < share_count) : (i += 1) {
        try interpolate(values[i], base, @intCast(i));
    }

    return values;
}

/// Release a `[][]u8` of share values, zeroizing each.
pub fn freeRawValues(allocator: Allocator, values: [][]u8) void {
    for (values) |v| {
        std.crypto.secureZero(u8, v);
        allocator.free(v);
    }
    allocator.free(values);
}

/// RecoverSecret(T, [(x_i, y_i)]) — see spec: "Sharing a secret".
///
/// `points` must hold exactly `threshold` pairwise-distinct points; callers
/// enforce that from the share metadata before getting here.
pub fn recoverSecret(allocator: Allocator, threshold: u8, points: []const RawShare) ![]u8 {
    if (points.len == 0) return Error.EmptyShareSet;

    const n = points[0].y.len;
    const secret = try allocator.alloc(u8, n);
    errdefer {
        std.crypto.secureZero(u8, secret);
        allocator.free(secret);
    }

    // With threshold 1 there is no digest share to check.
    if (threshold == 1) {
        @memcpy(secret, points[0].y);
        return secret;
    }

    try interpolate(secret, points, SECRET_INDEX);

    const digest_share = try allocator.alloc(u8, n);
    defer {
        std.crypto.secureZero(u8, digest_share);
        allocator.free(digest_share);
    }
    try interpolate(digest_share, points, DIGEST_INDEX);

    var expected: [DIGEST_LENGTH_BYTES]u8 = undefined;
    createDigest(&expected, digest_share[DIGEST_LENGTH_BYTES..], secret);
    // Constant-time compare: the digest is derived from secret material, so a
    // byte-by-byte early exit would leak how much of it matched.
    const ok = std.crypto.timing_safe.eql(
        [DIGEST_LENGTH_BYTES]u8,
        expected,
        digest_share[0..DIGEST_LENGTH_BYTES].*,
    );
    std.crypto.secureZero(u8, &expected);
    if (!ok) return Error.InvalidDigest;

    return secret;
}

// =============================================================================
// Encryption of the master secret
// (spec: "Encryption of the master secret", "Decryption of the master secret")
// =============================================================================

/// PBKDF2 salt prefix: empty when ext = 1, else "shamir" || id as two
/// big-endian bytes.
fn saltPrefix(buf: *[CUSTOMIZATION_STRING_ORIG.len + 2]u8, identifier: u15, extendable: bool) []const u8 {
    if (extendable) return buf[0..0];
    @memcpy(buf[0..CUSTOMIZATION_STRING_ORIG.len], CUSTOMIZATION_STRING_ORIG);
    std.mem.writeInt(u16, buf[CUSTOMIZATION_STRING_ORIG.len..][0..2], @as(u16, identifier), .big);
    return buf[0..];
}

/// F(i, R) = PBKDF2(HMAC-SHA256, (i || passphrase), (salt_prefix || R),
///                  iterations = 2500 << e, dkLen = |R|)
fn roundFunction(
    allocator: Allocator,
    out: []u8,
    round: u8,
    passphrase: []const u8,
    iteration_exponent: u4,
    salt_prefix: []const u8,
    r: []const u8,
) !void {
    const password = try allocator.alloc(u8, 1 + passphrase.len);
    defer {
        std.crypto.secureZero(u8, password);
        allocator.free(password);
    }
    password[0] = round;
    @memcpy(password[1..], passphrase);

    const salt = try allocator.alloc(u8, salt_prefix.len + r.len);
    defer {
        std.crypto.secureZero(u8, salt);
        allocator.free(salt);
    }
    @memcpy(salt[0..salt_prefix.len], salt_prefix);
    @memcpy(salt[salt_prefix.len..], r);

    // "The number of iterations is calculated as 10000 x 2^e", spread evenly
    // over the four Feistel rounds (spec: "Encryption of the master secret").
    const iterations: u32 = (@as(u32, BASE_ITERATION_COUNT) << iteration_exponent) / ROUND_COUNT;
    // pbkdf2 can only fail on rounds < 1 or an absurdly long derived key;
    // iterations is at least 2500 and `out` is half a master secret.
    std.crypto.pwhash.pbkdf2(out, password, salt, iterations, HmacSha256) catch unreachable;
}

fn feistel(
    allocator: Allocator,
    input: []const u8,
    passphrase: []const u8,
    iteration_exponent: u4,
    identifier: u15,
    extendable: bool,
    comptime decrypt: bool,
) ![]u8 {
    if (input.len % 2 != 0) return Error.InvalidMasterSecretLength;
    try validatePassphrase(passphrase);

    const half = input.len / 2;
    const out = try allocator.alloc(u8, input.len);
    errdefer {
        std.crypto.secureZero(u8, out);
        allocator.free(out);
    }

    // Working halves L and R, plus scratch for the round function output.
    const work = try allocator.alloc(u8, half * 3);
    defer {
        std.crypto.secureZero(u8, work);
        allocator.free(work);
    }
    var l = work[0..half];
    var r = work[half .. half * 2];
    const f = work[half * 2 ..];

    @memcpy(l, input[0..half]);
    @memcpy(r, input[half..]);

    var prefix_buf: [CUSTOMIZATION_STRING_ORIG.len + 2]u8 = undefined;
    const prefix = saltPrefix(&prefix_buf, identifier, extendable);

    // Encryption runs i = 0,1,2,3; decryption is the same network with the
    // round order reversed.
    var step: usize = 0;
    while (step < ROUND_COUNT) : (step += 1) {
        const round: u8 = if (decrypt) @intCast(ROUND_COUNT - 1 - step) else @intCast(step);
        try roundFunction(allocator, f, round, passphrase, iteration_exponent, prefix, r);
        // (L, R) = (R, L xor F(i, R)) — swap by rotating the slice aliases so
        // no copy of secret material is left behind.
        for (l, f) |*byte, mask| byte.* ^= mask;
        const new_r = l;
        l = r;
        r = new_r;
    }

    // EMS = R || L
    @memcpy(out[0..half], r);
    @memcpy(out[half..], l);
    return out;
}

/// Encrypt(MS, P, e, id, ext): the four-round Feistel network with PBKDF2 as
/// the round function. Caller owns the returned EMS.
pub fn encryptMasterSecret(
    allocator: Allocator,
    master_secret: []const u8,
    passphrase: []const u8,
    iteration_exponent: u4,
    identifier: u15,
    extendable: bool,
) ![]u8 {
    return feistel(allocator, master_secret, passphrase, iteration_exponent, identifier, extendable, false);
}

/// Decrypt(EMS, P, e, id, ext). Caller owns the returned master secret.
pub fn decryptMasterSecret(
    allocator: Allocator,
    encrypted_master_secret: []const u8,
    passphrase: []const u8,
    iteration_exponent: u4,
    identifier: u15,
    extendable: bool,
) ![]u8 {
    return feistel(allocator, encrypted_master_secret, passphrase, iteration_exponent, identifier, extendable, true);
}

/// The passphrase MUST be printable ASCII (code points 32-126) so that shares
/// stay recoverable across platforms (spec: "Passphrase").
pub fn validatePassphrase(passphrase: []const u8) !void {
    for (passphrase) |c| {
        if (c < 32 or c > 126) return Error.InvalidPassphrase;
    }
}

// =============================================================================
// Generating and combining shares
// (spec: "Generating the shares", "Combining the shares")
// =============================================================================

/// One group's (member threshold, member count) pair.
pub const GroupSpec = struct {
    member_threshold: u8,
    member_count: u8,
};

pub const GenerateOptions = struct {
    /// Number of groups required to reconstruct the master secret.
    group_threshold: u8,
    /// Per-group member thresholds and counts.
    groups: []const GroupSpec,
    passphrase: []const u8 = "",
    /// Newly created shares SHOULD set ext = 1 (spec: "Extendable backup flag").
    extendable: bool = true,
    /// Matches the reference implementation's default of 1 (20000 iterations).
    iteration_exponent: u4 = 1,
    /// Fixed identifier, for reproducing a known share set in tests. Random
    /// when null, which is what production callers want.
    identifier: ?u15 = null,
};

/// GenerateShares(GT, [(T_i, N_i)], MS, P, e) — returns every member share of
/// every group, flattened. Release with `freeShares`.
pub fn generateShares(allocator: Allocator, master_secret: []const u8, opts: GenerateOptions) ![]Share {
    if (opts.groups.len == 0 or opts.groups.len > MAX_SHARE_COUNT) {
        return Error.InvalidGroupConfiguration;
    }
    if (opts.group_threshold == 0 or opts.group_threshold > opts.groups.len) {
        return Error.InvalidGroupConfiguration;
    }
    if (master_secret.len * 8 < MIN_STRENGTH_BITS or master_secret.len % 2 != 0) {
        return Error.InvalidMasterSecretLength;
    }
    try validatePassphrase(opts.passphrase);

    var total_shares: usize = 0;
    for (opts.groups) |g| {
        if (g.member_threshold == 0 or g.member_threshold > g.member_count) return Error.InvalidThreshold;
        if (g.member_count > MAX_SHARE_COUNT) return Error.InvalidThreshold;
        // Step 1 of GenerateShares: a 1-of-N group with N > 1 adds no security
        // and is almost always a user error.
        if (g.member_threshold == 1 and g.member_count > 1) return Error.ThresholdOneWithMultipleMembers;
        total_shares += g.member_count;
    }

    const identifier: u15 = opts.identifier orelse blk: {
        var id_bytes: [2]u8 = undefined;
        try fillRandomBytes(&id_bytes);
        break :blk @truncate(std.mem.readInt(u16, &id_bytes, .big));
    };

    const ems = try encryptMasterSecret(
        allocator,
        master_secret,
        opts.passphrase,
        opts.iteration_exponent,
        identifier,
        opts.extendable,
    );
    defer {
        std.crypto.secureZero(u8, ems);
        allocator.free(ems);
    }

    // First level: split the EMS into one group share per group.
    const group_values = try splitSecret(allocator, opts.group_threshold, @intCast(opts.groups.len), ems);
    defer freeRawValues(allocator, group_values);

    const shares = try allocator.alloc(Share, total_shares);
    var filled: usize = 0;
    errdefer {
        for (shares[0..filled]) |*s| s.deinit(allocator);
        allocator.free(shares);
    }

    // Second level: split each group share among that group's members.
    for (opts.groups, 0..) |group, group_index| {
        const member_values = try splitSecret(
            allocator,
            group.member_threshold,
            group.member_count,
            group_values[group_index],
        );
        // Ownership of each member value moves into its Share.
        defer allocator.free(member_values);

        for (member_values, 0..) |value, member_index| {
            shares[filled] = Share{
                .identifier = identifier,
                .extendable = opts.extendable,
                .iteration_exponent = opts.iteration_exponent,
                .group_index = @intCast(group_index),
                .group_threshold = @intCast(opts.group_threshold),
                .group_count = @intCast(opts.groups.len),
                .member_index = @intCast(member_index),
                .member_threshold = @intCast(group.member_threshold),
                .value = value,
            };
            filled += 1;
        }
    }

    return shares;
}

/// Convenience wrapper: `generateShares` rendered as mnemonic strings, in the
/// same order (group 0 members first, then group 1, ...). Release with
/// `freeMnemonics`.
pub fn generateMnemonics(allocator: Allocator, master_secret: []const u8, opts: GenerateOptions) ![][]u8 {
    const shares = try generateShares(allocator, master_secret, opts);
    defer freeShares(allocator, shares);

    const mnemonics = try allocator.alloc([]u8, shares.len);
    var filled: usize = 0;
    errdefer {
        for (mnemonics[0..filled]) |m| allocator.free(m);
        allocator.free(mnemonics);
    }
    for (shares, 0..) |share, i| {
        mnemonics[i] = try share.toMnemonic(allocator);
        filled += 1;
    }
    return mnemonics;
}

/// Zeroize and release mnemonics from `generateMnemonics`. Each mnemonic string
/// is itself a share, so it is wiped rather than merely freed.
pub fn freeMnemonics(allocator: Allocator, mnemonics: [][]u8) void {
    for (mnemonics) |m| {
        std.crypto.secureZero(u8, m);
        allocator.free(m);
    }
    allocator.free(mnemonics);
}

/// Decode a list of mnemonics into shares. Release with `freeShares`.
pub fn decodeMnemonics(allocator: Allocator, mnemonics: []const []const u8) ![]Share {
    if (mnemonics.len == 0) return Error.EmptyShareSet;
    const shares = try allocator.alloc(Share, mnemonics.len);
    var filled: usize = 0;
    errdefer {
        for (shares[0..filled]) |*s| s.deinit(allocator);
        allocator.free(shares);
    }
    for (mnemonics, 0..) |m, i| {
        shares[i] = try Share.fromMnemonic(allocator, m);
        filled += 1;
    }
    return shares;
}

/// Combine mnemonics into the master secret. Caller owns the result.
pub fn combineMnemonics(allocator: Allocator, mnemonics: []const []const u8, passphrase: []const u8) ![]u8 {
    const shares = try decodeMnemonics(allocator, mnemonics);
    defer freeShares(allocator, shares);
    return combineShares(allocator, shares, passphrase);
}

/// Combine decoded shares into the master secret, applying every validity
/// check in the spec's "Combining the shares" section.
pub fn combineShares(allocator: Allocator, shares: []const Share, passphrase: []const u8) ![]u8 {
    if (shares.len == 0) return Error.EmptyShareSet;
    try validatePassphrase(passphrase);

    const first = shares[0];
    for (shares[1..]) |s| {
        if (!first.commonParametersEqual(s)) return Error.MismatchedShareParameters;
        if (s.value.len != first.value.len) return Error.InvalidShareValueLength;
    }
    if (first.value.len * 8 < MIN_STRENGTH_BITS) return Error.InvalidShareValueLength;
    // Enforced per share by Share.fromWords, restated here because
    // combineShares is also reachable with hand-built Share values.
    if (first.group_count < first.group_threshold) return Error.GroupThresholdExceedsCount;

    // Bucket shares by group index. Exact duplicates (same group, same member
    // index, same value) are folded together, matching the reference
    // implementation, which keeps shares in a set.
    var group_indices: [MAX_SHARE_COUNT]u4 = undefined;
    var group_members: [MAX_SHARE_COUNT][MAX_SHARE_COUNT]usize = undefined;
    var group_member_counts = [_]usize{0} ** MAX_SHARE_COUNT;
    var group_count: usize = 0;

    outer: for (shares, 0..) |share, share_pos| {
        var slot: usize = group_count;
        for (group_indices[0..group_count], 0..) |gi, g| {
            if (gi == share.group_index) {
                slot = g;
                break;
            }
        }
        if (slot == group_count) {
            group_indices[group_count] = share.group_index;
            group_count += 1;
        }

        const members = group_members[slot][0..group_member_counts[slot]];
        for (members) |existing_pos| {
            const existing = shares[existing_pos];
            if (existing.member_index != share.member_index) continue;
            // Same member index: identical share values are a harmless
            // duplicate, differing values mean the set is inconsistent.
            if (mem.eql(u8, existing.value, share.value)) continue :outer;
            return Error.DuplicateMemberIndex;
        }
        // All shares of a group must agree on the member threshold.
        if (group_member_counts[slot] > 0) {
            if (shares[group_members[slot][0]].member_threshold != share.member_threshold) {
                return Error.MismatchedMemberThreshold;
            }
        }
        if (group_member_counts[slot] == MAX_SHARE_COUNT) return Error.WrongNumberOfShares;
        group_members[slot][group_member_counts[slot]] = share_pos;
        group_member_counts[slot] += 1;
    }

    // GM MUST equal GT — neither fewer groups nor more.
    if (group_count != first.group_threshold) return Error.WrongNumberOfGroups;

    const value_len = first.value.len;
    const group_points = try allocator.alloc(RawShare, group_count);
    defer allocator.free(group_points);
    const group_secrets = try allocator.alloc([]u8, group_count);
    var recovered: usize = 0;
    defer {
        for (group_secrets[0..recovered]) |v| {
            std.crypto.secureZero(u8, v);
            allocator.free(v);
        }
        allocator.free(group_secrets);
    }

    var member_points: [MAX_SHARE_COUNT]RawShare = undefined;
    for (0..group_count) |g| {
        const members = group_members[g][0..group_member_counts[g]];
        const member_threshold = shares[members[0]].member_threshold;
        // M_i MUST equal T_i.
        if (members.len != member_threshold) return Error.WrongNumberOfShares;

        for (members, 0..) |pos, i| {
            member_points[i] = .{ .x = shares[pos].member_index, .y = shares[pos].value };
        }
        group_secrets[g] = try recoverSecret(
            allocator,
            @intCast(member_threshold),
            member_points[0..members.len],
        );
        recovered += 1;
        group_points[g] = .{ .x = group_indices[g], .y = group_secrets[g] };
        std.debug.assert(group_secrets[g].len == value_len);
    }

    const ems = try recoverSecret(allocator, @intCast(first.group_threshold), group_points);
    defer {
        std.crypto.secureZero(u8, ems);
        allocator.free(ems);
    }

    return decryptMasterSecret(
        allocator,
        ems,
        passphrase,
        first.iteration_exponent,
        first.identifier,
        first.extendable,
    );
}

// =============================================================================
// Randomness
// =============================================================================

/// Cross-platform cryptographic random bytes, straight to the OS CSPRNG —
/// getrandom on Linux (including Android at every API level), arc4random on
/// Darwin/BSD, /dev/urandom elsewhere.
///
/// "The source of randomness used to generate the values in steps 3 and 4 above
/// MUST be suitable for generating cryptographic keys" (spec: SplitSecret).
/// A short read is therefore fatal: proceeding would emit shares built from
/// uninitialised, predictable bytes.
fn fillRandomBytes(buf: []u8) Error!void {
    switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .freebsd, .netbsd, .openbsd, .dragonfly => {
            // arc4random_buf cannot fail on these platforms.
            std.c.arc4random_buf(buf.ptr, buf.len);
        },
        .linux => {
            var filled: usize = 0;
            while (filled < buf.len) {
                const rc = std.os.linux.getrandom(buf.ptr + filled, buf.len - filled, 0);
                if (rc == 0) return Error.RandomFailure; // no progress
                if (@as(isize, @bitCast(rc)) < 0) return Error.RandomFailure;
                filled += rc;
            }
        },
        else => {
            const fd = std.c.open("/dev/urandom", .{ .ACCMODE = .RDONLY }, 0);
            if (fd < 0) return Error.RandomFailure;
            defer _ = std.c.close(fd);
            var filled: usize = 0;
            while (filled < buf.len) {
                const n = std.c.read(fd, buf.ptr + filled, buf.len - filled);
                if (n <= 0) return Error.RandomFailure;
                filled += @intCast(n);
            }
        },
    }
}

/// Convert word indices to mnemonic string
pub fn wordsToMnemonic(allocator: Allocator, word_indices: []const u10) ![]u8 {
    var total_len: usize = 0;
    for (word_indices) |idx| {
        total_len += wordlist[idx].len + 1; // word + space
    }
    if (total_len > 0) total_len -= 1; // no trailing space

    var result = try allocator.alloc(u8, total_len);
    var pos: usize = 0;

    for (word_indices, 0..) |idx, i| {
        const word = wordlist[idx];
        @memcpy(result[pos .. pos + word.len], word);
        pos += word.len;
        if (i < word_indices.len - 1) {
            result[pos] = ' ';
            pos += 1;
        }
    }

    return result;
}

/// Parse mnemonic string to word indices
pub fn mnemonicToWords(allocator: Allocator, mnemonic: []const u8) ![]u10 {
    // Count words
    var word_count: usize = 0;
    var in_word = false;
    for (mnemonic) |c| {
        if (c == ' ' or c == '\t' or c == '\n') {
            in_word = false;
        } else if (!in_word) {
            in_word = true;
            word_count += 1;
        }
    }

    var words = try allocator.alloc(u10, word_count);
    errdefer allocator.free(words);

    // Parse each word
    var word_idx: usize = 0;
    var start: usize = 0;
    var i: usize = 0;

    while (i <= mnemonic.len) {
        const is_sep = i == mnemonic.len or mnemonic[i] == ' ' or mnemonic[i] == '\t' or mnemonic[i] == '\n';

        if (is_sep and i > start) {
            const word = mnemonic[start..i];
            words[word_idx] = try lookupWord(word);
            word_idx += 1;
            start = i + 1;
        } else if (is_sep) {
            start = i + 1;
        }

        i += 1;
    }

    return words;
}

/// Look up a word in the wordlist, case-insensitively.
///
/// The wordlist is alphabetically sorted (spec: "Wordlist"), so this is a
/// binary search. Mnemonic words are public data, so the data-dependent branch
/// pattern here is not a side channel.
pub fn lookupWord(word: []const u8) !u10 {
    // No wordlist entry is longer than 8 letters.
    if (word.len == 0 or word.len > 8) return Error.UnknownWord;
    var lower: [8]u8 = undefined;
    for (word, 0..) |c, i| {
        lower[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
    }
    const needle = lower[0..word.len];

    var lo: usize = 0;
    var hi: usize = wordlist.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        switch (mem.order(u8, wordlist[mid], needle)) {
            .lt => lo = mid + 1,
            .gt => hi = mid,
            .eq => return @intCast(mid),
        }
    }
    return Error.UnknownWord;
}

/// SLIP-39 1024-word wordlist
pub const wordlist = [_][]const u8{
    "academic",
    "acid",
    "acne",
    "acquire",
    "acrobat",
    "activity",
    "actress",
    "adapt",
    "adequate",
    "adjust",
    "admit",
    "adorn",
    "adult",
    "advance",
    "advocate",
    "afraid",
    "again",
    "agency",
    "agree",
    "aide",
    "aircraft",
    "airline",
    "airport",
    "ajar",
    "alarm",
    "album",
    "alcohol",
    "alien",
    "alive",
    "alpha",
    "already",
    "alto",
    "aluminum",
    "always",
    "amazing",
    "ambition",
    "amount",
    "amuse",
    "analysis",
    "anatomy",
    "ancestor",
    "ancient",
    "angel",
    "angry",
    "animal",
    "answer",
    "antenna",
    "anxiety",
    "apart",
    "aquatic",
    "arcade",
    "arena",
    "argue",
    "armed",
    "artist",
    "artwork",
    "aspect",
    "auction",
    "august",
    "aunt",
    "average",
    "aviation",
    "avoid",
    "award",
    "away",
    "axis",
    "axle",
    "beam",
    "beard",
    "beaver",
    "become",
    "bedroom",
    "behavior",
    "being",
    "believe",
    "belong",
    "benefit",
    "best",
    "beyond",
    "bike",
    "biology",
    "birthday",
    "bishop",
    "black",
    "blanket",
    "blessing",
    "blimp",
    "blind",
    "blue",
    "body",
    "bolt",
    "boring",
    "born",
    "both",
    "boundary",
    "bracelet",
    "branch",
    "brave",
    "breathe",
    "briefing",
    "broken",
    "brother",
    "browser",
    "bucket",
    "budget",
    "building",
    "bulb",
    "bulge",
    "bumpy",
    "bundle",
    "burden",
    "burning",
    "busy",
    "buyer",
    "cage",
    "calcium",
    "camera",
    "campus",
    "canyon",
    "capacity",
    "capital",
    "capture",
    "carbon",
    "cards",
    "careful",
    "cargo",
    "carpet",
    "carve",
    "category",
    "cause",
    "ceiling",
    "center",
    "ceramic",
    "champion",
    "change",
    "charity",
    "check",
    "chemical",
    "chest",
    "chew",
    "chubby",
    "cinema",
    "civil",
    "class",
    "clay",
    "cleanup",
    "client",
    "climate",
    "clinic",
    "clock",
    "clogs",
    "closet",
    "clothes",
    "club",
    "cluster",
    "coal",
    "coastal",
    "coding",
    "column",
    "company",
    "corner",
    "costume",
    "counter",
    "course",
    "cover",
    "cowboy",
    "cradle",
    "craft",
    "crazy",
    "credit",
    "cricket",
    "criminal",
    "crisis",
    "critical",
    "crowd",
    "crucial",
    "crunch",
    "crush",
    "crystal",
    "cubic",
    "cultural",
    "curious",
    "curly",
    "custody",
    "cylinder",
    "daisy",
    "damage",
    "dance",
    "darkness",
    "database",
    "daughter",
    "deadline",
    "deal",
    "debris",
    "debut",
    "decent",
    "decision",
    "declare",
    "decorate",
    "decrease",
    "deliver",
    "demand",
    "density",
    "deny",
    "depart",
    "depend",
    "depict",
    "deploy",
    "describe",
    "desert",
    "desire",
    "desktop",
    "destroy",
    "detailed",
    "detect",
    "device",
    "devote",
    "diagnose",
    "dictate",
    "diet",
    "dilemma",
    "diminish",
    "dining",
    "diploma",
    "disaster",
    "discuss",
    "disease",
    "dish",
    "dismiss",
    "display",
    "distance",
    "dive",
    "divorce",
    "document",
    "domain",
    "domestic",
    "dominant",
    "dough",
    "downtown",
    "dragon",
    "dramatic",
    "dream",
    "dress",
    "drift",
    "drink",
    "drove",
    "drug",
    "dryer",
    "duckling",
    "duke",
    "duration",
    "dwarf",
    "dynamic",
    "early",
    "earth",
    "easel",
    "easy",
    "echo",
    "eclipse",
    "ecology",
    "edge",
    "editor",
    "educate",
    "either",
    "elbow",
    "elder",
    "election",
    "elegant",
    "element",
    "elephant",
    "elevator",
    "elite",
    "else",
    "email",
    "emerald",
    "emission",
    "emperor",
    "emphasis",
    "employer",
    "empty",
    "ending",
    "endless",
    "endorse",
    "enemy",
    "energy",
    "enforce",
    "engage",
    "enjoy",
    "enlarge",
    "entrance",
    "envelope",
    "envy",
    "epidemic",
    "episode",
    "equation",
    "equip",
    "eraser",
    "erode",
    "escape",
    "estate",
    "estimate",
    "evaluate",
    "evening",
    "evidence",
    "evil",
    "evoke",
    "exact",
    "example",
    "exceed",
    "exchange",
    "exclude",
    "excuse",
    "execute",
    "exercise",
    "exhaust",
    "exotic",
    "expand",
    "expect",
    "explain",
    "express",
    "extend",
    "extra",
    "eyebrow",
    "facility",
    "fact",
    "failure",
    "faint",
    "fake",
    "false",
    "family",
    "famous",
    "fancy",
    "fangs",
    "fantasy",
    "fatal",
    "fatigue",
    "favorite",
    "fawn",
    "fiber",
    "fiction",
    "filter",
    "finance",
    "findings",
    "finger",
    "firefly",
    "firm",
    "fiscal",
    "fishing",
    "fitness",
    "flame",
    "flash",
    "flavor",
    "flea",
    "flexible",
    "flip",
    "float",
    "floral",
    "fluff",
    "focus",
    "forbid",
    "force",
    "forecast",
    "forget",
    "formal",
    "fortune",
    "forward",
    "founder",
    "fraction",
    "fragment",
    "frequent",
    "freshman",
    "friar",
    "fridge",
    "friendly",
    "frost",
    "froth",
    "frozen",
    "fumes",
    "funding",
    "furl",
    "fused",
    "galaxy",
    "game",
    "garbage",
    "garden",
    "garlic",
    "gasoline",
    "gather",
    "general",
    "genius",
    "genre",
    "genuine",
    "geology",
    "gesture",
    "glad",
    "glance",
    "glasses",
    "glen",
    "glimpse",
    "goat",
    "golden",
    "graduate",
    "grant",
    "grasp",
    "gravity",
    "gray",
    "greatest",
    "grief",
    "grill",
    "grin",
    "grocery",
    "gross",
    "group",
    "grownup",
    "grumpy",
    "guard",
    "guest",
    "guilt",
    "guitar",
    "gums",
    "hairy",
    "hamster",
    "hand",
    "hanger",
    "harvest",
    "have",
    "havoc",
    "hawk",
    "hazard",
    "headset",
    "health",
    "hearing",
    "heat",
    "helpful",
    "herald",
    "herd",
    "hesitate",
    "hobo",
    "holiday",
    "holy",
    "home",
    "hormone",
    "hospital",
    "hour",
    "huge",
    "human",
    "humidity",
    "hunting",
    "husband",
    "hush",
    "husky",
    "hybrid",
    "idea",
    "identify",
    "idle",
    "image",
    "impact",
    "imply",
    "improve",
    "impulse",
    "include",
    "income",
    "increase",
    "index",
    "indicate",
    "industry",
    "infant",
    "inform",
    "inherit",
    "injury",
    "inmate",
    "insect",
    "inside",
    "install",
    "intend",
    "intimate",
    "invasion",
    "involve",
    "iris",
    "island",
    "isolate",
    "item",
    "ivory",
    "jacket",
    "jerky",
    "jewelry",
    "join",
    "judicial",
    "juice",
    "jump",
    "junction",
    "junior",
    "junk",
    "jury",
    "justice",
    "kernel",
    "keyboard",
    "kidney",
    "kind",
    "kitchen",
    "knife",
    "knit",
    "laden",
    "ladle",
    "ladybug",
    "lair",
    "lamp",
    "language",
    "large",
    "laser",
    "laundry",
    "lawsuit",
    "leader",
    "leaf",
    "learn",
    "leaves",
    "lecture",
    "legal",
    "legend",
    "legs",
    "lend",
    "length",
    "level",
    "liberty",
    "library",
    "license",
    "lift",
    "likely",
    "lilac",
    "lily",
    "lips",
    "liquid",
    "listen",
    "literary",
    "living",
    "lizard",
    "loan",
    "lobe",
    "location",
    "losing",
    "loud",
    "loyalty",
    "luck",
    "lunar",
    "lunch",
    "lungs",
    "luxury",
    "lying",
    "lyrics",
    "machine",
    "magazine",
    "maiden",
    "mailman",
    "main",
    "makeup",
    "making",
    "mama",
    "manager",
    "mandate",
    "mansion",
    "manual",
    "marathon",
    "march",
    "market",
    "marvel",
    "mason",
    "material",
    "math",
    "maximum",
    "mayor",
    "meaning",
    "medal",
    "medical",
    "member",
    "memory",
    "mental",
    "merchant",
    "merit",
    "method",
    "metric",
    "midst",
    "mild",
    "military",
    "mineral",
    "minister",
    "miracle",
    "mixed",
    "mixture",
    "mobile",
    "modern",
    "modify",
    "moisture",
    "moment",
    "morning",
    "mortgage",
    "mother",
    "mountain",
    "mouse",
    "move",
    "much",
    "mule",
    "multiple",
    "muscle",
    "museum",
    "music",
    "mustang",
    "nail",
    "national",
    "necklace",
    "negative",
    "nervous",
    "network",
    "news",
    "nuclear",
    "numb",
    "numerous",
    "nylon",
    "oasis",
    "obesity",
    "object",
    "observe",
    "obtain",
    "ocean",
    "often",
    "olympic",
    "omit",
    "oral",
    "orange",
    "orbit",
    "order",
    "ordinary",
    "organize",
    "ounce",
    "oven",
    "overall",
    "owner",
    "paces",
    "pacific",
    "package",
    "paid",
    "painting",
    "pajamas",
    "pancake",
    "pants",
    "papa",
    "paper",
    "parcel",
    "parking",
    "party",
    "patent",
    "patrol",
    "payment",
    "payroll",
    "peaceful",
    "peanut",
    "peasant",
    "pecan",
    "penalty",
    "pencil",
    "percent",
    "perfect",
    "permit",
    "petition",
    "phantom",
    "pharmacy",
    "photo",
    "phrase",
    "physics",
    "pickup",
    "picture",
    "piece",
    "pile",
    "pink",
    "pipeline",
    "pistol",
    "pitch",
    "plains",
    "plan",
    "plastic",
    "platform",
    "playoff",
    "pleasure",
    "plot",
    "plunge",
    "practice",
    "prayer",
    "preach",
    "predator",
    "pregnant",
    "premium",
    "prepare",
    "presence",
    "prevent",
    "priest",
    "primary",
    "priority",
    "prisoner",
    "privacy",
    "prize",
    "problem",
    "process",
    "profile",
    "program",
    "promise",
    "prospect",
    "provide",
    "prune",
    "public",
    "pulse",
    "pumps",
    "punish",
    "puny",
    "pupal",
    "purchase",
    "purple",
    "python",
    "quantity",
    "quarter",
    "quick",
    "quiet",
    "race",
    "racism",
    "radar",
    "railroad",
    "rainbow",
    "raisin",
    "random",
    "ranked",
    "rapids",
    "raspy",
    "reaction",
    "realize",
    "rebound",
    "rebuild",
    "recall",
    "receiver",
    "recover",
    "regret",
    "regular",
    "reject",
    "relate",
    "remember",
    "remind",
    "remove",
    "render",
    "repair",
    "repeat",
    "replace",
    "require",
    "rescue",
    "research",
    "resident",
    "response",
    "result",
    "retailer",
    "retreat",
    "reunion",
    "revenue",
    "review",
    "reward",
    "rhyme",
    "rhythm",
    "rich",
    "rival",
    "river",
    "robin",
    "rocky",
    "romantic",
    "romp",
    "roster",
    "round",
    "royal",
    "ruin",
    "ruler",
    "rumor",
    "sack",
    "safari",
    "salary",
    "salon",
    "salt",
    "satisfy",
    "satoshi",
    "saver",
    "says",
    "scandal",
    "scared",
    "scatter",
    "scene",
    "scholar",
    "science",
    "scout",
    "scramble",
    "screw",
    "script",
    "scroll",
    "seafood",
    "season",
    "secret",
    "security",
    "segment",
    "senior",
    "shadow",
    "shaft",
    "shame",
    "shaped",
    "sharp",
    "shelter",
    "sheriff",
    "short",
    "should",
    "shrimp",
    "sidewalk",
    "silent",
    "silver",
    "similar",
    "simple",
    "single",
    "sister",
    "skin",
    "skunk",
    "slap",
    "slavery",
    "sled",
    "slice",
    "slim",
    "slow",
    "slush",
    "smart",
    "smear",
    "smell",
    "smirk",
    "smith",
    "smoking",
    "smug",
    "snake",
    "snapshot",
    "sniff",
    "society",
    "software",
    "soldier",
    "solution",
    "soul",
    "source",
    "space",
    "spark",
    "speak",
    "species",
    "spelling",
    "spend",
    "spew",
    "spider",
    "spill",
    "spine",
    "spirit",
    "spit",
    "spray",
    "sprinkle",
    "square",
    "squeeze",
    "stadium",
    "staff",
    "standard",
    "starting",
    "station",
    "stay",
    "steady",
    "step",
    "stick",
    "stilt",
    "story",
    "strategy",
    "strike",
    "style",
    "subject",
    "submit",
    "sugar",
    "suitable",
    "sunlight",
    "superior",
    "surface",
    "surprise",
    "survive",
    "sweater",
    "swimming",
    "swing",
    "switch",
    "symbolic",
    "sympathy",
    "syndrome",
    "system",
    "tackle",
    "tactics",
    "tadpole",
    "talent",
    "task",
    "taste",
    "taught",
    "taxi",
    "teacher",
    "teammate",
    "teaspoon",
    "temple",
    "tenant",
    "tendency",
    "tension",
    "terminal",
    "testify",
    "texture",
    "thank",
    "that",
    "theater",
    "theory",
    "therapy",
    "thorn",
    "threaten",
    "thumb",
    "thunder",
    "ticket",
    "tidy",
    "timber",
    "timely",
    "ting",
    "tofu",
    "together",
    "tolerate",
    "total",
    "toxic",
    "tracks",
    "traffic",
    "training",
    "transfer",
    "trash",
    "traveler",
    "treat",
    "trend",
    "trial",
    "tricycle",
    "trip",
    "triumph",
    "trouble",
    "true",
    "trust",
    "twice",
    "twin",
    "type",
    "typical",
    "ugly",
    "ultimate",
    "umbrella",
    "uncover",
    "undergo",
    "unfair",
    "unfold",
    "unhappy",
    "union",
    "universe",
    "unkind",
    "unknown",
    "unusual",
    "unwrap",
    "upgrade",
    "upstairs",
    "username",
    "usher",
    "usual",
    "valid",
    "valuable",
    "vampire",
    "vanish",
    "various",
    "vegan",
    "velvet",
    "venture",
    "verdict",
    "verify",
    "very",
    "veteran",
    "vexed",
    "victim",
    "video",
    "view",
    "vintage",
    "violence",
    "viral",
    "visitor",
    "visual",
    "vitamins",
    "vocal",
    "voice",
    "volume",
    "voter",
    "voting",
    "walnut",
    "warmth",
    "warn",
    "watch",
    "wavy",
    "wealthy",
    "weapon",
    "webcam",
    "welcome",
    "welfare",
    "western",
    "width",
    "wildlife",
    "window",
    "wine",
    "wireless",
    "wisdom",
    "withdraw",
    "wits",
    "wolf",
    "woman",
    "work",
    "worthy",
    "wrap",
    "wrist",
    "writing",
    "wrote",
    "year",
    "yelp",
    "yield",
    "yoga",
    "zero",
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "wordlist size and ordering" {
    try testing.expectEqual(@as(usize, 1024), wordlist.len);
    // The spec requires the list to be alphabetically sorted with a unique
    // 4-letter prefix per word; both are load-bearing for lookupWord's binary
    // search and for human error detection.
    for (wordlist[1..], 1..) |word, i| {
        try testing.expect(mem.order(u8, wordlist[i - 1], word) == .lt);
        try testing.expect(word.len >= 4 and word.len <= 8);
        try testing.expect(!mem.eql(u8, wordlist[i - 1][0..4], word[0..4]));
    }
}

test "word lookup" {
    try testing.expectEqual(@as(u10, 0), try lookupWord("academic"));
    try testing.expectEqual(@as(u10, 1), try lookupWord("acid"));
    try testing.expectEqual(@as(u10, 1023), try lookupWord("zero"));
    // "satoshi" is at 1-based line 782 of the official wordlist.
    try testing.expectEqual(@as(u10, 781), try lookupWord("satoshi"));
    try testing.expectEqual(@as(u10, 781), try lookupWord("SaToShI"));
    try testing.expectError(Error.UnknownWord, lookupWord("notaword"));
    try testing.expectError(Error.UnknownWord, lookupWord(""));
}

test "GF(256) arithmetic matches AES field" {
    // FIPS-197 section 4.2 worked example.
    try testing.expectEqual(@as(u8, 0xC1), gfMul(0x57, 0x83));
    try testing.expectEqual(@as(u8, 0xFE), gfMul(0x57, 0x13));
    try testing.expectEqual(@as(u8, 0), gfMul(0, 0x83));
    try testing.expectEqual(@as(u8, 0x57), gfMul(0x57, 1));

    // Every non-zero element has an inverse, and division undoes it.
    var a: u16 = 1;
    while (a < 256) : (a += 1) {
        const x: u8 = @intCast(a);
        try testing.expectEqual(@as(u8, 1), gfMul(x, gfInv(x)));
        try testing.expectEqual(x, gfDiv(x, 1));
        try testing.expectEqual(@as(u8, 1), gfDiv(x, x));
    }
}

test "RS1024 checksum round-trips for both customization strings" {
    for ([_]bool{ false, true }) |extendable| {
        const data = [_]u10{ 0, 1, 2, 3, 4 };
        const checksum = createChecksum(&data, extendable);
        const full = [_]u10{ 0, 1, 2, 3, 4, checksum[0], checksum[1], checksum[2] };
        try testing.expect(verifyChecksum(&full, extendable));
        // The two customization strings must not accept each other's checksums,
        // otherwise an ext=0 share could be read as ext=1 and decrypt to a
        // different master secret.
        try testing.expect(!verifyChecksum(&full, !extendable));
    }
}

test "RS1024 detects single-word corruption everywhere in the mnemonic" {
    const data = [_]u10{ 512, 33, 7, 900, 1, 1023, 44, 88, 101, 202 };
    const checksum = createChecksum(&data, true);
    var full: [13]u10 = undefined;
    @memcpy(full[0..10], &data);
    @memcpy(full[10..], &checksum);

    for (0..full.len) |i| {
        const saved = full[i];
        full[i] = saved ^ 1;
        try testing.expect(!verifyChecksum(&full, true));
        full[i] = saved;
    }
    try testing.expect(verifyChecksum(&full, true));
}

test "mnemonic word/string roundtrip" {
    const allocator = testing.allocator;

    const original_words = [_]u10{ 0, 100, 200, 300, 400, 500, 600, 700, 800, 900 };
    const mnemonic = try wordsToMnemonic(allocator, &original_words);
    defer allocator.free(mnemonic);

    const parsed = try mnemonicToWords(allocator, mnemonic);
    defer allocator.free(parsed);

    try testing.expectEqualSlices(u10, &original_words, parsed);
}

test "share encode/decode roundtrip preserves every metadata field" {
    const allocator = testing.allocator;

    const value = [_]u8{
        0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
        0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF,
    };

    for ([_]bool{ false, true }) |extendable| {
        const original = Share{
            .identifier = 0x2AAA,
            .extendable = extendable,
            .iteration_exponent = 9,
            .group_index = 13,
            .group_threshold = 3,
            .group_count = 16,
            .member_index = 7,
            .member_threshold = 16,
            .value = @constCast(value[0..]),
        };

        const mnemonic = try original.toMnemonic(allocator);
        defer allocator.free(mnemonic);

        var decoded = try Share.fromMnemonic(allocator, mnemonic);
        defer decoded.deinit(allocator);

        try testing.expectEqual(original.identifier, decoded.identifier);
        try testing.expectEqual(original.extendable, decoded.extendable);
        try testing.expectEqual(original.iteration_exponent, decoded.iteration_exponent);
        try testing.expectEqual(original.group_index, decoded.group_index);
        try testing.expectEqual(original.group_threshold, decoded.group_threshold);
        try testing.expectEqual(original.group_count, decoded.group_count);
        try testing.expectEqual(original.member_index, decoded.member_index);
        try testing.expectEqual(original.member_threshold, decoded.member_threshold);
        try testing.expectEqualSlices(u8, value[0..], decoded.value);
    }
}

test "share value lengths whose padding is 8 bits round-trip" {
    // A 24-byte share value pads to 200 bits (padding = 8), the boundary case
    // the spec allows but a "padding = bits mod 8" reading gets wrong.
    const allocator = testing.allocator;
    var value: [24]u8 = undefined;
    for (&value, 0..) |*b, i| b.* = @intCast(i * 7 + 1);

    const original = Share{
        .identifier = 1,
        .extendable = true,
        .iteration_exponent = 1,
        .group_index = 0,
        .group_threshold = 1,
        .group_count = 1,
        .member_index = 0,
        .member_threshold = 1,
        .value = &value,
    };
    const words = try original.toWords(allocator);
    defer allocator.free(words);
    try testing.expectEqual(@as(usize, METADATA_WORDS + 20), words.len);

    var decoded = try Share.fromWords(allocator, words);
    defer decoded.deinit(allocator);
    try testing.expectEqualSlices(u8, &value, decoded.value);
}

test "decode rejects non-zero padding bits" {
    const allocator = testing.allocator;
    var value: [16]u8 = undefined;
    @memset(&value, 0xAB);
    const share = Share{
        .identifier = 1,
        .extendable = true,
        .iteration_exponent = 1,
        .group_index = 0,
        .group_threshold = 1,
        .group_count = 1,
        .member_index = 0,
        .member_threshold = 1,
        .value = &value,
    };
    const words = try share.toWords(allocator);
    defer allocator.free(words);

    // Set the topmost padding bit of the first value word, then re-checksum so
    // that padding — not the checksum — is what rejects the mnemonic.
    var tampered = try allocator.dupe(u10, words);
    defer allocator.free(tampered);
    tampered[ID_EXP_WORDS + SHARE_PARAMS_WORDS] |= 1 << 9;
    const fixed = createChecksum(tampered[0 .. tampered.len - CHECKSUM_WORDS], true);
    @memcpy(tampered[tampered.len - CHECKSUM_WORDS ..], &fixed);

    try testing.expectError(Error.InvalidPadding, Share.fromWords(allocator, tampered));
}

test "split/recover round-trips for every threshold and detects a tampered share" {
    const allocator = testing.allocator;
    const secret = "correct horse battery stap"; // 26 bytes, even, >= 128 bits

    var threshold: u8 = 1;
    while (threshold <= 5) : (threshold += 1) {
        const values = try splitSecret(allocator, threshold, 5, secret);
        defer freeRawValues(allocator, values);

        // Any `threshold` of the five shares recover the secret; use the last
        // ones, which are the interpolated rather than the random shares.
        var points: [5]RawShare = undefined;
        for (0..threshold) |i| {
            const idx = 5 - threshold + i;
            points[i] = .{ .x = @intCast(idx), .y = values[idx] };
        }
        const recovered = try recoverSecret(allocator, threshold, points[0..threshold]);
        defer allocator.free(recovered);
        try testing.expectEqualSlices(u8, secret, recovered);

        // Flipping a bit in a share must be caught by the digest, except at
        // threshold 1 where the spec stores no digest.
        if (threshold >= 2) {
            values[5 - threshold][0] ^= 0x01;
            try testing.expectError(
                Error.InvalidDigest,
                recoverSecret(allocator, threshold, points[0..threshold]),
            );
            values[5 - threshold][0] ^= 0x01;
        }
    }
}

test "interpolate rejects duplicate x-coordinates" {
    var y = [_]u8{0} ** 16;
    var out = [_]u8{0} ** 16;
    const points = [_]RawShare{
        .{ .x = 3, .y = &y },
        .{ .x = 3, .y = &y },
    };
    try testing.expectError(Error.DuplicateMemberIndex, interpolate(&out, &points, SECRET_INDEX));
}

test "Feistel encryption is invertible with and without a passphrase" {
    const allocator = testing.allocator;
    const master_secret = [_]u8{
        0xBB, 0x54, 0xAA, 0xC4, 0xB8, 0x9D, 0xC8, 0x68,
        0xBA, 0x37, 0xD9, 0xCC, 0x21, 0xB2, 0xCE, 0xCE,
    };

    for ([_][]const u8{ "", "TREZOR" }) |passphrase| {
        for ([_]bool{ false, true }) |extendable| {
            const ems = try encryptMasterSecret(allocator, &master_secret, passphrase, 0, 0x1234, extendable);
            defer allocator.free(ems);
            // The permutation must actually permute.
            try testing.expect(!mem.eql(u8, &master_secret, ems));

            const back = try decryptMasterSecret(allocator, ems, passphrase, 0, 0x1234, extendable);
            defer allocator.free(back);
            try testing.expectEqualSlices(u8, &master_secret, back);
        }
    }
}

test "ext=0 binds the identifier into the encryption salt" {
    const allocator = testing.allocator;
    const master_secret = [_]u8{0x42} ** 16;

    // With ext = 0 the id salts PBKDF2, so two ids give different ciphertexts.
    const a = try encryptMasterSecret(allocator, &master_secret, "", 0, 1, false);
    defer allocator.free(a);
    const b = try encryptMasterSecret(allocator, &master_secret, "", 0, 2, false);
    defer allocator.free(b);
    try testing.expect(!mem.eql(u8, a, b));

    // With ext = 1 the id is not used as salt, which is the whole point of the
    // extendable backup flag: the same EMS for any id.
    const c = try encryptMasterSecret(allocator, &master_secret, "", 0, 1, true);
    defer allocator.free(c);
    const d = try encryptMasterSecret(allocator, &master_secret, "", 0, 2, true);
    defer allocator.free(d);
    try testing.expectEqualSlices(u8, c, d);
}

test "generate/combine round-trip: single group, multiple thresholds" {
    const allocator = testing.allocator;
    const master_secret = [_]u8{
        0x0C, 0x94, 0x90, 0xE5, 0x7C, 0x6E, 0x39, 0x0F,
        0xEB, 0x1D, 0x87, 0x67, 0xB2, 0x2C, 0x6D, 0x8B,
    };

    const mnemonics = try generateMnemonics(allocator, &master_secret, .{
        .group_threshold = 1,
        .groups = &.{.{ .member_threshold = 3, .member_count = 5 }},
        .passphrase = "TREZOR",
        .iteration_exponent = 0,
    });
    defer freeMnemonics(allocator, mnemonics);
    try testing.expectEqual(@as(usize, 5), mnemonics.len);

    const subset = [_][]const u8{ mnemonics[4], mnemonics[1], mnemonics[2] };
    const recovered = try combineMnemonics(allocator, &subset, "TREZOR");
    defer allocator.free(recovered);
    try testing.expectEqualSlices(u8, &master_secret, recovered);

    // Two of three is below the threshold: the group is incomplete.
    const short = [_][]const u8{ mnemonics[4], mnemonics[1] };
    try testing.expectError(Error.WrongNumberOfShares, combineMnemonics(allocator, &short, "TREZOR"));

    // A wrong passphrase yields a different master secret rather than an error:
    // that is the specified plausible-deniability behaviour.
    const wrong = try combineMnemonics(allocator, &subset, "wrong");
    defer allocator.free(wrong);
    try testing.expect(!mem.eql(u8, &master_secret, wrong));
}

test "generate/combine round-trip: 2-of-3 groups with independent member thresholds" {
    const allocator = testing.allocator;
    const master_secret = [_]u8{
        0xB4, 0x3C, 0xEB, 0x7E, 0x57, 0xA0, 0xEA, 0x8A,
        0x6A, 0x2E, 0x39, 0x8B, 0x40, 0x1B, 0xE1, 0x11,
        0x6D, 0x5E, 0x8B, 0x00, 0x6D, 0x5E, 0x8B, 0x00,
        0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
    };

    const mnemonics = try generateMnemonics(allocator, &master_secret, .{
        .group_threshold = 2,
        .groups = &.{
            .{ .member_threshold = 1, .member_count = 1 },
            .{ .member_threshold = 3, .member_count = 5 },
            .{ .member_threshold = 2, .member_count = 3 },
        },
        .passphrase = "TREZOR",
        .iteration_exponent = 0,
    });
    defer freeMnemonics(allocator, mnemonics);
    try testing.expectEqual(@as(usize, 9), mnemonics.len);

    // Group 0 (1 share) + group 2 (2 of 3).
    const combo_a = [_][]const u8{ mnemonics[0], mnemonics[6], mnemonics[8] };
    const rec_a = try combineMnemonics(allocator, &combo_a, "TREZOR");
    defer allocator.free(rec_a);
    try testing.expectEqualSlices(u8, &master_secret, rec_a);

    // Group 1 (3 of 5) + group 2 (2 of 3).
    const combo_b = [_][]const u8{ mnemonics[1], mnemonics[3], mnemonics[5], mnemonics[7], mnemonics[6] };
    const rec_b = try combineMnemonics(allocator, &combo_b, "TREZOR");
    defer allocator.free(rec_b);
    try testing.expectEqualSlices(u8, &master_secret, rec_b);

    // One group alone is below the group threshold.
    const one_group = [_][]const u8{ mnemonics[1], mnemonics[2], mnemonics[3] };
    try testing.expectError(Error.WrongNumberOfGroups, combineMnemonics(allocator, &one_group, "TREZOR"));

    // All three groups is *more* than the group threshold, which the spec also
    // rejects (GM MUST equal GT).
    const three_groups = [_][]const u8{
        mnemonics[0], mnemonics[1], mnemonics[2], mnemonics[3], mnemonics[6], mnemonics[7],
    };
    try testing.expectError(Error.WrongNumberOfGroups, combineMnemonics(allocator, &three_groups, "TREZOR"));
}

test "generate rejects invalid configurations" {
    const allocator = testing.allocator;
    const ms = [_]u8{0x11} ** 16;
    const one_group = [_]GroupSpec{.{ .member_threshold = 1, .member_count = 1 }};

    // 1-of-N with N > 1 (spec: GenerateShares step 1).
    try testing.expectError(Error.ThresholdOneWithMultipleMembers, generateShares(allocator, &ms, .{
        .group_threshold = 1,
        .groups = &.{.{ .member_threshold = 1, .member_count = 3 }},
    }));
    // Group threshold above the group count.
    try testing.expectError(Error.InvalidGroupConfiguration, generateShares(allocator, &ms, .{
        .group_threshold = 2,
        .groups = &one_group,
    }));
    // Master secret below 128 bits.
    const short = [_]u8{0x11} ** 14;
    try testing.expectError(Error.InvalidMasterSecretLength, generateShares(allocator, &short, .{
        .group_threshold = 1,
        .groups = &one_group,
    }));
    // Master secret with an odd byte length.
    const odd = [_]u8{0x11} ** 17;
    try testing.expectError(Error.InvalidMasterSecretLength, generateShares(allocator, &odd, .{
        .group_threshold = 1,
        .groups = &one_group,
    }));
    // Non-printable passphrase byte.
    try testing.expectError(Error.InvalidPassphrase, generateShares(allocator, &ms, .{
        .group_threshold = 1,
        .groups = &one_group,
        .passphrase = "bad\x00passphrase",
    }));
}

test "combine rejects a share set assembled from two different splits" {
    const allocator = testing.allocator;
    const ms = [_]u8{0x5A} ** 16;
    const opts = GenerateOptions{
        .group_threshold = 1,
        .groups = &.{.{ .member_threshold = 2, .member_count = 3 }},
        .iteration_exponent = 0,
        // A fixed identifier makes the two sets agree on every metadata field,
        // so only the digest can catch the mix — the dangerous case.
        .identifier = 0x1234,
    };

    const set_a = try generateMnemonics(allocator, &ms, opts);
    defer freeMnemonics(allocator, set_a);
    const set_b = try generateMnemonics(allocator, &ms, opts);
    defer freeMnemonics(allocator, set_b);

    const mixed = [_][]const u8{ set_a[0], set_b[1] };
    try testing.expectError(Error.InvalidDigest, combineMnemonics(allocator, &mixed, ""));
}

test "combine folds exact duplicate mnemonics and rejects conflicting ones" {
    const allocator = testing.allocator;
    const ms = [_]u8{0x77} ** 16;
    const mnemonics = try generateMnemonics(allocator, &ms, .{
        .group_threshold = 1,
        .groups = &.{.{ .member_threshold = 2, .member_count = 3 }},
        .iteration_exponent = 0,
    });
    defer freeMnemonics(allocator, mnemonics);

    // The same mnemonic pasted twice alongside a distinct one still recovers,
    // matching the reference implementation's set semantics.
    const with_dup = [_][]const u8{ mnemonics[0], mnemonics[0], mnemonics[1] };
    const recovered = try combineMnemonics(allocator, &with_dup, "");
    defer allocator.free(recovered);
    try testing.expectEqualSlices(u8, &ms, recovered);

    // A duplicate index carrying a *different* value is an inconsistent set.
    var forged = try Share.fromMnemonic(allocator, mnemonics[0]);
    defer forged.deinit(allocator);
    forged.value[0] ^= 0xFF;
    const forged_mnemonic = try forged.toMnemonic(allocator);
    defer allocator.free(forged_mnemonic);

    const conflicting = [_][]const u8{ mnemonics[0], forged_mnemonic };
    try testing.expectError(Error.DuplicateMemberIndex, combineMnemonics(allocator, &conflicting, ""));
}

test "256-bit master secret round-trips through 33-word mnemonics" {
    const allocator = testing.allocator;
    var ms: [32]u8 = undefined;
    for (&ms, 0..) |*b, i| b.* = @intCast(i * 5 + 3);

    const mnemonics = try generateMnemonics(allocator, &ms, .{
        .group_threshold = 1,
        .groups = &.{.{ .member_threshold = 2, .member_count = 2 }},
        .iteration_exponent = 0,
    });
    defer freeMnemonics(allocator, mnemonics);

    // Spec table: 256-bit security is a 330-bit / 33-word share.
    const words = try mnemonicToWords(allocator, mnemonics[0]);
    defer allocator.free(words);
    try testing.expectEqual(@as(usize, 33), words.len);

    const recovered = try combineMnemonics(allocator, mnemonics, "");
    defer allocator.free(recovered);
    try testing.expectEqualSlices(u8, &ms, recovered);
}
