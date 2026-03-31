//! The Forge - Single-Machine Brute-Force Variable Tester
//!
//! High-performance parallel testing engine for exhaustive search problems.
//! Supports pluggable test functions and file-based task loading.
//!
//! Usage:
//!   forge --test <test_name> --file <tasks.txt> [options]
//!   forge --test <test_name> --range <start> <end> [options]
//!
//! Options:
//!   --threads <n>     Number of worker threads (default: auto)
//!   --verbose         Print each solution as found
//!   --stop-on-find    Stop after first solution found

const std = @import("std");
const posix = std.posix;

/// Test result from evaluating a single variable/formula
pub const TestResult = struct {
    success: bool,
    score: f64,
    data: []const u8, // Optional result data
};

/// Test function signature
pub const TestFn = *const fn (task_data: []const u8, task_id: u64) TestResult;

/// Solution found during search
pub const Solution = struct {
    task_id: u64,
    data: []const u8,
    score: f64,
};

/// Thread context for parallel execution
const ThreadContext = struct {
    thread_id: usize,
    start_idx: usize,
    end_idx: usize,
    tasks: []const []const u8,
    test_fn: TestFn,

    // Results
    processed: u64,
    solutions_found: u64,
    best_score: f64,
    best_task_id: u64,
    best_data: ?[]const u8,

    // Config
    stop_on_find: bool,
    verbose: bool,
    global_stop: *std.atomic.Value(bool),
};

// ============================================================================
// Built-in Test Functions
// ============================================================================

/// Numeric match test - finds a specific number
pub fn testNumericMatch(task_data: []const u8, task_id: u64) TestResult {
    _ = task_id;
    const SECRET: u64 = 8_734_501;

    const num = std.fmt.parseInt(u64, std.mem.trim(u8, task_data, &std.ascii.whitespace), 10) catch {
        return .{ .success = false, .score = 0.0, .data = task_data };
    };

    const success = (num == SECRET);
    return .{ .success = success, .score = if (success) 1.0 else 0.0, .data = task_data };
}

/// Lossless compression test - evaluates compression formulas
/// Task data format: compression formula/algorithm specification
/// Returns success if formula achieves compression AND is lossless
pub fn testLosslessCompression(task_data: []const u8, task_id: u64) TestResult {
    _ = task_id;

    // Test data - representative sample for compression testing
    const test_samples = [_][]const u8{
        "AAAABBBCCDAA",
        "The quick brown fox jumps over the lazy dog",
        "abcabcabcabcabcabc",
        &[_]u8{ 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00 },
        "111111111111111111111111111111111111111111111111",
    };

    var total_original: usize = 0;
    var total_compressed: usize = 0;
    var all_lossless = true;

    for (test_samples) |sample| {
        // Apply the formula (parse and execute)
        const result = applyCompressionFormula(task_data, sample) catch {
            return .{ .success = false, .score = 0.0, .data = task_data };
        };

        // Verify lossless by decompressing
        const decompressed = decompressWithFormula(task_data, result.compressed) catch {
            return .{ .success = false, .score = 0.0, .data = task_data };
        };

        if (!std.mem.eql(u8, sample, decompressed)) {
            all_lossless = false;
            break;
        }

        total_original += sample.len;
        total_compressed += result.compressed.len;
    }

    if (!all_lossless) {
        return .{ .success = false, .score = 0.0, .data = task_data };
    }

    // Calculate compression ratio (lower is better, 1.0 = no compression)
    const ratio = @as(f64, @floatFromInt(total_compressed)) / @as(f64, @floatFromInt(total_original));

    // Success if we achieved any compression
    const success = ratio < 1.0;

    // Score: inverse of ratio (higher score = better compression)
    const score = if (success) 1.0 / ratio else 0.0;

    return .{ .success = success, .score = score, .data = task_data };
}

/// Compression formula result
const CompressionResult = struct {
    compressed: []const u8,
};

/// Apply a compression formula to data
/// Formula format: Simple DSL for compression algorithms
/// Examples:
///   "RLE" - Run-length encoding
///   "RLE+DELTA" - RLE with delta encoding
///   "DICT:4" - Dictionary with 4-byte words
fn applyCompressionFormula(formula: []const u8, data: []const u8) !CompressionResult {
    // For now, implement basic RLE as proof of concept
    // This will be expanded to parse and execute arbitrary formulas

    if (std.mem.startsWith(u8, formula, "RLE")) {
        return .{ .compressed = try runLengthEncode(data) };
    }

    // Unknown formula - return original (no compression)
    return .{ .compressed = data };
}

/// Decompress using formula
fn decompressWithFormula(formula: []const u8, data: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, formula, "RLE")) {
        return try runLengthDecode(data);
    }
    return data;
}

/// Simple run-length encoding (static buffer for benchmark speed)
threadlocal var rle_encode_buf: [65536]u8 = undefined;
threadlocal var rle_decode_buf: [65536]u8 = undefined;

