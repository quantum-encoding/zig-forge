# Usage Guide

## Quick Start

### Benchmark Mode

Test SHA256d performance without connecting to a pool:

```bash
./zig-out/bin/stratum-engine --benchmark x x
```

Output:
```
╔═══════════════════════════════════════════════════╗
║   ZIG STRATUM ENGINE v0.1.0                    ║
║   High-Performance Bitcoin Mining Client         ║
║   Built with Zig 0.16 - Bleeding Edge            ║
╚═══════════════════════════════════════════════════╝

📡 Pool: --benchmark
👤 Worker: x

🖥️  CPU Cores: 16
📊 CPU Features:
   ✅ AVX-512 (16-way parallel hashing)
   ✅ SSE4.2

🔥 Running SHA256d benchmark...

📈 Performance:
   1.2 MH/s (1000000 hashes in 0.83s)

🎯 Hash output sample:
   90edfc9af553c6ef...
```

### Mining Mode (Live Pool)

Connect to a Stratum mining pool:

```bash
./zig-out/bin/stratum-engine \
  stratum+tcp://solo.ckpool.org:3333 \
  bc1qYourWalletAddress.worker1 \
  x
```

**Note**: Currently requires IP address instead of hostname (DNS resolution coming soon).

Example with IP:

```bash
./zig-out/bin/stratum-engine \
  stratum+tcp://139.99.102.106:3333 \
  bc1qYourWalletAddress.worker1 \
  x
```

### Building

```bash
# Debug build (fast compile, slower runtime)
zig build

# Release build (optimized)
zig build -Doptimize=ReleaseFast

# Native CPU features (enables AVX-512/AVX2)
zig build -Doptimize=ReleaseFast -Dcpu=native
```

### Running Benchmarks

```bash
# Comprehensive benchmark suite
zig build bench

# Output:
═══════════════════════════════════════
  SHA256d Benchmark Suite
═══════════════════════════════════════

📊 Scalar Implementation
   Iterations: 100000
   Time:       0.083s
   Hashrate:   1.20 MH/s
   ns/hash:    832.74

📊 Scalar Implementation
   Iterations: 1000000
   Time:       0.842s
   Hashrate:   1.19 MH/s
   ns/hash:    842.31

📊 Scalar Implementation
   Iterations: 10000000
   Time:       7.798s
   Hashrate:   1.28 MH/s
   ns/hash:    779.79

✨ Benchmark complete!
```

## Command-Line Options

```
Usage: stratum-engine <pool_url> <username> <password>

Arguments:
  pool_url   Mining pool (stratum+tcp://host:port or --benchmark)
  username   Worker name (usually wallet.workername)
  password   Worker password (often just "x")

Examples:
  # Benchmark mode
  stratum-engine --benchmark x x

  # Solo mining (CKPool)
  stratum-engine stratum+tcp://solo.ckpool.org:3333 bc1qwallet.worker1 x

  # Pool mining (Slush Pool)
  stratum-engine stratum+tcp://stratum.slushpool.com:3333 username.worker1 password
```

## Mining Pools

### Testnet Pools (for testing)
- **CK Solo**: `stratum+tcp://solo.ckpool.org:3333`
  - No registration required
  - Solo mining (find full blocks)
  - Good for testing

### Mainnet Pools
- **Slush Pool**: `stratum.slushpool.com:3333`
- **F2Pool**: `stratum.f2pool.com:3333`
- **Antpool**: `stratum.antpool.com:3333`

**Warning**: CPU/GPU mining Bitcoin is unprofitable. This is for educational purposes only.

## Performance Tuning

### 1. Use Release Build
```bash
zig build -Doptimize=ReleaseFast
```

### 2. Enable Native CPU Features
```bash
zig build -Doptimize=ReleaseFast -Dcpu=native
```

### 3. Pin to Physical Cores
```bash
# Linux: Use taskset to pin to cores 0-7
taskset -c 0-7 ./zig-out/bin/stratum-engine ...
```

### 4. Disable Hyperthreading
For maximum single-threaded performance:
```bash
# Linux: Disable HT on cores 8-15
echo 0 | sudo tee /sys/devices/system/cpu/cpu{8..15}/online
```

## Monitoring

The engine prints statistics every 10 seconds:

```
📊 Hashrate: 18.5 MH/s | Shares: 3 | Threads: 16
```

- **Hashrate**: Hashes per second (MH/s = million hashes/second)
- **Shares**: Valid proof-of-work solutions found
- **Threads**: Active mining threads

## Troubleshooting

### Connection Failed
```
❌ Connection failed: ConnectionRefused
```

**Solution**: Check pool URL and port. Ensure pool is reachable:
```bash
ping solo.ckpool.org
telnet solo.ckpool.org 3333
```

### DNS Resolution Not Working
```
❌ Connection failed: InvalidArgument
```

**Current Limitation**: DNS resolution not yet implemented. Use IP addresses:
```bash
# Find pool IP
host solo.ckpool.org
# Use IP directly
stratum-engine stratum+tcp://139.99.102.106:3333 ...
```

### Low Hashrate
- Check CPU usage (`htop`)
- Ensure using release build (`-Doptimize=ReleaseFast`)
- Enable native CPU features (`-Dcpu=native`)
- Verify AVX-512/AVX2 detected in output

### No Shares Found
This is normal! Difficulty is extremely high. With 1-2 MH/s, you might find a share once per hour (or never).

## Development

### Running Tests
```bash
zig build test
```

### Project Structure
```
src/
├── main.zig           # Entry point
├── engine.zig         # Mining coordinator
├── stratum/           # Protocol layer
│   ├── client.zig
│   ├── protocol.zig
│   └── types.zig
├── crypto/            # Hashing
│   └── sha256d.zig
├── miner/             # Mining threads
│   ├── worker.zig
│   └── dispatcher.zig
└── metrics/           # Statistics
    └── stats.zig
```

### Adding SIMD Support

Coming in Phase 4! Will add:
- `src/crypto/sha256_avx2.zig` - 8-way parallel
- `src/crypto/sha256_avx512.zig` - 16-way parallel
- Runtime CPU dispatch

---

**Educational Project** - Built to demonstrate Zig systems programming, not for profitable mining.
