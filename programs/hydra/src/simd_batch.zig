//! SIMD Batch Preparation - AVX-512 accelerated work unit generation
//!
//! The CPU Queen uses SIMD instructions to rapidly prepare work units
//! before dispatching to the GPU. This includes:
//! - Parallel hash computation for target generation
//! - Vectorized memory operations for batch assembly
//! - Fast range checking and filtering
//!
//! Architecture: "The General's Staff"
//! While the GPU army (Hydra) does the brute-force search,
//! the CPU's SIMD units act as the staff officers preparing battle plans.

const std = @import("std");
const work_unit = @import("work_unit");

/// Timer using clock_gettime (Timer removed in Zig 0.16)
const Timer = struct {
    start_ts: std.c.timespec,

    pub fn start() error{}!Timer {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &ts);
        return Timer{ .start_ts = ts };
    }

    pub fn reset(self: *Timer) void {
        _ = std.c.clock_gettime(.MONOTONIC, &self.start_ts);
    }

    pub fn read(self: *const Timer) u64 {
        var now: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &now);
        const start_ns: i128 = @as(i128, self.start_ts.sec) * 1_000_000_000 + self.start_ts.nsec;
        const now_ns: i128 = @as(i128, now.sec) * 1_000_000_000 + now.nsec;
        const diff = now_ns - start_ns;
        return if (diff > 0) @intCast(diff) else 0;
    }
};

/// SIMD vector types for x86-64
const Vec8u64 = @Vector(8, u64);
const Vec16u32 = @Vector(16, u32);
const Vec32u16 = @Vector(32, u16);
const Vec64u8 = @Vector(64, u8);

/// Check if AVX-512 is available at runtime
pub fn hasAvx512() bool {
    // Runtime detection via inline asm would be needed for true check
    // For simplicity, return false
    return false;
}

/// Check if AVX2 is available (fallback)
pub fn hasAvx2() bool {
    // For now, assume AVX2 is available on modern x86-64
    return true;
}

/// Simple hash function (Splitmix64) - vectorized for 8 values at once
pub fn hashVec8(values: Vec8u64) Vec8u64 {
    var x = values;
    x = (x ^ (x >> @splat(30))) *% @as(Vec8u64, @splat(0xbf58476d1ce4e5b9));
    x = (x ^ (x >> @splat(27))) *% @as(Vec8u64, @splat(0x94d049bb133111eb));
    x = x ^ (x >> @splat(31));
    return x;
}

/// Scalar hash function (same algorithm, for comparison)
pub fn hashScalar(x_in: u64) u64 {
    var x = x_in;
    x = (x ^ (x >> 30)) *% 0xbf58476d1ce4e5b9;
    x = (x ^ (x >> 27)) *% 0x94d049bb133111eb;
    x = x ^ (x >> 31);
    return x;
}

/// Batch hash 8 values using SIMD, storing results in output array
pub fn batchHash8(inputs: [8]u64) [8]u64 {
    const vec: Vec8u64 = inputs;
    const hashed = hashVec8(vec);

    var result: [8]u64 = undefined;
    inline for (0..8) |i| {
        result[i] = hashed[i];
    }
    return result;
}

/// Fast memset using SIMD - zero a buffer
pub fn simdZero(dest: []u8) void {
    const zero_vec: Vec64u8 = @splat(0);
    const aligned_len = dest.len & ~@as(usize, 63);

    // Process 64 bytes at a time
    var i: usize = 0;
    while (i < aligned_len) : (i += 64) {
        const ptr: *Vec64u8 = @ptrCast(@alignCast(dest[i..].ptr));
        ptr.* = zero_vec;
    }

    // Handle remainder
    for (dest[aligned_len..]) |*b| {
        b.* = 0;
    }
}

/// Fast memcpy using SIMD
pub fn simdCopy(dest: []u8, src: []const u8) void {
    const len = @min(dest.len, src.len);
    const aligned_len = len & ~@as(usize, 63);

    // Process 64 bytes at a time
    var i: usize = 0;
    while (i < aligned_len) : (i += 64) {
        const src_ptr: *const Vec64u8 = @ptrCast(@alignCast(src[i..].ptr));
        const dest_ptr: *Vec64u8 = @ptrCast(@alignCast(dest[i..].ptr));
        dest_ptr.* = src_ptr.*;
    }

    // Handle remainder
    for (dest[aligned_len..len], src[aligned_len..len]) |*d, s| {
        d.* = s;
    }
}

