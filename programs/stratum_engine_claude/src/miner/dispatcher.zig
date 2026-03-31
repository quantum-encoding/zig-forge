//! Work Dispatcher
//! Distributes mining jobs to worker threads and collects shares

const std = @import("std");
const types = @import("../stratum/types.zig");
const Worker = @import("worker.zig").Worker;
const WorkerStats = @import("worker.zig").WorkerStats;

pub const Dispatcher = struct {
    allocator: std.mem.Allocator,
    workers: []Worker,
    threads: []std.Thread,
    global_stats: *WorkerStats,
    current_job: ?types.Job,
    current_target: types.Target,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, num_workers: u32) !Self {
        const workers = try allocator.alloc(Worker, num_workers);
        errdefer allocator.free(workers);
        const threads = try allocator.alloc(std.Thread, num_workers);
        errdefer allocator.free(threads);

        // Heap-allocate stats so pointer remains valid
        const global_stats = try allocator.create(WorkerStats);
        global_stats.* = WorkerStats.init();

        // Initialize workers with pointer to heap-allocated stats
        for (workers, 0..) |*worker, i| {
            worker.* = Worker.init(@intCast(i), global_stats);
        }

        return .{
            .allocator = allocator,
            .workers = workers,
            .threads = threads,
            .global_stats = global_stats,
            .current_job = null,
            .current_target = types.Target.fromNBits(0x1d00ffff),
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.workers);
        self.allocator.free(self.threads);
        self.allocator.destroy(self.global_stats);
    }

    /// Start all mining threads
    pub fn start(self: *Self) !void {
        for (self.workers, 0..) |*worker, i| {
            self.threads[i] = try std.Thread.spawn(.{}, Worker.run, .{worker});
        }
    }

    /// Stop all mining threads
    pub fn stop(self: *Self) void {
        // Signal all workers to stop
        for (self.workers) |*worker| {
            worker.stop();
        }

        // Wait for threads to finish
        for (self.threads) |thread| {
            thread.join();
        }
    }

    /// Update all workers with new job
    pub fn updateJob(self: *Self, job: types.Job, target: types.Target) void {
        self.current_job = job;
        self.current_target = target;

        for (self.workers) |*worker| {
            worker.updateJob(job, target);
        }
    }

    /// Get current hashrate across all workers
    pub fn getHashrate(self: *Self, duration_ns: u64) f64 {
        return self.global_stats.getHashrate(duration_ns);
    }

    /// Get total shares found
    pub fn getSharesFound(self: *Self) u32 {
        return self.global_stats.shares_found.load(.monotonic);
    }
};

test "dispatcher init" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var dispatcher = try Dispatcher.init(allocator, 4);
    defer dispatcher.deinit();

    try testing.expectEqual(@as(usize, 4), dispatcher.workers.len);
}
