# Zig Stratum Engine - Architecture

## Overview

A high-performance Bitcoin Stratum V1 mining client built with Zig 0.16, designed to showcase systems programming excellence and SIMD optimization techniques.

## Project Structure

```
zig-stratum-engine/
├── src/
│   ├── main.zig                 # Entry point, CLI interface
│   ├── stratum/                 # Protocol layer
│   │   ├── types.zig            # Core data structures (Job, Share, Target)
│   │   ├── client.zig           # TCP client for pool communication
│   │   └── protocol.zig         # JSON-RPC parser (zero-alloc)
│   ├── crypto/
│   │   ├── sha256d.zig          # Double SHA-256 (scalar baseline)
│   │   └── sha256_simd.zig      # AVX2/AVX-512 implementations (TODO)
│   ├── miner/
│   │   ├── worker.zig           # Per-thread mining worker
│   │   └── dispatcher.zig       # Work distribution coordinator
│   └── metrics/
│       └── stats.zig            # Real-time statistics tracking
├── benchmarks/
│   └── sha256_bench.zig         # Performance benchmarking suite
└── docs/
    └── ARCHITECTURE.md          # This file
```

## Component Breakdown

### 1. Stratum Layer (`src/stratum/`)

**Purpose**: Handle all network communication with mining pools.

#### `types.zig` - Core Data Structures
- `Job`: Mining work from pool (block header template)
- `Share`: Proof-of-work solution to submit
- `Target`: Difficulty target (256-bit comparison)
- `Credentials`: Pool connection details

#### `client.zig` - TCP Network Client
- **State Machine**: `disconnected → connecting → subscribing → authorizing → ready`
- **Protocol**: Raw TCP socket using `std.posix`
- **Message Framing**: Line-delimited JSON (`\n` separator)
- **API**:
  - `connect()` - Establish TCP connection
  - `subscribe()` - mining.subscribe handshake
  - `authorize()` - mining.authorize authentication
  - `submitShare()` - mining.submit proof-of-work
  - `receiveJob()` - mining.notify job updates

#### `protocol.zig` - JSON-RPC Parser
Zero-allocation message building:
- `buildSubscribe()` - Subscribe request
- `buildAuthorize()` - Auth request
- `buildSubmit()` - Share submission
- `parseDifficulty()` - Extract difficulty from JSON
- `extractMethod()` - Parse method name

### 2. Crypto Layer (`src/crypto/`)

**Purpose**: Bitcoin's double SHA-256 hash function.

#### `sha256d.zig` - Scalar Implementation
- **Algorithm**: SHA-256(SHA-256(data))
- **Input**: 80-byte block header
- **Output**: 32-byte hash
- **Performance**: ~1.2 MH/s (baseline)

**Implementation Details**:
- Uses Bitcoin's big-endian byte order
- Compile-time constant tables (`K`, `H`)
- Inline functions for bit operations
- Manual loop unrolling for performance

#### `sha256_simd.zig` (TODO - Phase 4)
- **AVX2**: 8-way parallel (256-bit registers)
- **AVX-512**: 16-way parallel (512-bit registers)
- **Target**: 35+ MH/s with AVX-512

### 3. Mining Layer (`src/miner/`)

**Purpose**: Multi-threaded mining execution.

#### `worker.zig` - Per-Thread Miner
Each worker runs independently:
1. Build block header from job + nonce
2. Hash with SHA256d
3. Compare against difficulty target
4. Submit if valid, increment nonce
5. Repeat

**Key Features**:
- Lock-free atomic statistics
- Nonce space partitioning (by worker ID)
- Periodic yielding for fairness

#### `dispatcher.zig` - Coordinator
- Spawns N worker threads
- Distributes jobs to all workers
- Aggregates statistics
- Handles graceful shutdown

### 4. Metrics Layer (`src/metrics/`)

**Purpose**: Real-time performance tracking.

#### `stats.zig`
- Hashrate calculation (hashes/second)
- Share acceptance rate
- Uptime tracking
- Thread-safe atomic counters

