//! Parallel directory walker with lock-free inode tracking
//!
//! Key optimizations over Rust uutils:
//! - Per-thread inode sets (no Arc<Mutex<HashSet>> contention)
//! - Direct thread spawning (no thread pool overhead)
//! - Atomic result aggregation
//! - Work-stealing for load balancing

const std = @import("std");
const Thread = std.Thread;
const Atomic = std.atomic.Value;
const main = @import("main.zig");

// Zig 0.16 compatible Mutex (std.Thread.Mutex was removed)
const Mutex = struct {
    inner: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,

    pub fn lock(self: *Mutex) void {
        _ = std.c.pthread_mutex_lock(&self.inner);
    }

    pub fn unlock(self: *Mutex) void {
        _ = std.c.pthread_mutex_unlock(&self.inner);
    }
};
const Options = main.Options;
const DirStat = main.DirStat;
const libc = std.c;

const Timespec = extern struct {
    sec: i64,
    nsec: i64,
};

extern "c" fn nanosleep(req: *const Timespec, rem: ?*Timespec) c_int;

fn sleepNs(ns: u64) void {
    const req = Timespec{
        .sec = @intCast(ns / 1_000_000_000),
        .nsec = @intCast(ns % 1_000_000_000),
    };
    _ = nanosleep(&req, null);
}

/// Minimum directories to enable parallelism
const PARALLEL_THRESHOLD: usize = 4;

/// Maximum worker threads
const MAX_WORKERS: usize = 32;

/// Atomic u64 for lock-free aggregation
const AtomicU64 = Atomic(u64);

/// Thread-safe work queue for directories
const WorkQueue = struct {
    items: std.ArrayList(WorkItem),
    mutex: Mutex,
    done: Atomic(bool),

    const WorkItem = struct {
        path: []const u8,
        depth: usize,
        dev: u64,
    };

    fn init(allocator: std.mem.Allocator) !*WorkQueue {
        const self = try allocator.create(WorkQueue);
        self.* = .{
            .items = try std.ArrayList(WorkItem).initCapacity(allocator, 256),
            .mutex = .{},
            .done = Atomic(bool).init(false),
        };
        return self;
    }

    fn deinit(self: *WorkQueue, allocator: std.mem.Allocator) void {
        self.items.deinit(allocator);
        allocator.destroy(self);
    }

    fn push(self: *WorkQueue, allocator: std.mem.Allocator, item: WorkItem) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.items.append(allocator, item);
    }

    fn pop(self: *WorkQueue) ?WorkItem {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.items.items.len == 0) return null;
        return self.items.pop();
    }

    fn setDone(self: *WorkQueue) void {
        self.done.store(true, .release);
    }

    fn isDone(self: *WorkQueue) bool {
        return self.done.load(.acquire);
    }
};

