//! The Worker - Compute Drone for the Brute-Force Swarm
//!
//! Responsibilities:
//! - Connect to Queen and receive test library path
//! - Dynamically load test function via dlopen()
//! - Request and execute task chunks using multi-threaded pool
//! - Report successful results
//! - Send periodic heartbeats
//!
//! Architecture: "Dumb Workhorse" - Worker is test-agnostic.
//! Queen specifies which .so library to load at connection time.

const std = @import("std");
const posix = std.posix;
const c = std.c;
const protocol = @import("protocol");
const variable_tester = @import("variable_tester");
const test_interface = @import("test_interface");

// Zig 0.16 compatibility: std.Thread.Mutex was removed
const Mutex = struct {
    inner: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,
    pub fn lock(self: *Mutex) void {
        _ = std.c.pthread_mutex_lock(&self.inner);
    }
    pub fn unlock(self: *Mutex) void {
        _ = std.c.pthread_mutex_unlock(&self.inner);
    }
};

// Darwin nanosleep for delays
const timespec = extern struct {
    sec: isize,
    nsec: isize,
};
extern "c" fn nanosleep(req: *const timespec, rem: ?*timespec) c_int;

fn sleepNs(sec: u64, nsec: u64) void {
    const ts = timespec{
        .sec = @intCast(sec),
        .nsec = @intCast(nsec),
    };
    _ = nanosleep(&ts, null);
}

fn sleepSec(sec: u64) void {
    sleepNs(sec, 0);
}

/// Worker configuration
pub const WorkerConfig = struct {
    queen_host: []const u8 = "127.0.0.1",
    queen_port: u16 = protocol.DEFAULT_PORT,
    num_threads: ?usize = null, // null = auto-detect
};

/// Task item for thread pool processing
const TaskItem = struct {
    task_id: u64,
    data: []const u8,
    test_fn_id: u32,
};

/// Thread-safe task queue for parallel processing
const TaskQueue = struct {
    items: []TaskItem,
    head: std.atomic.Value(usize),
    tail: std.atomic.Value(usize),
    capacity: usize,

    fn init(allocator: std.mem.Allocator, capacity: usize) !*TaskQueue {
        const self = try allocator.create(TaskQueue);
        self.items = try allocator.alloc(TaskItem, capacity);
        self.head = std.atomic.Value(usize).init(0);
        self.tail = std.atomic.Value(usize).init(0);
        self.capacity = capacity;
        return self;
    }

    fn deinit(self: *TaskQueue, allocator: std.mem.Allocator) void {
        allocator.free(self.items);
        allocator.destroy(self);
    }

    fn push(self: *TaskQueue, item: TaskItem) bool {
        const tail = self.tail.load(.monotonic);
        const next_tail = (tail + 1) % self.capacity;
        if (next_tail == self.head.load(.acquire)) return false; // Full
        self.items[tail] = item;
        self.tail.store(next_tail, .release);
        return true;
    }

    fn pop(self: *TaskQueue) ?TaskItem {
        const head = self.head.load(.monotonic);
        if (head == self.tail.load(.acquire)) return null; // Empty
        const item = self.items[head];
        self.head.store((head + 1) % self.capacity, .release);
        return item;
    }

    fn isEmpty(self: *TaskQueue) bool {
        return self.head.load(.acquire) == self.tail.load(.acquire);
    }
};

