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
/// Signature = HMAC-SHA256(secret, timestamp || method || requestPath || body)
/// Header: CB-ACCESS-SIGN: <hex-encoded signature>
///
/// Streams the four segments directly into the inner SHA-256 hasher.
/// The previous implementation concatenated them into a 512-byte fixed
/// stack buffer first, which was a stack-overflow vector: an attacker-
/// influenced `body` longer than ~512 - (timestamp+method+path) would
/// scribble past the buffer with a wraparound @memcpy. Streaming removes
/// the buffer entirely, so the only ceiling is the i32-bit length cap
/// inside SHA-256 itself (2^32 bytes — far above any plausible request
/// body), and there's no longer a stack allocation that scales with
/// caller-supplied data.
pub fn signCoinbase(
    secret: []const u8,
    timestamp: []const u8,
    method: []const u8,
    path: []const u8,
    body: []const u8,
    output: *[HASH_SIZE]u8,
) void {
    // Prepare K': pad/hash the key to BLOCK_SIZE the same way as
    // hmacSha256 does internally. We can't call hmacSha256 directly
    // because its API takes a single contiguous message slice.
    var key_padded: [BLOCK_SIZE]u8 = [_]u8{0} ** BLOCK_SIZE;
    if (secret.len > BLOCK_SIZE) {
        var key_hash: [HASH_SIZE]u8 = undefined;
        Sha256.hash(secret, &key_hash, .{});
        @memcpy(key_padded[0..HASH_SIZE], &key_hash);
    } else {
        @memcpy(key_padded[0..secret.len], secret);
    }

    // Inner = SHA256((K' ⊕ ipad) || timestamp || method || path || body)
    var inner_key: [BLOCK_SIZE]u8 = undefined;
    for (&inner_key, key_padded) |*b, k| b.* = k ^ IPAD;

    var inner = Sha256.init(.{});
    inner.update(&inner_key);
    inner.update(timestamp);
    inner.update(method);
    inner.update(path);
    inner.update(body);
    var inner_hash: [HASH_SIZE]u8 = undefined;
    inner.final(&inner_hash);

    // Outer = SHA256((K' ⊕ opad) || inner_hash)
    var outer_key: [BLOCK_SIZE]u8 = undefined;
    for (&outer_key, key_padded) |*b, k| b.* = k ^ OPAD;

    var outer = Sha256.init(.{});
    outer.update(&outer_key);
    outer.update(&inner_hash);
    outer.final(output);
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
    var start_time: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &start_time);
    const start = @as(i64, @intCast(start_time.sec)) * 1_000_000_000 + @as(i64, @intCast(start_time.nsec));

    var output: [32]u8 = undefined;
    for (0..iterations) |_| {
        hmacSha256(key, message, &output);
    }

    var end_time: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &end_time);
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
    var start_time: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &start_time);
    const start = @as(i64, @intCast(start_time.sec)) * 1_000_000_000 + @as(i64, @intCast(start_time.nsec));

    var output: [32]u8 = undefined;
    for (0..iterations) |_| {
        ctx.sign(message, &output);
    }

    var end_time: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &end_time);
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

test "Coinbase signature: streamed output matches concatenated reference" {
    // Sanity check that the streaming signCoinbase (no fixed buffer)
    // produces the same MAC as the equivalent HMAC over the manually
    // concatenated message. This locks in the new implementation against
    // a hand-rolled reference rather than self-roundtripping.
    const secret = "shhh-don't-tell";
    const timestamp = "1700000000";
    const method = "POST";
    const path = "/orders";
    const body = "{\"product_id\":\"BTC-USD\",\"side\":\"buy\",\"size\":\"0.5\"}";

    // Reference: concatenate ourselves, then HMAC normally.
    var concat_buf: [256]u8 = undefined;
    var p: usize = 0;
    @memcpy(concat_buf[p..][0..timestamp.len], timestamp);
    p += timestamp.len;
    @memcpy(concat_buf[p..][0..method.len], method);
    p += method.len;
    @memcpy(concat_buf[p..][0..path.len], path);
    p += path.len;
    @memcpy(concat_buf[p..][0..body.len], body);
    p += body.len;
    var expected: [32]u8 = undefined;
    hmacSha256(secret, concat_buf[0..p], &expected);

    // Subject under test.
    var actual: [32]u8 = undefined;
    signCoinbase(secret, timestamp, method, path, body, &actual);

    try std.testing.expectEqualSlices(u8, &expected, &actual);
}

test "Coinbase signature: 256 KiB body no longer overflows stack" {
    // Pre-fix, signCoinbase used a 512-byte fixed stack buffer and
    // @memcpy'd `body` into it without a length check — a body bigger
    // than 512 - (timestamp+method+path) would scribble past the buffer.
    // Post-fix, the body is streamed into Sha256.update so any length
    // up to the SHA-256 internal limit (2^32 bytes) is safe. 256 KiB
    // is dwarfs the original 512-byte cap; this test just confirms the
    // call completes and the result matches the streaming reference.
    const allocator = std.testing.allocator;
    const big_body = try allocator.alloc(u8, 256 * 1024);
    defer allocator.free(big_body);
    @memset(big_body, 'A');

    var sig: [32]u8 = undefined;
    signCoinbase("k", "ts", "POST", "/foo", big_body, &sig);

    // Verify against the manual concatenation hash, but use the actual
    // streaming path (which is the only available API now). The point
    // of the test is "does not crash / overflow the stack".
    var ctx = HmacContext.init("k");
    var streamed: [32]u8 = undefined;
    {
        // Manually drive an HMAC over the concatenated segments using
        // a heap allocation so the reference itself can't overflow.
        const total = "ts".len + "POST".len + "/foo".len + big_body.len;
        const ref_buf = try allocator.alloc(u8, total);
        defer allocator.free(ref_buf);
        var off: usize = 0;
        @memcpy(ref_buf[off..][0.."ts".len], "ts");
        off += "ts".len;
        @memcpy(ref_buf[off..][0.."POST".len], "POST");
        off += "POST".len;
        @memcpy(ref_buf[off..][0.."/foo".len], "/foo");
        off += "/foo".len;
        @memcpy(ref_buf[off..][0..big_body.len], big_body);
        ctx.sign(ref_buf, &streamed);
    }

    try std.testing.expectEqualSlices(u8, &streamed, &sig);
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
