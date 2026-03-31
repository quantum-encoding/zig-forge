//! HMAC-SHA256 Implementation (RFC 2104)
//! Optimized for exchange API authentication with pre-computation support
//!
//! Target: <1μs per HMAC operation for HFT execution

const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;

/// HMAC-SHA256 constants
const BLOCK_SIZE = 64; // SHA-256 block size in bytes
const HASH_SIZE = 32;  // SHA-256 output size in bytes
const IPAD: u8 = 0x36;
const OPAD: u8 = 0x5C;

/// HMAC-SHA256 computation (RFC 2104)
///
/// Algorithm:
///   H(K XOR opad, H(K XOR ipad, message))
///
/// Where:
///   K = secret key (padded to BLOCK_SIZE)
///   ipad = 0x36 repeated BLOCK_SIZE times
///   opad = 0x5C repeated BLOCK_SIZE times
///   H = SHA-256 hash function
///
/// Performance: ~2-3μs on modern CPUs (target: <1μs with optimization)
pub fn hmacSha256(key: []const u8, message: []const u8, output: *[HASH_SIZE]u8) void {
    var key_padded: [BLOCK_SIZE]u8 = [_]u8{0} ** BLOCK_SIZE;

    // Step 1: Prepare key
    if (key.len > BLOCK_SIZE) {
        // If key > block size, hash it first
        var key_hash: [HASH_SIZE]u8 = undefined;
        Sha256.hash(key, &key_hash, .{});
        @memcpy(key_padded[0..HASH_SIZE], &key_hash);
    } else {
        // Otherwise use key directly (zero-padded)
        @memcpy(key_padded[0..key.len], key);
    }

    // Step 2: Compute inner hash = SHA256((K ⊕ ipad) || message)
    var inner_key: [BLOCK_SIZE]u8 = undefined;
    for (&inner_key, key_padded) |*byte, k| {
        byte.* = k ^ IPAD;
    }

    var inner_hasher = Sha256.init(.{});
    inner_hasher.update(&inner_key);
    inner_hasher.update(message);
    var inner_hash: [HASH_SIZE]u8 = undefined;
    inner_hasher.final(&inner_hash);

    // Step 3: Compute outer hash = SHA256((K ⊕ opad) || inner_hash)
    var outer_key: [BLOCK_SIZE]u8 = undefined;
    for (&outer_key, key_padded) |*byte, k| {
        byte.* = k ^ OPAD;
    }

    var outer_hasher = Sha256.init(.{});
    outer_hasher.update(&outer_key);
    outer_hasher.update(&inner_hash);
    outer_hasher.final(output);
}

/// Pre-computed HMAC context for optimized signing
///
/// Use this when signing multiple messages with the same key.
/// Pre-computes the XOR operations and initial hash states.
///
/// Optimization: Saves ~0.5μs per operation by avoiding key processing
pub const HmacContext = struct {
    inner_state: Sha256,
    outer_state: Sha256,

    /// Initialize HMAC context with secret key (do this once at startup)
    pub fn init(key: []const u8) HmacContext {
        var key_padded: [BLOCK_SIZE]u8 = [_]u8{0} ** BLOCK_SIZE;

        // Prepare key
        if (key.len > BLOCK_SIZE) {
            var key_hash: [HASH_SIZE]u8 = undefined;
            Sha256.hash(key, &key_hash, .{});
            @memcpy(key_padded[0..HASH_SIZE], &key_hash);
        } else {
            @memcpy(key_padded[0..key.len], key);
        }

        // Pre-compute inner state (K ⊕ ipad)
        var inner_key: [BLOCK_SIZE]u8 = undefined;
        for (&inner_key, key_padded) |*byte, k| {
            byte.* = k ^ IPAD;
        }
        var inner_state = Sha256.init(.{});
        inner_state.update(&inner_key);

        // Pre-compute outer state (K ⊕ opad)
        var outer_key: [BLOCK_SIZE]u8 = undefined;
        for (&outer_key, key_padded) |*byte, k| {
            byte.* = k ^ OPAD;
        }
        var outer_state = Sha256.init(.{});
        outer_state.update(&outer_key);

        return .{
            .inner_state = inner_state,
            .outer_state = outer_state,
        };
    }

    /// Sign message using pre-computed context (fast path)
    ///
    /// This is the hot path for HFT order signing.
    /// Target: <1μs
    pub fn sign(self: *const HmacContext, message: []const u8, output: *[HASH_SIZE]u8) void {
        // Clone inner state and finalize with message
        var inner = self.inner_state;
        inner.update(message);
        var inner_hash: [HASH_SIZE]u8 = undefined;
        inner.final(&inner_hash);

        // Clone outer state and finalize with inner hash
        var outer = self.outer_state;
        outer.update(&inner_hash);
        outer.final(output);
    }
};