/// Batch Preparer - uses SIMD to efficiently create work unit batches
pub const BatchPreparer = struct {
    /// Scratch buffer for intermediate computations
    scratch: []u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !BatchPreparer {
        // Allocate aligned scratch buffer (64KB for efficient SIMD ops)
        const scratch = try allocator.alignedAlloc(u8, .@"64", 64 * 1024);
        return BatchPreparer{
            .scratch = scratch,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *BatchPreparer) void {
        self.allocator.free(self.scratch);
    }

    /// Prepare a batch of work unit headers with SIMD-accelerated operations
    pub fn prepareBatch(
        self: *BatchPreparer,
        batch: *work_unit.GpuBatch,
        start_index: u64,
        search_type: work_unit.SearchType,
        target_hash: []const u8,
    ) void {
        _ = self; // scratch unused for now

        const candidates_per_unit = work_unit.Config.candidates_per_unit;

        // Process headers in groups of 8 for potential SIMD optimization
        var i: u32 = 0;
        while (i < batch.count) : (i += 1) {
            const unit_start = start_index + @as(u64, i) * candidates_per_unit;

            batch.headers[i] = work_unit.WorkUnitHeader{
                .start_index = unit_start,
                .count = candidates_per_unit,
                .search_type = search_type,
                .target_hash = undefined,
            };

            // Copy target hash
            const copy_len = @min(target_hash.len, work_unit.Config.max_hash_size);
            @memcpy(batch.headers[i].target_hash[0..copy_len], target_hash[0..copy_len]);
            @memset(batch.headers[i].target_hash[copy_len..], 0);
        }

        // Zero all results using SIMD
        const results_bytes = std.mem.sliceAsBytes(batch.results[0..batch.count]);
        simdZero(results_bytes);
    }

    /// Find all matches in a batch of computed hashes (SIMD-accelerated)
    pub fn findMatches(
        hashes: []const u64,
        target: u64,
        matches: *std.ArrayList(usize),
    ) !void {
        const target_vec: Vec8u64 = @splat(target);

        // Process 8 hashes at a time
        var i: usize = 0;
        while (i + 8 <= hashes.len) : (i += 8) {
            const hash_vec: Vec8u64 = hashes[i..][0..8].*;
            const cmp = hash_vec == target_vec;

            // Check each lane
            inline for (0..8) |lane| {
                if (cmp[lane]) {
                    try matches.append(i + lane);
                }
            }
        }

        // Handle remainder
        while (i < hashes.len) : (i += 1) {
            if (hashes[i] == target) {
                try matches.append(i);
            }
        }
    }
};

/// Benchmark: Compare SIMD vs scalar hashing performance
pub fn benchmarkHash(iterations: u64) struct { simd_ns: u64, scalar_ns: u64, speedup: f64 } {
    const timer = Timer;
    var t = timer.start() catch return .{ .simd_ns = 0, .scalar_ns = 0, .speedup = 0 };

    // Benchmark SIMD (8 at a time)
    var simd_sum: u64 = 0;
    t.reset();
    var i: u64 = 0;
    while (i < iterations) : (i += 8) {
        const inputs = [8]u64{ i, i + 1, i + 2, i + 3, i + 4, i + 5, i + 6, i + 7 };
        const results = batchHash8(inputs);
        simd_sum +%= results[0];
    }
    const simd_ns = t.read();

    // Benchmark scalar
    var scalar_sum: u64 = 0;
    t.reset();
    i = 0;
    while (i < iterations) : (i += 1) {
        scalar_sum +%= hashScalar(i);
    }
    const scalar_ns = t.read();

    // Prevent optimization
    std.mem.doNotOptimizeAway(&simd_sum);
    std.mem.doNotOptimizeAway(&scalar_sum);

    const speedup = if (simd_ns > 0)
        @as(f64, @floatFromInt(scalar_ns)) / @as(f64, @floatFromInt(simd_ns))
    else
        0;

    return .{
        .simd_ns = simd_ns,
        .scalar_ns = scalar_ns,
        .speedup = speedup,
    };
}

test "SIMD hash matches scalar hash" {
    const values = [8]u64{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const simd_results = batchHash8(values);

    for (values, simd_results) |v, simd_hash| {
        const scalar_hash = hashScalar(v);
        try std.testing.expectEqual(scalar_hash, simd_hash);
    }
}

test "simdZero clears buffer" {
    var buf: [256]u8 = undefined;
    @memset(&buf, 0xFF);
    simdZero(&buf);
    for (buf) |b| {
        try std.testing.expectEqual(@as(u8, 0), b);
    }
}

test "simdCopy copies data" {
    const src = "Hello, SIMD world! This is a test of vectorized memory operations.";
    var dest: [128]u8 = undefined;
    simdCopy(&dest, src);
    try std.testing.expectEqualStrings(src, dest[0..src.len]);
}
