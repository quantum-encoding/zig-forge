//! Performance benchmarks for async scheduler

const std = @import("std");
const Scheduler = @import("scheduler/worksteal.zig").Scheduler;

/// Simple timer using clock_gettime for Zig 0.16 compatibility
const Timer = struct {
    start_time: std.c.timespec,

    pub fn start() Timer {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &ts);
        return .{ .start_time = ts };
    }

    pub fn read(self: Timer) u64 {
        var now: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &now);

        const start_ns = @as(u64, @intCast(self.start_time.sec)) * std.time.ns_per_s +
            @as(u64, @intCast(self.start_time.nsec));
        const now_ns = @as(u64, @intCast(now.sec)) * std.time.ns_per_s +
            @as(u64, @intCast(now.nsec));

        return now_ns - start_ns;
    }
};

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    std.debug.print("\n=== Async Task Scheduler Benchmarks ===\n\n", .{});

    // Benchmark 1: Task spawn latency
    try benchTaskSpawn(allocator);

    // Benchmark 2: Throughput with many tasks
    try benchThroughput(allocator);

    // Benchmark 3: Work stealing efficiency
    try benchWorkStealing(allocator);
}

fn benchTaskSpawn(allocator: std.mem.Allocator) !void {
    std.debug.print("Benchmark 1: Task Spawn Latency\n", .{});
    std.debug.print("--------------------------------\n", .{});

    var scheduler = try Scheduler.init(allocator, .{ .thread_count = 4 });
    defer scheduler.deinit();

    try scheduler.start();
    defer scheduler.stop();

    const noop = struct {
        fn run() void {}
    }.run;

    const iterations = 1000;
    var timer = Timer.start();

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        _ = try scheduler.spawn(noop, .{});
    }

    const elapsed = timer.read();
    const ns_per_spawn = elapsed / iterations;

    std.debug.print("  Tasks: {}\n", .{iterations});
    std.debug.print("  Total time: {d:.2} ms\n", .{@as(f64, @floatFromInt(elapsed)) / std.time.ns_per_ms});
    std.debug.print("  Per-task spawn: {} ns\n", .{ns_per_spawn});
    std.debug.print("  Target: <100 ns per task\n", .{});

    if (ns_per_spawn < 100) {
        std.debug.print("  ✓ PASS\n\n", .{});
    } else if (ns_per_spawn < 200) {
        std.debug.print("  ~ ACCEPTABLE (within 2x target)\n\n", .{});
    } else {
        std.debug.print("  ✗ SLOW (exceeds 2x target)\n\n", .{});
    }
}

fn benchThroughput(allocator: std.mem.Allocator) !void {
    std.debug.print("Benchmark 2: Throughput (10K tasks)\n", .{});
    std.debug.print("-------------------------------------\n", .{});

    var scheduler = try Scheduler.init(allocator, .{ .thread_count = 4 });
    defer scheduler.deinit();

    try scheduler.start();
    defer scheduler.stop();

    var counter: u64 = 0;
    const increment = struct {
        fn run(c: *u64) void {
            _ = @atomicRmw(u64, c, .Add, 1, .monotonic);
        }
    }.run;

    const task_count = 10_000;
    var timer = Timer.start();

    const handles = try allocator.alloc(@TypeOf(try scheduler.spawn(increment, .{&counter})), task_count);
    defer allocator.free(handles);

    // Spawn all tasks
    for (handles) |*handle| {
        handle.* = try scheduler.spawn(increment, .{&counter});
    }

    // Wait for all to complete
    for (handles) |handle| {
        handle.await_completion();
    }

    const elapsed = timer.read();
    const tasks_per_sec = (@as(f64, @floatFromInt(task_count)) / @as(f64, @floatFromInt(elapsed))) * std.time.ns_per_s;

    std.debug.print("  Tasks: {}\n", .{task_count});
    std.debug.print("  Total time: {d:.2} ms\n", .{@as(f64, @floatFromInt(elapsed)) / std.time.ns_per_ms});
    std.debug.print("  Throughput: {d:.2}M tasks/sec\n", .{tasks_per_sec / 1_000_000});
    std.debug.print("  Counter result: {}\n", .{@atomicLoad(u64, &counter, .monotonic)});
    std.debug.print("  Target: >1M tasks/sec\n", .{});

    if (tasks_per_sec > 1_000_000) {
        std.debug.print("  ✓ PASS\n\n", .{});
    } else {
        std.debug.print("  ✗ BELOW TARGET\n\n", .{});
    }
}

fn benchWorkStealing(allocator: std.mem.Allocator) !void {
    std.debug.print("Benchmark 3: Work Stealing (unbalanced load)\n", .{});
    std.debug.print("---------------------------------------------\n", .{});

    var scheduler = try Scheduler.init(allocator, .{ .thread_count = 4 });
    defer scheduler.deinit();

    try scheduler.start();
    defer scheduler.stop();

    const compute = struct {
        fn run(result: *u64, value: u64) void {
            // Simulate varying workload
            var sum: u64 = 0;
            var i: u64 = 0;
            while (i < value * 1000) : (i += 1) {
                sum +%= i;
            }
            result.* = sum;
        }
    }.run;

    const task_count = 100;
    var results = try allocator.alloc(u64, task_count);
    defer allocator.free(results);

    const handles = try allocator.alloc(@TypeOf(try scheduler.spawn(compute, .{ &results[0], @as(u64, 0) })), task_count);
    defer allocator.free(handles);

    var timer = Timer.start();

    // Spawn tasks with varying workloads
    for (handles, 0..) |*handle, i| {
        const workload = (i % 10) + 1; // Workload varies from 1-10
        handle.* = try scheduler.spawn(compute, .{ &results[i], @as(u64, workload) });
    }

    // Wait for all
    for (handles) |handle| {
        handle.await_completion();
    }

    const elapsed = timer.read();

    std.debug.print("  Tasks: {} (variable workload)\n", .{task_count});
    std.debug.print("  Total time: {d:.2} ms\n", .{@as(f64, @floatFromInt(elapsed)) / std.time.ns_per_ms});
    std.debug.print("  Threads: 4\n", .{});
    std.debug.print("  Work-stealing enabled: yes\n", .{});
    std.debug.print("  ✓ Completed without deadlock\n\n", .{});
}
