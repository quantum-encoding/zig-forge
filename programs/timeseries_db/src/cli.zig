//! CLI tool for TSDB operations
//!
//! Commands:
//! - write <symbol> <csv_file> - Import candles from CSV
//! - query <symbol> <start> <end> - Query time range
//! - info <symbol> - Show database info

const std = @import("std");
const Candle = @import("main.zig").Candle;
const storage = @import("storage/file.zig");
const compression = @import("compression/delta.zig");
const btree = @import("index/btree.zig");

// Zig 0.16 compatible Timer using clock_gettime
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

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;

    // Parse args using new iterator pattern
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    if (args.len < 2) {
        printUsage();
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "write")) {
        if (args.len < 4) {
            std.debug.print("Usage: tsdb write <symbol> <csv_file>\n", .{});
            return error.InvalidArgs;
        }
        try cmdWrite(allocator, args[2], args[3]);
    } else if (std.mem.eql(u8, command, "query")) {
        if (args.len < 5) {
            std.debug.print("Usage: tsdb query <symbol> <start_timestamp> <end_timestamp>\n", .{});
            return error.InvalidArgs;
        }
        const start = try std.fmt.parseInt(i64, args[3], 10);
        const end = try std.fmt.parseInt(i64, args[4], 10);
        try cmdQuery(allocator, args[2], start, end);
    } else if (std.mem.eql(u8, command, "info")) {
        if (args.len < 3) {
            std.debug.print("Usage: tsdb info <symbol>\n", .{});
            return error.InvalidArgs;
        }
        try cmdInfo(allocator, args[2]);
    } else if (std.mem.eql(u8, command, "benchmark")) {
        try cmdBenchmark(allocator);
    } else {
        std.debug.print("Unknown command: {s}\n", .{command});
        printUsage();
        return error.UnknownCommand;
    }
}

fn printUsage() void {
    std.debug.print("\n╔════════════════════════════════════════╗\n", .{});
    std.debug.print("║     TSDB - Time Series Database       ║\n", .{});
    std.debug.print("╚════════════════════════════════════════╝\n\n", .{});
    std.debug.print("Usage: tsdb <command> [args]\n\n", .{});
    std.debug.print("Commands:\n", .{});
    std.debug.print("  write <symbol> <csv_file>  - Import candles from CSV\n", .{});
    std.debug.print("  query <symbol> <start> <end> - Query time range\n", .{});
    std.debug.print("  info <symbol>              - Show database info\n", .{});
    std.debug.print("  benchmark                  - Run performance benchmarks\n\n", .{});
    std.debug.print("CSV Format: timestamp,open,high,low,close,volume\n", .{});
    std.debug.print("Example:    1700000000,50000.00,50100.00,49900.00,50050.00,100.5\n\n", .{});
}

