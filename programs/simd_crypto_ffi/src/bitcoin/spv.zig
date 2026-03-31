const std = @import("std");
const crypto = std.crypto;
const Sha256 = crypto.hash.sha2.Sha256;

// =============================================================================
// SPV (Simplified Payment Verification) Implementation
// =============================================================================
//
// This module implements Bitcoin SPV verification as described in the
// Bitcoin whitepaper Section 8. It allows verification that a transaction
// is included in a block without downloading the entire blockchain.
//
// Key Operations:
// 1. Merkle Proof Verification - Prove tx inclusion in block
// 2. Block Header Validation - Verify header chain linkage
// 3. Proof of Work Verification - Validate difficulty target
//
// =============================================================================

/// Standard Hash Size for Bitcoin
pub const HASH_SIZE = 32;
pub const Hash = [HASH_SIZE]u8;

/// Maximum depth of Merkle tree (2^32 transactions)
pub const MAX_MERKLE_DEPTH = 32;

// =============================================================================
// CORE CRYPTOGRAPHIC PRIMITIVES
// =============================================================================

/// Performs the standard Double SHA-256 hash: SHA256(SHA256(data))
/// This is used throughout Bitcoin for block hashes, tx hashes, and Merkle nodes.
pub fn hashDoubleSha256(data: []const u8) Hash {
    var round1: Hash = undefined;
    var round2: Hash = undefined;

    Sha256.hash(data, &round1, .{});
    Sha256.hash(&round1, &round2, .{});
    return round2;
}

/// Concatenates two hashes and performs Double SHA-256
/// Used for computing Merkle tree internal nodes
pub fn hashPair(left: Hash, right: Hash) Hash {
    var buffer: [64]u8 = undefined;
    @memcpy(buffer[0..32], &left);
    @memcpy(buffer[32..64], &right);
    return hashDoubleSha256(&buffer);
}

/// Reverse a hash in-place (for display format conversion)
/// Bitcoin displays hashes in big-endian but stores in little-endian
pub fn reverseHash(hash: *Hash) void {
    var i: usize = 0;
    while (i < HASH_SIZE / 2) : (i += 1) {
        const tmp = hash[i];
        hash[i] = hash[HASH_SIZE - 1 - i];
        hash[HASH_SIZE - 1 - i] = tmp;
    }
}

// =============================================================================
// DATA STRUCTURES
// =============================================================================

/// Bitcoin Block Header (80 bytes)
/// All multi-byte fields are little-endian in serialized form
pub const BlockHeader = struct {
    /// Block version (currently 0x20000000 for most blocks)
    version: i32,
    /// Hash of the previous block header
    prev_block_hash: Hash,
    /// Root of the Merkle tree of transactions
    merkle_root: Hash,
    /// Unix timestamp (seconds since epoch)
    timestamp: u32,
    /// Compact difficulty target (nBits)
    bits: u32,
    /// Nonce used to achieve required difficulty
    nonce: u32,

    /// Serialize the header to 80 bytes for hashing
    pub fn serialize(self: BlockHeader) [80]u8 {
        var buf: [80]u8 = undefined;
        std.mem.writeInt(i32, buf[0..4], self.version, .little);
        @memcpy(buf[4..36], &self.prev_block_hash);
        @memcpy(buf[36..68], &self.merkle_root);
        std.mem.writeInt(u32, buf[68..72], self.timestamp, .little);
        std.mem.writeInt(u32, buf[72..76], self.bits, .little);
        std.mem.writeInt(u32, buf[76..80], self.nonce, .little);
        return buf;
    }

    /// Deserialize 80 bytes into a BlockHeader
    pub fn deserialize(data: *const [80]u8) BlockHeader {
        return BlockHeader{
            .version = std.mem.readInt(i32, data[0..4], .little),
            .prev_block_hash = data[4..36].*,
            .merkle_root = data[36..68].*,
            .timestamp = std.mem.readInt(u32, data[68..72], .little),
            .bits = std.mem.readInt(u32, data[72..76], .little),
            .nonce = std.mem.readInt(u32, data[76..80], .little),
        };
    }

    /// Calculate the hash of this block (Block ID)
    /// Returns hash in internal byte order (little-endian)
    pub fn getHash(self: BlockHeader) Hash {
        const bytes = self.serialize();
        return hashDoubleSha256(&bytes);
    }

    /// Calculate block hash and return in display format (big-endian)
    pub fn getHashDisplay(self: BlockHeader) Hash {
        var hash = self.getHash();
        reverseHash(&hash);
        return hash;
    }
};