fn runLengthEncode(input: []const u8) ![]const u8 {
    if (input.len == 0) return input[0..0];
    if (input.len > 32768) return error.InputTooLarge;

    var out_len: usize = 0;
    var i: usize = 0;

    while (i < input.len) {
        const char = input[i];
        var count: u8 = 1;

        while (i + count < input.len and input[i + count] == char and count < 255) {
            count += 1;
        }

        if (out_len + 2 > rle_encode_buf.len) return error.OutputTooLarge;
        rle_encode_buf[out_len] = count;
        rle_encode_buf[out_len + 1] = char;
        out_len += 2;
        i += count;
    }

    return rle_encode_buf[0..out_len];
}

fn runLengthDecode(input: []const u8) ![]const u8 {
    var out_len: usize = 0;
    var i: usize = 0;

    while (i + 1 < input.len) {
        const count = input[i];
        const char = input[i + 1];

        if (out_len + count > rle_decode_buf.len) return error.OutputTooLarge;

        for (0..count) |_| {
            rle_decode_buf[out_len] = char;
            out_len += 1;
        }
        i += 2;
    }

    return rle_decode_buf[0..out_len];
}

/// Prime number test
pub fn testPrimeNumber(task_data: []const u8, task_id: u64) TestResult {
    _ = task_id;

    const num = std.fmt.parseInt(u64, std.mem.trim(u8, task_data, &std.ascii.whitespace), 10) catch {
        return .{ .success = false, .score = 0.0, .data = task_data };
    };

    if (num < 2) return .{ .success = false, .score = 0.0, .data = task_data };
    if (num == 2) return .{ .success = true, .score = 1.0, .data = task_data };
    if (num % 2 == 0) return .{ .success = false, .score = 0.0, .data = task_data };

    const sqrt_num = @as(u64, @intFromFloat(@sqrt(@as(f64, @floatFromInt(num))))) + 1;
    var i: u64 = 3;
    while (i <= sqrt_num) : (i += 2) {
        if (num % i == 0) return .{ .success = false, .score = 0.0, .data = task_data };
    }

    return .{ .success = true, .score = 1.0, .data = task_data };
}

// ============================================================================
// Worker Thread
// ============================================================================

fn workerThread(ctx: *ThreadContext) void {
    var processed: u64 = 0;
    var solutions: u64 = 0;
    var best_score: f64 = 0.0;
    var best_id: u64 = 0;
    var best_data: ?[]const u8 = null;

    var idx = ctx.start_idx;
    while (idx < ctx.end_idx) : (idx += 1) {
        // Check for early stop
        if (ctx.stop_on_find and ctx.global_stop.load(.acquire)) break;

        const task_data = ctx.tasks[idx];
        const task_id = idx;

        const result = ctx.test_fn(task_data, task_id);
        processed += 1;

        if (result.success) {
            solutions += 1;

            if (result.score > best_score) {
                best_score = result.score;
                best_id = task_id;
                best_data = result.data;
            }

            if (ctx.verbose) {
                std.debug.print("🎯 [T{}] Solution #{}: task={} score={d:.4} data=\"{s}\"\n", .{
                    ctx.thread_id, solutions, task_id, result.score,
                    if (result.data.len > 50) result.data[0..50] else result.data,
                });
            }

            if (ctx.stop_on_find) {
                ctx.global_stop.store(true, .release);
            }
        }
    }

    ctx.processed = processed;
    ctx.solutions_found = solutions;
    ctx.best_score = best_score;
    ctx.best_task_id = best_id;
    ctx.best_data = best_data;
}

