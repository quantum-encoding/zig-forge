# Bitcoin Whale Sniffer - Quick Start

## Location
**Source:** `src/mempool/sniffer.zig`  
**Docs:** `docs/MEMPOOL-SNIFFER.md`  
**Binary:** Build with `zig build-exe src/mempool/sniffer.zig -femit-bin=whale-sniffer`

## What It Does
Connects to live Bitcoin network and alerts when transactions >1 BTC enter the mempool.

## Build & Run
```bash
cd /home/founder/zig_forge/zig-stratum-engine

# Build
zig build-exe src/mempool/sniffer.zig -femit-bin=whale-sniffer

# Run (connects automatically to Bitcoin network)
./whale-sniffer

# Run in background
nohup ./whale-sniffer > whale-alerts.log 2>&1 &

# Monitor for whales
tail -f whale-alerts.log | grep "WHALE ALERT"
```

## Expected Output
```
🌐 Connecting to Bitcoin network...
✅ Connected!
✅ Handshake complete!
🔊 Passive sonar active - listening for inv broadcasts...
💓 Heartbeat (ping/pong)
🚨 WHALE ALERT: 2.50000000 BTC - [transaction hash in red]
```

## Key Features
- ✅ **Double-SHA256 Checksum** - Proper Bitcoin protocol compliance
- ✅ **Fresh DNS Seed Nodes** - Auto-connects to live Bitcoin nodes
- ✅ **Protocol 70015** - Modern Bitcoin Core compatibility
- ✅ **Passive Sonar Mode** - Listen-only, no mempool dump request
- ✅ **Ping/Pong Keepalive** - Maintains connection
- ✅ **SIMD Hash Display** - AVX2-accelerated hash reversal
- ✅ **Whale Detection** - Alerts on transactions >1 BTC

## Updating Seed Nodes
```bash
# Get fresh Bitcoin node IPs
dig +short seed.bitcoin.sipa.be | head -3

# Update lines 104-108 in src/mempool/sniffer.zig with new IPs
```

## Status: FULLY OPERATIONAL
Connected to live Bitcoin network, waiting for whale transactions.

## Architecture
- **Zig 0.16.0-dev.1303** compatible
- **io_uring** async I/O (standard mode, no SQPOLL)
- **Zero-copy** packet parsing
- **SIMD** hash byte reversal
- **3.4MB** binary (debug), ~500KB (release)

---
*Last Updated: 2025-11-23*
*Zig Financial Engine / Mempool Sniffer v1.0*