/// The Worker drone
pub const Worker = struct {
    allocator: std.mem.Allocator,
    config: WorkerConfig,
    sockfd: posix.socket_t,
    worker_id: u64,
    assigned_id: u64,
    chunk_size: u32,
    running: std.atomic.Value(bool),

    // Dynamically loaded test library
    test_lib: ?test_interface.TestLibrary,
    test_lib_path: ?[]u8, // Allocated copy of library path

    // Statistics
    tasks_processed: std.atomic.Value(u64),
    tasks_succeeded: std.atomic.Value(u64),
    start_time: i64,

    // Thread pool for parallel processing
    num_threads: usize,
    task_queue: ?*TaskQueue,
    pool_running: std.atomic.Value(bool),
    pool_threads: ?[]std.Thread,
    pending_tasks: std.atomic.Value(u64),

    // Result reporting mutex (socket is not thread-safe)
    result_mutex: Mutex,

    pub fn init(allocator: std.mem.Allocator, config: WorkerConfig) !*Worker {
        const self = try allocator.create(Worker);
        errdefer allocator.destroy(self);

        // Generate random worker ID using linux getrandom syscall
        var random_bytes: [8]u8 = undefined;
        _ = std.os.linux.getrandom(&random_bytes, random_bytes.len, 0);
        const worker_id = std.mem.readInt(u64, &random_bytes, .little);

        const num_threads = config.num_threads orelse try std.Thread.getCpuCount();

        // Create task queue with large capacity for buffering
        const queue_capacity: usize = 1024 * 1024; // 1M task buffer
        const task_queue = try TaskQueue.init(allocator, queue_capacity);
        errdefer task_queue.deinit(allocator);

        self.* = Worker{
            .allocator = allocator,
            .config = config,
            .sockfd = undefined,
            .worker_id = worker_id,
            .assigned_id = 0,
            .chunk_size = 0,
            .running = std.atomic.Value(bool).init(false),
            .test_lib = null,
            .test_lib_path = null,
            .tasks_processed = std.atomic.Value(u64).init(0),
            .tasks_succeeded = std.atomic.Value(u64).init(0),
            .start_time = 0,
            .num_threads = num_threads,
            .task_queue = task_queue,
            .pool_running = std.atomic.Value(bool).init(false),
            .pool_threads = null,
            .pending_tasks = std.atomic.Value(u64).init(0),
            .result_mutex = Mutex{},
        };

        return self;
    }

    pub fn deinit(self: *Worker) void {
        self.stop();

        // Unload test library
        if (self.test_lib) |*lib| {
            lib.unload();
        }
        if (self.test_lib_path) |path| {
            self.allocator.free(path);
        }

        // Clean up thread pool
        if (self.pool_threads) |threads| {
            self.allocator.free(threads);
        }

        // Clean up task queue
        if (self.task_queue) |queue| {
            queue.deinit(self.allocator);
        }

        self.allocator.destroy(self);
    }

    /// Connect to Queen
    pub fn connect(self: *Worker) !void {
        // Create socket
        const sockfd_ret = c.socket(c.AF.INET, c.SOCK.STREAM, c.IPPROTO.TCP);
        if (sockfd_ret < 0) return error.SocketCreateFailed;
        self.sockfd = @intCast(sockfd_ret);
        errdefer _ = std.c.close(self.sockfd);

        // Parse host IP
        var ip_parts: [4]u8 = undefined;
        var iter = std.mem.splitScalar(u8, self.config.queen_host, '.');
        var idx: usize = 0;
        while (iter.next()) |part| : (idx += 1) {
            if (idx >= 4) return error.InvalidIPAddress;
            ip_parts[idx] = try std.fmt.parseInt(u8, part, 10);
        }
        if (idx != 4) return error.InvalidIPAddress;

        // Connect
        var addr: c.sockaddr.in = .{
            .family = c.AF.INET,
            .port = std.mem.nativeToBig(u16, self.config.queen_port),
            .addr = std.mem.nativeToBig(u32, (@as(u32, ip_parts[0]) << 24) | (@as(u32, ip_parts[1]) << 16) | (@as(u32, ip_parts[2]) << 8) | ip_parts[3]),
        };

        if (c.connect(self.sockfd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) < 0) {
            return error.ConnectFailed;
        }

        std.debug.print("🐝 Connected to Queen at {s}:{}\n", .{ self.config.queen_host, self.config.queen_port });

        // Send hello
        const hello = protocol.WorkerHello.init(@intCast(self.num_threads), self.worker_id);
        try protocol.Net.sendStruct(self.sockfd, .worker_hello, hello);

        // Receive welcome
        var buffer: [1024]u8 = undefined;
        const header = try protocol.Net.recvHeader(self.sockfd, &buffer);

        if (header.msg_type != .queen_welcome) {
            return error.UnexpectedResponse;
        }

        const payload = try protocol.Net.recvPayload(self.sockfd, &buffer, header.payload_len);
        const welcome: *const protocol.QueenWelcome = @ptrCast(@alignCast(payload.ptr));

        self.assigned_id = welcome.assigned_id;
        self.chunk_size = welcome.chunk_size;

        std.debug.print("🐝 Registered as Worker {} (chunk_size={})\n", .{ self.assigned_id, self.chunk_size });

        // Extract and load test library path
        if (welcome.test_lib_len > 0) {
            const lib_path_start = @sizeOf(protocol.QueenWelcome);
            const lib_path_end = lib_path_start + welcome.test_lib_len;
            if (lib_path_end > payload.len) return error.InvalidPayload;

            const lib_path = payload[lib_path_start..lib_path_end];

            // Store a copy of the path
            self.test_lib_path = try self.allocator.dupe(u8, lib_path);
            errdefer {
                self.allocator.free(self.test_lib_path.?);
                self.test_lib_path = null;
            }

            std.debug.print("🐝 Loading test library: {s}\n", .{lib_path});

            // Load the shared library via dlopen
            self.test_lib = try test_interface.TestLibrary.load(lib_path);
            errdefer {
                self.test_lib.?.unload();
                self.test_lib = null;
            }

            std.debug.print("🐝 Test library loaded successfully\n", .{});
        } else {
            std.debug.print("🐝 Warning: No test library specified by Queen\n", .{});
        }
    }

    /// Start the worker loop
    pub fn start(self: *Worker) !void {
        if (self.running.load(.acquire)) return error.AlreadyRunning;
        self.running.store(true, .release);
        self.pool_running.store(true, .release);

        var start_ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.REALTIME, &start_ts);
        self.start_time = start_ts.sec;

        // Spawn thread pool for parallel task execution
        const threads = try self.allocator.alloc(std.Thread, self.num_threads);
        self.pool_threads = threads;

        for (0..self.num_threads) |i| {
            threads[i] = try std.Thread.spawn(.{}, workerThreadLoop, .{self});
        }

        std.debug.print("🐝 Started {} worker threads\n", .{self.num_threads});

        // Spawn heartbeat thread
        _ = try std.Thread.spawn(.{}, heartbeatLoop, .{self});

        // Main work loop (receives chunks and distributes to thread pool)
        self.workLoop();

        // Wait for all pending tasks to complete
        while (self.pending_tasks.load(.acquire) > 0) {
            sleepNs(0, 1_000_000); // 1ms
        }

        // Signal pool threads to stop and wait for them
        self.pool_running.store(false, .release);
        for (threads) |thread| {
            thread.join();
        }
    }

    /// Stop the worker
    pub fn stop(self: *Worker) void {
        if (self.running.load(.acquire)) {
            self.running.store(false, .release);
            self.pool_running.store(false, .release);
            _ = std.c.close(self.sockfd);
        }
    }

    /// Worker thread loop - pulls tasks from queue and executes them
    fn workerThreadLoop(self: *Worker) void {
        while (self.pool_running.load(.acquire)) {
            if (self.task_queue) |queue| {
                if (queue.pop()) |task| {
                    self.executeTask(task);
                    _ = self.pending_tasks.fetchSub(1, .release);
                } else {
                    // No work available, brief spin wait
                    std.atomic.spinLoopHint();
                }
            } else break;
        }
    }

    /// Execute a single task (called by worker threads)
    fn executeTask(self: *Worker, task: TaskItem) void {
        // Use dynamically loaded test library
        if (self.test_lib) |*lib| {
            var result_buf: [4096]u8 = undefined;
            const result_code = lib.execute(task.data, &result_buf);

            _ = self.tasks_processed.fetchAdd(1, .monotonic);

            if (result_code > 0) {
                // Success - parse result from buffer
                _ = self.tasks_succeeded.fetchAdd(1, .monotonic);

                // Extract score from result buffer (format: [u8 success][padding 7][f64 ratio]...)
                const score: f64 = if (result_code >= 16)
                    @bitCast(result_buf[8..16].*)
                else
                    1.0;

                const result = variable_tester.Result{
                    .task_id = task.task_id,
                    .success = true,
                    .score = score,
                    .data = result_buf[0..@intCast(result_code)],
                };

                // Report result to Queen (mutex protected)
                self.result_mutex.lock();
                defer self.result_mutex.unlock();
                self.reportResult(task.task_id, result) catch {};
            }
            // result_code <= 0 means no match or error, no reporting needed
        } else {
            // No library loaded - count as processed but failed
            _ = self.tasks_processed.fetchAdd(1, .monotonic);
        }
    }

    /// Main work loop
    fn workLoop(self: *Worker) void {
        var buffer: [1024 * 1024]u8 = undefined; // 1MB buffer for task data

        while (self.running.load(.acquire)) {
            // Request work
            const request = protocol.WorkRequest.init(
                self.assigned_id,
                self.tasks_processed.load(.monotonic),
                self.chunk_size,
            );

            protocol.Net.sendStruct(self.sockfd, .request_work, request) catch |err| {
                std.debug.print("🐝 Failed to request work: {}\n", .{err});
                break;
            };

            // Receive response
            const header = protocol.Net.recvHeader(self.sockfd, &buffer) catch |err| {
                std.debug.print("🐝 Failed to receive work response: {}\n", .{err});
                break;
            };

            switch (header.msg_type) {
                .dispatch_work => {
                    const payload = protocol.Net.recvPayload(self.sockfd, &buffer, header.payload_len) catch |err| {
                        std.debug.print("🐝 Failed to receive work payload: {}\n", .{err});
                        break;
                    };
                    self.processWorkChunk(payload);
                },
                .no_work => {
                    std.debug.print("🐝 No more work available, waiting...\n", .{});
                    sleepSec(1); // Wait 1 second before retrying
                },
                .shutdown => {
                    std.debug.print("🐝 Received shutdown signal from Queen\n", .{});
                    break;
                },
                else => {
                    std.debug.print("🐝 Unexpected message type: {}\n", .{header.msg_type});
                },
            }
        }

        std.debug.print("🐝 Worker loop ended\n", .{});
    }

    /// Process a chunk of work - enqueues tasks for parallel execution
    fn processWorkChunk(self: *Worker, payload: []const u8) void {
        if (payload.len < @sizeOf(protocol.WorkDispatch)) return;

        const dispatch: *const protocol.WorkDispatch = @ptrCast(@alignCast(payload.ptr));

        std.debug.print("🐝 Enqueueing {} tasks starting at {}\n", .{ dispatch.task_count, dispatch.start_task_id });

        const queue = self.task_queue orelse return;

        // Parse tasks and enqueue for parallel processing
        var offset: usize = @sizeOf(protocol.WorkDispatch);
        var tasks_enqueued: u32 = 0;

        while (tasks_enqueued < dispatch.task_count and offset < payload.len) : (tasks_enqueued += 1) {
            if (offset + @sizeOf(protocol.TaskEntry) > payload.len) break;

            const entry: *const protocol.TaskEntry = @ptrCast(@alignCast(payload[offset..].ptr));
            offset += @sizeOf(protocol.TaskEntry);

            if (offset + entry.data_len > payload.len) break;

            const task_data = payload[offset..][0..entry.data_len];
            offset += entry.data_len;

            // Enqueue task for parallel processing
            const task_item = TaskItem{
                .task_id = entry.task_id,
                .data = task_data,
                .test_fn_id = dispatch.test_fn_id,
            };

            _ = self.pending_tasks.fetchAdd(1, .release);

            // Spin until we can enqueue (should rarely happen with 1M capacity)
            while (!queue.push(task_item)) {
                std.atomic.spinLoopHint();
            }
        }

        // Wait for all tasks in this chunk to complete before requesting more
        while (self.pending_tasks.load(.acquire) > 0) {
            std.atomic.spinLoopHint();
        }

        std.debug.print("🐝 Completed {} tasks\n", .{tasks_enqueued});
    }

    /// Report a successful result to Queen
    fn reportResult(self: *Worker, task_id: u64, result: variable_tester.Result) !void {
        var payload_buf: [4096]u8 = undefined;

        const submit = protocol.ResultSubmit.init(
            self.assigned_id,
            task_id,
            result.success,
            result.score,
            @intCast(result.data.len),
        );

        // Copy header
        const header_bytes = std.mem.asBytes(&submit);
        @memcpy(payload_buf[0..header_bytes.len], header_bytes);

        // Copy data
        @memcpy(payload_buf[header_bytes.len..][0..result.data.len], result.data);

        const total_len = header_bytes.len + result.data.len;

        try protocol.Net.sendMessage(self.sockfd, .submit_result, payload_buf[0..total_len]);

        // Wait for ACK
        var ack_buf: [64]u8 = undefined;
        const ack_header = try protocol.Net.recvHeader(self.sockfd, &ack_buf);
        if (ack_header.msg_type != .ack_result) {
            return error.UnexpectedResponse;
        }
    }

    /// Heartbeat loop
    fn heartbeatLoop(self: *Worker) void {
        while (self.running.load(.acquire)) {
            sleepSec(protocol.HEARTBEAT_INTERVAL_SEC);

            if (!self.running.load(.acquire)) break;

            var now_ts: std.c.timespec = undefined;
            if (std.c.clock_gettime(.REALTIME, &now_ts) != 0) continue;
            const now = now_ts.sec;
            const uptime: u32 = @intCast(now - self.start_time);

            const hb = protocol.Heartbeat.init(
                self.assigned_id,
                self.tasks_processed.load(.monotonic),
                self.tasks_succeeded.load(.monotonic),
                uptime,
            );

            protocol.Net.sendStruct(self.sockfd, .heartbeat, hb) catch continue;
        }
    }

    /// Get current statistics
    pub fn getStats(self: *Worker) WorkerStats {
        var now_ts: std.c.timespec = undefined;
        if (std.c.clock_gettime(.REALTIME, &now_ts) != 0) {
            return WorkerStats{
                .tasks_processed = 0,
                .tasks_succeeded = 0,
                .uptime_secs = 0,
            };
        }
        const now = now_ts.sec;

        return WorkerStats{
            .tasks_processed = self.tasks_processed.load(.monotonic),
            .tasks_succeeded = self.tasks_succeeded.load(.monotonic),
            .uptime_secs = @intCast(now - self.start_time),
        };
    }

    pub const WorkerStats = struct {
        tasks_processed: u64,
        tasks_succeeded: u64,
        uptime_secs: u32,
    };
};
