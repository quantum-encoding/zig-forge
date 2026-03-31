//! High-Performance Time Series Database
//!
//! Columnar storage optimized for OHLCV (candlestick) data
//! Target: 1M inserts/sec, 10M reads/sec
//!
//! Features:
//! - mmap-based storage for zero-copy reads
//! - SIMD compression (delta encoding)
//! - Lock-free concurrent reads
//! - B-tree index for fast time-range queries

const std = @import("std");

// Core modules
pub const storage = @import("storage/file.zig");
pub const compression = @import("compression/delta.zig");
pub const index = @import("index/btree.zig");
pub const query = @import("query/engine.zig");

/// OHLCV candle (candlestick data)
pub const Candle = struct {
    timestamp: i64,      // Unix timestamp (seconds or milliseconds)
    open: f64,
    high: f64,
    low: f64,
    close: f64,
    volume: f64,

    pub fn init(timestamp: i64, open: f64, high: f64, low: f64, close: f64, volume: f64) Candle {
        return .{
            .timestamp = timestamp,
            .open = open,
            .high = high,
            .low = low,
            .close = close,
            .volume = volume,
        };
    }
};

/// Time series database handle
pub const TSDB = struct {
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    file_handle: ?std.Io.File,
    indexes: std.StringHashMap(index.BTree),

    pub fn init(allocator: std.mem.Allocator, data_dir: []const u8) !TSDB {
        // Create data directory if it doesn't exist
        _ = std.c.mkdir(data_dir, 0o755);

        return .{
            .allocator = allocator,
            .data_dir = data_dir,
            .file_handle = null,
            .indexes = std.StringHashMap(index.BTree).init(allocator),
        };
    }

    pub fn deinit(self: *TSDB) void {
        if (self.file_handle) |file| {
            const io = std.Io.Threaded.global_single_threaded.io();
            file.close(io);
        }

        // Deinit all B-tree indexes
        var iter = self.indexes.valueIterator();
        while (iter.next()) |btree| {
            btree.deinit();
        }
        self.indexes.deinit();
    }

    /// Insert candle data
    pub fn insert(self: *TSDB, symbol: []const u8, candles: []const Candle) !void {
        if (candles.len == 0) return;

        // Create storage file path: {data_dir}/{symbol}.tsdb
        const file_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}.tsdb", .{ self.data_dir, symbol });
        defer self.allocator.free(file_path);

        // Open or create storage
        const store = try storage.FileStorage.create(file_path, 1024 * 1024);
        var file_store = store;
        defer file_store.deinit();

        const row_count = candles.len;

        // Allocate temporary buffers for encoding
        var timestamps = try self.allocator.alloc(i64, row_count);
        defer self.allocator.free(timestamps);

        var opens = try self.allocator.alloc(f64, row_count);
        defer self.allocator.free(opens);

        var highs = try self.allocator.alloc(f64, row_count);
        defer self.allocator.free(highs);

        var lows = try self.allocator.alloc(f64, row_count);
        defer self.allocator.free(lows);

        var closes = try self.allocator.alloc(f64, row_count);
        defer self.allocator.free(closes);

        var volumes = try self.allocator.alloc(f64, row_count);
        defer self.allocator.free(volumes);

        // Extract columns from candles
        for (candles, 0..) |candle, i| {
            timestamps[i] = candle.timestamp;
            opens[i] = candle.open;
            highs[i] = candle.high;
            lows[i] = candle.low;
            closes[i] = candle.close;
            volumes[i] = candle.volume;
        }

        // Allocate buffers for encoded data
        const enc_timestamps = try self.allocator.alloc(i64, row_count);
        defer self.allocator.free(enc_timestamps);

        const enc_opens = try self.allocator.alloc(i32, row_count);
        defer self.allocator.free(enc_opens);

        const enc_highs = try self.allocator.alloc(i32, row_count);
        defer self.allocator.free(enc_highs);

        const enc_lows = try self.allocator.alloc(i32, row_count);
        defer self.allocator.free(enc_lows);

        const enc_closes = try self.allocator.alloc(i32, row_count);
        defer self.allocator.free(enc_closes);

        const enc_volumes = try self.allocator.alloc(i32, row_count);
        defer self.allocator.free(enc_volumes);

        // Delta-encode timestamps
        try compression.encodeTimestamps(timestamps, enc_timestamps);

        // Delta-encode prices (scale by 100 for 2 decimal places)
        const scale = 100.0;
        _ = try compression.encodePrices(opens, enc_opens, scale);
        _ = try compression.encodePrices(highs, enc_highs, scale);
        _ = try compression.encodePrices(lows, enc_lows, scale);
        _ = try compression.encodePrices(closes, enc_closes, scale);
        _ = try compression.encodePrices(volumes, enc_volumes, scale);

        // Calculate sizes
        const ts_size = enc_timestamps.len * @sizeOf(i64);
        const open_size = enc_opens.len * @sizeOf(i32);
        const high_size = enc_highs.len * @sizeOf(i32);
        const low_size = enc_lows.len * @sizeOf(i32);
        const close_size = enc_closes.len * @sizeOf(i32);
        const volume_size = enc_volumes.len * @sizeOf(i32);

        // Calculate offsets (after 4KB header)
        const header_size = storage.FileHeader.SIZE;
        var offset: u64 = header_size;

        const ts_offset = offset;
        offset += ts_size;

        const open_offset = offset;
        offset += open_size;

        const high_offset = offset;
        offset += high_size;

        const low_offset = offset;
        offset += low_size;

        const close_offset = offset;
        offset += close_size;

        const volume_offset = offset;
        offset += volume_size;

        // Ensure file is large enough
        try file_store.expand(offset);

        // Write compressed data to mmap
        const ts_slice = try file_store.getSliceMut(ts_offset, ts_size);
        @memcpy(ts_slice, std.mem.sliceAsBytes(enc_timestamps));

        const open_slice = try file_store.getSliceMut(open_offset, open_size);
        @memcpy(open_slice, std.mem.sliceAsBytes(enc_opens));

        const high_slice = try file_store.getSliceMut(high_offset, high_size);
        @memcpy(high_slice, std.mem.sliceAsBytes(enc_highs));

        const low_slice = try file_store.getSliceMut(low_offset, low_size);
        @memcpy(low_slice, std.mem.sliceAsBytes(enc_lows));

        const close_slice = try file_store.getSliceMut(close_offset, close_size);
        @memcpy(close_slice, std.mem.sliceAsBytes(enc_closes));

        const volume_slice = try file_store.getSliceMut(volume_offset, volume_size);
        @memcpy(volume_slice, std.mem.sliceAsBytes(enc_volumes));

        // Update file header
        const header = file_store.getHeader();
        header.row_count = @intCast(row_count);
        header.column_offsets[0] = ts_offset;
        header.column_offsets[1] = open_offset;
        header.column_offsets[2] = high_offset;
        header.column_offsets[3] = low_offset;
        header.column_offsets[4] = close_offset;
        header.column_offsets[5] = volume_offset;

        // Flush changes to disk
        try file_store.flush();

        // Build B-tree index from timestamps
        var btree = try index.BTree.init(self.allocator);
        for (timestamps, 0..) |ts, i| {
            try btree.insert(ts, @intCast(i));
        }

        // Store index in map (using a copy of symbol as key)
        const symbol_copy = try self.allocator.dupe(u8, symbol);
        try self.indexes.put(symbol_copy, btree);
    }

    /// Query candles in time range
    pub fn query(self: *TSDB, symbol: []const u8, start: i64, end: i64, allocator: std.mem.Allocator) ![]Candle {
        // Get the B-tree index for this symbol
        const btree = self.indexes.get(symbol) orelse return error.SymbolNotFound;

        // Perform range query on B-tree
        const entries = try btree.rangeQuery(start, end, allocator);
        defer allocator.free(entries);

        if (entries.len == 0) {
            return allocator.alloc(Candle, 0);
        }

        // Open storage file
        const file_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}.tsdb", .{ self.data_dir, symbol });
        defer self.allocator.free(file_path);

        var file_store = try storage.FileStorage.open(file_path, false);
        defer file_store.deinit();

        const header = file_store.getHeaderConst();

        // Allocate result array
        var results = try allocator.alloc(Candle, entries.len);

        // Read and decode columns
        const ts_data = try file_store.getSlice(header.column_offsets[0], header.row_count * @sizeOf(i64));
        const open_data = try file_store.getSlice(header.column_offsets[1], header.row_count * @sizeOf(i32));
        const high_data = try file_store.getSlice(header.column_offsets[2], header.row_count * @sizeOf(i32));
        const low_data = try file_store.getSlice(header.column_offsets[3], header.row_count * @sizeOf(i32));
        const close_data = try file_store.getSlice(header.column_offsets[4], header.row_count * @sizeOf(i32));
        const volume_data = try file_store.getSlice(header.column_offsets[5], header.row_count * @sizeOf(i32));

        // Convert byte slices to typed slices
        const ts_slice: []const i64 = std.mem.bytesAsSlice(i64, ts_data);
        const open_slice: []const i32 = std.mem.bytesAsSlice(i32, open_data);
        const high_slice: []const i32 = std.mem.bytesAsSlice(i32, high_data);
        const low_slice: []const i32 = std.mem.bytesAsSlice(i32, low_data);
        const close_slice: []const i32 = std.mem.bytesAsSlice(i32, close_data);
        const volume_slice: []const i32 = std.mem.bytesAsSlice(i32, volume_data);

        // Decode timestamps
        const dec_timestamps = try allocator.alloc(i64, header.row_count);
        defer allocator.free(dec_timestamps);
        try compression.decodeTimestamps(ts_slice, dec_timestamps);

        // Decode prices
        const scale = 100.0;

        const dec_opens = try allocator.alloc(f64, header.row_count);
        defer allocator.free(dec_opens);
        const dec_highs = try allocator.alloc(f64, header.row_count);
        defer allocator.free(dec_highs);
        const dec_lows = try allocator.alloc(f64, header.row_count);
        defer allocator.free(dec_lows);
        const dec_closes = try allocator.alloc(f64, header.row_count);
        defer allocator.free(dec_closes);
        const dec_volumes = try allocator.alloc(f64, header.row_count);
        defer allocator.free(dec_volumes);

        // For prices, we need the base value. Calculate from first encoded value + first delta
        const first_open_scaled = @as(i64, @intFromFloat(0.0 * scale)) + open_slice[0];
        const first_high_scaled = @as(i64, @intFromFloat(0.0 * scale)) + high_slice[0];
        const first_low_scaled = @as(i64, @intFromFloat(0.0 * scale)) + low_slice[0];
        const first_close_scaled = @as(i64, @intFromFloat(0.0 * scale)) + close_slice[0];
        const first_volume_scaled = @as(i64, @intFromFloat(0.0 * scale)) + volume_slice[0];

        try compression.decodePrices(open_slice, dec_opens, first_open_scaled, scale);
        try compression.decodePrices(high_slice, dec_highs, first_high_scaled, scale);
        try compression.decodePrices(low_slice, dec_lows, first_low_scaled, scale);
        try compression.decodePrices(close_slice, dec_closes, first_close_scaled, scale);
        try compression.decodePrices(volume_slice, dec_volumes, first_volume_scaled, scale);

        // Reconstruct candles from matching indices
        for (entries, 0..) |entry, i| {
            const idx = entry.value;
            results[i] = Candle.init(
                dec_timestamps[idx],
                dec_opens[idx],
                dec_highs[idx],
                dec_lows[idx],
                dec_closes[idx],
                dec_volumes[idx],
            );
        }

        return results;
    }
};

test "library imports" {
    try std.testing.expect(true);
}
