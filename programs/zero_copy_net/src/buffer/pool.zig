//! High-performance fixed-size buffer pool for io_uring zero-copy networking
//! • O(1) lock-free acquire/release via an ABA-safe Treiber stack
//! • Page-aligned buffers (perfect for IORING_REGISTER_BUFFERS)
//! • Full io_uring fixed-buffer registration support
//! • Built-in statistics and safety checks

const std = @import("std");
const os = std.os;
const linux = os.linux;
const mem = std.mem;
const atomic = std.atomic;
const testing = std.testing;
const builtin = @import("builtin");

const page_size = std.heap.page_size_min; // 4096 on almost all systems

/// Sentinel free-stack index meaning "empty" (no free buffer).
/// Reserving the top u32 value caps the pool at maxInt(u32) buffers, which is
/// far beyond any realistic io_uring buffer count.
const EMPTY_IDX: u32 = std.math.maxInt(u32);

/// The free stack head is a single u64 CAS word packing a monotonically
/// increasing tag in the high 32 bits and the top buffer's array index in the
/// low 32 bits. The tag is bumped on every push and pop so a stale
/// compare-and-swap can never succeed against a recycled head value — this is
/// what makes the Treiber stack ABA-safe (a plain pointer/index stack is not).
inline fn packHead(tag: u32, idx: u32) u64 {
    return (@as(u64, tag) << 32) | @as(u64, idx);
}
inline fn headTag(v: u64) u32 {
    return @truncate(v >> 32);
}
inline fn headIdx(v: u64) u32 {
    return @truncate(v);
}

