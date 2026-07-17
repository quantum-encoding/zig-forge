//! Comprehensive tests for the async scheduler

const std = @import("std");
const testing = std.testing;
const Scheduler = @import("scheduler/worksteal.zig").Scheduler;

// std.Thread.sleep / std.time.sleep do not exist in this Zig 0.16; the library
// links libc everywhere, so sleep via nanosleep(2).
fn sleepNs(ns: u64) void {
    var ts: std.c.timespec = .{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    _ = std.c.nanosleep(&ts, null);
}

// Shared state for the concurrent-spawner stress test.
const SpawnStress = struct {
    sched: *Scheduler,
    completed: *std.atomic.Value(u64),
    checksum: *std.atomic.Value(u64),
    base: u64,
    count: u64,

    fn taskBody(completed: *std.atomic.Value(u64), checksum: *std.atomic.Value(u64), val: u64) void {
        _ = checksum.fetchAdd(val, .monotonic);
        _ = completed.fetchAdd(1, .monotonic);
    }

    fn spawnerBody(ctx: *SpawnStress) void {
        var i: u64 = 0;
        while (i < ctx.count) {
            const val = ctx.base + i;
            _ = ctx.sched.spawn(taskBody, .{ ctx.completed, ctx.checksum, val }) catch {
                // Only reachable on allocation failure; back off and retry the
                // same value so the checksum stays exact.
                sleepNs(std.time.ns_per_us);
                continue;
            };
            i += 1;
        }
    }
};

// Regression test for work-order #6: multiple threads calling spawn() (which the
// C API advertises as safe from any thread) used to race on a single-owner deque
// — silently losing tasks or double-executing/double-freeing. With the shared
// MPMC injector queue every task must run exactly once, so the checksum over all
// unique task values is exact and no allocation is leaked (testing.allocator).
test "Scheduler - concurrent spawners stress" {
    // Small queue_size forces deque growth under concurrent stealers, also
    // exercising the grow-path use-after-free fix (retire-until-deinit).
    var scheduler = try Scheduler.init(testing.allocator, .{ .thread_count = 4, .queue_size = 64 });
    defer scheduler.deinit();

    try scheduler.start();
    defer scheduler.stop();

    const num_spawners: u64 = 4;
    const tasks_per_spawner: u64 = 2000;
    const total = num_spawners * tasks_per_spawner;

    var completed = std.atomic.Value(u64).init(0);
    var checksum = std.atomic.Value(u64).init(0);

    var ctxs: [num_spawners]SpawnStress = undefined;
    for (&ctxs, 0..) |*ctx, s| {
        ctx.* = .{
            .sched = &scheduler,
            .completed = &completed,
            .checksum = &checksum,
            .base = @as(u64, @intCast(s)) * tasks_per_spawner + 1,
            .count = tasks_per_spawner,
        };
    }

    var threads: [num_spawners]std.Thread = undefined;
    for (&threads, 0..) |*t, s| {
        t.* = try std.Thread.spawn(.{}, SpawnStress.spawnerBody, .{&ctxs[s]});
    }
    for (threads) |t| t.join();

    // Every spawned task must actually execute before teardown: a task frees its
    // boxed args only when it runs, so dropping undrained tasks would leak.
    while (completed.load(.monotonic) < total) {
        sleepNs(100 * std.time.ns_per_us);
    }

    try testing.expectEqual(total, completed.load(.monotonic));
    // Values are the contiguous range 1..=total spread across the spawners.
    const expected_checksum: u64 = total * (total + 1) / 2;
    try testing.expectEqual(expected_checksum, checksum.load(.monotonic));
}

test "Scheduler - basic task spawn and execution" {
    var scheduler = try Scheduler.init(testing.allocator, .{ .thread_count = 2 });
    defer scheduler.deinit();

    try scheduler.start();
    defer scheduler.stop();

    var counter: u32 = 0;
    const increment = struct {
        fn run(c: *u32) void {
            _ = @atomicRmw(u32, c, .Add, 1, .monotonic);
        }
    }.run;

    const handle = try scheduler.spawn(increment, .{&counter});
    handle.await_completion();

    try testing.expectEqual(@as(u32, 1), @atomicLoad(u32, &counter, .monotonic));
}

test "Scheduler - multiple tasks" {
    var scheduler = try Scheduler.init(testing.allocator, .{ .thread_count = 4 });
    defer scheduler.deinit();

    try scheduler.start();
    defer scheduler.stop();

    var counter: u32 = 0;
    const increment = struct {
        fn run(c: *u32) void {
            _ = @atomicRmw(u32, c, .Add, 1, .monotonic);
        }
    }.run;

    const task_count = 100;
    var handles: [task_count]@TypeOf(try scheduler.spawn(increment, .{&counter})) = undefined;

    // Spawn all tasks
    for (&handles) |*handle| {
        handle.* = try scheduler.spawn(increment, .{&counter});
    }

    // Wait for all to complete
    for (handles) |handle| {
        handle.await_completion();
    }

    try testing.expectEqual(@as(u32, task_count), @atomicLoad(u32, &counter, .monotonic));
}

test "Scheduler - work stealing" {
    var scheduler = try Scheduler.init(testing.allocator, .{ .thread_count = 4 });
    defer scheduler.deinit();

    try scheduler.start();
    defer scheduler.stop();

    var results: [8]u32 = undefined;
    const compute = struct {
        fn run(result: *u32, value: u32) void {
            // Simulate some work
            var sum: u32 = 0;
            var i: u32 = 0;
            while (i < 1000) : (i += 1) {
                sum +%= i;
            }
            result.* = value + sum;
        }
    }.run;

    var handles: [8]@TypeOf(try scheduler.spawn(compute, .{ &results[0], @as(u32, 0) })) = undefined;

    // Spawn tasks that will be distributed across threads
    for (&handles, 0..) |*handle, i| {
        handle.* = try scheduler.spawn(compute, .{ &results[i], @as(u32, @intCast(i)) });
    }

    // Wait for all
    for (handles) |handle| {
        handle.await_completion();
    }

    // Verify all tasks completed
    for (results, 0..) |result, i| {
        try testing.expect(result > i); // Should have computed something
    }
}

test "Scheduler - task status tracking" {
    var scheduler = try Scheduler.init(testing.allocator, .{ .thread_count = 2 });
    defer scheduler.deinit();

    try scheduler.start();
    defer scheduler.stop();

    const slow_task = struct {
        fn run() void {
            sleepNs(10 * std.time.ns_per_ms);
        }
    }.run;

    const handle = try scheduler.spawn(slow_task, .{});

    // Task should be pending or running
    const status = handle.getStatus();
    try testing.expect(status == .pending or status == .running);

    handle.await_completion();

    // Task should be completed or removed
    const final_status = handle.getStatus();
    try testing.expect(final_status == null or final_status == .completed);
}

test "Scheduler - concurrent execution" {
    var scheduler = try Scheduler.init(testing.allocator, .{ .thread_count = 4 });
    defer scheduler.deinit();

    try scheduler.start();
    defer scheduler.stop();

    var shared_array: [1000]u32 = undefined;
    for (&shared_array, 0..) |*elem, i| {
        elem.* = @intCast(i);
    }

    const process_chunk = struct {
        fn run(arr: []u32, start: usize, end: usize) void {
            var i = start;
            while (i < end) : (i += 1) {
                arr[i] = arr[i] * 2;
            }
        }
    }.run;

    const chunk_size = 250;
    var handles: [4]@TypeOf(try scheduler.spawn(process_chunk, .{ &shared_array, @as(usize, 0), @as(usize, 0) })) = undefined;

    // Spawn 4 tasks to process array in parallel
    for (&handles, 0..) |*handle, i| {
        const start = i * chunk_size;
        const end = start + chunk_size;
        handle.* = try scheduler.spawn(process_chunk, .{ &shared_array, start, end });
    }

    // Wait for all
    for (handles) |handle| {
        handle.await_completion();
    }

    // Verify results
    for (shared_array, 0..) |elem, i| {
        try testing.expectEqual(@as(u32, @intCast(i * 2)), elem);
    }
}

test "Scheduler - many small tasks" {
    var scheduler = try Scheduler.init(testing.allocator, .{ .thread_count = 4 });
    defer scheduler.deinit();

    try scheduler.start();
    defer scheduler.stop();

    var sum: u64 = 0;
    const add_value = struct {
        fn run(s: *u64, val: u64) void {
            _ = @atomicRmw(u64, s, .Add, val, .monotonic);
        }
    }.run;

    const task_count = 1000;
    var handles: [task_count]@TypeOf(try scheduler.spawn(add_value, .{ &sum, @as(u64, 0) })) = undefined;

    // Spawn many small tasks
    for (&handles, 0..) |*handle, i| {
        handle.* = try scheduler.spawn(add_value, .{ &sum, @as(u64, @intCast(i + 1)) });
    }

    // Wait for all
    for (handles) |handle| {
        handle.await_completion();
    }

    // Sum of 1..1000 = 500500
    const expected: u64 = (task_count * (task_count + 1)) / 2;
    try testing.expectEqual(expected, @atomicLoad(u64, &sum, .monotonic));
}

test "Scheduler - fibonacci computation" {
    var scheduler = try Scheduler.init(testing.allocator, .{ .thread_count = 4 });
    defer scheduler.deinit();

    try scheduler.start();
    defer scheduler.stop();

    const fib = struct {
        fn compute(n: u32) u64 {
            if (n <= 1) return n;
            var a: u64 = 0;
            var b: u64 = 1;
            var i: u32 = 2;
            while (i <= n) : (i += 1) {
                const tmp = a + b;
                a = b;
                b = tmp;
            }
            return b;
        }

        fn run(result: *u64, n: u32) void {
            result.* = compute(n);
        }
    };

    var results: [10]u64 = undefined;
    var handles: [10]@TypeOf(try scheduler.spawn(fib.run, .{ &results[0], @as(u32, 0) })) = undefined;

    // Compute fib(0) through fib(9) in parallel
    for (&handles, 0..) |*handle, i| {
        handle.* = try scheduler.spawn(fib.run, .{ &results[i], @as(u32, @intCast(i)) });
    }

    // Wait for all
    for (handles) |handle| {
        handle.await_completion();
    }

    // Verify fibonacci sequence
    const expected = [_]u64{ 0, 1, 1, 2, 3, 5, 8, 13, 21, 34 };
    for (expected, 0..) |exp, i| {
        try testing.expectEqual(exp, results[i]);
    }
}
