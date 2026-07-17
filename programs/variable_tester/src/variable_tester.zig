const std = @import("std");
// N worker threads pop tasks from one shared queue and push into one shared
// result queue. That is multi-producer/multi-consumer on both queues, so an
// SPSC (single-producer/single-consumer) queue is the wrong primitive and
// races/corrupts under >1 worker. Use the lock-free MPMC queue instead.
const mpmc = @import("lockfree_queue").mpmc;

/// Task represents a unit of work to be tested
pub const Task = struct {
    id: u64,
    data: []const u8,

    pub fn init(id: u64, data: []const u8) Task {
        return Task{
            .id = id,
            .data = data,
        };
    }
};

/// Result represents the outcome of a test
pub const Result = struct {
    task_id: u64,
    success: bool,
    data: []const u8,
    score: f64, // Quality metric (e.g., compression ratio)

    pub fn init(task_id: u64, success: bool, data: []const u8, score: f64) Result {
        return Result{
            .task_id = task_id,
            .success = success,
            .data = data,
            .score = score,
        };
    }
};

/// TestFunction is the pluggable test interface
pub const TestFn = *const fn (task: *const Task, allocator: std.mem.Allocator) anyerror!Result;

/// WorkerContext holds per-worker state
pub const WorkerContext = struct {
    id: usize,
    task_queue: *mpmc.MpmcQueue(Task),
    result_queue: *mpmc.MpmcQueue(Result),
    test_fn: TestFn,
    allocator: std.mem.Allocator,
    running: *std.atomic.Value(bool),
    stats: WorkerStats,

    pub const WorkerStats = struct {
        tasks_processed: std.atomic.Value(u64),
        tasks_succeeded: std.atomic.Value(u64),
        tasks_failed: std.atomic.Value(u64),

        pub fn init() WorkerStats {
            return WorkerStats{
                .tasks_processed = std.atomic.Value(u64).init(0),
                .tasks_succeeded = std.atomic.Value(u64).init(0),
                .tasks_failed = std.atomic.Value(u64).init(0),
            };
        }
    };

    pub fn init(
        id: usize,
        task_queue: *mpmc.MpmcQueue(Task),
        result_queue: *mpmc.MpmcQueue(Result),
        test_fn: TestFn,
        allocator: std.mem.Allocator,
        running: *std.atomic.Value(bool),
    ) WorkerContext {
        return WorkerContext{
            .id = id,
            .task_queue = task_queue,
            .result_queue = result_queue,
            .test_fn = test_fn,
            .allocator = allocator,
            .running = running,
            .stats = WorkerStats.init(),
        };
    }
};

/// Worker thread main loop
pub fn workerThread(ctx: *WorkerContext) void {
    while (ctx.running.load(.acquire)) {
        // Try to get a task
        const task = ctx.task_queue.pop() catch {
            // No tasks available, yield
            std.atomic.spinLoopHint();
            continue;
        };

        // Execute test function
        const result = ctx.test_fn(&task, ctx.allocator) catch |err| {
            _ = ctx.stats.tasks_failed.fetchAdd(1, .monotonic);
            std.debug.print("[Worker {}] Test failed for task {}: {}\n", .{ ctx.id, task.id, err });
            continue;
        };

        // Update statistics
        _ = ctx.stats.tasks_processed.fetchAdd(1, .monotonic);
        if (result.success) {
            _ = ctx.stats.tasks_succeeded.fetchAdd(1, .monotonic);
        } else {
            _ = ctx.stats.tasks_failed.fetchAdd(1, .monotonic);
        }

        // Push result to output queue
        ctx.result_queue.push(result) catch |err| {
            std.debug.print("[Worker {}] Failed to push result: {}\n", .{ ctx.id, err });
        };
    }
}

