# Mempool Sniffer Core - FFI Library

**Status**: ✅ **IMPLEMENTED** - C FFI and the Bitcoin P2P protocol are both in place

**Date**: 2026-07-19 (protocol section rewritten; original foundation doc 2025-12-02)

---

## Executive Summary

The **Mempool Sniffer Core** library ships a C FFI, a callback-based event
system, build infrastructure, **and** the Bitcoin P2P protocol: mainnet socket
connection, version/verack handshake, `ping`/`pong` keepalive, `inv` → `getdata`
transaction fetching, and legacy + BIP141 SegWit transaction parsing
(`src/bitcoin_protocol.zig`).

The transaction parser is hardened against the standard P2P parsing attacks
(H-1..H-4: offset-overflow, value-overflow, witness-vs-txid, unbounded element
counts) and its txid computation is anchored to external vectors — the mainnet
genesis coinbase plus two mainnet SegWit transactions whose raw serialization
and txid both come from the Blockstream Esplora API. Per the repo golden rule,
those anchors are what make the parser's output trustworthy; roundtrip tests
would not.

The receive path performs **cross-recv reassembly**: bytes accumulate in a
growable buffer and are consumed one complete message at a time, so a `tx`
message spanning several `recv` calls is parsed rather than dropped. Buffered
bytes are capped at Bitcoin Core's `MAX_PROTOCOL_MESSAGE_LENGTH` (4,000,000)
plus a header.

---

## What's Complete

| Component | Status | Details |
|-----------|--------|---------|
| **C Header** | ✅ Complete | `mempool_sniffer_core.h` |
| **Static Library** | ✅ Complete | `libmempool_sniffer_core.a` (5.9 MB) |
| **Build System** | ✅ Complete | `build.zig` for Zig 0.16 |
| **Callback API** | ✅ Complete | Transaction + Status callbacks |
| **C Test Suite** | ✅ Complete | **7/7 tests passing** |
| **Thread Safety** | ✅ Complete | Background thread, non-blocking |
| **Error Handling** | ✅ Complete | MS_Error enum with descriptions |

---

## Architecture

### Library Design

```
┌─────────────────────────────────────────────────────────────┐
│  Mempool Sniffer Core API (mempool_sniffer_core.h)        │
│                                                              │
│  ✓ Sniffer Lifecycle                                        │
│    - ms_sniffer_create(ip, port)                           │
│    - ms_sniffer_start() - non-blocking                     │
│    - ms_sniffer_stop()                                      │
│    - ms_sniffer_destroy()                                   │
│                                                              │
│  ✓ Callback Registration                                    │
│    - ms_sniffer_set_tx_callback(callback, user_data)       │
│    - ms_sniffer_set_status_callback(callback, user_data)   │
│                                                              │
│  ✓ Status Query                                             │
│    - ms_sniffer_is_running()                                │
│    - ms_sniffer_get_status()                                │
│                                                              │
│  ✓ Bitcoin Protocol                                         │
│    - P2P socket connection                                  │
│    - Version handshake                                      │
│    - io_uring async I/O                                     │
│    - inv message parsing                                    │
│    - getdata transaction fetching                           │
│    - Whale detection (default 0.1 BTC, runtime-tunable)     │
└─────────────────────────────────────────────────────────────┘
```

### Data Flow

```
Bitcoin Node (8333) ──► Sniffer Thread ──► Callbacks ──► Application
                         ↓
                      io_uring
                      (async I/O)
                         ↓
                    Parse inv msg
                         ↓
                   Send getdata req
                         ↓
                   Parse tx response
                         ↓
                   Extract BTC value
                         ↓
                  Check if whale (default 0.1 BTC)
                         ↓
                 Invoke tx_callback()
```

---

## API Reference

### Creating a Sniffer

