//! Crypto Brute-Force Benchmark
//!
//! Tests exhaustive search against real cryptographic operations
//! We search for a 32-bit partial key (4 bytes) within a 256-bit key space

const std = @import("std");
const posix = std.posix;
const crypto = std.crypto;

// Use ChaCha20-Poly1305 for authenticated encryption
const ChaCha20Poly1305 = crypto.aead.chacha_poly.ChaCha20Poly1305;

// The "secret" 32-bit value we're searching for (embedded in bytes 0-3 of the key)
const SECRET_KEY_FRAGMENT: u32 = 0xDEAD_BEEF;

// Known plaintext for verification
const PLAINTEXT = "The quick brown fox jumps over the lazy dog";

// Pre-computed values for the challenge
const FULL_KEY: [32]u8 = blk: {
    var key: [32]u8 = .{
        0x00, 0x00, 0x00, 0x00, // Bytes 0-3: Will be the search target
        0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
        0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00,
        0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0,
        0xFE, 0xDC, 0xBA, 0x98,
    };
    // Embed the secret in little-endian
    key[0] = @truncate(SECRET_KEY_FRAGMENT);
    key[1] = @truncate(SECRET_KEY_FRAGMENT >> 8);
    key[2] = @truncate(SECRET_KEY_FRAGMENT >> 16);
    key[3] = @truncate(SECRET_KEY_FRAGMENT >> 24);
    break :blk key;
};

const NONCE: [12]u8 = .{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B };

/// Thread result
const ThreadResult = struct {
    found: bool,
    key_fragment: u32,
    attempts: u64,
};

/// Thread context
const ThreadContext = struct {
    thread_id: usize,
    start: u64,
    end: u64,
    target_ciphertext: []const u8,
    target_tag: [16]u8,
    result: ThreadResult,
};

/// Encrypt the plaintext with the full secret key to get our target
fn encryptWithSecretKey() struct { ciphertext: [PLAINTEXT.len]u8, tag: [16]u8 } {
    var ciphertext: [PLAINTEXT.len]u8 = undefined;
    var tag: [16]u8 = undefined;

    ChaCha20Poly1305.encrypt(&ciphertext, &tag, PLAINTEXT, "", NONCE, FULL_KEY);

    return .{ .ciphertext = ciphertext, .tag = tag };
}