// ============================================================================
// Main Entry Point
// ============================================================================

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    // Parse arguments
    var test_name: []const u8 = "numeric";
    var file_path: ?[]const u8 = null;
    var range_start: ?u64 = null;
    var range_end: ?u64 = null;
    var num_threads: usize = try std.Thread.getCpuCount();
    var verbose = false;
    var stop_on_find = false;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--test")) {
            if (args.next()) |v| test_name = v;
        } else if (std.mem.eql(u8, arg, "--file")) {
            if (args.next()) |v| file_path = v;
        } else if (std.mem.eql(u8, arg, "--range")) {
            if (args.next()) |v| range_start = try std.fmt.parseInt(u64, v, 10);
            if (args.next()) |v| range_end = try std.fmt.parseInt(u64, v, 10);
        } else if (std.mem.eql(u8, arg, "--threads")) {
            if (args.next()) |v| num_threads = try std.fmt.parseInt(usize, v, 10);
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "--stop-on-find")) {
            stop_on_find = true;
        }
    }

    // Select test function
    const test_fn: TestFn = if (std.mem.eql(u8, test_name, "numeric"))
        testNumericMatch
    else if (std.mem.eql(u8, test_name, "compression"))
        testLosslessCompression
    else if (std.mem.eql(u8, test_name, "prime"))
        testPrimeNumber
    else {
        std.debug.print("Unknown test: {s}\n", .{test_name});
        std.debug.print("Available: numeric, compression, prime\n", .{});
        return;
    };

    // Load tasks
    var tasks: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (tasks.items) |t| allocator.free(t);
        tasks.deinit(allocator);
    }

    if (file_path) |path| {
        // Load from file (one task per line)
        const io = std.Io.Threaded.global_single_threaded.io();
        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);

        // Read entire file using readPositionalAll
        const stat = try file.stat(io);
        const contents = try allocator.alloc(u8, stat.size);
        defer allocator.free(contents);
        _ = try file.readPositionalAll(io, contents, 0);

        // Split into lines
        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
            if (trimmed.len > 0) {
                const task = try allocator.dupe(u8, trimmed);
                try tasks.append(allocator, task);
            }
        }
    } else if (range_start != null and range_end != null) {
        // Generate numeric range
        var i = range_start.?;
        while (i < range_end.?) : (i += 1) {
            const task = try std.fmt.allocPrint(allocator, "{}", .{i});
            try tasks.append(allocator, task);
        }
    } else {
        std.debug.print("Error: Must specify --file <path> or --range <start> <end>\n", .{});
        return;
    }

    const task_count = tasks.items.len;

    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  THE FORGE - Brute-Force Variable Tester                             ║\n", .{});
    std.debug.print("╠══════════════════════════════════════════════════════════════════════╣\n", .{});
    std.debug.print("║  Test: {s: <63}║\n", .{test_name});
    std.debug.print("║  Tasks: {: <62}║\n", .{task_count});
    std.debug.print("║  Threads: {: <60}║\n", .{num_threads});
    std.debug.print("╚══════════════════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    if (task_count == 0) {
        std.debug.print("No tasks to process.\n", .{});
        return;
    }

    // Allocate thread contexts
    const contexts = try allocator.alloc(ThreadContext, num_threads);
    defer allocator.free(contexts);

    const threads = try allocator.alloc(std.Thread, num_threads);
    defer allocator.free(threads);

    var global_stop = std.atomic.Value(bool).init(false);

    // Partition tasks
    const tasks_per_thread = task_count / num_threads;
    for (0..num_threads) |i| {
        const start = i * tasks_per_thread;
        const end = if (i == num_threads - 1) task_count else start + tasks_per_thread;

        contexts[i] = ThreadContext{
            .thread_id = i,
            .start_idx = start,
            .end_idx = end,
            .tasks = tasks.items,
            .test_fn = test_fn,
            .processed = 0,
            .solutions_found = 0,
            .best_score = 0,
            .best_task_id = 0,
            .best_data = null,
            .stop_on_find = stop_on_find,
            .verbose = verbose,
            .global_stop = &global_stop,
        };
    }

    std.debug.print("Starting search...\n", .{});

    // Start timer
    var start_ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &start_ts) != 0) return error.TimerFailed;
    const start_time = start_ts;

    // Spawn threads
    for (0..num_threads) |i| {
        threads[i] = try std.Thread.spawn(.{}, workerThread, .{&contexts[i]});
    }

    // Wait for completion
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
    var total_solutions: u64 = 0;
    var best_score: f64 = 0;
    var best_task_id: u64 = 0;
    var best_data: ?[]const u8 = null;

    for (contexts) |ctx| {
        total_processed += ctx.processed;
        total_solutions += ctx.solutions_found;
        if (ctx.best_score > best_score) {
            best_score = ctx.best_score;
            best_task_id = ctx.best_task_id;
            best_data = ctx.best_data;
        }
    }

    const throughput = @as(f64, @floatFromInt(total_processed)) / elapsed_secs;

    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  RESULTS                                                             ║\n", .{});
    std.debug.print("╠══════════════════════════════════════════════════════════════════════╣\n", .{});
    std.debug.print("║  Tasks Processed: {: <52}║\n", .{total_processed});
    std.debug.print("║  Solutions Found: {: <52}║\n", .{total_solutions});
    std.debug.print("║  Elapsed Time: {d:.3} seconds{s: <42}║\n", .{ elapsed_secs, "" });
    std.debug.print("║  Throughput: {d:.0} tasks/sec{s: <40}║\n", .{ throughput, "" });
    if (total_solutions > 0) {
        std.debug.print("╠══════════════════════════════════════════════════════════════════════╣\n", .{});
        std.debug.print("║  Best Score: {d:.6}{s: <52}║\n", .{ best_score, "" });
        std.debug.print("║  Best Task ID: {: <55}║\n", .{best_task_id});
        if (best_data) |data| {
            const display = if (data.len > 50) data[0..50] else data;
            std.debug.print("║  Best Data: {s: <58}║\n", .{display});
        }
    }
    std.debug.print("╚══════════════════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});
}
