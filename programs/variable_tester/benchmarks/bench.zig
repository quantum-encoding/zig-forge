const std = @import("std");
const posix = std.posix;
const variable_tester = @import("variable_tester");
const test_functions = @import("test_functions");

// Darwin nanosleep for polling delays
const timespec = extern struct {
    sec: isize,
    nsec: isize,
};
extern "c" fn nanosleep(req: *const timespec, rem: ?*timespec) c_int;

fn sleepUs(us: u64) void {
    const ts = timespec{
        .sec = @intCast(us / 1_000_000),
        .nsec = @intCast((us % 1_000_000) * 1000),
    };
    _ = nanosleep(&ts, null);
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  Variable Tester - Performance Benchmark                ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    const num_cpus = try std.Thread.getCpuCount();
    std.debug.print("System: {} CPU cores\n", .{num_cpus});
    std.debug.print("\n", .{});

    const test_configs = [_]struct {
        name: []const u8,
        workers: usize,
        tasks: u64,
        test_fn: variable_tester.TestFn,
    }{
        .{ .name = "Compression (1 worker)", .workers = 1, .tasks = 1000, .test_fn = test_functions.testLosslessCompression },
        .{ .name = "Compression (4 workers)", .workers = 4, .tasks = 1000, .test_fn = test_functions.testLosslessCompression },
        .{ .name = "Compression (all cores)", .workers = num_cpus, .tasks = 1000, .test_fn = test_functions.testLosslessCompression },
        .{ .name = "Prime numbers (all cores)", .workers = num_cpus, .tasks = 1000, .test_fn = test_functions.testPrimeNumber },
        .{ .name = "Hash collision (all cores)", .workers = num_cpus, .tasks = 1000, .test_fn = test_functions.testHashCollision },
    };

    for (test_configs) |config| {
        try runBenchmark(allocator, config.name, config.workers, config.tasks, config.test_fn);
    }

    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  Benchmark Complete                                      ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});
}

fn runBenchmark(
    allocator: std.mem.Allocator,
    name: []const u8,
    num_workers: usize,
    num_tasks: u64,
    test_fn: variable_tester.TestFn,
) !void {
    std.debug.print("Running: {s}\n", .{name});
    std.debug.print("  Workers: {}, Tasks: {}\n", .{ num_workers, num_tasks });

    const queue_capacity: usize = 16384; // Power of 2

    const tester = try variable_tester.VariableTester.init(
        allocator,
        num_workers,
        queue_capacity,
        test_fn,
    );
    defer tester.deinit();

    try tester.start();

    var start_ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &start_ts);
    const start_time = start_ts;

    // Submit tasks
    var task_id: u64 = 0;
    while (task_id < num_tasks) : (task_id += 1) {
        const task_data = try std.fmt.allocPrint(allocator, "{}", .{task_id});
        const task = variable_tester.Task.init(task_id, task_data);
        try tester.submitTask(task);
    }

    // Collect results
    var results_collected: u64 = 0;
    while (results_collected < num_tasks) {
        if (tester.collectResult()) |result| {
            allocator.free(result.data);
            results_collected += 1;
        } else {
            sleepUs(100);
        }
    }

    var end_ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &end_ts);
    const end_time = end_ts;
    const elapsed_ns = @as(u64, @intCast(end_time.sec - start_time.sec)) * std.time.ns_per_s + @as(u64, @intCast(end_time.nsec - start_time.nsec));
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(std.time.ns_per_ms));

    tester.stop();

    const stats = tester.getStats();
    const throughput = @as(f64, @floatFromInt(stats.total_processed)) / (elapsed_ms / 1000.0);

    std.debug.print("  ✓ Completed in {d:.2} ms\n", .{elapsed_ms});
    std.debug.print("  ✓ Throughput: {d:.0} tasks/sec\n", .{throughput});
    std.debug.print("  ✓ Success rate: {d:.1}%\n", .{
        (@as(f64, @floatFromInt(stats.total_succeeded)) / @as(f64, @floatFromInt(stats.total_processed))) * 100.0,
    });
    std.debug.print("\n", .{});
}