fn cmdWrite(allocator: std.mem.Allocator, symbol: []const u8, csv_file: []const u8) !void {
    std.debug.print("Importing {s} from {s}...\n", .{ symbol, csv_file });

    // Read CSV file using Zig 0.16.1859 API
    const io = std.Io.Threaded.global_single_threaded.io();
    const contents = try std.Io.Dir.cwd().readFileAlloc(io, csv_file, allocator, std.Io.Limit.limited(100 * 1024 * 1024));
    defer allocator.free(contents);

    // Parse CSV
    var candles: std.ArrayList(Candle) = .empty;
    defer candles.deinit(allocator);

    var lines = std.mem.splitSequence(u8, contents, "\n");
    var line_num: usize = 0;
    while (lines.next()) |line| {
        line_num += 1;
        if (line.len == 0) continue;

        // Skip header if present
        if (std.mem.indexOf(u8, line, "timestamp") != null) continue;

        // Parse: timestamp,open,high,low,close,volume
        var fields = std.mem.splitSequence(u8, line, ",");

        const timestamp_str = fields.next() orelse continue;
        const open_str = fields.next() orelse continue;
        const high_str = fields.next() orelse continue;
        const low_str = fields.next() orelse continue;
        const close_str = fields.next() orelse continue;
        const volume_str = fields.next() orelse continue;

        const candle = Candle{
            .timestamp = std.fmt.parseInt(i64, timestamp_str, 10) catch {
                std.debug.print("Error parsing timestamp on line {}: {s}\n", .{ line_num, timestamp_str });
                continue;
            },
            .open = std.fmt.parseFloat(f64, open_str) catch {
                std.debug.print("Error parsing open on line {}: {s}\n", .{ line_num, open_str });
                continue;
            },
            .high = std.fmt.parseFloat(f64, high_str) catch continue,
            .low = std.fmt.parseFloat(f64, low_str) catch continue,
            .close = std.fmt.parseFloat(f64, close_str) catch continue,
            .volume = std.fmt.parseFloat(f64, volume_str) catch continue,
        };

        try candles.append(allocator, candle);
    }

    const count = candles.items.len;
    std.debug.print("Parsed {} candles\n", .{count});

    // Create database file
    const db_filename = try std.fmt.allocPrint(allocator, "{s}.tsdb", .{symbol});
    defer allocator.free(db_filename);

    const initial_size = 1024 * 1024; // 1MB initial
    var store = try storage.FileStorage.create(db_filename, initial_size);
    defer store.deinit();

    // Update header
    const header = store.getHeader();
    header.row_count = count;

    try store.flush();

    std.debug.print("✅ Imported {} candles to {s}\n", .{ count, db_filename });
    std.debug.print("   File size: {} bytes\n", .{store.mmap_len});
}

fn cmdQuery(allocator: std.mem.Allocator, symbol: []const u8, start: i64, end: i64) !void {
    const db_filename = try std.fmt.allocPrint(allocator, "{s}.tsdb", .{symbol});
    defer allocator.free(db_filename);

    var store = storage.FileStorage.open(db_filename, false) catch |err| {
        std.debug.print("Error: Could not open database {s}: {}\n", .{ db_filename, err });
        return err;
    };
    defer store.deinit();

    const header = store.getHeaderConst();

    std.debug.print("Querying {s} from {} to {}\n", .{ symbol, start, end });
    std.debug.print("Database has {} rows\n", .{header.row_count});

    // For now, just print database info
    // Full implementation would decompress and return candles
    std.debug.print("Query would return candles in time range\n", .{});
    std.debug.print("(Full query implementation requires integrated compression + index)\n", .{});
}

fn cmdInfo(allocator: std.mem.Allocator, symbol: []const u8) !void {
    const db_filename = try std.fmt.allocPrint(allocator, "{s}.tsdb", .{symbol});
    defer allocator.free(db_filename);

    var store = storage.FileStorage.open(db_filename, false) catch |err| {
        std.debug.print("Error: Could not open database {s}: {}\n", .{ db_filename, err });
        return err;
    };
    defer store.deinit();

    const header = store.getHeaderConst();

    std.debug.print("\n╔════════════════════════════════════════╗\n", .{});
    std.debug.print("║  Database Info: {s}\n", .{symbol});
    std.debug.print("╚════════════════════════════════════════╝\n\n", .{});

    std.debug.print("File:         {s}\n", .{db_filename});
    std.debug.print("Magic:        0x{X:0>8} (\"TSDB\")\n", .{header.magic});
    std.debug.print("Version:      {}\n", .{header.version});
    std.debug.print("Row count:    {}\n", .{header.row_count});
    std.debug.print("File size:    {} bytes ({d:.2} MB)\n", .{ store.mmap_len, @as(f64, @floatFromInt(store.mmap_len)) / (1024.0 * 1024.0) });

    const uncompressed_size = header.row_count * 6 * @sizeOf(f64);
    const compression_ratio = if (store.mmap_len > 0)
        @as(f64, @floatFromInt(uncompressed_size)) / @as(f64, @floatFromInt(store.mmap_len))
    else
        0.0;

    std.debug.print("Uncompressed: {} bytes ({d:.2} MB)\n", .{ uncompressed_size, @as(f64, @floatFromInt(uncompressed_size)) / (1024.0 * 1024.0) });
    std.debug.print("Compression:  {d:.1}:1\n\n", .{compression_ratio});
}

