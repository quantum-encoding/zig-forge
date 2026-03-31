//! Comprehensive tests for the async scheduler

const std = @import("std");
const testing = std.testing;
const Scheduler = @import("scheduler/worksteal.zig").Scheduler;

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
            std.time.sleep(10 * std.time.ns_per_ms);
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