/// Shared state for parallel workers
const SharedState = struct {
    queue: *WorkQueue,
    options: Options,
    root_dev: u64,
    allocator: std.mem.Allocator,

    // Atomic counters for results
    total_size: AtomicU64,
    total_blocks: AtomicU64,
    total_inodes: AtomicU64,

    // Results collection (mutex protected)
    results_mutex: Mutex,
    results: std.ArrayList(DirStat),

    fn init(allocator: std.mem.Allocator, options: Options, root_dev: u64) !*SharedState {
        const self = try allocator.create(SharedState);
        self.* = .{
            .queue = try WorkQueue.init(allocator),
            .options = options,
            .root_dev = root_dev,
            .allocator = allocator,
            .total_size = AtomicU64.init(0),
            .total_blocks = AtomicU64.init(0),
            .total_inodes = AtomicU64.init(0),
            .results_mutex = .{},
            .results = try std.ArrayList(DirStat).initCapacity(allocator, 1024),
        };
        return self;
    }

    fn deinit(self: *SharedState) void {
        self.queue.deinit(self.allocator);
        self.results.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn addSize(self: *SharedState, size: u64) void {
        _ = self.total_size.fetchAdd(size, .monotonic);
    }

    fn addBlocks(self: *SharedState, blocks: u64) void {
        _ = self.total_blocks.fetchAdd(blocks, .monotonic);
    }

    fn addInodes(self: *SharedState, inodes: u64) void {
        _ = self.total_inodes.fetchAdd(inodes, .monotonic);
    }

    fn addResult(self: *SharedState, stat: DirStat) !void {
        self.results_mutex.lock();
        defer self.results_mutex.unlock();
        try self.results.append(self.allocator, stat);
    }
};

/// Per-thread worker context
const WorkerContext = struct {
    shared: *SharedState,
    seen_inodes: std.AutoHashMap(InodeKey, void),
    local_results: std.ArrayList(DirStat),
    allocator: std.mem.Allocator,

    const InodeKey = struct {
        dev: u64,
        ino: u64,
    };

    fn init(allocator: std.mem.Allocator, shared: *SharedState) !WorkerContext {
        return .{
            .shared = shared,
            .seen_inodes = std.AutoHashMap(InodeKey, void).init(allocator),
            .local_results = try std.ArrayList(DirStat).initCapacity(allocator, 128),
            .allocator = allocator,
        };
    }

    fn deinit(self: *WorkerContext) void {
        self.seen_inodes.deinit();
        self.local_results.deinit(self.allocator);
    }
};

/// Worker thread function
fn workerThread(ctx_ptr: *WorkerContext) void {
    const ctx = ctx_ptr;
    const shared = ctx.shared;
    const queue = shared.queue;

    while (true) {
        // Try to get work
        const work = queue.pop();
        if (work == null) {
            // No work available
            if (queue.isDone()) {
                break;
            }
            // Spin wait briefly
            std.Thread.yield() catch {};
            continue;
        }

        const item = work.?;
        processDirectory(ctx, item.path, item.depth, item.dev) catch {};
    }

    // Merge local results to shared
    shared.results_mutex.lock();
    defer shared.results_mutex.unlock();
    for (ctx.local_results.items) |result| {
        shared.results.append(shared.allocator, result) catch {};
    }
}

/// Process a single directory
fn processDirectory(ctx: *WorkerContext, dir_path: []const u8, depth: usize, parent_dev: u64) !void {
    const shared = ctx.shared;
    const options = shared.options;
    const io = std.Io.Threaded.global_single_threaded.io();

    // Get the directory's own blocks (like GNU du)
    const dir_stat = statPath(dir_path, options.dereference) catch return;
    const dir_own_blocks = dir_stat.blocks;

    var local_size: u64 = 0;
    var local_blocks: u64 = dir_own_blocks; // Start with directory's own blocks
    var local_inodes: u64 = 0;

    // Open directory
    var dir = openDir(dir_path) catch return;
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        const full_path = try std.fs.path.join(ctx.allocator, &[_][]const u8{ dir_path, entry.name });
        defer ctx.allocator.free(full_path);

        // Stat the entry
        const stat_result = statPath(full_path, options.dereference) catch continue;

        // Check one-file-system
        if (options.one_file_system and stat_result.dev != shared.root_dev) {
            continue;
        }

        // Handle hard links
        if (!options.count_links and stat_result.nlink > 1) {
            const key = WorkerContext.InodeKey{ .dev = stat_result.dev, .ino = stat_result.ino };
            const gop = try ctx.seen_inodes.getOrPut(key);
            if (gop.found_existing) continue;
        }

        local_inodes += 1;

        if (stat_result.is_dir) {
            // Queue subdirectory for parallel processing
            const path_copy = try ctx.allocator.dupe(u8, full_path);
            try shared.queue.push(shared.allocator, .{
                .path = path_copy,
                .depth = depth + 1,
                .dev = stat_result.dev,
            });
        } else {
            local_size += stat_result.size;
            local_blocks += stat_result.blocks;

            if (options.all) {
                const path_copy = try ctx.allocator.dupe(u8, full_path);
                try ctx.local_results.append(ctx.allocator, DirStat{
                    .path = path_copy,
                    .size = stat_result.size,
                    .blocks = stat_result.blocks,
                    .inodes = 1,
                    .depth = depth + 1,
                    .dev = stat_result.dev,
                });
            }
        }
    }

    // Add directory entry
    if (!options.summarize or depth == 0) {
        const path_copy = try ctx.allocator.dupe(u8, dir_path);
        try ctx.local_results.append(ctx.allocator, DirStat{
            .path = path_copy,
            .size = local_size,
            .blocks = local_blocks,
            .inodes = local_inodes,
            .depth = depth,
            .dev = parent_dev,
        });
    }

    // Update atomic counters
    shared.addSize(local_size);
    shared.addBlocks(local_blocks);
    shared.addInodes(local_inodes);
}

/// Open directory helper
fn openDir(path: []const u8) !std.Io.Dir {
    const io = std.Io.Threaded.global_single_threaded.io();
    if (path.len > 0 and path[0] == '/') {
        return std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true });
    }
    const cwd = std.Io.Dir.cwd();
    return cwd.openDir(io, path, .{ .iterate = true });
}