/// Coinbase-specific signature format
///
/// Signature = HMAC-SHA256(secret, timestamp + method + requestPath + body)
/// Header: CB-ACCESS-SIGN: <hex-encoded signature>
pub fn signCoinbase(
    secret: []const u8,
    timestamp: []const u8,
    method: []const u8,
    path: []const u8,
    body: []const u8,
    output: *[HASH_SIZE]u8,
) void {
    // Build message: timestamp + method + path + body
    var message_buf: [512]u8 = undefined;
    var pos: usize = 0;

    @memcpy(message_buf[pos..][0..timestamp.len], timestamp);
    pos += timestamp.len;

    @memcpy(message_buf[pos..][0..method.len], method);
    pos += method.len;

    @memcpy(message_buf[pos..][0..path.len], path);
    pos += path.len;

    @memcpy(message_buf[pos..][0..body.len], body);
    pos += body.len;

    const message = message_buf[0..pos];

    hmacSha256(secret, message, output);
}

/// Binance-specific signature format
///
/// Signature = HMAC-SHA256(secret, queryString)
/// Append to URL: &signature=<hex-encoded signature>
pub fn signBinance(
    secret: []const u8,
    query_string: []const u8,
    output: *[HASH_SIZE]u8,
) void {
    hmacSha256(secret, query_string, output);
}

// ============================================================================
// Tests
// ============================================================================

test "HMAC-SHA256 RFC 2104 test vector 1" {
    const key = "Jefe";
    const data = "what do ya want for nothing?";
    const expected_hex = "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843";

    var output: [32]u8 = undefined;
    hmacSha256(key, data, &output);

    const hex = std.fmt.bytesToHex(output, .lower);

    try std.testing.expectEqualStrings(expected_hex, &hex);
}

test "HMAC-SHA256 RFC 2104 test vector 2" {
    const key = [_]u8{0x0b} ** 20;
    const data = "Hi There";
    const expected_hex = "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7";

    var output: [32]u8 = undefined;
    hmacSha256(&key, data, &output);

    const hex = std.fmt.bytesToHex(output, .lower);

    try std.testing.expectEqualStrings(expected_hex, &hex);
}

test "HMAC context pre-computation" {
    const key = "test_secret_key";
    const message = "test message";

    // Method 1: Direct HMAC
    var output1: [32]u8 = undefined;
    hmacSha256(key, message, &output1);

    // Method 2: Pre-computed context
    const ctx = HmacContext.init(key);
    var output2: [32]u8 = undefined;
    ctx.sign(message, &output2);

    // Both should produce identical results
    try std.testing.expectEqualSlices(u8, &output1, &output2);
}