/// Merkle Proof for SPV verification
pub const MerkleProof = struct {
    /// The hashes forming the path from leaf to root
    hashes: []const Hash,
    /// The index of the transaction in the block
    /// Used to determine left/right ordering at each level
    index: u32,
};

// =============================================================================
// PROOF OF WORK VERIFICATION
// =============================================================================

/// Decode compact "bits" format to 256-bit target
/// Format: 0xAABBBBBB where AA is exponent, BBBBBB is mantissa
/// Target = mantissa * 2^(8*(exponent-3))
pub fn decodeCompactTarget(bits: u32) Hash {
    var target: Hash = [_]u8{0} ** 32;

    const exponent = @as(u8, @truncate(bits >> 24));
    const mantissa = bits & 0x007fffff;

    // Handle edge cases
    if (exponent == 0) return target;
    if (exponent > 32) return target; // Invalid

    // Calculate position - mantissa goes at position (exponent - 3)
    // But stored in little-endian, so we need to reverse thinking
    const byte_pos: usize = if (exponent >= 3) exponent - 3 else 0;

    if (byte_pos < 32) {
        // Write mantissa bytes (big-endian within the mantissa)
        if (byte_pos + 2 < 32) target[byte_pos + 2] = @truncate(mantissa & 0xff);
        if (byte_pos + 1 < 32) target[byte_pos + 1] = @truncate((mantissa >> 8) & 0xff);
        if (byte_pos < 32) target[byte_pos] = @truncate((mantissa >> 16) & 0xff);
    }

    return target;
}

/// Compare two 256-bit numbers (as little-endian byte arrays)
/// Returns: -1 if a < b, 0 if a == b, 1 if a > b
pub fn compareHash(a: Hash, b: Hash) i32 {
    // Compare from most significant byte (end of array for little-endian)
    var i: usize = 31;
    while (true) : (i -= 1) {
        if (a[i] < b[i]) return -1;
        if (a[i] > b[i]) return 1;
        if (i == 0) break;
    }
    return 0;
}

/// Verify that a block hash meets the difficulty target
/// Returns true if hash <= target (valid proof of work)
pub fn verifyProofOfWork(header: BlockHeader) bool {
    const hash = header.getHash();
    const target = decodeCompactTarget(header.bits);

    // Hash must be <= target for valid PoW
    return compareHash(hash, target) <= 0;
}

/// Calculate the difficulty from compact bits
/// Difficulty = max_target / current_target
/// Returns difficulty as a u64 (truncated for simplicity)
pub fn calculateDifficulty(bits: u32) u64 {
    const target = decodeCompactTarget(bits);

    // Max target for difficulty 1 (0x1d00ffff)
    const max_bits: u32 = 0x1d00ffff;
    const max_target = decodeCompactTarget(max_bits);

    // Simple difficulty calculation - count leading zeros difference
    // This is an approximation; full calculation requires big integer division
    var target_zeros: u32 = 0;
    var max_zeros: u32 = 0;

    var i: usize = 31;
    while (i > 0) : (i -= 1) {
        if (target[i] == 0) {
            target_zeros += 8;
        } else {
            target_zeros += @clz(target[i]);
            break;
        }
    }

    i = 31;
    while (i > 0) : (i -= 1) {
        if (max_target[i] == 0) {
            max_zeros += 8;
        } else {
            max_zeros += @clz(max_target[i]);
            break;
        }
    }

    // Approximate difficulty as 2^(target_zeros - max_zeros)
    if (target_zeros > max_zeros) {
        const shift = target_zeros - max_zeros;
        if (shift >= 64) return std.math.maxInt(u64);
        return @as(u64, 1) << @intCast(shift);
    }
    return 1;
}

// =============================================================================
// VERIFICATION LOGIC
// =============================================================================

/// SPV Verification Errors
pub const SpvError = error{
    /// Block header doesn't link to expected previous block
    BrokenChain,
    /// Transaction not found in Merkle tree
    InvalidMerkleProof,
    /// Block hash doesn't meet difficulty target
    InsufficientWork,
    /// Merkle proof depth exceeds maximum
    ProofTooDeep,
    /// Invalid block header data
    InvalidHeader,
    /// Timestamp validation failed
    InvalidTimestamp,
};