pub const BufferPool = struct {
    const Self = @This();

    /// One buffer + metadata. `next` is an intrusive free-stack link stored as
    /// an array index (EMPTY_IDX == end of stack). It is read/written atomically
    /// because a concurrent push of the same buffer would otherwise race the
    /// acquire-side read; `in_use` is retained purely as double-free detection.
    pub const Buffer = struct {
        data: []align(page_size) u8, // actual network buffer
        id: u32, // buffer ID (== index into `buffers`) for io_uring fixed buffers
        in_use: atomic.Value(bool), // true when owned by user
        next: atomic.Value(u32), // intrusive free-stack link (array index)

        fn init(ptr: []align(page_size) u8, id: u32) Buffer {
            return .{
                .data = ptr,
                .id = id,
                .in_use = atomic.Value(bool).init(false),
                .next = atomic.Value(u32).init(EMPTY_IDX),
            };
        }
    };

    allocator: mem.Allocator,
    /// The single backing allocation (metadata block + data region). Stored so
    /// `deinit` frees exactly what `init` allocated — the two must not drift.
    backing: []align(page_size) u8,
    buffers: []Buffer,
    free_head: atomic.Value(u64),

    total: usize,
    buffer_size: usize,

    stats: struct {
        allocated: atomic.Value(usize),
        freed: atomic.Value(usize),
    },

    pub const Stats = struct {
        total: usize,
        in_use: usize,
        free: usize,
        allocated: usize,
        freed: usize,
    };

    pub const InitError = mem.Allocator.Error || error{OutOfMemory};

    /// Create a new pool
    pub fn init(allocator: mem.Allocator, buffer_size: usize, count: usize) InitError!Self {
        if (count == 0 or buffer_size == 0) return error.OutOfMemory;
        // The free-stack index (and buffer id) must fit in u32 with EMPTY_IDX
        // reserved as the empty sentinel.
        if (count >= EMPTY_IDX) return error.OutOfMemory;

        const aligned_size = mem.alignForward(usize, buffer_size, page_size);
        const total_mem = aligned_size * count;

        // Metadata block rounded up to a page boundary so the data region that
        // follows it starts page-aligned (required for IORING_REGISTER_BUFFERS
        // and for the `[*]align(page_size) u8` casts below to be legal).
        const meta_bytes = mem.alignForward(usize, count * @sizeOf(Buffer), page_size);

        // Allocate one contiguous block for everything
        const backing = try allocator.alignedAlloc(
            u8,
            mem.Alignment.fromByteUnits(page_size),
            total_mem + meta_bytes,
        );
        errdefer allocator.free(backing);

        const metadata = @as([*]Buffer, @ptrCast(@alignCast(backing.ptr)))[0..count];
        // Page-aligned because backing.ptr is page-aligned and meta_bytes is a
        // whole number of pages.
        const data_start = backing.ptr + meta_bytes;

        var pool = Self{
            .allocator = allocator,
            .backing = backing,
            .buffers = metadata,
            .free_head = atomic.Value(u64).init(packHead(0, EMPTY_IDX)),
            .total = count,
            .buffer_size = aligned_size,
            .stats = .{
                .allocated = atomic.Value(usize).init(0),
                .freed = atomic.Value(usize).init(0),
            },
        };

        // Initialize buffers and link them into the free stack (LIFO). Init is
        // single-threaded, so the list is built directly with no CAS needed.
        // Pushing in reverse leaves buffer 0 on top.
        var head_idx: u32 = EMPTY_IDX;
        var i: usize = count;
        while (i > 0) {
            i -= 1;
            const buf_ptr = &pool.buffers[i];
            const data_ptr: [*]align(page_size) u8 = @ptrFromInt(@intFromPtr(data_start) + i * aligned_size);
            const data_slice = data_ptr[0..aligned_size];
            buf_ptr.* = Buffer.init(data_slice, @intCast(i));
            buf_ptr.next.store(head_idx, .monotonic);
            head_idx = @intCast(i);
        }
        pool.free_head = atomic.Value(u64).init(packHead(0, head_idx));

        return pool;
    }

    pub fn deinit(self: *Self) void {
        if (self.total == 0) return;
        self.allocator.free(self.backing);
        self.* = undefined;
    }

    /// Acquire a buffer – lock-free Treiber-stack pop.
    pub fn acquire(self: *Self) ?*Buffer {
        while (true) {
            const head = self.free_head.load(.acquire);
            const idx = headIdx(head);
            if (idx == EMPTY_IDX) return null; // pool exhausted
            const buf = &self.buffers[idx];
            // Atomic read guards against a torn read racing a concurrent push of
            // this same buffer; the tagged CAS below rejects any such race.
            const next_idx = buf.next.load(.monotonic);
            const new_head = packHead(headTag(head) +% 1, next_idx);
            if (self.free_head.cmpxchgWeak(head, new_head, .acq_rel, .acquire)) |_| {
                continue; // stack changed under us — retry
            }
            // `buf` is now off the free stack and exclusively ours.
            if (buf.in_use.swap(true, .acq_rel)) {
                @panic("BufferPool: free-stack corruption (acquired an in-use buffer)");
            }
            _ = self.stats.allocated.fetchAdd(1, .monotonic);
            return buf;
        }
    }

    /// Release a buffer – lock-free Treiber-stack push.
    pub fn release(self: *Self, buf: *Buffer) void {
        if (!buf.in_use.swap(false, .acq_rel)) {
            // Double free protection
            @panic("BufferPool: double free detected");
        }

        while (true) {
            const head = self.free_head.load(.acquire);
            // Publish this buffer's successor before it becomes reachable.
            buf.next.store(headIdx(head), .monotonic);
            const new_head = packHead(headTag(head) +% 1, buf.id);
            if (self.free_head.cmpxchgWeak(head, new_head, .release, .acquire)) |_| {
                continue; // another push/pop won — retry
            }
            break;
        }
        _ = self.stats.freed.fetchAdd(1, .monotonic);
    }

    /// Register all buffers with io_uring for zero-copy (fixed buffer mode)
    pub fn registerWithIoUring(self: *Self, ring: anytype) !void {
        const posix = std.posix;
        var iovs = try std.heap.page_allocator.alloc(posix.iovec, self.total);
        defer std.heap.page_allocator.free(iovs);

        for (self.buffers, 0..) |*buf, i| {
            iovs[i] = posix.iovec{
                .base = buf.data.ptr,
                .len = buf.data.len,
            };
        }

        try ring.register_buffers(iovs);
    }

    pub fn getStats(self: *const Self) Stats {
        const allocated = self.stats.allocated.load(.monotonic);
        const freed = self.stats.freed.load(.monotonic);
        const in_use = allocated - freed;
        return Stats{
            .total = self.total,
            .in_use = in_use,
            .free = self.total - in_use,
            .allocated = allocated,
            .freed = freed,
        };
    }
};

// ====================================================================
// Tests
// ====================================================================

test "init/deinit" {
    // Request 4096; the pool rounds the buffer size up to a whole page, so the
    // expectation is page-size-relative (4096 on Linux, 16384 on 16 KiB-page
    // hosts like Apple silicon).
    const want = mem.alignForward(usize, 4096, page_size);
    var pool = try BufferPool.init(testing.allocator, 4096, 128);
    defer pool.deinit();
    try testing.expect(pool.total == 128);
    try testing.expect(pool.buffer_size == want);
}

test "acquire/release single" {
    const want = mem.alignForward(usize, 4096, page_size);
    var pool = try BufferPool.init(testing.allocator, 4096, 16);
    defer pool.deinit();

    const buf = pool.acquire() orelse return error.NoBuffer;
    try testing.expect(buf.data.len == want);
    try testing.expect(@intFromPtr(buf.data.ptr) == mem.alignForward(usize, @intFromPtr(buf.data.ptr), page_size));

    pool.release(buf);
}

