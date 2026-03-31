//! Parallel file hashing for high-throughput NVMe utilization
//!
//! NVMe drives perform best with high queue depth (32-64 concurrent I/O operations).
//! This module provides parallel hashing to saturate NVMe bandwidth.

const std = @import("std");
const hasher = @import("hasher.zig");
const types = @import("types.zig");

/// Hash job for worker threads
const HashJob = struct {
    /// Index into the files array
    file_idx: usize,
    /// Whether to do quick hash (first N bytes) or full hash
    quick_hash: bool,
    /// Quick hash size (only used if quick_hash is true)
    quick_hash_size: usize,
};

/// Parallel hasher using a thread pool
pub const ParallelHasher = struct {
    allocator: std.mem.Allocator,
    /// Files to hash (shared reference)
    files: []types.FileEntry,
    /// Work queue
    jobs: std.ArrayListUnmanaged(HashJob),
    /// Current job index (atomic for work stealing)
    job_index: std.atomic.Value(usize),
    /// Number of completed jobs (for progress)
    completed: std.atomic.Value(usize),
    /// Thread handles
    threads: []std.Thread,
    /// Hash algorithm to use
    algorithm: types.Config.HashAlgorithm,
    /// Number of worker threads
    thread_count: u32,
    /// Progress callback (called periodically)
    progress_callback: ?types.ProgressCallback,
    /// Progress data for callback
    progress: types.Progress,

    pub fn init(
        allocator: std.mem.Allocator,
        files: []types.FileEntry,
        algorithm: types.Config.HashAlgorithm,
        thread_count: u32,
    ) ParallelHasher {
        return .{
            .allocator = allocator,
            .files = files,
            .jobs = .empty,
            .job_index = std.atomic.Value(usize).init(0),
            .completed = std.atomic.Value(usize).init(0),
            .threads = &.{},
            .algorithm = algorithm,
            .thread_count = thread_count,
            .progress_callback = null,
            .progress = .{
                .phase = .quick_hashing,
                .files_processed = 0,
                .files_total = 0,
                .bytes_processed = 0,
                .bytes_total = 0,
                .current_file = null,
            },
        };
    }

    pub fn deinit(self: *ParallelHasher) void {
        self.jobs.deinit(self.allocator);
        if (self.threads.len > 0) {
            self.allocator.free(self.threads);
        }
    }

    /// Set progress callback
    pub fn setProgressCallback(self: *ParallelHasher, callback: types.ProgressCallback) void {
        self.progress_callback = callback;
    }

    /// Add a quick hash job
    pub fn addQuickHashJob(self: *ParallelHasher, file_idx: usize, quick_hash_size: usize) !void {
        try self.jobs.append(self.allocator, .{
            .file_idx = file_idx,
            .quick_hash = true,
            .quick_hash_size = quick_hash_size,
        });
    }

    /// Add a full hash job
    pub fn addFullHashJob(self: *ParallelHasher, file_idx: usize) !void {
        try self.jobs.append(self.allocator, .{
            .file_idx = file_idx,
            .quick_hash = false,
            .quick_hash_size = 0,
        });
    }

    /// Run all queued hash jobs in parallel
    pub fn run(self: *ParallelHasher) !void {
        if (self.jobs.items.len == 0) return;

        // Reset counters
        self.job_index.store(0, .release);
        self.completed.store(0, .release);

        // Update progress
        self.progress.files_total = self.jobs.items.len;
        self.progress.files_processed = 0;

        // Determine actual thread count (don't spawn more threads than jobs)
        const actual_threads = @min(self.thread_count, @as(u32, @intCast(self.jobs.items.len)));

        if (actual_threads <= 1) {
            // Single-threaded fallback
            self.workerLoop();
            return;
        }

        // Allocate thread handles
        self.threads = try self.allocator.alloc(std.Thread, actual_threads);
        errdefer self.allocator.free(self.threads);

        // Spawn worker threads
        for (self.threads) |*t| {
            t.* = try std.Thread.spawn(.{}, workerThreadFn, .{self});
        }

        // Wait for all threads to complete
        for (self.threads) |t| {
            t.join();
        }

        // Free thread handles
        self.allocator.free(self.threads);
        self.threads = &.{};
    }

    /// Worker thread function
    fn workerThreadFn(self: *ParallelHasher) void {
        self.workerLoop();
    }

    /// Main worker loop - atomically grab and process jobs
    fn workerLoop(self: *ParallelHasher) void {
        const file_hasher = hasher.FileHasher.init(self.algorithm);

        while (true) {
            // Atomically grab next job index
            const idx = self.job_index.fetchAdd(1, .acquire);
            if (idx >= self.jobs.items.len) break;

            const job = self.jobs.items[idx];
            const entry = &self.files[job.file_idx];

            // Perform hashing
            if (job.quick_hash) {
                entry.quick_hash = file_hasher.hashFileQuick(
                    entry.path,
                    job.quick_hash_size,
                ) catch null;
            } else {
                entry.hash = file_hasher.hashFile(entry.path) catch null;
            }

            // Update completed count
            const completed = self.completed.fetchAdd(1, .release) + 1;

            // Update progress (every 100 files or so to reduce callback overhead)
            if (completed % 100 == 0 or completed == self.jobs.items.len) {
                self.progress.files_processed = completed;
                if (self.progress_callback) |cb| {
                    cb(&self.progress);
                }
            }
        }
    }

    /// Get number of completed jobs
    pub fn getCompleted(self: *const ParallelHasher) usize {
        return self.completed.load(.acquire);
    }

    /// Clear all jobs for reuse
    pub fn clearJobs(self: *ParallelHasher) void {
        self.jobs.clearRetainingCapacity();
    }
};