/// VariableTester orchestrates the brute-force testing engine
pub const VariableTester = struct {
    allocator: std.mem.Allocator,
    task_queue: mpmc.MpmcQueue(Task),
    result_queue: mpmc.MpmcQueue(Result),
    workers: []std.Thread,
    worker_contexts: []WorkerContext,
    running: std.atomic.Value(bool),
    test_fn: TestFn,

    pub fn init(
        allocator: std.mem.Allocator,
        num_workers: usize,
        queue_capacity: usize,
        test_fn: TestFn,
    ) !*VariableTester {
        const self = try allocator.create(VariableTester);
        errdefer allocator.destroy(self);

        // Initialize task and result queues
        var task_queue = try mpmc.MpmcQueue(Task).init(allocator, queue_capacity);
        errdefer task_queue.deinit();

        var result_queue = try mpmc.MpmcQueue(Result).init(allocator, queue_capacity);
        errdefer result_queue.deinit();

        // Allocate worker arrays
        const workers = try allocator.alloc(std.Thread, num_workers);
        errdefer allocator.free(workers);

        const worker_contexts = try allocator.alloc(WorkerContext, num_workers);
        errdefer allocator.free(worker_contexts);

        self.* = VariableTester{
            .allocator = allocator,
            .task_queue = task_queue,
            .result_queue = result_queue,
            .workers = workers,
            .worker_contexts = worker_contexts,
            .running = std.atomic.Value(bool).init(false),
            .test_fn = test_fn,
        };

        return self;
    }

    pub fn deinit(self: *VariableTester) void {
        self.stop();
        self.allocator.free(self.workers);
        self.allocator.free(self.worker_contexts);
        self.task_queue.deinit();
        self.result_queue.deinit();
        self.allocator.destroy(self);
    }

    pub fn start(self: *VariableTester) !void {
        if (self.running.load(.acquire)) {
            return error.AlreadyRunning;
        }

        self.running.store(true, .release);

        // Spawn worker threads
        for (self.workers, 0..) |*worker, i| {
            self.worker_contexts[i] = WorkerContext.init(
                i,
                &self.task_queue,
                &self.result_queue,
                self.test_fn,
                self.allocator,
                &self.running,
            );

            worker.* = try std.Thread.spawn(.{}, workerThread, .{&self.worker_contexts[i]});
        }
    }

    pub fn stop(self: *VariableTester) void {
        if (!self.running.load(.acquire)) {
            return;
        }

        self.running.store(false, .release);

        // Join all worker threads
        for (self.workers) |worker| {
            worker.join();
        }
    }

    pub fn submitTask(self: *VariableTester, task: Task) !void {
        try self.task_queue.push(task);
    }

    pub fn collectResult(self: *VariableTester) ?Result {
        return self.result_queue.pop() catch null;
    }

    pub fn getStats(self: *VariableTester) TesterStats {
        var stats = TesterStats{
            .total_processed = 0,
            .total_succeeded = 0,
            .total_failed = 0,
        };

        for (self.worker_contexts) |*ctx| {
            stats.total_processed += ctx.stats.tasks_processed.load(.monotonic);
            stats.total_succeeded += ctx.stats.tasks_succeeded.load(.monotonic);
            stats.total_failed += ctx.stats.tasks_failed.load(.monotonic);
        }

        return stats;
    }

    pub const TesterStats = struct {
        total_processed: u64,
        total_succeeded: u64,
        total_failed: u64,
    };
};

// ============================ Tests ============================

test "Task.init / Result.init store fields" {
    const t = Task.init(7, "abc");
    try std.testing.expectEqual(@as(u64, 7), t.id);
    try std.testing.expectEqualStrings("abc", t.data);

    const r = Result.init(7, true, "xy", 1.5);
    try std.testing.expectEqual(@as(u64, 7), r.task_id);
    try std.testing.expect(r.success);
    try std.testing.expectEqualStrings("xy", r.data);
    try std.testing.expectEqual(@as(f64, 1.5), r.score);
}

// Deterministic test function used by the concurrency tests below.
// Succeeds iff the task id is even; allocates a 1-byte result payload so the
// collector exercises the same free path as the real `main`.
fn evenParityTest(task: *const Task, allocator: std.mem.Allocator) anyerror!Result {
    const buf = try allocator.alloc(u8, 1);
    buf[0] = @truncate(task.id);
    return Result.init(task.id, (task.id % 2) == 0, buf, @floatFromInt(task.id));
}

// This is the regression test for the SPSC-misuse fix: N worker threads pop
// from one shared task queue and push into one shared result queue. With the
// old single-producer/single-consumer queue this races and drops/dupes items;
// with the MPMC queue every task must be processed exactly once.
test "VariableTester processes every task exactly once across N workers" {
    // Concurrent test_fn allocations run across worker threads, so a
    // thread-safe allocator is required (std.testing.allocator is not).
    const allocator = std.heap.smp_allocator;

    const num_workers: usize = 8;
    const queue_capacity: usize = 4096; // power of two, >= num_tasks
    const num_tasks: u64 = 2000;

    const tester = try VariableTester.init(allocator, num_workers, queue_capacity, evenParityTest);
    defer tester.deinit();

    try tester.start();

    var task_id: u64 = 0;
    while (task_id < num_tasks) : (task_id += 1) {
        // Retry on transient QueueFull (shouldn't happen at this capacity, but
        // keep the producer robust rather than dropping work).
        while (true) {
            tester.submitTask(Task.init(task_id, "formula")) catch {
                std.atomic.spinLoopHint();
                continue;
            };
            break;
        }
    }

    var seen = try allocator.alloc(bool, num_tasks);
    defer allocator.free(seen);
    @memset(seen, false);

    var collected: u64 = 0;
    var succeeded: u64 = 0;
    while (collected < num_tasks) {
        if (tester.collectResult()) |result| {
            // No task id may be reported twice.
            try std.testing.expect(!seen[result.task_id]);
            seen[result.task_id] = true;
            // Success flag must match the deterministic parity rule.
            try std.testing.expectEqual((result.task_id % 2) == 0, result.success);
            if (result.success) succeeded += 1;
            allocator.free(result.data);
            collected += 1;
        } else {
            std.atomic.spinLoopHint();
        }
    }

    tester.stop();

    // Every id appeared exactly once.
    for (seen) |s| try std.testing.expect(s);
    try std.testing.expectEqual(num_tasks, collected);
    // Exactly half the ids (the even ones) succeeded.
    try std.testing.expectEqual(num_tasks / 2, succeeded);

    const stats = tester.getStats();
    try std.testing.expectEqual(num_tasks, stats.total_processed);
    try std.testing.expectEqual(num_tasks / 2, stats.total_succeeded);
    try std.testing.expectEqual(num_tasks / 2, stats.total_failed);
}