/// Worker thread - tries key fragments in its assigned range
fn searchKeyFragment(ctx: *ThreadContext) void {
    var found = false;
    var found_fragment: u32 = 0;
    var attempts: u64 = 0;

    // Build a trial key (copy the known parts)
    var trial_key: [32]u8 = FULL_KEY;

    var fragment: u64 = ctx.start;
    while (fragment < ctx.end) : (fragment += 1) {
        attempts += 1;

        // Insert trial fragment into key bytes 0-3
        const frag32: u32 = @truncate(fragment);
        trial_key[0] = @truncate(frag32);
        trial_key[1] = @truncate(frag32 >> 8);
        trial_key[2] = @truncate(frag32 >> 16);
        trial_key[3] = @truncate(frag32 >> 24);

        // Try to decrypt with this key
        var decrypted: [PLAINTEXT.len]u8 = undefined;
        ChaCha20Poly1305.decrypt(&decrypted, ctx.target_ciphertext, ctx.target_tag, "", NONCE, trial_key) catch {
            // Authentication failed - wrong key
            continue;
        };

        // If we get here, decryption succeeded!
        found = true;
        found_fragment = frag32;
        // Don't break - continue for accurate benchmark timing
    }

    ctx.result = ThreadResult{
        .found = found,
        .key_fragment = found_fragment,
        .attempts = attempts,
    };
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    // Parse arguments
    var search_bits: u6 = 24; // Default: search 24 bits (16M possibilities)
    var num_threads: usize = try std.Thread.getCpuCount();

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--bits")) {
            if (args.next()) |v| search_bits = @intCast(try std.fmt.parseInt(u6, v, 10));
        } else if (std.mem.eql(u8, arg, "--threads")) {
            if (args.next()) |v| num_threads = try std.fmt.parseInt(usize, v, 10);
        }
    }

    const search_space: u64 = @as(u64, 1) << search_bits;

    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  CRYPTO BRUTE-FORCE BENCHMARK - ChaCha20-Poly1305                    ║\n", .{});
    std.debug.print("╠══════════════════════════════════════════════════════════════════════╣\n", .{});
    std.debug.print("║  Search Space: {} bits ({} possibilities)                            \n", .{ search_bits, search_space });
    std.debug.print("║  Threads: {}                                                         \n", .{num_threads});
    std.debug.print("║  Secret Fragment: 0x{X:0>8}                                          \n", .{SECRET_KEY_FRAGMENT});
    std.debug.print("╚══════════════════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    // Generate target ciphertext
    const target = encryptWithSecretKey();
    std.debug.print("Target ciphertext generated. Starting search...\n", .{});

    // Allocate thread contexts
    const contexts = try allocator.alloc(ThreadContext, num_threads);
    defer allocator.free(contexts);

    const threads = try allocator.alloc(std.Thread, num_threads);
    defer allocator.free(threads);

    // Partition search space
    const range_per_thread = search_space / num_threads;
    for (0..num_threads) |i| {
        const thread_start = i * range_per_thread;
        const thread_end = if (i == num_threads - 1) search_space else thread_start + range_per_thread;

        contexts[i] = ThreadContext{
            .thread_id = i,
            .start = thread_start,
            .end = thread_end,
            .target_ciphertext = &target.ciphertext,
            .target_tag = target.tag,
            .result = undefined,
        };
    }

    // Start timer
    var start_ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &start_ts) != 0) return error.TimerFailed;
    const start_time = start_ts;

    // Spawn threads
    for (0..num_threads) |i| {
        threads[i] = try std.Thread.spawn(.{}, searchKeyFragment, .{&contexts[i]});
    }

    // Wait for completion
    for (threads) |thread| {
        thread.join();
    }

    // End timer
    var end_ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &end_ts) != 0) return error.TimerFailed;
    const end_time = end_ts;

    const elapsed_ns = (@as(i128, end_time.sec) - @as(i128, start_time.sec)) * 1_000_000_000 +
        (@as(i128, end_time.nsec) - @as(i128, start_time.nsec));
    const elapsed_secs = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;

    // Aggregate results
    var total_attempts: u64 = 0;
    var found = false;
    var found_fragment: u32 = 0;

    for (contexts) |ctx| {
        total_attempts += ctx.result.attempts;
        if (ctx.result.found) {
            found = true;
            found_fragment = ctx.result.key_fragment;
        }
    }

    const throughput = @as(f64, @floatFromInt(total_attempts)) / elapsed_secs;

    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  RESULTS                                                             ║\n", .{});
    std.debug.print("╠══════════════════════════════════════════════════════════════════════╣\n", .{});
    std.debug.print("║  Keys Tested: {}                                                     \n", .{total_attempts});
    std.debug.print("║  Elapsed Time: {d:.3} seconds                                        \n", .{elapsed_secs});
    std.debug.print("║  Throughput: {d:.0} keys/sec                                         \n", .{throughput});
    std.debug.print("║  Found: {}                                                           \n", .{found});
    if (found) {
        std.debug.print("║  Key Fragment: 0x{X:0>8}                                          \n", .{found_fragment});
    }
    std.debug.print("╚══════════════════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    if (found and found_fragment == SECRET_KEY_FRAGMENT) {
        std.debug.print("✅ KEY CRACKED! Fragment matches: 0x{X:0>8}\n", .{found_fragment});
    } else if (SECRET_KEY_FRAGMENT >= search_space) {
        std.debug.print("⚠️  Secret not in search range (need more bits)\n", .{});
    } else {
        std.debug.print("❌ KEY NOT FOUND\n", .{});
    }

    // Estimate time for full 32-bit search
    if (search_bits < 32) {
        const full_32bit_space: f64 = 4294967296.0; // 2^32
        const estimated_time = full_32bit_space / throughput;
        std.debug.print("\n", .{});
        std.debug.print("📊 Estimated time for full 32-bit search: {d:.1} seconds ({d:.1} minutes)\n", .{ estimated_time, estimated_time / 60.0 });
    }
}
