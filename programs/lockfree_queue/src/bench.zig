//! Microbenchmarks for the lock-free queues.
//!
//! Purpose: substantiate (or correct) the performance numbers quoted in the
//! docs with figures that are actually reproducible on the machine running
//! them. The historical "100M+ msg/sec / <50ns" claims had no benchmark
//! behind them — this is that benchmark.
//!
//! Run with:  zig build bench -Doptimize=ReleaseFast
//! (Debug numbers are meaningless — always benchmark an optimized build.)
//!
//! Timing uses the monotonic clock (clock_gettime MONOTONIC), never wall-clock.

const std = @import("std");
const builtin = @import("builtin");
const lfq = @import("main.zig");

const WARMUP: u64 = 100_000;
const ITERS: u64 = 10_000_000;

// Zig 0.16: monotonic-clock timer (matches the convention used elsewhere in
// the tree, e.g. zig_socket/src/bench.zig).
const Timer = struct {
    start_ns: i128,

    fn start() Timer {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &ts);
        return .{ .start_ns = @as(i128, ts.sec) * 1_000_000_000 + ts.nsec };
    }

    fn read(self: Timer) u64 {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &ts);
        const now = @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
        return @intCast(now - self.start_ns);
    }
};

fn nsPerOp(elapsed_ns: u64, ops: u64) f64 {
    return @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(ops));
}

fn mOpsPerSec(elapsed_ns: u64, ops: u64) f64 {
    const secs = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
    return (@as(f64, @floatFromInt(ops)) / secs) / 1_000_000.0;
}

/// Single-thread push+pop pair latency for the raw SPSC ring (no allocator).
fn benchSpscRing(allocator: std.mem.Allocator, out: *std.Io.Writer) !void {
    var q = try lfq.Spsc(u64).init(allocator, 1024);
    defer q.deinit();

    var i: u64 = 0;
    var checksum: u64 = 0;
    while (i < WARMUP) : (i += 1) {
        try q.push(i);
        checksum +%= try q.pop();
    }

    const timer = Timer.start();
    i = 0;
    while (i < ITERS) : (i += 1) {
        try q.push(i);
        const v = try q.pop();
        std.mem.doNotOptimizeAway(v);
        checksum +%= v;
    }
    const elapsed = timer.read();
    std.mem.doNotOptimizeAway(checksum);

    try out.print(
        "  SPSC ring   push+pop pair : {d:>7.2} ns/pair  ({d:>6.1} M pairs/s)\n",
        .{ nsPerOp(elapsed, ITERS), mOpsPerSec(elapsed, ITERS) },
    );
}

/// Single-thread push+pop pair latency for the raw MPMC ring, uncontended.
fn benchMpmcRing(allocator: std.mem.Allocator, out: *std.Io.Writer) !void {
    var q = try lfq.Mpmc(u64).init(allocator, 1024);
    defer q.deinit();

    var i: u64 = 0;
    var checksum: u64 = 0;
    while (i < WARMUP) : (i += 1) {
        try q.push(i);
        checksum +%= try q.pop();
    }

    const timer = Timer.start();
    i = 0;
    while (i < ITERS) : (i += 1) {
        try q.push(i);
        const v = try q.pop();
        std.mem.doNotOptimizeAway(v);
        checksum +%= v;
    }
    const elapsed = timer.read();
    std.mem.doNotOptimizeAway(checksum);

    try out.print(
        "  MPMC ring   push+pop pair : {d:>7.2} ns/pair  ({d:>6.1} M pairs/s)  [uncontended]\n",
        .{ nsPerOp(elapsed, ITERS), mOpsPerSec(elapsed, ITERS) },
    );
}

/// The cost the C FFI actually pays: a malloc/memcpy on push and a free on
/// pop for every message. This is why the FFI path is allocator-bound rather
/// than the raw ring's few-nanosecond cost.
fn benchFfiPath(out: *std.Io.Writer) !void {
    const allocator = std.heap.c_allocator;
    const Message = struct { data: []u8, len: usize };
    var q = try lfq.Spsc(Message).init(allocator, 1024);
    defer q.deinit();

    const payload = "market data update: BTCUSD 64123.55";
    const iters: u64 = 2_000_000; // fewer: allocator-bound, much slower per op

    var i: u64 = 0;
    var checksum: u64 = 0;
    while (i < WARMUP) : (i += 1) {
        const buf = try allocator.alloc(u8, payload.len);
        @memcpy(buf, payload);
        try q.push(.{ .data = buf, .len = payload.len });
        const msg = try q.pop();
        allocator.free(msg.data);
    }

    const timer = Timer.start();
    i = 0;
    while (i < iters) : (i += 1) {
        const buf = try allocator.alloc(u8, payload.len);
        @memcpy(buf, payload);
        std.mem.doNotOptimizeAway(buf.ptr);
        try q.push(.{ .data = buf, .len = payload.len });
        const msg = try q.pop();
        std.mem.doNotOptimizeAway(msg.data.ptr);
        checksum +%= msg.data[0];
        allocator.free(msg.data);
    }
    const elapsed = timer.read();
    std.mem.doNotOptimizeAway(checksum);

    try out.print(
        "  FFI copy    push+pop pair : {d:>7.2} ns/pair  ({d:>6.1} M pairs/s)  [malloc+free per msg]\n",
        .{ nsPerOp(elapsed, iters), mOpsPerSec(elapsed, iters) },
    );
}

const SpscThroughputProducer = struct {
    fn run(q: *lfq.Spsc(u64), n: u64) void {
        var i: u64 = 0;
        while (i < n) {
            q.push(i) catch {
                std.atomic.spinLoopHint();
                continue;
            };
            i += 1;
        }
    }
};

/// Two-thread sustained throughput: one producer, one consumer, the way SPSC
/// is meant to be driven. This is the number the "throughput" claim refers to.
fn benchSpscThroughput(allocator: std.mem.Allocator, out: *std.Io.Writer) !void {
    var q = try lfq.Spsc(u64).init(allocator, 1024);
    defer q.deinit();

    const n: u64 = 20_000_000;

    const timer = Timer.start();
    const producer = try std.Thread.spawn(.{}, SpscThroughputProducer.run, .{ &q, n });

    var got: u64 = 0;
    var checksum: u64 = 0;
    while (got < n) {
        const v = q.pop() catch {
            std.atomic.spinLoopHint();
            continue;
        };
        checksum +%= v;
        got += 1;
    }
    producer.join();
    const elapsed = timer.read();
    std.mem.doNotOptimizeAway(checksum);

    try out.print(
        "  SPSC 1P/1C  throughput    : {d:>7.2} ns/msg   ({d:>6.1} M msg/s)  [2 threads]\n",
        .{ nsPerOp(elapsed, n), mOpsPerSec(elapsed, n) },
    );
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &buf);
    const out = &stdout_writer.interface;

    try out.print("lockfree_queue benchmark ({d} iters, optimize={s})\n", .{
        ITERS, @tagName(builtin.mode),
    });
    try out.print("--------------------------------------------------------------------\n", .{});

    const allocator = std.heap.c_allocator;

    try benchSpscRing(allocator, out);
    try benchMpmcRing(allocator, out);
    try benchFfiPath(out);
    try benchSpscThroughput(allocator, out);

    try out.print("--------------------------------------------------------------------\n", .{});
    try out.print("Note: raw-ring pairs are the wait-free (SPSC) / lock-free (MPMC)\n", .{});
    try out.print("core; the FFI path pays a malloc+free per message on top.\n", .{});
    try out.flush();
}
