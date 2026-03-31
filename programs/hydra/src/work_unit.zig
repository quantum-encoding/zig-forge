//! Work Unit - The atomic unit of GPU computation
//!
//! A Work Unit represents a slice of the search space that the GPU
//! will process in parallel. The Queen generates these, the GPU consumes them.
//!
//! Design Philosophy:
//! - Fixed-size for GPU memory alignment (power of 2)
//! - Self-contained: all data needed for the search is embedded
//! - Cache-line friendly: 64 bytes aligned

const std = @import("std");

/// Configuration constants
pub const Config = struct {
    /// Number of candidates per work unit (tuned for RTX 3050's 2048 CUDA cores)
    /// Each SM can handle 32 threads (warp), RTX 3050 has 16 SMs = 512 concurrent warps
    /// We batch 1024 candidates per work unit for efficient memory coalescing
    pub const candidates_per_unit: u32 = 1024;

    /// Maximum hash size in bytes (SHA-256 = 32 bytes, plus padding for alignment)
    pub const max_hash_size: u32 = 32;

    /// Work unit batch size for GPU dispatch (balance between latency and throughput)
    /// RTX 3050 has 4GB VRAM - we can queue many batches
    pub const batch_size: u32 = 4096; // 4K work units per GPU dispatch

    /// Total candidates per batch = batch_size * candidates_per_unit
    /// = 4096 * 1024 = 4,194,304 candidates per GPU kernel launch
    pub const candidates_per_batch: u64 = @as(u64, batch_size) * candidates_per_unit;
};

/// Work Unit Header - metadata for each unit
/// 64 bytes, cache-line aligned
pub const WorkUnitHeader = extern struct {
    /// Starting index in the global search space
    start_index: u64 align(8),
    /// Number of candidates in this unit
    count: u32 align(4),
    /// Type of search (affects hash algorithm)
    search_type: SearchType align(4),
    /// Target hash to find (what we're looking for)
    target_hash: [Config.max_hash_size]u8 align(8),
    /// Reserved for future use / alignment padding
    _reserved: [16]u8 = .{0} ** 16,

    comptime {
        // Ensure exactly 64 bytes for cache-line alignment
        std.debug.assert(@sizeOf(WorkUnitHeader) == 64);
    }
};

/// Search types supported by the Hydra
pub const SearchType = enum(u32) {
    /// Numeric match: find N where hash(N) == target
    numeric_hash = 0,
    /// String permutation: find permutation where hash(perm) == target
    permutation_hash = 1,
    /// Compression formula: find formula that achieves target ratio
    compression_formula = 2,
    /// Prime search: find prime in range
    prime_search = 3,
    /// Custom: user-defined kernel
    custom = 0xFFFF,
};

/// Result from GPU - indicates if a match was found
/// 32 bytes for alignment
pub const WorkUnitResult = extern struct {
    /// Was a match found?
    found: u32 align(4),
    /// Index of the match (relative to work unit start)
    match_index: u32 align(4),
    /// The matching value (for verification)
    match_value: u64 align(8),
    /// Hash of the match (for verification)
    match_hash: [Config.max_hash_size / 2]u8 align(8), // First 16 bytes of hash

    comptime {
        std.debug.assert(@sizeOf(WorkUnitResult) == 32);
    }

    pub fn init() WorkUnitResult {
        return WorkUnitResult{
            .found = 0,
            .match_index = 0,
            .match_value = 0,
            .match_hash = .{0} ** (Config.max_hash_size / 2),
        };
    }
};

/// GPU Batch - collection of work units for a single kernel launch
/// This is what we actually send to the GPU
pub const GpuBatch = struct {
    /// Array of work unit headers
    headers: []WorkUnitHeader,
    /// Pre-allocated results buffer (one per work unit)
    results: []WorkUnitResult,
    /// Batch ID for tracking
    batch_id: u64,
    /// Number of work units in this batch
    count: u32,

    pub fn init(allocator: std.mem.Allocator, batch_id: u64, count: u32) !GpuBatch {
        const headers = try allocator.alloc(WorkUnitHeader, count);
        const results = try allocator.alloc(WorkUnitResult, count);

        // Initialize results to "not found"
        for (results) |*r| {
            r.* = WorkUnitResult.init();
        }

        return GpuBatch{
            .headers = headers,
            .results = results,
            .batch_id = batch_id,
            .count = count,
        };
    }

    pub fn deinit(self: *GpuBatch, allocator: std.mem.Allocator) void {
        allocator.free(self.headers);
        allocator.free(self.results);
    }

    /// Check if any work unit found a match
    pub fn hasMatch(self: *const GpuBatch) bool {
        for (self.results[0..self.count]) |r| {
            if (r.found != 0) return true;
        }
        return false;
    }

    /// Get all matches from this batch
    pub fn getMatches(self: *const GpuBatch, allocator: std.mem.Allocator) ![]MatchInfo {
        var matches: std.ArrayList(MatchInfo) = .empty;
        errdefer matches.deinit(allocator);

        for (self.results[0..self.count], 0..) |r, i| {
            if (r.found != 0) {
                const header = &self.headers[i];
                try matches.append(allocator, MatchInfo{
                    .global_index = header.start_index + r.match_index,
                    .value = r.match_value,
                    .hash_prefix = r.match_hash,
                    .batch_id = self.batch_id,
                    .work_unit_idx = @intCast(i),
                });
            }
        }

        return matches.toOwnedSlice(allocator);
    }
};

