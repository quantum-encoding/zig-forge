//! Thread pool executor

const std = @import("std");

pub const ThreadPool = struct {
    allocator: std.mem.Allocator,
    threads: []?std.Thread,  // Optional to handle unstarted state
    running: std.atomic.Value(bool),

    pub fn init(allocator: std.mem.Allocator, thread_count: usize) !ThreadPool {
        const threads = try allocator.alloc(?std.Thread, thread_count);
        // Initialize all to null (not started)
        for (threads) |*t| {
            t.* = null;
        }

        return ThreadPool{
            .allocator = allocator,
            .threads = threads,
            .running = std.atomic.Value(bool).init(false),
        };
    }

    pub fn deinit(self: *ThreadPool) void {
        self.running.store(false, .release);
        for (self.threads) |maybe_thread| {
            if (maybe_thread) |thread| {
                thread.join();
            }
        }
        self.allocator.free(self.threads);
    }

    // Note: Thread pool threads are started by Scheduler
    // The workerThread function is now in the Scheduler implementation
};
