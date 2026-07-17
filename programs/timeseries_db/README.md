# Time Series Database

Columnar storage for OHLCV (candlestick) market data, written in Zig.

Candles are stored per symbol in a single `<symbol>.tsdb` file: each of the six
fields (timestamp, open, high, low, close, volume) is written as its own
delta-encoded column behind a 4 KB page-aligned header, and an in-memory B-tree
maps timestamps to row offsets for time-range queries.

## What is implemented

- **Columnar on-disk format** — one file per symbol, 4 KB `FileHeader` followed
  by six independent columns (`src/storage/file.zig`).
- **mmap-backed storage** — columns are read/written through a memory-mapped
  region (`src/storage/file.zig`).
- **Delta encoding** — timestamps are delta-encoded; prices/volume are scaled by
  100 (2 decimal places) and delta-encoded as `i32`, with the per-column scaled
  base value persisted in the header. The price path uses `@Vector(4, ...)` SIMD
  for the delta step (`src/compression/delta.zig`).
- **B-tree index** — timestamp → row-offset index with range queries, rebuilt in
  memory on insert (`src/index/btree.zig`).
- **`tsdb` CLI** — command-line front end (`src/cli.zig`).

Not implemented: concurrent/lock-free reads, write-ahead log, compaction,
resampling/aggregation, replication, and a SQL-like query layer. No benchmark
numbers are published here — measure on your own hardware and data before
relying on any throughput claim.

## Library usage

Consume the `timeseries_db` module (exposed via `b.addModule` in `build.zig`):

```zig
const std = @import("std");
const tsdb = @import("timeseries_db");
const TSDB = tsdb.TSDB;
const Candle = tsdb.Candle;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var db = try TSDB.init(io, allocator, "./data");
    defer db.deinit();

    var candles = [_]Candle{
        Candle.init(1700000000, 50000.0, 50100.0, 49900.0, 50050.0, 100.5),
        Candle.init(1700000060, 50050.0, 50150.0, 50000.0, 50100.0, 95.2),
    };
    try db.insert("BTCUSDT", &candles);

    const results = try db.query("BTCUSDT", 1700000000, 1700000120, allocator);
    defer allocator.free(results);
    for (results) |candle| {
        std.debug.print("Time: {}, Close: {d:.2}\n", .{ candle.timestamp, candle.close });
    }
}
```

`TSDB.init` takes a `std.Io`, an allocator, and a data directory. See
`src/main.zig` for the exact signatures.

## Build

```bash
zig build          # build the tsdb CLI (installed to zig-out/bin/tsdb)
zig build test     # run the unit + golden + end-to-end tests
```

## On-disk format

```
File: <symbol>.tsdb

┌──────────────────────────────────────┐
│ FileHeader (4 KB, page-aligned)      │
│  - magic / version / flags           │
│  - row_count                         │
│  - column_offsets[6]                 │
│  - base_values[6] (scaled bases)     │
└──────────────────────────────────────┘
│ Timestamp column (delta-encoded i64) │
│ Open   column (delta-encoded i32)    │
│ High / Low / Close / Volume columns  │
└──────────────────────────────────────┘
```

Prices are scaled by 100 and delta-encoded: the first slot holds a `0`
placeholder and each following slot holds the adjacent difference of the scaled
integers; the scaled base for each column lives in `FileHeader.base_values` so
the first value decodes correctly. Exact byte-level expectations for this format
are covered by the golden/end-to-end tests in `src/main.zig`.

## License

MIT