/// Stat info
const StatInfo = struct {
    dev: u64,
    ino: u64,
    size: u64,
    blocks: u64,
    nlink: u64,
    is_dir: bool,
};

/// Stat a path using statx syscall
fn statPath(path: []const u8, follow_symlinks: bool) !StatInfo {
    const linux = std.os.linux;

    // Build flags: AT_SYMLINK_NOFOLLOW for lstat behavior
    var flags: u32 = linux.AT.EMPTY_PATH;
    if (!follow_symlinks) {
        flags |= linux.AT.SYMLINK_NOFOLLOW;
    }

    // Convert path to null-terminated
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= path_buf.len) return error.NameTooLong;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(&path_buf);

    // Call statx directly
    var statx_buf: linux.Statx = undefined;
    const mask = linux.STATX.BASIC_STATS;
    const rc = linux.statx(linux.AT.FDCWD, path_z, flags, mask, &statx_buf);

    if (rc != 0) {
        const err = std.posix.errno(@as(isize, @bitCast(rc)));
        return switch (err) {
            .ACCES => error.AccessDenied,
            .NOENT => error.FileNotFound,
            .NOTDIR => error.FileNotFound,
            .LOOP => error.SymLinkLoop,
            .NAMETOOLONG => error.NameTooLong,
            else => error.Unexpected,
        };
    }

    // Combine dev_major and dev_minor into a single device ID
    const dev = (@as(u64, statx_buf.dev_major) << 32) | @as(u64, statx_buf.dev_minor);

    return StatInfo{
        .dev = dev,
        .ino = statx_buf.ino,
        .size = statx_buf.size,
        .blocks = statx_buf.blocks,
        .nlink = statx_buf.nlink,
        .is_dir = (statx_buf.mode & linux.S.IFMT) == linux.S.IFDIR,
    };
}

/// Accumulate child directory totals into parent directories
/// This makes the output match GNU du (each directory shows total of itself + all subdirs)
fn accumulateChildTotals(allocator: std.mem.Allocator, results: *std.ArrayList(DirStat)) !void {
    if (results.items.len == 0) return;

    // Build path -> index map for O(1) parent lookup
    var path_to_idx = std.StringHashMap(usize).init(allocator);
    defer path_to_idx.deinit();

    for (results.items, 0..) |entry, i| {
        try path_to_idx.put(entry.path, i);
    }

    // Find max depth
    var max_depth: usize = 0;
    for (results.items) |entry| {
        if (entry.depth > max_depth) max_depth = entry.depth;
    }

    // Process from deepest to shallowest (bottom-up accumulation)
    var current_depth = max_depth;
    while (current_depth > 0) : (current_depth -= 1) {
        for (results.items) |entry| {
            if (entry.depth != current_depth) continue;

            // Get parent path
            const parent_path = std.fs.path.dirname(entry.path) orelse continue;

            // Find parent in results
            if (path_to_idx.get(parent_path)) |parent_idx| {
                // Add this entry's totals to parent
                results.items[parent_idx].blocks += entry.blocks;
                results.items[parent_idx].size += entry.size;
                results.items[parent_idx].inodes += entry.inodes;
            }
        }
    }
}

/// Result of parallel walk
pub const ParallelWalkResult = struct {
    entries: []DirStat,
    total_size: u64,
    total_blocks: u64,
    total_inodes: u64,
};