/// Information about a match found by the GPU
pub const MatchInfo = struct {
    global_index: u64,
    value: u64,
    hash_prefix: [Config.max_hash_size / 2]u8,
    batch_id: u64,
    work_unit_idx: u32,
};

/// Work Generator - produces work units for a given search space
pub const WorkGenerator = struct {
    current_index: u64,
    end_index: u64,
    search_type: SearchType,
    target_hash: [Config.max_hash_size]u8,
    batch_counter: u64,

    pub fn init(start: u64, end: u64, search_type: SearchType, target_hash: []const u8) WorkGenerator {
        var hash_buf: [Config.max_hash_size]u8 = .{0} ** Config.max_hash_size;
        const copy_len = @min(target_hash.len, Config.max_hash_size);
        @memcpy(hash_buf[0..copy_len], target_hash[0..copy_len]);

        return WorkGenerator{
            .current_index = start,
            .end_index = end,
            .search_type = search_type,
            .target_hash = hash_buf,
            .batch_counter = 0,
        };
    }

    /// Generate the next batch of work units
    pub fn nextBatch(self: *WorkGenerator, allocator: std.mem.Allocator) !?GpuBatch {
        if (self.current_index >= self.end_index) {
            return null; // No more work
        }

        // Calculate how many work units we can generate
        const candidates_remaining = self.end_index - self.current_index;
        const units_needed = (candidates_remaining + Config.candidates_per_unit - 1) / Config.candidates_per_unit;
        const units_this_batch: u32 = @intCast(@min(units_needed, Config.batch_size));

        var batch = try GpuBatch.init(allocator, self.batch_counter, units_this_batch);
        errdefer batch.deinit(allocator);

        // Fill in the work unit headers
        var i: u32 = 0;
        while (i < units_this_batch) : (i += 1) {
            const start = self.current_index + @as(u64, i) * Config.candidates_per_unit;
            const end = @min(start + Config.candidates_per_unit, self.end_index);
            const count: u32 = @intCast(end - start);

            batch.headers[i] = WorkUnitHeader{
                .start_index = start,
                .count = count,
                .search_type = self.search_type,
                .target_hash = self.target_hash,
            };
        }

        // Update state
        self.current_index += @as(u64, units_this_batch) * Config.candidates_per_unit;
        self.batch_counter += 1;

        return batch;
    }

    /// Get progress as percentage
    pub fn progress(self: *const WorkGenerator) f64 {
        const total = self.end_index;
        if (total == 0) return 100.0;
        return @as(f64, @floatFromInt(self.current_index)) / @as(f64, @floatFromInt(total)) * 100.0;
    }

    /// Get remaining candidates
    pub fn remaining(self: *const WorkGenerator) u64 {
        if (self.current_index >= self.end_index) return 0;
        return self.end_index - self.current_index;
    }
};

test "WorkUnitHeader size" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(WorkUnitHeader));
}

test "WorkUnitResult size" {
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(WorkUnitResult));
}

test "WorkGenerator produces correct batches" {
    const allocator = std.heap.c_allocator;

    const target = [_]u8{0xDE, 0xAD, 0xBE, 0xEF} ++ ([_]u8{0} ** 28);
    var gen = WorkGenerator.init(0, 10000, .numeric_hash, &target);

    var total_candidates: u64 = 0;
    var batch_count: u64 = 0;

    while (try gen.nextBatch(allocator)) |*batch| {
        defer batch.deinit(allocator);
        for (batch.headers[0..batch.count]) |h| {
            total_candidates += h.count;
        }
        batch_count += 1;
    }

    try std.testing.expectEqual(@as(u64, 10000), total_candidates);
}