// ============================================================================
// Convenience functions for batch hashing
// ============================================================================

/// Hash multiple files in parallel (quick hash)
pub fn parallelQuickHash(
    allocator: std.mem.Allocator,
    files: []types.FileEntry,
    indices: []const usize,
    quick_hash_size: usize,
    algorithm: types.Config.HashAlgorithm,
    thread_count: u32,
    progress_callback: ?types.ProgressCallback,
) !void {
    var hasher_pool = ParallelHasher.init(allocator, files, algorithm, thread_count);
    defer hasher_pool.deinit();

    if (progress_callback) |cb| {
        hasher_pool.setProgressCallback(cb);
        hasher_pool.progress.phase = .quick_hashing;
    }

    for (indices) |idx| {
        try hasher_pool.addQuickHashJob(idx, quick_hash_size);
    }

    try hasher_pool.run();
}

/// Hash multiple files in parallel (full hash)
pub fn parallelFullHash(
    allocator: std.mem.Allocator,
    files: []types.FileEntry,
    indices: []const usize,
    algorithm: types.Config.HashAlgorithm,
    thread_count: u32,
    progress_callback: ?types.ProgressCallback,
) !void {
    var hasher_pool = ParallelHasher.init(allocator, files, algorithm, thread_count);
    defer hasher_pool.deinit();

    if (progress_callback) |cb| {
        hasher_pool.setProgressCallback(cb);
        hasher_pool.progress.phase = .full_hashing;
    }

    for (indices) |idx| {
        try hasher_pool.addFullHashJob(idx);
    }

    try hasher_pool.run();
}

// ============================================================================
// Tests
// ============================================================================

test "ParallelHasher initialization" {
    const allocator = std.testing.allocator;
    var files: [0]types.FileEntry = .{};
    var hasher_pool = ParallelHasher.init(allocator, &files, .blake3, 4);
    defer hasher_pool.deinit();

    try std.testing.expectEqual(@as(usize, 0), hasher_pool.jobs.items.len);
}

test "ParallelHasher job queue" {
    const allocator = std.testing.allocator;
    var files: [0]types.FileEntry = .{};
    var hasher_pool = ParallelHasher.init(allocator, &files, .blake3, 4);
    defer hasher_pool.deinit();

    try hasher_pool.addQuickHashJob(0, 4096);
    try hasher_pool.addQuickHashJob(1, 4096);
    try hasher_pool.addFullHashJob(2);

    try std.testing.expectEqual(@as(usize, 3), hasher_pool.jobs.items.len);
    try std.testing.expect(hasher_pool.jobs.items[0].quick_hash);
    try std.testing.expect(hasher_pool.jobs.items[1].quick_hash);
    try std.testing.expect(!hasher_pool.jobs.items[2].quick_hash);
}
