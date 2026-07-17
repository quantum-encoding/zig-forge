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
    io: std.Io,
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    file_handle: ?std.Io.File,
    indexes: std.StringHashMap(index.BTree),

    pub fn init(io: std.Io, allocator: std.mem.Allocator, data_dir: []const u8) !TSDB {
        // Create data directory if it doesn't exist
        std.Io.Dir.cwd().createDirPath(io, data_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        return .{
            .io = io,
            .allocator = allocator,
            .data_dir = data_dir,
            .file_handle = null,
            .indexes = std.StringHashMap(index.BTree).init(allocator),
        };
    }

    pub fn deinit(self: *TSDB) void {
        if (self.file_handle) |file| {
            file.close(self.io);
        }

        // Deinit all B-tree indexes and free the duped symbol keys (the map
        // stores copies of each symbol; StringHashMap does not own them).
        var iter = self.indexes.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit();
            self.allocator.free(entry.key_ptr.*);
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
        const store = try storage.FileStorage.create(self.io, file_path, 1024 * 1024);
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

        // Delta-encode prices (scale by 100 for 2 decimal places).
        // Capture each returned scaled base value so it can be persisted in the
        // header — the encoded column itself stores 0 as a placeholder for the
        // first value, so without the base every price would decode from 0.
        const scale = 100.0;
        const base_open = try compression.encodePrices(opens, enc_opens, scale);
        const base_high = try compression.encodePrices(highs, enc_highs, scale);
        const base_low = try compression.encodePrices(lows, enc_lows, scale);
        const base_close = try compression.encodePrices(closes, enc_closes, scale);
        const base_volume = try compression.encodePrices(volumes, enc_volumes, scale);

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

        // Persist the per-column base values (index 0 = timestamp, whose base
        // is stored in-band; indices 1..5 hold the price/volume bases).
        header.base_values[0] = 0;
        header.base_values[1] = base_open;
        header.base_values[2] = base_high;
        header.base_values[3] = base_low;
        header.base_values[4] = base_close;
        header.base_values[5] = base_volume;

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

        var file_store = try storage.FileStorage.open(self.io, file_path, false);
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

        // Convert byte slices to typed slices. These are align(1) (they point
        // straight into the mmap byte region); the decoders read them unaligned.
        const ts_slice = std.mem.bytesAsSlice(i64, ts_data);
        const open_slice = std.mem.bytesAsSlice(i32, open_data);
        const high_slice = std.mem.bytesAsSlice(i32, high_data);
        const low_slice = std.mem.bytesAsSlice(i32, low_data);
        const close_slice = std.mem.bytesAsSlice(i32, close_data);
        const volume_slice = std.mem.bytesAsSlice(i32, volume_data);

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

        // For prices, the scaled base value is persisted in the header (the
        // encoded column stores 0 as a placeholder for its first value).
        const first_open_scaled = header.base_values[1];
        const first_high_scaled = header.base_values[2];
        const first_low_scaled = header.base_values[3];
        const first_close_scaled = header.base_values[4];
        const first_volume_scaled = header.base_values[5];

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

test "library tests" {
    std.testing.refAllDecls(@This());
}

// ============================================================================
// External-anchored golden vectors
//
// These do NOT rely on decode(encode(x)) == x. The wire-format numbers below
// are derived independently from the documented format contract:
//   * delta.zig documents: prices scaled by `scale` (100 for 2dp), first value
//     replaced by 0 placeholder with the scaled base carried out-of-band, and
//     each subsequent slot holding the successive difference of the scaled
//     integers (i.e. the well-defined adjacent-difference / numpy.diff of the
//     scaled series).
//   * file.zig documents the FileHeader layout and that base_values holds the
//     scaled base per price column.
// The known price series is a fixed OHLC-shaped input; the expected scaled
// integers and on-disk bytes are computed by hand from that spec, so deleting
// every roundtrip test would still leave encode AND decode covered against
// externally-specified numbers.
// ============================================================================

test "golden decode: hand-crafted delta bytes decode to the known price series" {
    // Known price series (BTC-ish OHLC, exact multiples of 0.25 so f64 is exact):
    //   [50000.00, 50000.50, 50001.00, 50000.75]
    // Scaled by 100: [5000000, 5000050, 5000100, 5000075]
    //   base  = 5000000
    //   deltas (adjacent differences, slot 0 = 0 placeholder): [0, 50, 50, -25]
    // On disk each delta is a little-endian i32. -25 = 0xFFFFFFE7.
    var raw_bytes: [16]u8 align(4) = .{
        0x00, 0x00, 0x00, 0x00, // slot 0: 0 (placeholder for base)
        0x32, 0x00, 0x00, 0x00, // slot 1: 50
        0x32, 0x00, 0x00, 0x00, // slot 2: 50
        0xE7, 0xFF, 0xFF, 0xFF, // slot 3: -25
    };
    const deltas = std.mem.bytesAsSlice(i32, raw_bytes[0..]);

    const base: i64 = 5000000; // externally-specified scaled base
    const scale: f64 = 100.0;

    var decoded: [4]f64 = undefined;
    try compression.decodePrices(deltas, &decoded, base, scale);

    const expected = [_]f64{ 50000.00, 50000.50, 50001.00, 50000.75 };
    for (expected, decoded) |want, got| {
        try std.testing.expectEqual(want, got);
    }
}

test "golden encode: insert persists spec-derived scaled base and i32 deltas on disk" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const data_dir = "/tmp/tsdb_golden_encode";
    std.Io.Dir.cwd().deleteTree(io, data_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, data_dir) catch {};

    var db = try TSDB.init(io, allocator, data_dir);
    defer db.deinit();

    // Same known OHLC 'open' series as the golden-decode vector.
    const candles = [_]Candle{
        Candle.init(1700000000, 50000.00, 0, 0, 0, 0),
        Candle.init(1700000060, 50000.50, 0, 0, 0, 0),
        Candle.init(1700000120, 50001.00, 0, 0, 0, 0),
        Candle.init(1700000180, 50000.75, 0, 0, 0, 0),
    };
    try db.insert("GOLD", &candles);

    // Reopen the raw file and inspect bytes directly (NOT via decode).
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}.tsdb", .{ data_dir, "GOLD" });
    defer allocator.free(path);

    var fs = try storage.FileStorage.open(io, path, false);
    defer fs.deinit();

    const header = fs.getHeaderConst();
    try std.testing.expectEqual(@as(u16, storage.FileHeader.VERSION), header.version);
    try std.testing.expectEqual(@as(u64, 4), header.row_count);

    // Persisted scaled base for the 'open' column must be 5000000, not 0.
    try std.testing.expectEqual(@as(i64, 5000000), header.base_values[1]);

    // The 'open' column's on-disk i32 deltas must equal the spec-derived series.
    const open_bytes = try fs.getSlice(header.column_offsets[1], header.row_count * @sizeOf(i32));
    const open_deltas = std.mem.bytesAsSlice(i32, open_bytes);
    const expected_deltas = [_]i32{ 0, 50, 50, -25 };
    for (expected_deltas, open_deltas) |want, got| {
        try std.testing.expectEqual(want, got);
    }
}

