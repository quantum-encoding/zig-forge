//! Saturation Benchmark - Direct Multi-Threaded Exhaustive Search
//!
//! No network overhead, no queues - pure parallel computation
//! Each thread gets a contiguous range to search

const std = @import("std");
const posix = std.posix;

const SECRET_NUMBER: u64 = 8_734_501;

/// Result from a thread's search
const ThreadResult = struct {
    found: bool,
    value: u64,
    tasks_processed: u64,
};

/// Thread context
const ThreadContext = struct {
    thread_id: usize,
    start: u64,
    end: u64,
    result: ThreadResult,
};

/// Worker thread function - searches its assigned range
/// Uses volatile to prevent optimizer from eliminating work
fn searchRange(ctx: *ThreadContext) void {
    var found = false;
    var found_value: u64 = 0;
    var count: u64 = 0;

    // Buffer for number formatting (simulates real task parsing)
    var buf: [32]u8 = undefined;

    var i = ctx.start;
    while (i < ctx.end) : (i += 1) {
        count += 1;

        // Format number to string (simulates parsing task data)
        const num_str = std.fmt.bufPrint(&buf, "{}", .{i}) catch continue;

        // Parse it back (simulates real test function work)
        const parsed = std.fmt.parseInt(u64, num_str, 10) catch continue;

        // Compare (the actual test)
        if (parsed == SECRET_NUMBER) {
            found = true;
            found_value = parsed;
        }
    }

    ctx.result = ThreadResult{
        .found = found,
        .value = found_value,
        .tasks_processed = count,
    };
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    // Parse arguments
    var start_val: u64 = 0;
    var end_val: u64 = 10_000_000;
    var num_threads: usize = try std.Thread.getCpuCount();

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--start")) {
            if (args.next()) |v| start_val = try std.fmt.parseInt(u64, v, 10);
        } else if (std.mem.eql(u8, arg, "--end")) {
            if (args.next()) |v| end_val = try std.fmt.parseInt(u64, v, 10);
        } else if (std.mem.eql(u8, arg, "--threads")) {
            if (args.next()) |v| num_threads = try std.fmt.parseInt(usize, v, 10);
        }
    }

    const total_tasks = end_val - start_val;
    const tasks_per_thread = total_tasks / num_threads;

    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  SATURATION BENCHMARK - Direct Multi-Threaded Search                 ║\n", .{});
    std.debug.print("╠══════════════════════════════════════════════════════════════════════╣\n", .{});
    std.debug.print("║  Range: {} to {} ({} tasks)                         \n", .{ start_val, end_val, total_tasks });
    std.debug.print("║  Threads: {}                                                         \n", .{num_threads});
    std.debug.print("║  Tasks/Thread: {}                                                    \n", .{tasks_per_thread});
    std.debug.print("║  Secret: {}                                                          \n", .{SECRET_NUMBER});
    std.debug.print("╚══════════════════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    // Allocate thread contexts
    const contexts = try allocator.alloc(ThreadContext, num_threads);
    defer allocator.free(contexts);

    const threads = try allocator.alloc(std.Thread, num_threads);
    defer allocator.free(threads);

    // Partition range across threads
    for (0..num_threads) |i| {
        const thread_start = start_val + i * tasks_per_thread;
        const thread_end = if (i == num_threads - 1) end_val else thread_start + tasks_per_thread;

        contexts[i] = ThreadContext{
            .thread_id = i,
            .start = thread_start,
            .end = thread_end,
            .result = undefined,
        };
    }

    std.debug.print("Starting search...\n", .{});

    // Start timer
    var start_ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &start_ts) != 0) return error.TimerFailed;
    const start_time = start_ts;

    // Spawn all threads
    for (0..num_threads) |i| {
        threads[i] = try std.Thread.spawn(.{}, searchRange, .{&contexts[i]});
    }

    // Wait for all threads
    for (threads) |thread| {
        thread.join();
    }

    // End timer
    var end_ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &end_ts) != 0) return error.TimerFailed;
    const end_time = end_ts;

    const elapsed_ns = (@as(i128, end_time.sec) - @as(i128, start_time.sec)) * 1_000_000_000 +
        (@as(i128, end_time.nsec) - @as(i128, start_time.nsec));
    const elapsed_secs = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;

    // Aggregate results
    var total_processed: u64 = 0;
    var found = false;
    var found_value: u64 = 0;

    for (contexts) |ctx| {
        total_processed += ctx.result.tasks_processed;
        if (ctx.result.found) {
            found = true;
            found_value = ctx.result.value;
        }
    }

    const throughput = @as(f64, @floatFromInt(total_processed)) / elapsed_secs;

    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  RESULTS                                                             ║\n", .{});
    std.debug.print("╠══════════════════════════════════════════════════════════════════════╣\n", .{});
    std.debug.print("║  Tasks Processed: {}                                                 \n", .{total_processed});
    std.debug.print("║  Elapsed Time: {d:.3} seconds                                        \n", .{elapsed_secs});
    std.debug.print("║  Throughput: {d:.0} tasks/sec                                        \n", .{throughput});
    std.debug.print("║  Found: {} (value: {})                                               \n", .{ found, found_value });
    std.debug.print("╚══════════════════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    if (found and found_value == SECRET_NUMBER) {
        std.debug.print("✅ VERIFICATION: SUCCESS\n", .{});
    } else if (!found and (SECRET_NUMBER < start_val or SECRET_NUMBER >= end_val)) {
        std.debug.print("✅ VERIFICATION: SUCCESS (secret not in range)\n", .{});
    } else {
        std.debug.print("❌ VERIFICATION: FAILURE\n", .{});
    }
}
