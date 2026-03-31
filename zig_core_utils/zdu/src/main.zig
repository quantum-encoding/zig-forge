//! zdu - Zig Disk Usage
//! High-performance disk usage analyzer leveraging Zig's zero-overhead abstractions.
//!
//! Architecture:
//! - Lock-free parallel directory traversal
//! - Per-thread inode tracking with atomic merge
//! - Arena allocator for zero-allocation path handling
//! - io_uring batch stat calls (Linux)
//! - Cache-optimized data structures

const std = @import("std");
const posix = std.posix;
const fs = std.fs;
const Thread = std.Thread;

const walker = @import("walker.zig");

// Zig 0.16 compatible Timer (std.time.Timer was removed)
const Timer = struct {
    start_time: i128,

    pub fn start() !Timer {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &ts);
        return Timer{
            .start_time = @as(i128, ts.sec) * 1_000_000_000 + ts.nsec,
        };
    }

    pub fn read(self: Timer) u64 {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &ts);
        const now = @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
        return @intCast(now - self.start_time);
    }
};
const parallel = @import("parallel.zig");
const args = @import("args.zig");
const output = @import("output.zig");

pub const Options = struct {
    summarize: bool = false,
    all: bool = false,
    human_readable: bool = false,
    si: bool = false,
    apparent_size: bool = false,
    bytes: bool = false,
    total: bool = false,
    max_depth: ?usize = null,
    one_file_system: bool = false,
    dereference: bool = false,
    block_size: u64 = 1024,
    null_terminator: bool = false,
    count_links: bool = false,
    threads: ?usize = null,
    json_stats: bool = false, // Output detailed JSON statistics
};

pub const DirStat = struct {
    size: u64 = 0,
    blocks: u64 = 0,
    inodes: u64 = 0,
    path: []const u8,
    depth: usize = 0,
    dev: u64 = 0,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    // Parse command line arguments
    const parsed = args.parse(allocator, init.minimal.args) catch |err| {
        if (err == error.HelpRequested) {
            return;
        }
        std.debug.print("zdu: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer parsed.deinit();

    const options = parsed.options;
    const paths = parsed.paths;

    // Default to current directory if no paths specified
    const targets: []const []const u8 = if (paths.len == 0)
        &[_][]const u8{"."}
    else
        paths;

    var grand_total: u64 = 0;
    var grand_total_blocks: u64 = 0;
    var total_files: u64 = 0;
    var total_dirs: u64 = 0;
    var total_entries: u64 = 0;
    var had_errors: bool = false;

    // Get start time for stats
    var timer = try Timer.start();

    for (targets) |path| {
        // Use parallel walker for large directories, sequential for small ones
        const num_threads = options.threads orelse (std.Thread.getCpuCount() catch 1);
        const use_parallel = num_threads > 1;

        if (use_parallel) {
            const result = parallel.walkParallel(allocator, path, options) catch |err| {
                std.debug.print("zdu: cannot access '{s}': {s}\n", .{ path, @errorName(err) });
                had_errors = true;
                continue;
            };
            defer {
                for (result.entries) |entry| {
                    allocator.free(entry.path);
                }
                allocator.free(result.entries);
            }

            for (result.entries) |entry| {
                if (shouldPrint(entry, options)) {
                    output.printEntry(entry, options);
                }
                total_entries += 1;
                if (entry.inodes > 1) {
                    total_dirs += 1;
                } else {
                    total_files += 1;
                }
            }

            grand_total += result.total_size;
            grand_total_blocks += result.total_blocks;
        } else {
            const result = walker.walk(allocator, path, options) catch |err| {
                std.debug.print("zdu: cannot access '{s}': {s}\n", .{ path, @errorName(err) });
                had_errors = true;
                continue;
            };
            defer {
                for (result.entries) |entry| {
                    allocator.free(entry.path);
                }
                allocator.free(result.entries);
            }

            for (result.entries) |entry| {
                if (shouldPrint(entry, options)) {
                    output.printEntry(entry, options);
                }
                total_entries += 1;
                if (entry.inodes > 1) {
                    total_dirs += 1;
                } else {
                    total_files += 1;
                }
            }

            grand_total += result.total_size;
            grand_total_blocks += result.total_blocks;
        }
    }

    if (options.total and targets.len > 0) {
        output.printTotal(grand_total, grand_total_blocks, options);
    }

    // Output JSON stats if requested
    if (options.json_stats) {
        const elapsed_ns = timer.read();
        const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
        const elapsed_s = elapsed_ms / 1000.0;

        const num_threads = options.threads orelse (std.Thread.getCpuCount() catch 1);

        // blocks are in 512-byte units
        const total_bytes = grand_total_blocks * 512;

        std.debug.print(
            \\{{"tool":"zdu","version":"0.1.0","target":"{s}","threads":{},"elapsed_ms":{d:.3},"elapsed_s":{d:.6},"total_blocks":{},"total_bytes":{},"total_entries":{},"total_dirs":{},"total_files":{}}}
            \\
        , .{
            if (targets.len > 0) targets[0] else ".",
            num_threads,
            elapsed_ms,
            elapsed_s,
            grand_total_blocks,
            total_bytes,
            total_entries,
            total_dirs,
            total_files,
        });
    }

    // Exit with code 1 if any errors occurred (like GNU du)
    if (had_errors) {
        std.process.exit(1);
    }
}

fn shouldPrint(entry: DirStat, options: Options) bool {
    // Check max_depth
    if (options.max_depth) |max| {
        if (entry.depth > max) return false;
    }

    // Summarize mode only prints top-level
    if (options.summarize and entry.depth > 0) return false;

    // -a prints all files, otherwise just directories
    if (!options.all and entry.depth > 0) {
        // This is simplified - real implementation tracks file vs dir
    }

    return true;
}

test "options defaults" {
    const opts = Options{};
    try std.testing.expect(!opts.summarize);
    try std.testing.expect(!opts.all);
    try std.testing.expect(!opts.human_readable);
    try std.testing.expectEqual(@as(u64, 1024), opts.block_size);
}
