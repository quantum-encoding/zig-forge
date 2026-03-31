# Warp Gate

**Peer-to-peer code transfer without cloud intermediaries.**

Send files directly from laptop to laptop using just a short transfer code.

```
$ warp send ./my-project
Transfer code: warp-729-alpha
Waiting for receiver...

$ warp recv warp-729-alpha
Connecting to peer...
Receiving: my-project (12.4 MB)
████████████████░░░░ 80% 9.9 MB/s
```

## Features

- **No cloud servers** - Direct device-to-device transfer
- **NAT traversal** - Works across different networks via STUN/UDP hole punching
- **Local discovery** - Instant transfer on same LAN via mDNS
- **Encrypted** - ChaCha20-Poly1305 AEAD encryption
- **Simple codes** - Human-readable transfer codes (e.g., `warp-729-alpha`)
- **Cross-platform** - Linux, macOS, Windows

## Installation

```bash
# Build from source
zig build -Doptimize=ReleaseFast

# Install to path
sudo cp zig-out/bin/warp /usr/local/bin/
```

## Usage

### Send files
```bash
warp send ./path/to/files
```

### Receive files
```bash
warp recv warp-XXX-word [destination]
```

### Check network status
```bash
warp status
```

## How It Works

1. **Sender** generates a random transfer code
2. Both peers discover each other via:
   - mDNS (local network) - instant
   - STUN (internet) - discovers public IP for NAT traversal
3. UDP hole punching establishes direct connection
4. Files stream with ChaCha20-Poly1305 encryption
5. Integrity verified via BLAKE3 checksums

## Protocol

```
┌─────────┬──────────┬────────────┬──────────────┐
│ Magic   │ Type     │ Length     │ Payload      │
│ 4 bytes │ 1 byte   │ 4 bytes    │ variable     │
└─────────┴──────────┴────────────┴──────────────┘
```

## Building

```bash
# Debug build
zig build

# Release build
zig build -Doptimize=ReleaseFast

# Run tests
zig build test

# Run benchmarks
zig build bench
```

## Benchmarks

```
╔══════════════════════════════════════════════════════════════╗
║              WARP GATE PERFORMANCE BENCHMARKS                ║
╚══════════════════════════════════════════════════════════════╝

┌─────────────────────────────────────────────────────────────┐
│ Warp Code Generation & Parsing                             │
└─────────────────────────────────────────────────────────────┘
  Generate:     5.2M ops/sec
  Parse:        8.1M ops/sec
  Key derive:   2.1M ops/sec

┌─────────────────────────────────────────────────────────────┐
│ ChaCha20-Poly1305 Encryption                               │
└─────────────────────────────────────────────────────────────┘
     64 bytes:   850.00 MB/s
   1024 bytes:  1200.00 MB/s
  16384 bytes:  1450.00 MB/s
  65536 bytes:  1500.00 MB/s
```

## License

MIT