test "acquire returns N distinct buffers then exhausts" {
    // This is the exact test that would have caught the original S1 livelock:
    // a stack that never pops hands back the same pointer (or spins forever).
    const count = 64;
    var pool = try BufferPool.init(testing.allocator, 1024, count);
    defer pool.deinit();

    var seen = std.AutoHashMap(usize, void).init(testing.allocator);
    defer seen.deinit();

    var bufs: [count]*BufferPool.Buffer = undefined;
    for (&bufs) |*slot| {
        const b = pool.acquire() orelse return error.PoolExhaustedEarly;
        const gop = try seen.getOrPut(@intFromPtr(b));
        try testing.expect(!gop.found_existing); // every pointer must be unique
        slot.* = b;
    }
    try testing.expect(pool.acquire() == null); // now genuinely exhausted

    for (bufs) |b| pool.release(b);
}

test "exhaustion" {
    var pool = try BufferPool.init(testing.allocator, 1024, 4);
    defer pool.deinit();

    const b1 = pool.acquire() orelse unreachable;
    const b2 = pool.acquire() orelse unreachable;
    const b3 = pool.acquire() orelse unreachable;
    const b4 = pool.acquire() orelse unreachable;
    try testing.expect(pool.acquire() == null);

    pool.release(b2);
    const b5 = pool.acquire() orelse return error.TestFailed;
    try testing.expect(b5 == b2); // LIFO: most-recently-released comes back first
    pool.release(b1);
    pool.release(b3);
    pool.release(b4);
    pool.release(b5);
}

test "release then reacquire returns same buffer" {
    // Note: release() @panic()s on an actual double free (in_use guard). That
    // path cannot be exercised in-process without aborting the test runner, so
    // this test verifies the observable, non-aborting invariant instead: a
    // released buffer returns to the free stack and is handed back on reacquire.
    var pool = try BufferPool.init(testing.allocator, 1024, 1);
    defer pool.deinit();

    const buf = pool.acquire() orelse unreachable;
    try testing.expect(pool.acquire() == null); // single-buffer pool now empty
    pool.release(buf);

    const stats = pool.getStats();
    try testing.expect(stats.in_use == 0);
    try testing.expect(stats.free == 1);

    const again = pool.acquire() orelse return error.NoBuffer;
    try testing.expect(again == buf);
    pool.release(again);
}

test "concurrent acquire/release (stress)" {
    var pool = try BufferPool.init(testing.allocator, 4096, 1024);
    defer pool.deinit();

    const thread_count = 8;
    const iterations = 100_000;

    const worker = struct {
        fn run(p: *BufferPool, iters: usize) void {
            var i: usize = 0;
            var bufs: std.ArrayList(*BufferPool.Buffer) = .empty;
            defer bufs.deinit(std.heap.page_allocator);

            while (i < iters) : (i += 1) {
                if (p.acquire()) |b| {
                    bufs.append(std.heap.page_allocator, b) catch @panic("OOM");
                }
            }
            for (bufs.items) |b| p.release(b);
        }
    };

    var threads: [thread_count]std.Thread = undefined;
    for (&threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, worker.run, .{ &pool, iterations + i });
    }
    for (threads) |t| t.join();

    const stats = pool.getStats();
    try testing.expect(stats.in_use == 0);
    try testing.expect(stats.free == pool.total);
}

test "stats correctness" {
    var pool = try BufferPool.init(testing.allocator, 2048, 32);
    defer pool.deinit();

    var bufs: [32]*BufferPool.Buffer = undefined;
    for (&bufs) |*b| b.* = pool.acquire() orelse unreachable;

    var stats = pool.getStats();
    try testing.expect(stats.in_use == 32);
    try testing.expect(stats.free == 0);

    for (bufs) |b| pool.release(b);
    stats = pool.getStats();
    try testing.expect(stats.in_use == 0);
    try testing.expect(stats.free == 32);
}

test "performance: acquire/release hot loop" {
    if (builtin.is_test) return error.SkipZigTest;

    var pool = try BufferPool.init(std.heap.page_allocator, 4096, 8192);
    defer pool.deinit();

    const rounds = 10_000_000;
    const start = std.time.nanoTimestamp();

    var i: usize = 0;
    var buf: *BufferPool.Buffer = undefined;
    while (i < rounds) : (i += 1) {
        buf = pool.acquire() orelse @panic("pool empty");
        pool.release(buf);
    }

    const elapsed = @as(f64, @floatFromInt(std.time.nanoTimestamp() - start));
    const ns_per_op = elapsed / @as(f64, @floatFromInt(rounds * 2)); // acquire + release
    std.debug.print("\nBufferPool acquire+release: {d:.2} ns/op\n", .{ns_per_op});
}