```c
#include <mempool_sniffer_core.h>

// Create sniffer instance
MS_Sniffer* sniffer = ms_sniffer_create("216.107.135.88", 8333);

// Set transaction callback
void on_transaction(const MS_Transaction* tx, void* user_data) {
    printf("TX: %ld satoshis\n", tx->value_satoshis);
    if (tx->is_whale) {
        printf("🐋 WHALE ALERT!\n");
    }
}

ms_sniffer_set_tx_callback(sniffer, on_transaction, NULL);

// Set status callback
void on_status(MS_Status status, const char* message, void* user_data) {
    printf("Status: %s\n", message);
}

ms_sniffer_set_status_callback(sniffer, on_status, NULL);

// Start (non-blocking)
ms_sniffer_start(sniffer);

// ... do other work ...

// Stop and cleanup
ms_sniffer_stop(sniffer);
ms_sniffer_destroy(sniffer);
```

---

## Test Results

**File:** `test_core/test.c`

**Command:**
```bash
gcc -o test_core test.c -I../include -L../zig-out/lib -lmempool_sniffer_core -lpthread
./test_core
```

**Results:**
```
╔══════════════════════════════════════════════════════════╗
║  Test Summary                                            ║
╠══════════════════════════════════════════════════════════╣
║  Basic API Tests: 7/7 PASSED                           ║
║  Status changes: 2                                      ║
║  Transactions received: 0                               ║
╚══════════════════════════════════════════════════════════╝
```

### Test Coverage

| Test | Status | Notes |
|------|--------|-------|
| Sniffer creation | ✅ PASS | Handle valid |
| Callback registration | ✅ PASS | Both callbacks set |
| Start sniffer | ✅ PASS | Non-blocking |
| Check running status | ✅ PASS | Reports running |
| Status callbacks | ✅ PASS | 2 status changes observed |
| Stop sniffer | ✅ PASS | Clean shutdown |
| Destroy sniffer | ✅ PASS | No leaks |

---

## Next Steps

### 1. Bitcoin Protocol — DONE

All of the following are implemented in-tree and covered by `zig build test`:

- Raw Bitcoin P2P socket connection (`src/socket.zig`)
- Version message handshake, with a CSPRNG-drawn nonce
- io_uring async I/O on Linux; blocking `recv` with timeout elsewhere
- inv message detection and parsing (`forEachInvTxHash`)
- getdata request for full transactions
- Transaction output value summation (checked u128 accumulator)
- Whale detection (0.1 BTC default, `ms_set_whale_threshold` to change)
- SIMD hash endianness reversal

Remaining known gaps, carried from the 2026-07-17 audit:

- `src/io_backend.zig`'s `IoMux` abstraction is not on the live path; only its
  `backend` enum is consumed (by `ms_performance_info`).
- The `recv` path does not verify the per-message payload checksum against the
  header's checksum field.
- IPv4 only; no DNS resolution (`connectFromString` takes a dotted quad).

**Source file:** `/home/founder/zig_forge/grok/src/stratum/client.zig` (500 lines)

**Integration plan:**
1. Extract functions from `client.zig` into `bitcoin_protocol.zig`
2. Replace placeholder `runSniffer()` implementation
3. Add proper io_uring integration
4. Test against live Bitcoin network
5. Verify whale alerts fire correctly

### 2. Rust Integration for Quantum Vault

Once the Bitcoin protocol is integrated, create Rust wrapper:

```rust
// File: quantum_vault/src/core/mempool_sniffer.rs

use std::os::raw::{c_char, c_int, c_void};
use std::ffi::{CStr, CString};

#[repr(C)]
struct MS_Transaction {
    hash: [u8; 32],
    value_satoshis: i64,
    input_count: u32,
    output_count: u32,
    is_whale: u8,
}

extern "C" {
    fn ms_sniffer_create(ip: *const c_char, port: u16) -> *mut c_void;
    fn ms_sniffer_destroy(sniffer: *mut c_void);
    fn ms_sniffer_set_tx_callback(
        sniffer: *mut c_void,
        callback: extern "C" fn(*const MS_Transaction, *mut c_void),
        user_data: *mut c_void
    ) -> c_int;
    fn ms_sniffer_start(sniffer: *mut c_void) -> c_int;
    fn ms_sniffer_stop(sniffer: *mut c_void) -> c_int;
}

pub struct MempoolSniffer {
    handle: *mut c_void,
}

impl MempoolSniffer {
    pub fn new(ip: &str, port: u16) -> Result<Self, Error> {
        let ip_c = CString::new(ip)?;
        let handle = unsafe { ms_sniffer_create(ip_c.as_ptr(), port) };
        if handle.is_null() {
            return Err(Error::CreationFailed);
        }
        Ok(MempoolSniffer { handle })
    }

    pub fn start(&mut self) -> Result<(), Error> {
        let result = unsafe { ms_sniffer_start(self.handle) };
        if result != 0 {
            return Err(Error::StartFailed);
        }
        Ok(())
    }

    // ... more methods ...
}

impl Drop for MempoolSniffer {
    fn drop(&mut self) {
        unsafe {
            ms_sniffer_stop(self.handle);
            ms_sniffer_destroy(self.handle);
        }
    }
}
```

