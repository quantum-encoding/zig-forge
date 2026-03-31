# Stratum Engine Claude - Project Notes

## Zig Version

This project uses **Zig 0.16.0-dev.1484+** which has significant API changes from earlier versions.

**IMPORTANT**: Before modifying any Zig code, read `ZIG_0.16_API_CHANGES.md` in this directory. It documents all the breaking changes encountered and their solutions.

## Key API Gotchas

1. **ArrayList**: All methods now require the allocator as first parameter
2. **Timestamps**: `std.time.timestamp()` removed - use `std.c.clock_gettime()`
3. **Sleep**: `std.time.sleep()` removed - use `posix.nanosleep()`
4. **Streams**: `std.io.fixedBufferStream()` removed - use `std.fmt.bufPrint()`
5. **Signals**: `callconv(.C)` → `callconv(.c)`, handler takes `posix.SIG` not `c_int`

## Compatibility Helper

Use `src/utils/compat.zig` for:
- `compat.timestamp()` - Get Unix timestamp in seconds
- `compat.timestampMs()` - Get Unix timestamp in milliseconds

## Build Commands

```bash
zig build              # Build all targets
zig build proxy        # Run the ASIC proxy server
zig build run          # Run main stratum engine
zig build dashboard    # Run mining dashboard
```

## Running the Engine

```bash
# Connect to a mining pool
./zig-out/bin/stratum-engine stratum+tcp://solo.ckpool.org:3333 wallet.worker x

# Demo mode (hash visualization without pool)
./zig-out/bin/stratum-engine --demo x x

# Benchmark mode
./zig-out/bin/stratum-engine --benchmark x x
```

## JSON Output Format

The engine emits JSON events to stderr for dashboard integration:

```json
{"type":"stats","hashrate":608.23,"unit":"KH/s","accepted":0,"rejected":0,"uptime":60,"threads":16}
{"type":"hash","hash":"0000cd8e...","leading_zeros":16,"nonce":10000411,"worker":10}
```

- **stats**: Emitted every 5 seconds with hashrate, shares, uptime
- **hash**: Emitted for hashes with 16+ leading zero bits (interesting finds)

## Known Issues / TODO

### SIMD Performance Optimization (Low Priority)
The AVX2/AVX-512 implementations are now correct (process 2 blocks for 80-byte headers),
but current performance is lower than expected. The SIMD version does ~280 KH/s vs
scalar ~600 KH/s. Potential optimizations:
- Pre-compute message schedule for Block 1 (same for all headers except nonce)
- Use midstate optimization (hash first 64 bytes once, only vary Block 2)
- Reduce memory operations in load functions

## Architecture

```
ASICs ←→ [Stratum Proxy :3333] ←→ Mining Pools
              │
              └─→ [WebSocket :9999] → Svelte Dashboard
              │
              └─→ [SQLite] → Persistence
```

## Module Structure

- `src/proxy/server.zig` - Accept ASIC connections (io_uring)
- `src/proxy/pool_manager.zig` - Multi-pool failover
- `src/proxy/miner_registry.zig` - Track miners, hashrates, alerts
- `src/proxy/websocket.zig` - Dashboard event broadcaster
- `src/storage/sqlite.zig` - Persistence layer
- `src/stratum/` - Stratum protocol types and client
