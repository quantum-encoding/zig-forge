//! The Queen - CPU Orchestrator for the Hydra GPU Swarm
//!
//! "A CPU is a general, a GPU is an army."
//!
//! The Queen's responsibilities:
//! 1. Work Decomposition - Break the search space into GPU-sized chunks
//! 2. Queue Management - Feed work to the GPU continuously
//! 3. Result Aggregation - Collect and verify matches found by the GPU
//! 4. Throughput Optimization - Keep the GPU fully saturated
//!
//! Architecture:
//! ┌─────────────────────────────────────────────────────────────┐
//! │                        QUEEN (CPU)                          │
//! │  ┌─────────────┐  ┌──────────────┐  ┌──────────────────┐  │
//! │  │ Work        │→ │ Lock-Free    │→ │ GPU Dispatcher   │  │
//! │  │ Generator   │  │ Queue        │  │ (Double Buffer)  │  │
//! │  └─────────────┘  └──────────────┘  └────────┬─────────┘  │
//! └──────────────────────────────────────────────┼─────────────┘
//!                                                ↓
//! ┌─────────────────────────────────────────────────────────────┐
//! │                     HYDRA (GPU)                             │
//! │  ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐    │
//! │  │ Head │ │ Head │ │ Head │ │ Head │ │ Head │ │ ... │    │
//! │  │  1   │ │  2   │ │  3   │ │  4   │ │  5   │ │ 2048│    │
//! │  └──────┘ └──────┘ └──────┘ └──────┘ └──────┘ └──────┘    │
//! └─────────────────────────────────────────────────────────────┘

const std = @import("std");
const work_unit = @import("work_unit");
const gpu_kernel = @import("gpu_kernel");
const simd_batch = @import("simd_batch");

/// Instant using clock_gettime (Instant removed in Zig 0.16)
const Instant = struct {
    ts: std.c.timespec,

    pub fn now() error{}!Instant {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &ts);
        return Instant{ .ts = ts };
    }

    pub fn since(self: Instant, earlier: Instant) u64 {
        const self_ns: i128 = @as(i128, self.ts.sec) * 1_000_000_000 + self.ts.nsec;
        const earlier_ns: i128 = @as(i128, earlier.ts.sec) * 1_000_000_000 + earlier.ts.nsec;
        const diff = self_ns - earlier_ns;
        return if (diff > 0) @intCast(diff) else 0;
    }
};

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

/// Queen statistics
pub const QueenStats = struct {
    total_candidates: u64,
    candidates_processed: u64,
    batches_dispatched: u64,
    matches_found: u64,
    gpu_time_ns: u64,
    cpu_time_ns: u64,
    start_instant: Instant,

    pub fn elapsedNs(self: *const QueenStats) u64 {
        const now = Instant.now() catch return 0;
        return now.since(self.start_instant);
    }

    pub fn throughput(self: *const QueenStats) f64 {
        const elapsed_ns = self.elapsedNs();
        if (elapsed_ns == 0) return 0;
        return @as(f64, @floatFromInt(self.candidates_processed)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1e9);
    }

    pub fn progress(self: *const QueenStats) f64 {
        if (self.total_candidates == 0) return 100.0;
        return @as(f64, @floatFromInt(self.candidates_processed)) / @as(f64, @floatFromInt(self.total_candidates)) * 100.0;
    }

    pub fn gpuUtilization(self: *const QueenStats) f64 {
        const total = self.gpu_time_ns + self.cpu_time_ns;
        if (total == 0) return 0;
        return @as(f64, @floatFromInt(self.gpu_time_ns)) / @as(f64, @floatFromInt(total)) * 100.0;
    }
};

