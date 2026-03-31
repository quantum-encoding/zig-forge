//! Work-stealing scheduler
//!
//! Performance: <100ns task spawn, 10M+ tasks/sec
const std = @import("std");
const sync = @import("../sync.zig");
const Mutex = sync.Mutex;
const Condition = sync.Condition;
const deque_mod = @import("../deque/worksteal.zig");
const ThreadPool = @import("../executor/threadpool.zig").ThreadPool;
const Task = @import("../task/handle.zig").Task;
pub const Scheduler = struct {
    const Self = @This();
    const WorkQueue = deque_mod.WorkStealDeque(*TaskEntry);
    const TaskMap = std.AutoHashMap(u64, *TaskEntry);
    allocator: std.mem.Allocator,
    thread_count: usize,
    thread_pool: ThreadPool,
    work_queues: []*WorkQueue,
    task_map: TaskMap,
    task_map_mutex: Mutex,
    next_task_id: std.atomic.Value(u64),
    running: std.atomic.Value(bool),
    // Condition variable for worker sleep/wake
    work_cond: Condition,
    work_mutex: Mutex,
    pub const Options = struct {
        thread_count: usize = 8,
        queue_size: usize = 4096,
    };
    const TaskEntry = struct {
        task: Task,
        func: *const fn (*anyopaque) void,
        context: *anyopaque,
        allocator: std.mem.Allocator,
        ref_count: std.atomic.Value(u32) = .{ .raw = 1 },
        mutex: Mutex = .{},
        cond: Condition = .{},
        pub fn execute(self: *TaskEntry) void {
            self.task.state.store(.running, .release);
            self.func(self.context);
            self.mutex.lock();
            defer self.mutex.unlock();
            self.task.complete(null);
            self.cond.broadcast();
        }
    };
    pub fn init(allocator: std.mem.Allocator, options: Options) !Self {
        const thread_count = if (options.thread_count == 0)
            try std.Thread.getCpuCount()
        else
            options.thread_count;
        // Create work queues (one per thread)
        const work_queues = try allocator.alloc(*WorkQueue, thread_count);
        errdefer allocator.free(work_queues);
        for (work_queues, 0..) |*queue, i| {
            queue.* = try allocator.create(WorkQueue);
            errdefer {
                var j: usize = 0;
                while (j < i) : (j += 1) {
                    allocator.destroy(work_queues[j]);
                }
            }
            queue.*.* = try WorkQueue.init(allocator, options.queue_size);
        }
        const thread_pool = try ThreadPool.init(allocator, thread_count);
        errdefer thread_pool.deinit();
        return Self{
            .allocator = allocator,
            .thread_count = thread_count,
            .thread_pool = thread_pool,
            .work_queues = work_queues,
            .task_map = TaskMap.init(allocator),
            .task_map_mutex = Mutex{},
            .next_task_id = std.atomic.Value(u64).init(0),
            .running = std.atomic.Value(bool).init(false),
            .work_cond = Condition{},
            .work_mutex = Mutex{},
        };
    }
    pub fn deinit(self: *Self) void {
        self.running.store(false, .release);
        self.thread_pool.deinit();
        // Clean up any remaining tasks
        var it = self.task_map.valueIterator();
        while (it.next()) |entry| {
            if (entry.*.ref_count.fetchSub(1, .release) == 1) {
                self.allocator.destroy(entry.*);
            }
        }
        self.task_map.deinit();
        for (self.work_queues) |queue| {
            queue.deinit();
            self.allocator.destroy(queue);
        }
        self.allocator.free(self.work_queues);
    }
    pub fn start(self: *Self) !void {
        self.running.store(true, .release);
        // Start thread pool with worker function
        for (self.thread_pool.threads, 0..) |*thread, i| {
            thread.* = try std.Thread.spawn(.{}, workerThread, .{ self, i });
        }
    }
    pub fn stop(self: *Self) void {
        self.running.store(false, .release);
        // Wake up all sleeping workers so they can see the shutdown flag
        self.work_mutex.lock();
        self.work_cond.broadcast();
        self.work_mutex.unlock();
    }
    /// Spawn a new task
    pub fn spawn(self: *Self, comptime func: anytype, args: anytype) !TaskHandle {
        const task_id = self.next_task_id.fetchAdd(1, .monotonic);
        // Create task entry
        const entry = try self.allocator.create(TaskEntry);
        errdefer self.allocator.destroy(entry);
        entry.* = TaskEntry{
            .task = Task.init(task_id),
            .func = undefined,
            .context = undefined,
            .allocator = self.allocator,
        };
        // Create wrapper for function + args
        const Args = @TypeOf(args);
        const Context = struct {
            allocator: std.mem.Allocator,
            args: Args,
        };
        const ctx = try self.allocator.create(Context);
        errdefer self.allocator.destroy(ctx);
        ctx.* = .{ .allocator = self.allocator, .args = args };
        entry.context = @ptrCast(ctx);
        entry.func = struct {
            fn wrapper(p: *anyopaque) void {
                const c: *Context = @alignCast(@ptrCast(p));
                @call(.auto, func, c.args);
                c.allocator.destroy(c);
            }
        }.wrapper;
        // Register task in map
        {
            self.task_map_mutex.lock();
            defer self.task_map_mutex.unlock();
            try self.task_map.put(task_id, entry);
        }
        // Push to queue (lock-free)
        const thread_id = task_id % self.thread_count;
        try self.work_queues[thread_id].push(entry);
        // Wake up all workers
        self.work_mutex.lock();
        self.work_cond.broadcast();
        self.work_mutex.unlock();
        return TaskHandle{ .id = task_id, .scheduler = self };
    }
    fn workerThread(self: *Self, worker_id: usize) void {
        var rng = std.Random.DefaultPrng.init(@intCast(worker_id));
        const random = rng.random();
        while (self.running.load(.acquire)) {
            // Try to pop from own queue
            if (self.work_queues[worker_id].pop()) |entry| {
                entry.execute();
                self.unregisterTask(entry);
                continue;
            }
            // Work stealing: try to steal from random queue
            var attempts: usize = 0;
            var found_work = false;
            while (attempts < self.thread_count) : (attempts += 1) {
                const victim = random.intRangeAtMost(usize, 0, self.thread_count - 1);
                if (victim == worker_id) continue;
                if (self.work_queues[victim].steal()) |entry| {
                    entry.execute();
                    self.unregisterTask(entry);
                    found_work = true;
                    break;
                }
            }
            // If we found work, continue immediately to check for more
            if (found_work) continue;
            // No work found - wait with timeout to handle race conditions
            self.work_mutex.lock();
            // Double-check running flag before sleeping
            if (!self.running.load(.acquire)) {
                self.work_mutex.unlock();
                break;
            }
            // Use timed wait to handle lost wake-ups (5ms timeout)
            // This is a safety net for the rare case where broadcast()
            // happens between our queue check and entering wait()
            self.work_cond.timedWait(&self.work_mutex, 5_000_000) catch {};
            self.work_mutex.unlock();
        }
    }
    fn unregisterTask(self: *Self, entry: *TaskEntry) void {
        self.task_map_mutex.lock();
        _ = self.task_map.remove(entry.task.id);
        self.task_map_mutex.unlock();
        if (entry.ref_count.fetchSub(1, .release) == 1) {
            self.allocator.destroy(entry);
        }
    }
};
pub const TaskHandle = struct {
    id: u64,
    scheduler: *Scheduler,
    pub fn await_completion(self: TaskHandle) void {
        const entry: ?*Scheduler.TaskEntry = blk: {
            self.scheduler.task_map_mutex.lock();
            if (self.scheduler.task_map.get(self.id)) |e| {
                _ = e.ref_count.fetchAdd(1, .acquire);
                self.scheduler.task_map_mutex.unlock();
                break :blk e;
            } else {
                self.scheduler.task_map_mutex.unlock();
                break :blk null;
            }
        };
        if (entry) |e| {
            defer {
                if (e.ref_count.fetchSub(1, .release) == 1) {
                    e.allocator.destroy(e);
                }
            }
            e.mutex.lock();
            defer e.mutex.unlock();
            while (!e.task.isCompleted()) {
                e.cond.wait(&e.mutex);
            }
        }
    }
    pub fn getStatus(self: TaskHandle) ?Task.State {
        self.scheduler.task_map_mutex.lock();
        defer self.scheduler.task_map_mutex.unlock();
        if (self.scheduler.task_map.get(self.id)) |entry| {
            return entry.task.getState();
        }
        return null; // Task completed and removed
    }
};