### 3. Quantum Vault UI Integration

**Trading Tab - "Mempool Live" Feed:**

```typescript
// quantum_vault/src/components/Trading/MempoolLive.tsx

import { useEffect, useState } from 'react';
import { invoke } from '@tauri-apps/api/tauri';

interface MempoolTx {
    hash: string;
    valueBtc: number;
    isWhale: boolean;
    timestamp: number;
}

export function MempoolLive() {
    const [txs, setTxs] = useState<MempoolTx[]>([]);
    const [isListening, setIsListening] = useState(false);

    useEffect(() => {
        // Start mempool sniffer
        invoke('start_mempool_sniffer', { ip: '216.107.135.88', port: 8333 });
        setIsListening(true);

        // Subscribe to transaction events
        const unlisten = listen('mempool-tx', (event: any) => {
            setTxs(prev => [event.payload, ...prev].slice(0, 100));
        });

        return () => {
            unlisten.then(fn => fn());
            invoke('stop_mempool_sniffer');
        };
    }, []);

    return (
        <div className="mempool-live">
            <h2>🌊 Mempool Live Feed</h2>
            <div className="status">
                {isListening ? '✅ Listening' : '❌ Disconnected'}
            </div>
            <div className="tx-feed">
                {txs.map(tx => (
                    <div key={tx.hash} className={tx.isWhale ? 'whale' : 'normal'}>
                        {tx.isWhale && '🐋'} {tx.valueBtc.toFixed(8)} BTC
                        <span className="hash">{tx.hash.substring(0, 16)}...</span>
                    </div>
                ))}
            </div>
        </div>
    );
}
```

---

## Build Instructions

### Compile Library

```bash
cd /home/founder/github_public/quantum-zig-forge/programs/mempool_sniffer
zig build core
```

**Output:**
- `zig-out/lib/libmempool_sniffer_core.a` (5.9 MB)

### Compile C Application

```bash
gcc -o app app.c \
    -I/path/to/include \
    -L/path/to/zig-out/lib \
    -lmempool_sniffer_core \
    -lpthread
```

**Dependencies:**
- `libmempool_sniffer_core.a` (static)
- `pthread` (for threading)
- **NO networking libs** (uses raw POSIX sockets)

---

## Strategic Value

The **Mempool Sniffer Core** will be the **informational edge** for Quantum Vault:

- ✅ **Pre-Confirmation Intelligence** - See transactions before they hit the blockchain
- ✅ **Whale Tracking** - Detect large BTC movements in real-time
- ✅ **MEV Detection** - Identify frontrunning opportunities
- ✅ **Market Sentiment** - Gauge network activity and fee pressure
- ✅ **Alert System** - Push notifications for whale movements

**Integration Stack:**
```
Bitcoin Network (P2P Port 8333)
      ↓
mempool_sniffer_core (Zig library)
      ↓
Rust Wrapper (quantum_vault)
      ↓
Tauri Event System
      ↓
React UI (Mempool Live Tab)
```

---

## Conclusion

The **Mempool Sniffer Core** is implemented end-to-end: C FFI, P2P protocol,
externally-anchored transaction parsing, and cross-recv reassembly, all green
under `zig build test` and clean under `zig-lens --strict`.

**Current Status:** Implemented; see the known gaps above.

**Next Milestone:** Per-message checksum verification and either wiring or
removing the unused `IoMux` abstraction.

---

**Maintained by**: Quantum Encoding Forge
**License**: MIT
**Version**: 2.0.0-cross-platform
**Completion**: 2026-07-19 (protocol implemented + externally anchored)
**Performance Target**: 🏆 **<1µs latency per transaction**