/// Verify that a transaction hash is part of the Merkle tree
/// This proves the transaction was included in the block
pub fn verifyMerkleProof(tx_hash: Hash, root: Hash, proof: MerkleProof) bool {
    // Sanity check on proof depth
    if (proof.hashes.len > MAX_MERKLE_DEPTH) return false;

    var current_hash = tx_hash;
    var current_index = proof.index;

    for (proof.hashes) |proof_element| {
        // If current index is even, we're on the LEFT, proof element is RIGHT
        // If current index is odd, we're on the RIGHT, proof element is LEFT
        if ((current_index & 1) == 0) {
            current_hash = hashPair(current_hash, proof_element);
        } else {
            current_hash = hashPair(proof_element, current_hash);
        }
        // Move up the tree
        current_index >>= 1;
    }

    return std.mem.eql(u8, &current_hash, &root);
}

/// Verify that a block header correctly links to the previous block
pub fn verifyHeaderLinkage(current: BlockHeader, prev_header_hash: Hash) SpvError!void {
    if (!std.mem.eql(u8, &current.prev_block_hash, &prev_header_hash)) {
        return SpvError.BrokenChain;
    }
}

/// Verify block header with proof of work check
pub fn verifyHeader(header: BlockHeader, prev_header_hash: Hash) SpvError!void {
    // 1. Verify linkage to previous block
    try verifyHeaderLinkage(header, prev_header_hash);

    // 2. Verify proof of work
    if (!verifyProofOfWork(header)) {
        return SpvError.InsufficientWork;
    }
}

/// Full SPV Payment Verification
/// Verifies that a transaction is included in a valid block
pub fn verifyPayment(
    tx_hash: Hash,
    proof: MerkleProof,
    header: BlockHeader,
    trusted_prev_hash: Hash,
    check_pow: bool,
) SpvError!void {
    // A. Verify the header belongs to the chain we trust
    try verifyHeaderLinkage(header, trusted_prev_hash);

    // B. Optionally verify proof of work
    if (check_pow and !verifyProofOfWork(header)) {
        return SpvError.InsufficientWork;
    }

    // C. Verify the transaction exists within that header's Merkle Root
    if (!verifyMerkleProof(tx_hash, header.merkle_root, proof)) {
        return SpvError.InvalidMerkleProof;
    }
}

/// Verify a chain of block headers
/// Returns the cumulative work (sum of difficulties) if valid
pub fn verifyHeaderChain(headers: []const BlockHeader, genesis_hash: Hash, check_pow: bool) SpvError!u64 {
    if (headers.len == 0) return 0;

    var prev_hash = genesis_hash;
    var cumulative_work: u64 = 0;

    for (headers) |header| {
        // Verify linkage
        try verifyHeaderLinkage(header, prev_hash);

        // Verify PoW if requested
        if (check_pow and !verifyProofOfWork(header)) {
            return SpvError.InsufficientWork;
        }

        // Accumulate work
        cumulative_work +|= calculateDifficulty(header.bits);

        // Update previous hash for next iteration
        prev_hash = header.getHash();
    }

    return cumulative_work;
}

// =============================================================================
// TESTS
// =============================================================================

test "Double SHA-256" {
    const data = "hello";
    const hash = hashDoubleSha256(data);

    // Verify it's not all zeros
    var all_zero = true;
    for (hash) |b| {
        if (b != 0) {
            all_zero = false;
            break;
        }
    }
    try std.testing.expect(!all_zero);
}

test "Hash Pair" {
    const left = [_]u8{0xAA} ** 32;
    const right = [_]u8{0xBB} ** 32;

    const result = hashPair(left, right);

    // Result should be different from inputs
    try std.testing.expect(!std.mem.eql(u8, &result, &left));
    try std.testing.expect(!std.mem.eql(u8, &result, &right));
}

test "Block Header Serialization Roundtrip" {
    const header = BlockHeader{
        .version = 0x20000000,
        .prev_block_hash = [_]u8{0x11} ** 32,
        .merkle_root = [_]u8{0x22} ** 32,
        .timestamp = 1600000000,
        .bits = 0x1d00ffff,
        .nonce = 12345,
    };

    const serialized = header.serialize();
    const deserialized = BlockHeader.deserialize(&serialized);

    try std.testing.expectEqual(header.version, deserialized.version);
    try std.testing.expectEqual(header.timestamp, deserialized.timestamp);
    try std.testing.expectEqual(header.bits, deserialized.bits);
    try std.testing.expectEqual(header.nonce, deserialized.nonce);
    try std.testing.expectEqualSlices(u8, &header.prev_block_hash, &deserialized.prev_block_hash);
    try std.testing.expectEqualSlices(u8, &header.merkle_root, &deserialized.merkle_root);
}

