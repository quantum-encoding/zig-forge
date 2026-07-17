# Market Data Parser

A Zig parser for exchange market-data WebSocket feeds: a zero-dependency C-ABI
static library (`market_data_core`) plus a higher-level Zig module that reads
JSON price/quantity/field values and maintains a fixed-size order book.

## What actually works today

- **JSON field parser** (`src/parsers/json_parser.zig`) — scans JSON structural
  characters with `@Vector` (SIMD) chunks, finds fields by key, and parses
  price / quantity / integer values. Tested against `std.fmt.parseFloat` and
  external IEEE-754 golden doubles.
- **Order book** (`src/orderbook/book.zig`) — top 100 levels per side, stored in
  cache-line-aligned (`align(64)`) arrays, with binary-search insertion and
  mid-price / spread helpers. Single-threaded: the update path uses no locks or
  atomics, so it is **not** safe for concurrent mutation despite the historical
  "lock-free" comment in the source.
- **C ABI / FFI** (`src/market_data_core.zig`) — `mdc_*` exports for parser,
  price/quantity parsing, and order-book operations. Zero external dependencies.
  Cross-compiles to Android ARM64 (`zig build android`).
- **Coinbase protocol module** (`src/protocols/coinbase.zig`) — message-type
  scaffolding; compiles and is covered by the test step.

## Not yet working

- **Binance protocol module** (`src/protocols/binance.zig`) and the **SBE binary
  decoder** (`src/parsers/sbe_parser.zig`) currently **do not compile** (API
  drift against Zig 0.16) and are excluded from `zig build test`. Do not rely on
  them until fixed.
- FIX protocol, multi-threading, and shared-memory order books are unimplemented.

## Build

```bash
zig build            # build the FFI static library + example/bench executables
zig build core       # just the zero-dep C-ABI static library
zig build android    # cross-compile the static library for aarch64-linux-android
zig build test       # run unit tests (json parser + order book + coinbase)
zig build bench      # run the local micro-benchmark harness
zig build example    # run the Binance parser example
zig build orderbook  # run the order-book demo
```

> The `bench` step prints numbers measured on your own machine. This repo does
> **not** ship verified throughput/latency figures, and none should be quoted
> without re-measuring on the target hardware.

## Usage (Zig)

```zig
const std = @import("std");
const mdp = @import("parser"); // the module name the build exposes to examples

pub fn main() !void {
    var book = mdp.orderbook.OrderBook.init("BTCUSDT");
    book.updateBid(50000.00, 0.1);
    book.updateAsk(50001.00, 0.2);

    if (book.getMidPrice()) |mid| std.debug.print("mid: {d:.2}\n", .{mid});
    if (book.getSpreadBps()) |bps| std.debug.print("spread: {d:.2} bps\n", .{bps});
}
```

## Layout

```
src/market_data_core.zig       C-ABI FFI surface (mdc_*)
src/parsers/json_parser.zig    SIMD-assisted JSON field/number parser
src/parsers/sbe_parser.zig     SBE binary decoder (does not compile yet)
src/orderbook/book.zig         fixed top-100 order book
src/protocols/binance.zig      Binance depth/trade (does not compile yet)
src/protocols/coinbase.zig     Coinbase message scaffolding
src/benchmarks/main_bench.zig  local micro-benchmarks
include/                       C header for the FFI library
examples/                      runnable Zig examples
```

## License

MIT