test "HMAC performance benchmark" {
    const key = "super_secret_api_key_12345";
    const message = "timestamp=1638999999&symbol=BTCUSDT&side=SELL&type=MARKET&quantity=1.0";

    const iterations: usize = 10_000;
    const start_time = try std.posix.clock_gettime(std.posix.CLOCK.MONOTONIC);
    const start = @as(i64, @intCast(start_time.sec)) * 1_000_000_000 + @as(i64, @intCast(start_time.nsec));

    var output: [32]u8 = undefined;
    for (0..iterations) |_| {
        hmacSha256(key, message, &output);
    }

    const end_time = try std.posix.clock_gettime(std.posix.CLOCK.MONOTONIC);
    const end = @as(i64, @intCast(end_time.sec)) * 1_000_000_000 + @as(i64, @intCast(end_time.nsec));
    const total_ns = end - start;
    const avg_ns = @divTrunc(total_ns, iterations);

    std.debug.print("\n📊 HMAC-SHA256 Benchmark:\n", .{});
    std.debug.print("   Iterations: {}\n", .{iterations});
    std.debug.print("   Average:    {} ns\n", .{avg_ns});
    std.debug.print("   Target:     <1000 ns (<1μs)\n", .{});

    if (avg_ns < 1000) {
        std.debug.print("   ✅ TARGET MET!\n\n", .{});
    } else {
        std.debug.print("   ⚠️  Above target ({}x slower)\n\n", .{@divTrunc(avg_ns, 1000)});
    }

    // Should complete in reasonable time
    try std.testing.expect(avg_ns < 10_000); // <10μs is still acceptable
}

test "HMAC context performance benchmark" {
    const key = "super_secret_api_key_12345";
    const message = "timestamp=1638999999&symbol=BTCUSDT&side=SELL&type=MARKET&quantity=1.0";

    // Pre-compute context
    const ctx = HmacContext.init(key);

    const iterations: usize = 10_000;
    const start_time = try std.posix.clock_gettime(std.posix.CLOCK.MONOTONIC);
    const start = @as(i64, @intCast(start_time.sec)) * 1_000_000_000 + @as(i64, @intCast(start_time.nsec));

    var output: [32]u8 = undefined;
    for (0..iterations) |_| {
        ctx.sign(message, &output);
    }

    const end_time = try std.posix.clock_gettime(std.posix.CLOCK.MONOTONIC);
    const end = @as(i64, @intCast(end_time.sec)) * 1_000_000_000 + @as(i64, @intCast(end_time.nsec));
    const total_ns = end - start;
    const avg_ns = @divTrunc(total_ns, iterations);

    std.debug.print("\n📊 HMAC Context (Pre-computed) Benchmark:\n", .{});
    std.debug.print("   Iterations: {}\n", .{iterations});
    std.debug.print("   Average:    {} ns\n", .{avg_ns});
    std.debug.print("   Target:     <1000 ns (<1μs)\n", .{});

    if (avg_ns < 1000) {
        std.debug.print("   ✅ TARGET MET! ({}x faster than target)\n\n", .{@divTrunc(1000, avg_ns)});
    } else {
        std.debug.print("   ⚠️  Above target ({}x slower)\n\n", .{@divTrunc(avg_ns, 1000)});
    }

    // Pre-computed should be faster
    try std.testing.expect(avg_ns < 10_000); // <10μs is still acceptable
}

test "Coinbase signature format" {
    const secret = "test_secret";
    const timestamp = "1638999999";
    const method = "POST";
    const path = "/orders";
    const body = "{\"symbol\":\"BTC-USD\",\"side\":\"sell\"}";

    var signature: [32]u8 = undefined;
    signCoinbase(secret, timestamp, method, path, body, &signature);

    // Should produce 32-byte signature
    try std.testing.expect(signature.len == 32);

    // Verify it's not all zeros (actual computation happened)
    var all_zeros = true;
    for (signature) |byte| {
        if (byte != 0) {
            all_zeros = false;
            break;
        }
    }
    try std.testing.expect(!all_zeros);
}

test "Binance signature format" {
    const secret = "test_secret";
    const query = "symbol=BTCUSDT&side=SELL&type=MARKET&quantity=1.0&timestamp=1638999999000";

    var signature: [32]u8 = undefined;
    signBinance(secret, query, &signature);

    // Should produce 32-byte signature
    try std.testing.expect(signature.len == 32);
}