/// The Queen - GPU orchestrator
pub const Queen = struct {
    allocator: std.mem.Allocator,

    // GPU engine
    hydra: ?gpu_kernel.Hydra,

    // Work generation
    generator: work_unit.WorkGenerator,

    // SIMD batch preparation
    batch_preparer: ?simd_batch.BatchPreparer,

    // Double-buffering for CPU/GPU overlap
    batch_a: ?work_unit.GpuBatch,
    batch_b: ?work_unit.GpuBatch,
    current_batch: enum { A, B },

    // Results
    matches: std.ArrayList(work_unit.MatchInfo),

    // Statistics
    stats: QueenStats,

    // Configuration
    max_batch_size: u32,

    pub fn init(
        allocator: std.mem.Allocator,
        start: u64,
        end: u64,
        search_type: work_unit.SearchType,
        target_hash: []const u8,
    ) !Queen {
        const max_batch_size = work_unit.Config.batch_size;

        // Initialize GPU
        std.debug.print("\nInitializing Hydra GPU engine...\n", .{});
        const hydra = gpu_kernel.Hydra.init(max_batch_size) catch |err| {
            std.debug.print("GPU initialization failed: {}\n", .{err});
            return error.NoGpu;
        };

        // Initialize batch preparer
        const batch_preparer = try simd_batch.BatchPreparer.init(allocator);

        // Pre-allocate double buffers
        const batch_a = try work_unit.GpuBatch.init(allocator, 0, max_batch_size);
        const batch_b = try work_unit.GpuBatch.init(allocator, 0, max_batch_size);

        return Queen{
            .allocator = allocator,
            .hydra = hydra,
            .generator = work_unit.WorkGenerator.init(start, end, search_type, target_hash),
            .batch_preparer = batch_preparer,
            .batch_a = batch_a,
            .batch_b = batch_b,
            .current_batch = .A,
            .matches = .empty,
            .stats = QueenStats{
                .total_candidates = end - start,
                .candidates_processed = 0,
                .batches_dispatched = 0,
                .matches_found = 0,
                .gpu_time_ns = 0,
                .cpu_time_ns = 0,
                .start_instant = Instant.now() catch unreachable,
            },
            .max_batch_size = max_batch_size,
        };
    }

    pub fn deinit(self: *Queen) void {
        if (self.batch_a) |*b| b.deinit(self.allocator);
        if (self.batch_b) |*b| b.deinit(self.allocator);
        if (self.batch_preparer) |*bp| bp.deinit();
        if (self.hydra) |*h| h.deinit();
        self.matches.deinit(self.allocator);
    }

    /// Run the search until completion or match found
    pub fn run(self: *Queen) !void {
        if (self.hydra == null) {
            std.debug.print("No GPU available\n", .{});
            return error.NoGpu;
        }

        std.debug.print("\n", .{});
        std.debug.print("Starting GPU search...\n", .{});
        std.debug.print("  Search space: {} candidates\n", .{self.stats.total_candidates});
        std.debug.print("  Batch size: {} work units\n", .{self.max_batch_size});
        std.debug.print("  Candidates per batch: {}\n", .{work_unit.Config.candidates_per_batch});
        std.debug.print("\n", .{});

        var timer = Timer.start() catch unreachable;
        var last_report_time: u64 = 0;
        const report_interval_ns: u64 = 500_000_000; // 500ms

        while (true) {
            // Generate next batch
            const cpu_start = timer.read();
            const maybe_batch = try self.generator.nextBatch(self.allocator);
            if (maybe_batch == null) break;
            var batch = maybe_batch.?;
            defer batch.deinit(self.allocator);

            self.stats.cpu_time_ns += timer.read() - cpu_start;

            // Execute on GPU
            const gpu_start = timer.read();
            try self.hydra.?.executeBatch(&batch);
            self.stats.gpu_time_ns += timer.read() - gpu_start;

            // Update stats
            for (batch.headers[0..batch.count]) |h| {
                self.stats.candidates_processed += h.count;
            }
            self.stats.batches_dispatched += 1;

            // Check for matches
            if (batch.hasMatch()) {
                const batch_matches = try batch.getMatches(self.allocator);
                defer self.allocator.free(batch_matches);

                for (batch_matches) |m| {
                    try self.matches.append(self.allocator, m);
                    self.stats.matches_found += 1;

                    std.debug.print("\n*** MATCH FOUND ***\n", .{});
                    std.debug.print("  Value: {}\n", .{m.value});
                    std.debug.print("  Index: {}\n", .{m.global_index});
                }
            }

            // Progress report
            const now = timer.read();
            if (now - last_report_time > report_interval_ns) {
                self.printProgress();
                last_report_time = now;
            }
        }

        std.debug.print("\n", .{});
        self.printFinalStats();
    }

    fn printProgress(self: *const Queen) void {
        std.debug.print("\r  Progress: {d:.1}% | Throughput: {d:.2}M/sec | Matches: {}   ", .{
            self.stats.progress(),
            self.stats.throughput() / 1e6,
            self.stats.matches_found,
        });
    }

    fn printFinalStats(self: *const Queen) void {
        const elapsed_ns = self.stats.elapsedNs();
        const elapsed_sec = @as(f64, @floatFromInt(elapsed_ns)) / 1e9;

        std.debug.print("Search Complete!\n", .{});
        std.debug.print("  Total candidates: {}\n", .{self.stats.total_candidates});
        std.debug.print("  Candidates processed: {}\n", .{self.stats.candidates_processed});
        std.debug.print("  Batches dispatched: {}\n", .{self.stats.batches_dispatched});
        std.debug.print("  Matches found: {}\n", .{self.stats.matches_found});
        std.debug.print("  Elapsed time: {d:.2}s\n", .{elapsed_sec});
        std.debug.print("  Throughput: {d:.2}M/sec\n", .{self.stats.throughput() / 1e6});
        std.debug.print("  GPU utilization: {d:.1}%\n", .{self.stats.gpuUtilization()});
    }

    /// Get all matches found so far
    pub fn getMatches(self: *const Queen) []const work_unit.MatchInfo {
        return self.matches.items;
    }

    /// Get current statistics
    pub fn getStats(self: *const Queen) QueenStats {
        return self.stats;
    }
};

test "Queen initialization" {
    const allocator = std.heap.c_allocator;

    const target = [_]u8{0} ** 32;
    var queen = try Queen.init(allocator, 0, 1000, .numeric_hash, &target);
    defer queen.deinit();

    try std.testing.expectEqual(@as(u64, 1000), queen.stats.total_candidates);
}