test "end-to-end: insert then query returns exact known prices across btree splits" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const data_dir = "/tmp/tsdb_e2e_query";
    std.Io.Dir.cwd().deleteTree(io, data_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, data_dir) catch {};

    var db = try TSDB.init(io, allocator, data_dir);
    defer db.deinit();

    // 200 candles forces multiple B-tree splits (MAX_KEYS = 63). Every field
    // uses a distinct exact (quarter/half-precision) formula so a base-0 decode,
    // a dropped split value, or a column mix-up all fail loudly.
    const N: usize = 200;
    const ts0: i64 = 1_700_000_000;
    var candles: [N]Candle = undefined;
    for (0..N) |i| {
        const fi: f64 = @floatFromInt(i);
        candles[i] = Candle.init(
            ts0 + @as(i64, @intCast(i)) * 60,
            50000.00 + fi * 0.25, // open
            50100.00 + fi * 0.25, // high
            49900.00 + fi * 0.25, // low
            50050.00 + fi * 0.25, // close
            1000.00 + fi * 0.50, // volume
        );
    }
    try db.insert("BTCUSD", &candles);

    // Query a strict sub-range: candles i = 50..150 inclusive (101 rows).
    const start_i: usize = 50;
    const end_i: usize = 150;
    const start = ts0 + @as(i64, @intCast(start_i)) * 60;
    const end = ts0 + @as(i64, @intCast(end_i)) * 60;

    const rows = try db.query("BTCUSD", start, end, allocator);
    defer allocator.free(rows);

    try std.testing.expectEqual(end_i - start_i + 1, rows.len);

    // Every field of every returned candle must match the exact inserted value.
    for (rows, 0..) |row, k| {
        const i = start_i + k;
        const fi: f64 = @floatFromInt(i);
        try std.testing.expectEqual(ts0 + @as(i64, @intCast(i)) * 60, row.timestamp);
        try std.testing.expectEqual(50000.00 + fi * 0.25, row.open);
        try std.testing.expectEqual(50100.00 + fi * 0.25, row.high);
        try std.testing.expectEqual(49900.00 + fi * 0.25, row.low);
        try std.testing.expectEqual(50050.00 + fi * 0.25, row.close);
        try std.testing.expectEqual(1000.00 + fi * 0.50, row.volume);
    }

    // Spot-check the very first inserted candle (open = 50000.00, not 0.00 —
    // the exact base-0 bug this upgrade fixes).
    const first = try db.query("BTCUSD", ts0, ts0, allocator);
    defer allocator.free(first);
    try std.testing.expectEqual(@as(usize, 1), first.len);
    try std.testing.expectEqual(@as(f64, 50000.00), first[0].open);
}
