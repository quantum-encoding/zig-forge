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
    // Whether this entry is a directory. Used by the parallel walker's
    // bottom-up accumulation to roll up only directory subtotals into parents;
    // file blocks are already included in their directory's own subtotal, so
    // rolling file entries up as well double-counts them.
    is_dir: bool = false,
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

    // One streaming stdout writer for the whole run. Creating a fresh
    // File.stdout() writer per line seeks back to offset 0 on each positional
    // write and corrupts redirected output (see output.zig), so we own it here
    // and flush once at the end.
    const io = std.Io.Threaded.global_single_threaded.io();
    var out_buf: [64 * 1024]u8 = undefined;
    const stdout_file = std.Io.File.stdout();
    var stdout_writer = stdout_file.writer(io, &out_buf);
    const w = &stdout_writer.interface;
    defer w.flush() catch {};

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
                    output.printEntry(w, entry, options);
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
                    output.printEntry(w, entry, options);
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
        output.printTotal(w, grand_total, grand_total_blocks, options);
    }

    // Output JSON stats if requested
    if (options.json_stats) {
        const elapsed_ns = timer.read();
        const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
        const elapsed_s = elapsed_ms / 1000.0;

        const num_threads = options.threads orelse (std.Thread.getCpuCount() catch 1);

        // blocks are in 512-byte units
        const total_bytes = grand_total_blocks * 512;

        // Build the JSON with the Stringify serializer so string fields (notably
        // the user-supplied target path, which may contain '"', '\\', or control
        // chars) are escaped. Interpolating the path into a format-string
        // template would emit invalid JSON / permit field forgery.
        const stats = .{
            .tool = "zdu",
            .version = "0.1.0",
            .target = if (targets.len > 0) targets[0] else ".",
            .threads = num_threads,
            .elapsed_ms = elapsed_ms,
            .elapsed_s = elapsed_s,
            .total_blocks = grand_total_blocks,
            .total_bytes = total_bytes,
            .total_entries = total_entries,
            .total_dirs = total_dirs,
            .total_files = total_files,
        };
        const json = std.json.Stringify.valueAlloc(allocator, stats, .{}) catch {
            w.flush() catch {};
            std.process.exit(if (had_errors) 1 else 0);
        };
        defer allocator.free(json);
        std.debug.print("{s}\n", .{json});
    }

    // Exit with code 1 if any errors occurred (like GNU du). process.exit does
    // not run defers, so flush the buffered stdout first or the output is lost.
    if (had_errors) {
        w.flush() catch {};
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

    // File-vs-directory print gating is enforced upstream: the walkers only
    // emit file entries when options.all is set (see walker.walkDir /
    // parallel.processDirectory), so no -a filtering is needed here.
    return true;
}

test {
    // Pull in the unit tests declared in the sibling modules so `zig build test`
    // (rooted at main.zig) actually runs them -- Zig only runs tests in the root
    // file plus files referenced from a test block like this one.
    _ = @import("output.zig");
    _ = @import("args.zig");
    _ = @import("walker.zig");
    _ = @import("stat.zig");
}

test "options defaults" {
    const opts = Options{};
    try std.testing.expect(!opts.summarize);
    try std.testing.expect(!opts.all);
    try std.testing.expect(!opts.human_readable);
    try std.testing.expectEqual(@as(u64, 1024), opts.block_size);
}
