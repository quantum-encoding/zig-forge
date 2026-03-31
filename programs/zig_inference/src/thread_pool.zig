const std = @import("std");
const math = @import("math.zig");
const tensor_mod = @import("tensor.zig");
const TensorView = tensor_mod.TensorView;
const Io = std.Io;

pub const WorkItem = struct {
    out: [*]f32,
    x: [*]const f32,
    weight: TensorView,
    n_rows: usize,
    n_cols: usize,
};

pub const ThreadPool = struct {
    n_threads: u32,
    threads: []std.Thread,
    work: WorkItem,
    generation: u32,
    remaining: u32,
    shutdown: bool,
    allocator: std.mem.Allocator,
    generic_work: ?GenericWork = null,
    mutex: Io.Mutex,
    gen_cond: Io.Condition,
    done_cond: Io.Condition,
    threaded: Io.Threaded,

    pub fn init(allocator: std.mem.Allocator, n_threads: u32) !*ThreadPool {
        const self = try allocator.create(ThreadPool);
        self.* = ThreadPool{
            .n_threads = n_threads,
            .threads = &.{},
            .work = undefined,
            .generation = 0,
            .remaining = 0,
            .shutdown = false,
            .allocator = allocator,
            .mutex = .init,
            .gen_cond = .init,
            .done_cond = .init,
            .threaded = .init(std.mem.Allocator.failing, .{}),
        };

        // Spawn N-1 worker threads (main thread is worker 0)
        const n_workers = n_threads - 1;
        if (n_workers > 0) {
            self.threads = try allocator.alloc(std.Thread, n_workers);
            for (0..n_workers) |i| {
                self.threads[i] = std.Thread.spawn(.{}, workerLoop, .{ self, @as(u32, @intCast(i + 1)) }) catch {
                    // If spawn fails, shrink to what we got
                    self.threads = self.threads[0..i];
                    self.n_threads = @intCast(i + 1);
                    return self;
                };
            }
        }
        return self;
    }

    fn io(self: *ThreadPool) Io {
        return self.threaded.io();
    }

    pub fn deinit(self: *ThreadPool) void {
        const sio = self.io();
        // Signal shutdown
        self.mutex.lockUncancelable(sio);
        self.shutdown = true;
        self.generation += 1;
        self.mutex.unlock(sio);
        self.gen_cond.broadcast(sio);

        // Join all worker threads
        for (self.threads) |t| {
            t.join();
        }

        if (self.threads.len > 0) {
            self.allocator.free(self.threads);
        }
        self.threaded.deinit();
        self.allocator.destroy(self);
    }

    pub fn matmul(self: *ThreadPool, out: []f32, x: []const f32, weight: TensorView) void {
        const n_rows = weight.rows();

        // For small matmuls, skip threading overhead
        if (n_rows < @as(usize, self.n_threads) * 4 or self.n_threads == 1) {
            math.matmulRows(out, x, weight, 0, n_rows);
            return;
        }

        const sio = self.io();

        // Set up work descriptor and wake workers
        self.mutex.lockUncancelable(sio);
        self.work = WorkItem{
            .out = out.ptr,
            .x = x.ptr,
            .weight = weight,
            .n_rows = n_rows,
            .n_cols = weight.cols(),
        };
        self.remaining = self.n_threads;
        self.generation += 1;
        self.mutex.unlock(sio);
        self.gen_cond.broadcast(sio);

        // Main thread does its chunk as worker 0
        self.doWork(0);

        // Wait for all workers to finish
        self.mutex.lockUncancelable(sio);
        while (self.remaining != 0) {
            self.done_cond.waitUncancelable(sio, &self.mutex);
        }
        self.mutex.unlock(sio);
    }

    fn doWork(self: *ThreadPool, thread_id: u32) void {
        const n_rows = self.work.n_rows;
        const n_threads = self.n_threads;

        // Divide rows evenly; extras go to first threads
        const rows_per_thread = n_rows / n_threads;
        const extra = n_rows % n_threads;

        const start_row = if (thread_id < extra)
            thread_id * (rows_per_thread + 1)
        else
            extra * (rows_per_thread + 1) + (thread_id - @as(u32, @intCast(extra))) * rows_per_thread;

        const end_row = if (thread_id < extra)
            start_row + rows_per_thread + 1
        else
            start_row + rows_per_thread;

        if (start_row < end_row) {
            const out = self.work.out[0..self.work.n_rows];
            const x = self.work.x[0..self.work.n_cols];
            math.matmulRows(out, x, self.work.weight, start_row, end_row);
        }

        const sio = self.io();

        // Signal completion
        self.mutex.lockUncancelable(sio);
        self.remaining -= 1;
        const done = self.remaining == 0;
        self.mutex.unlock(sio);
        if (done) {
            self.done_cond.signal(sio);
        }
    }

    fn workerLoop(self: *ThreadPool, thread_id: u32) void {
        const sio = self.io();

        var my_gen: u32 = blk: {
            self.mutex.lockUncancelable(sio);
            defer self.mutex.unlock(sio);
            break :blk self.generation;
        };

        while (true) {
            // Wait for new work (generation to change)
            self.mutex.lockUncancelable(sio);
            while (self.generation == my_gen) {
                self.gen_cond.waitUncancelable(sio, &self.mutex);
            }
            my_gen = self.generation;
            const is_shutdown = self.shutdown;
            self.mutex.unlock(sio);

            // Check shutdown
            if (is_shutdown) return;

            // Check work type
            if (self.generic_work) |gw| {
                self.doGenericWork(thread_id, gw);
            } else {
                self.doWork(thread_id);
            }
        }
    }

    // ── Generic parallel dispatch ──

    pub const GenericWork = struct {
        start: usize,
        end: usize,
        context: *anyopaque,
        func: *const fn (usize, usize, *anyopaque) void,
    };

    /// Parallel for: divide [start, end) across all threads and call func for each range.
    pub fn parallelFor(
        self: *ThreadPool,
        start: usize,
        end: usize,
        context: *anyopaque,
        func: *const fn (usize, usize, *anyopaque) void,
    ) void {
        const n_items = end - start;
        if (n_items == 0) return;

        // For small work, skip threading overhead
        if (n_items < @as(usize, self.n_threads) * 2 or self.n_threads == 1) {
            func(start, end, context);
            return;
        }

        const sio = self.io();

        // Set up generic work descriptor and wake workers
        self.mutex.lockUncancelable(sio);
        self.generic_work = GenericWork{
            .start = start,
            .end = end,
            .context = context,
            .func = func,
        };
        self.remaining = self.n_threads;
        self.generation += 1;
        self.mutex.unlock(sio);
        self.gen_cond.broadcast(sio);

        // Main thread does its chunk as worker 0
        self.doGenericWork(0, self.generic_work.?);

        // Wait for all workers to finish
        self.mutex.lockUncancelable(sio);
        while (self.remaining != 0) {
            self.done_cond.waitUncancelable(sio, &self.mutex);
        }
        self.mutex.unlock(sio);

        // Clear generic work
        self.generic_work = null;
    }

    fn doGenericWork(self: *ThreadPool, thread_id: u32, gw: GenericWork) void {
        const n_items = gw.end - gw.start;
        const n_threads = self.n_threads;

        const items_per_thread = n_items / n_threads;
        const extra = n_items % n_threads;

        const my_start = gw.start + if (thread_id < extra)
            thread_id * (items_per_thread + 1)
        else
            extra * (items_per_thread + 1) + (thread_id - @as(u32, @intCast(extra))) * items_per_thread;

        const my_end = my_start + items_per_thread + @as(usize, if (thread_id < extra) 1 else 0);

        if (my_start < my_end) {
            gw.func(my_start, my_end, gw.context);
        }

        const sio = self.io();

        // Signal completion
        self.mutex.lockUncancelable(sio);
        self.remaining -= 1;
        const done = self.remaining == 0;
        self.mutex.unlock(sio);
        if (done) {
            self.done_cond.signal(sio);
        }
    }
};