test "Merkle Proof Verification - Valid" {
    // Build a simple Merkle tree:
    //       Root
    //      /    \
    //     H1    H2
    //    / \
    //  TX  PA
    const tx_hash = hashDoubleSha256("Transaction Data");
    const sibling_a = hashDoubleSha256("Sibling A");
    const sibling_b = hashDoubleSha256("Sibling B");

    // Calculate expected root
    const h1 = hashPair(tx_hash, sibling_a);
    const root = hashPair(h1, sibling_b);

    const proof_hashes = [_]Hash{ sibling_a, sibling_b };
    const proof = MerkleProof{
        .hashes = &proof_hashes,
        .index = 0, // TX is at index 0 (leftmost)
    };

    try std.testing.expect(verifyMerkleProof(tx_hash, root, proof));
}

test "Merkle Proof Verification - Invalid" {
    const tx_hash = [_]u8{1} ** 32;
    const root = [_]u8{2} ** 32;
    const fake_hashes = [_]Hash{[_]u8{3} ** 32};

    const proof = MerkleProof{
        .hashes = &fake_hashes,
        .index = 0,
    };

    try std.testing.expect(!verifyMerkleProof(tx_hash, root, proof));
}

test "Merkle Proof - Right Child" {
    // TX at index 1 (right child)
    const tx_hash = hashDoubleSha256("Right Transaction");
    const sibling = hashDoubleSha256("Left Sibling");

    // For index 1, sibling is on LEFT
    const root = hashPair(sibling, tx_hash);

    const proof_hashes = [_]Hash{sibling};
    const proof = MerkleProof{
        .hashes = &proof_hashes,
        .index = 1, // TX is right child
    };

    try std.testing.expect(verifyMerkleProof(tx_hash, root, proof));
}

test "Header Linkage - Valid" {
    const prev_hash = [_]u8{0xAA} ** 32;
    const header = BlockHeader{
        .version = 1,
        .prev_block_hash = prev_hash,
        .merkle_root = [_]u8{0} ** 32,
        .timestamp = 0,
        .bits = 0x1d00ffff,
        .nonce = 0,
    };

    try verifyHeaderLinkage(header, prev_hash);
}

test "Header Linkage - Broken Chain" {
    const prev_hash = [_]u8{0xAA} ** 32;
    const wrong_hash = [_]u8{0xBB} ** 32;
    const header = BlockHeader{
        .version = 1,
        .prev_block_hash = wrong_hash,
        .merkle_root = [_]u8{0} ** 32,
        .timestamp = 0,
        .bits = 0x1d00ffff,
        .nonce = 0,
    };

    try std.testing.expectError(SpvError.BrokenChain, verifyHeaderLinkage(header, prev_hash));
}

test "Compact Target Decode" {
    // Difficulty 1 target: 0x1d00ffff
    const target = decodeCompactTarget(0x1d00ffff);

    // Should have non-zero bytes
    var has_nonzero = false;
    for (target) |b| {
        if (b != 0) {
            has_nonzero = true;
            break;
        }
    }
    try std.testing.expect(has_nonzero);
}

test "SPV Full Verification" {
    // Build test data
    const tx_hash = hashDoubleSha256("Payment: 1 BTC");
    const sibling = hashDoubleSha256("Other TX");
    const merkle_root = hashPair(tx_hash, sibling);
    const prev_hash = [_]u8{0x00} ** 32;

    const header = BlockHeader{
        .version = 1,
        .prev_block_hash = prev_hash,
        .merkle_root = merkle_root,
        .timestamp = 1600000000,
        .bits = 0x1d00ffff,
        .nonce = 0,
    };

    const proof_hashes = [_]Hash{sibling};
    const proof = MerkleProof{
        .hashes = &proof_hashes,
        .index = 0,
    };

    // Verify without PoW check (our test header won't have valid PoW)
    try verifyPayment(tx_hash, proof, header, prev_hash, false);
}

test "Hash Comparison" {
    const smaller = [_]u8{0x00} ** 31 ++ [_]u8{0x01};
    const larger = [_]u8{0x00} ** 31 ++ [_]u8{0x02};
    const equal = [_]u8{0x00} ** 31 ++ [_]u8{0x01};

    try std.testing.expectEqual(@as(i32, -1), compareHash(smaller, larger));
    try std.testing.expectEqual(@as(i32, 1), compareHash(larger, smaller));
    try std.testing.expectEqual(@as(i32, 0), compareHash(smaller, equal));
}