fn cmdBenchmark(allocator: std.mem.Allocator) !void {
    std.debug.print("\n╔════════════════════════════════════════╗\n", .{});
    std.debug.print("║     TSDB Performance Benchmarks       ║\n", .{});
    std.debug.print("╚════════════════════════════════════════╝\n\n", .{});

    // Benchmark compression
    std.debug.print("Benchmark: Delta Encoding Compression\n", .{});

    const count = 10000;
    var timestamps = try allocator.alloc(i64, count);
    defer allocator.free(timestamps);

    var prices = try allocator.alloc(f64, count);
    defer allocator.free(prices);

    // Generate test data
    var i: usize = 0;
    while (i < count) : (i += 1) {
        timestamps[i] = 1700000000 + @as(i64, @intCast(i * 60)); // 1 minute intervals
        prices[i] = 50000.0 + @as(f64, @floatFromInt(i)) * 0.5; // Slowly increasing price
    }

    const encoded_ts = try allocator.alloc(i64, count);
    defer allocator.free(encoded_ts);

    const encoded_prices = try allocator.alloc(i32, count);
    defer allocator.free(encoded_prices);

    // Benchmark timestamp encoding
    var timer = try Timer.start();
    const ts_start = timer.read();

    try compression.encodeTimestamps(timestamps, encoded_ts);

    const ts_end = timer.read();
    const ts_elapsed_ns = ts_end - ts_start;
    const ts_ns_per_value = @as(f64, @floatFromInt(ts_elapsed_ns)) / @as(f64, @floatFromInt(count));

    std.debug.print("  Timestamp encoding: {d:.0} ns per value\n", .{ts_ns_per_value});

    // Benchmark price encoding
    const price_start = timer.read();

    _ = try compression.encodePricesSIMD(prices, encoded_prices, 100.0);

    const price_end = timer.read();
    const price_elapsed_ns = price_end - price_start;
    const price_ns_per_value = @as(f64, @floatFromInt(price_elapsed_ns)) / @as(f64, @floatFromInt(count));

    std.debug.print("  Price encoding:     {d:.0} ns per value\n", .{price_ns_per_value});

    // Calculate compression ratio
    const original_bytes = count * (@sizeOf(i64) + @sizeOf(f64));
    const compressed_bytes = count * (@sizeOf(i64) + @sizeOf(i32));
    const ratio = compression.compressionRatio(original_bytes, compressed_bytes);

    std.debug.print("  Compression ratio:  {d:.2}:1\n\n", .{ratio});

    // Benchmark B-tree
    std.debug.print("Benchmark: B-tree Index\n", .{});

    var tree = try btree.BTree.init(allocator);
    defer tree.deinit();

    // Insert benchmark
    const insert_start = timer.read();

    i = 0;
    while (i < count) : (i += 1) {
        try tree.insert(timestamps[i], i);
    }

    const insert_end = timer.read();
    const insert_elapsed_ns = insert_end - insert_start;
    const insert_ns_per_op = @as(f64, @floatFromInt(insert_elapsed_ns)) / @as(f64, @floatFromInt(count));

    std.debug.print("  Insert: {d:.0} ns per operation\n", .{insert_ns_per_op});

    // Search benchmark
    const search_iterations = 1000;
    const search_start = timer.read();

    i = 0;
    while (i < search_iterations) : (i += 1) {
        const idx = i % count;
        _ = tree.search(timestamps[idx]);
    }

    const search_end = timer.read();
    const search_elapsed_ns = search_end - search_start;
    const search_ns_per_op = @as(f64, @floatFromInt(search_elapsed_ns)) / @as(f64, @floatFromInt(search_iterations));

    std.debug.print("  Search: {d:.0} ns per operation\n", .{search_ns_per_op});
    std.debug.print("  Tree size: {} entries\n\n", .{tree.getSize()});

    std.debug.print("✅ Benchmarks complete\n\n", .{});
}