/// Parallel directory walk - main entry point
pub fn walkParallel(allocator: std.mem.Allocator, path: []const u8, options: Options) !ParallelWalkResult {
    const io = std.Io.Threaded.global_single_threaded.io();

    // Get root stat
    const root_stat = try statPath(path, options.dereference);

    // Handle regular files (not directories)
    if (!root_stat.is_dir) {
        var entries = try allocator.alloc(DirStat, 1);
        entries[0] = DirStat{
            .path = try allocator.dupe(u8, path),
            .size = root_stat.size,
            .blocks = root_stat.blocks,
            .inodes = 1,
            .depth = 0,
            .dev = root_stat.dev,
        };
        return ParallelWalkResult{
            .entries = entries,
            .total_size = root_stat.size,
            .total_blocks = root_stat.blocks,
            .total_inodes = 1,
        };
    }

    // Count top-level directories and files in root
    var dir = try openDir(path);
    defer dir.close(io);

    var subdirs = std.ArrayList([]const u8).initCapacity(allocator, 32) catch unreachable;
    defer {
        for (subdirs.items) |p| allocator.free(p);
        subdirs.deinit(allocator);
    }

    // Track files directly in root directory
    var root_files_blocks: u64 = 0;
    var root_files_size: u64 = 0;
    var root_files_inodes: u64 = 0;

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        const full_path = try std.fs.path.join(allocator, &[_][]const u8{ path, entry.name });

        const stat = statPath(full_path, options.dereference) catch {
            allocator.free(full_path);
            continue;
        };

        if (stat.is_dir) {
            try subdirs.append(allocator, full_path);
        } else {
            // Count files directly in root
            root_files_blocks += stat.blocks;
            root_files_size += stat.size;
            root_files_inodes += 1;
            allocator.free(full_path);
        }
    }

    // Decide parallel vs sequential
    const num_threads = options.threads orelse @min(try Thread.getCpuCount(), MAX_WORKERS);

    if (subdirs.items.len < PARALLEL_THRESHOLD or num_threads <= 1) {
        // Fall back to sequential walker
        const walker = @import("walker.zig");
        const result = try walker.walk(allocator, path, options);
        return ParallelWalkResult{
            .entries = result.entries,
            .total_size = result.total_size,
            .total_blocks = result.total_blocks,
            .total_inodes = result.total_inodes,
        };
    }

    // Initialize shared state
    var shared = try SharedState.init(allocator, options, root_stat.dev);
    // Note: we manage cleanup manually, not with defer

    // Queue initial work
    for (subdirs.items) |subdir| {
        const subdir_stat = statPath(subdir, options.dereference) catch continue;
        try shared.queue.push(allocator, .{
            .path = try allocator.dupe(u8, subdir),
            .depth = 1,
            .dev = subdir_stat.dev,
        });
    }

    // Spawn worker threads
    const actual_threads = @min(num_threads, subdirs.items.len);
    var workers: [MAX_WORKERS]?Thread = [_]?Thread{null} ** MAX_WORKERS;
    var contexts: [MAX_WORKERS]?WorkerContext = [_]?WorkerContext{null} ** MAX_WORKERS;

    for (0..actual_threads) |i| {
        contexts[i] = try WorkerContext.init(allocator, shared);
        workers[i] = try Thread.spawn(.{}, workerThread, .{&contexts[i].?});
    }

    // Wait for initial processing then signal done
    sleepNs(50_000_000); // 50ms initial delay

    // Keep polling until queue is empty
    var empty_count: usize = 0;
    while (empty_count < 3) {
        shared.queue.mutex.lock();
        const queue_len = shared.queue.items.items.len;
        shared.queue.mutex.unlock();

        if (queue_len == 0) {
            empty_count += 1;
        } else {
            empty_count = 0;
        }
        sleepNs(5_000_000); // 5ms polling
    }
    shared.queue.setDone();

    // Join all threads
    for (0..actual_threads) |i| {
        if (workers[i]) |w| {
            w.join();
        }
    }

    // Post-process: accumulate child directory totals into parents (like GNU du)
    // Each entry currently only has its direct contents, we need to add subdirectory totals
    try accumulateChildTotals(allocator, &shared.results);

    // Calculate actual totals by summing all depth-1 entries (direct children of root)
    // Also include root's own blocks and files directly in root
    var accumulated_blocks: u64 = root_stat.blocks + root_files_blocks;
    var accumulated_size: u64 = root_files_size;
    var accumulated_inodes: u64 = 1 + root_files_inodes; // +1 for root itself

    for (shared.results.items) |entry| {
        if (entry.depth == 1) {
            accumulated_blocks += entry.blocks;
            accumulated_size += entry.size;
            accumulated_inodes += entry.inodes;
        }
    }

    // Add root entry with accumulated totals
    try shared.results.append(allocator, DirStat{
        .path = try allocator.dupe(u8, path),
        .size = accumulated_size,
        .blocks = accumulated_blocks,
        .inodes = accumulated_inodes,
        .depth = 0,
        .dev = root_stat.dev,
    });

    // Collect results before cleanup
    const entries = try allocator.dupe(DirStat, shared.results.items);

    // Cleanup worker contexts
    for (0..actual_threads) |i| {
        if (contexts[i]) |*ctx| {
            ctx.deinit();
        }
    }

    // Don't deinit shared here - entries point to it
    // Caller will free entries including paths

    return ParallelWalkResult{
        .entries = entries,
        .total_size = accumulated_size,
        .total_blocks = accumulated_blocks,
        .total_inodes = accumulated_inodes,
    };
}