## Data Flow

```
┌─────────────────────────────────────────────────────┐
│                  Main Thread                        │
│  ┌──────────────┐      ┌──────────────┐            │
│  │ Stratum      │      │ Dispatcher   │            │
│  │ Client       │─────▶│              │            │
│  └──────────────┘ Job  └──────┬───────┘            │
│         │                      │                    │
│         │                      │ Distribute         │
│         │                      │                    │
└─────────┼──────────────────────┼────────────────────┘
          │ Share                │
          │ Submit               │
          │                      ▼
┌─────────▼────────────────────────────────────────────┐
│              Worker Threads (N cores)                │
│  ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐        │
│  │Worker 0│ │Worker 1│ │Worker 2│ │Worker N│        │
│  │        │ │        │ │        │ │        │        │
│  │ SHA256d│ │ SHA256d│ │ SHA256d│ │ SHA256d│        │
│  │  Loop  │ │  Loop  │ │  Loop  │ │  Loop  │        │
│  └────────┘ └────────┘ └────────┘ └────────┘        │
│       │         │         │         │                │
│       └─────────┴─────────┴─────────┘                │
│                   │                                  │
│                   ▼                                  │
│           Atomic Statistics                          │
└──────────────────────────────────────────────────────┘
```

## Performance Characteristics

### Current (Scalar)
- **Hashrate**: ~1.2 MH/s per core
- **Latency**: ~840 ns per hash
- **Threads**: 1-16 (CPU dependent)

### Target (AVX-512)
- **Hashrate**: ~35 MH/s per core (14x improvement)
- **Latency**: ~60 ns per hash
- **SIMD Width**: 16 hashes in parallel

## Mining Algorithm

### Block Header Construction (80 bytes)
```
Bytes  0-3  : Version (u32 little-endian)
Bytes  4-35 : Previous Block Hash (32 bytes)
Bytes 36-67 : Merkle Root (32 bytes)
Bytes 68-71 : Time (u32 little-endian)
Bytes 72-75 : Difficulty Bits (u32 little-endian)
Bytes 76-79 : Nonce (u32 little-endian) ← We brute-force this
```

### Mining Loop
```zig
while (true) {
    header = buildHeader(job, nonce)
    hash = SHA256d(header)

    if (hash < target) {
        submitShare(nonce)
    }

    nonce += 1
}
```

## Future Optimizations

### Phase 3: Integration
- Wire up Stratum client to dispatcher
- Implement job pipeline
- Test against live pools

### Phase 4: SIMD
- AVX2: Process 8 nonces per instruction
- AVX-512: Process 16 nonces per instruction
- Runtime CPU feature detection

### Phase 5: Advanced
- **io_uring**: Zero-copy networking on Linux
- **CPU Pinning**: Dedicate physical cores
- **NUMA-aware**: Optimize for multi-socket systems
- **Metrics Export**: Prometheus endpoint

## Why This Architecture?

1. **Separation of Concerns**: Network, crypto, and mining are independent
2. **Testability**: Each component has unit tests
3. **Performance**: Lock-free where possible, atomic operations
4. **Scalability**: Horizontal scaling via worker threads
5. **Zig Showcase**: Modern language features (comptime, SIMD, zero-cost abstractions)

## Compiling for Maximum Performance

```bash
# Debug build (fast compile)
zig build

# Release build (optimizations enabled)
zig build -Doptimize=ReleaseFast

# Native CPU (enables all SIMD features)
zig build -Doptimize=ReleaseFast -Dcpu=native

# Benchmark
zig build bench
```

## Educational Value

This project demonstrates:
- **Systems Programming**: Raw sockets, byte manipulation
- **Concurrency**: Lock-free algorithms, atomic operations
- **Cryptography**: SHA-256 internals
- **SIMD**: Data parallelism, vectorization
- **Networking**: Protocol implementation, state machines
- **Zig Mastery**: comptime, inline assembly, cross-platform builds

---

**Built with Zig 0.16** - The future of systems programming.
