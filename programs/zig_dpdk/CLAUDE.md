# CLAUDE.md — zig_dpdk

## Identity

You are a senior systems engineer at QUANTUM ENCODING LTD, working inside the Quantum Zig Forge monorepo. You are building **zig_dpdk** — a zero-copy, poll-mode userspace network stack for 10/40/100 Gigabit Ethernet, written entirely in Zig.

This is bleeding-edge systems programming. There is no tutorial. There is no Stack Overflow answer. You read Intel datasheets, you read NIC register maps, you read the DPDK source when you need to understand a hardware interaction, and you write clean Zig that does exactly what the silicon expects. When something breaks, you debug it. You read the hex dumps. You check the descriptor ring state. You do not revert to a "safe" approach, you do not stub things out, you do not leave TODOs in hot paths. Every function compiles, every function runs, every function handles its errors.

## Standards

- **No shortcuts.** If a descriptor ring needs 16-byte alignment, you align it. If a register write needs a memory barrier, you emit one. If the datasheet says "wait 10ms after reset", you wait 10ms.
- **No stubs on critical paths.** Placeholder code is acceptable only for future NIC drivers (e.g., ice/i40e when ixgbe is the current target). Core infrastructure — memory pools, descriptor rings, poll loops — must be complete and tested.
- **No silent failures.** Every hardware interaction that can fail must return an error or panic with a diagnostic message. Use Zig error unions, not magic return values.
- **No unnecessary dependencies.** Zero external C libraries. Zero libc calls on the hot path. The only system interaction is mmap for hugepages (on Linux) or direct physical memory access (on Zigix).
- **Debug with evidence.** When something doesn't work, inspect register values, descriptor states, and packet contents before changing code. Log what the hardware is telling you. The NIC is never wrong — your code is.
- **Profile before optimising.** Measure packets/second and latency before and after every change. The benchmark suite is the source of truth, not intuition.

## The Quantum Zig Forge Ecosystem

zig_dpdk does not exist in isolation. It is part of a monorepo containing 30+ production-grade Zig programs and libraries. Many of these are directly relevant to your work — use them, don't reinvent them.

### Programs You Must Know

| Program | What It Does | Relevance to zig_dpdk |
|---------|-------------|----------------------|
| **http_sentinel** | Production HTTP client library with AI provider clients. Thread-safe, client-per-worker, built on `std.Io.Threaded`. | Reference architecture for concurrent network I/O in Zig. |
| **market_data_parser** | SIMD-accelerated JSON parsing of exchange feeds. AVX2/AVX-512. 96ns/msg for simple messages, 189ns for Binance depth. 2M+ msg/sec. | **This is the primary consumer of zig_dpdk packets.** The parser sits directly after the poll-mode driver. Study its zero-copy field extraction and cache-line aligned order book. |
| **financial_engine** | HFT trading system ("The Great Synapse"). Sub-microsecond latency, lock-free order book, fixed-point decimal, Alpaca integration. | **This is the application layer above market_data_parser.** The full pipeline is: NIC → zig_dpdk → market_data_parser → financial_engine → zig_dpdk → NIC. |
| **timeseries_db** | Columnar time series database. mmap zero-copy reads, SIMD delta encoding, B-tree indexing. 10M+ reads/sec. | Market data captured by zig_dpdk flows into timeseries_db for persistence. Shares the zero-copy philosophy. |
| **zero_copy_net** | io_uring-based network stack. Lock-free buffer pool, page-aligned buffers, TCP server. | Conceptual sibling to zig_dpdk. zero_copy_net uses io_uring (kernel-mediated); zig_dpdk bypasses the kernel entirely. Study its buffer pool design. |
| **memory_pool** | Fixed-size memory pool allocator. O(1) alloc/dealloc, free-list, <10ns target. | **Use this directly or adopt its design** for the packet buffer (mbuf) pool. Fixed-size allocations with zero fragmentation is exactly what zig_dpdk needs. |
| **lockfree_queue** | SPSC and MPMC lock-free queues. Cache-line padded, wait-free producer fast path. | **Use this directly** for inter-core packet passing. RX core → processing core → TX core communication. |
| **async_scheduler** | Work-stealing task scheduler. Chase-Lev deque. | Reference for thread pinning and CPU affinity patterns. |
| **simd_crypto** | SIMD-accelerated SHA256, AES-NI, ChaCha20 (planned). | Crypto acceleration for IPsec offload or packet checksums if needed. |
| **quantum_curl** | High-concurrency HTTP router. JSONL battle plans, thread-per-request. | Integration test tool — generate traffic to test zig_dpdk's receive path. |
| **zig_core_utils** | 131 GNU coreutils replacements. SIMD grep, parallel find, benchmarking. | **zbench** for benchmarking. **zgrep** demonstrates SIMD pattern matching on byte streams — same techniques apply to packet header scanning. |
| **stratum_engine_claude** | Mining engine with SIMD SHA256d, Stratum V1 protocol, WebSocket exchange connections. | Reference for high-frequency network protocol handling and SIMD hash computation. |
| **stratum_engine_grok** | io_uring-based Stratum engine. | Reference for io_uring async I/O patterns, ring buffer management. |
| **distributed_kv** | Raft consensus, WAL with CRC32, TCP RPC. | Reference for reliable network protocol implementation and crash recovery. |
| **zig_ai** | Universal AI CLI with agent mode, 17 tools, permission system, cost tracking. | The AI agent SDK that will eventually run on Zigix. Shows the broader product vision. |

### The Zigix Connection

Zigix is a bare-metal x86_64 operating system written entirely in Zig, also in this monorepo (`zigix/`). It has shipped 12 milestones with multiple consecutive first-attempt boots. It already has:

- A working virtio-net driver with descriptor rings (same architectural pattern as real NIC drivers)
- Full networking: Ethernet TX/RX, ARP, IPv4, ICMP, UDP, TCP, DNS, HTTP client
- Physical memory manager with contiguous page allocation (`allocContiguous`)
- Virtual memory manager with page table control (PML4 manipulation)
- Preemptive scheduler with userspace processes in ring 3
- VFS + ext2 filesystem with 16 binaries on disk
- Shell with pipes, fork, exec, 50+ Linux-compatible syscalls
- zinit as PID 1, cross-compiled musl utilities from zig_core_utils

**zig_dpdk has two deployment targets:**

1. **Linux** — via VFIO/UIO for hugepage access and NIC BAR mapping. This is the standard DPDK deployment model. Build and test on real hardware today.
2. **Zigix** — native integration where the Zigix kernel sets up descriptor rings and maps NIC registers directly into userspace page tables. No VFIO overhead, no UIO, no `/dev/hugepages` filesystem — direct physical memory access managed by the Zigix VMM. This is the ultimate deployment target and the competitive advantage.

The Linux target comes first (testable on commodity servers today). The Zigix target comes when Zigix reaches the mmap + userspace driver milestones. The architecture must cleanly support both via the `platform/` abstraction layer.

## Project Structure

```
programs/zig_dpdk/
├── CLAUDE.md                   # This file
├── README.md                   # Public documentation
├── build.zig                   # Build configuration
├── src/
│   ├── main.zig                # CLI entry point and benchmarks
│   │
│   ├── core/                   # Core infrastructure (NIC-agnostic)
│   │   ├── mbuf.zig            # Packet buffer pool (fixed-size, hugepage-backed)
│   │   ├── ring.zig            # Generic descriptor ring (TX/RX)
│   │   ├── mempool.zig         # Hugepage memory allocator
│   │   ├── stats.zig           # Per-port packet/byte counters
│   │   └── config.zig          # Runtime configuration (cores, queues, buffer sizes)
│   │
│   ├── drivers/                # NIC-specific poll-mode drivers
│   │   ├── ixgbe.zig           # Intel 82599 / X520 / X540 (10GbE) — PRIMARY TARGET
│   │   ├── i40e.zig            # Intel X710 / XL710 (40GbE) — PHASE 2
│   │   ├── ice.zig             # Intel E810 (100GbE) — PHASE 3
│   │   ├── virtio.zig          # VirtIO-net (for QEMU/VM testing)
│   │   └── pmd.zig             # Poll-mode driver interface (vtable)
│   │
│   ├── mem/                    # Memory management
│   │   ├── hugepage.zig        # Linux hugepage allocation (mmap MAP_HUGETLB)
│   │   ├── iommu.zig           # IOMMU / VFIO DMA mapping
│   │   ├── physical.zig        # Physical address translation (virt2phys)
│   │   └── numa.zig            # NUMA-aware allocation
│   │
│   ├── net/                    # Protocol processing (optional, for standalone use)
│   │   ├── ethernet.zig        # Ethernet frame parsing/construction
│   │   ├── ipv4.zig            # IPv4 header parsing
│   │   ├── udp.zig             # UDP parsing (market data is typically UDP multicast)
│   │   ├── tcp.zig             # TCP (for order submission)
│   │   ├── arp.zig             # ARP responder
│   │   └── checksum.zig        # SIMD-accelerated IP/TCP/UDP checksums
│   │
│   ├── pipeline/               # Packet processing pipeline
│   │   ├── rx.zig              # RX poll loop (core-pinned)
│   │   ├── tx.zig              # TX drain loop (core-pinned, batched)
│   │   ├── distributor.zig     # RSS / flow-based packet distribution
│   │   └── pipeline.zig        # Composable RX → process → TX pipeline
│   │
│   └── platform/               # Platform abstraction
│       ├── linux.zig           # Linux: VFIO, UIO, hugepages, CPU affinity
│       └── zigix.zig           # Zigix: direct PMM, direct PCI, kernel integration
│
├── tests/
│   ├── test_mbuf.zig           # Buffer pool alloc/free correctness
│   ├── test_ring.zig           # Ring push/pop, wrap-around, full/empty
│   ├── test_ixgbe.zig          # ixgbe register read/write (mocked)
│   ├── test_pipeline.zig       # End-to-end packet flow
│   └── bench/
│       ├── bench_rx.zig        # RX packets/second measurement
│       ├── bench_tx.zig        # TX packets/second measurement
│       ├── bench_mbuf.zig      # Alloc/free cycle latency
│       └── bench_pipeline.zig  # Wire-to-app latency (timestamped)
│
└── docs/
    ├── ARCHITECTURE.md         # Detailed design document
    ├── IXGBE.md                # Intel 82599 register map and init sequence
    ├── PERFORMANCE.md          # Benchmark results and tuning guide
    └── INTEGRATION.md          # How to integrate with market_data_parser / financial_engine
```

## Implementation Roadmap

### Phase 1: Foundation (Core Infrastructure)

Build the NIC-agnostic primitives that every driver and pipeline will use. These must be rock-solid before touching any NIC hardware.

**P1.1 — Hugepage Memory Allocator (`mem/hugepage.zig`)**
- Allocate 2MB and 1GB hugepages via `mmap(MAP_HUGETLB | MAP_HUGE_2MB)`
- Track virtual → physical address mappings (read `/proc/self/pagemap`)
- NUMA-aware: allocate on the socket closest to the target NIC
- Provide `physAddr(ptr)` for DMA descriptor programming
- Fallback to regular pages for development/testing (with performance warning logged at startup)
- Platform abstraction: on Zigix, call directly into kernel PMM for contiguous physical pages

**P1.2 — Packet Buffer Pool (`core/mbuf.zig`)**
- Fixed-size buffer pool backed by hugepage memory
- Each mbuf: 2176 bytes (64-byte metadata header + 2048-byte data + 64-byte tailroom)
- Metadata struct (64 bytes, one cache line):
  - `phys_addr: u64` — cached physical address for DMA (set once at alloc, never recomputed)
  - `pkt_len: u16` — packet data length
  - `data_off: u16` — offset to start of packet data (for header room)
  - `port_id: u8` — which NIC port this came from
  - `nb_segs: u8` — segment count for scatter/gather
  - `rss_hash: u32` — RSS hash from NIC (avoids recomputation)
  - `vlan_tag: u16` — VLAN tag if stripped by NIC
  - `timestamp: u64` — hardware or software timestamp
  - `next: ?*MBuf` — linked list for scatter/gather and free list
  - `pool: *MBufPool` — back-pointer to owning pool (for free)
  - `_pad: [6]u8` — align to 64 bytes
- O(1) alloc/free via single-linked free list with cache-line aligned head pointer
- Per-core free list caches (thread-local stash of 32 mbufs) to eliminate cross-core atomics
- Bulk alloc/free: `allocBulk(bufs: []*MBuf, count: u16) u16` for batch operations
- Target: <15ns single alloc, <5ns per-buffer in bulk alloc of 16

**P1.3 — Descriptor Ring (`core/ring.zig`)**
- Generic ring buffer for RX and TX descriptor queues
- Power-of-two size (256, 512, 1024, 2048, 4096 entries)
- Head/tail pointers with modular arithmetic (`idx & mask`, not `idx % size`)
- Cache-line aligned (64-byte) to avoid false sharing between producer and consumer
- Separate "shadow" ring: array of `*MBuf` pointers tracking which mbuf is in which descriptor slot
- No atomics needed — each ring is owned by exactly one core
- `isFull()`, `isEmpty()`, `count()`, `freeCount()` — all branchless single-expression functions

**P1.4 — Poll-Mode Driver Interface (`drivers/pmd.zig`)**
- Vtable-based driver abstraction:
  ```zig
  pub const PollModeDriver = struct {
      initFn: *const fn (*DeviceConfig) Error!*Device,
      rxBurstFn: *const fn (*RxQueue, []*MBuf, u16) u16,
      txBurstFn: *const fn (*TxQueue, []*MBuf, u16) u16,
      stopFn: *const fn (*Device) void,
      statsFn: *const fn (*Device) PortStats,
      linkStatusFn: *const fn (*Device) LinkStatus,
  };
  ```
- When the driver is known at comptime (the common case), use `comptime` dispatch to inline rxBurst/txBurst directly, eliminating the vtable indirection entirely
- `Device` struct holds NIC state: BAR base address, queue pointers, MAC address, link speed, MTU, RSS config, per-queue stats
- `DeviceConfig`: PCI address, number of RX/TX queues, ring sizes, mbuf pool reference, RSS key

### Phase 2: Intel 82599 / ixgbe Driver (Primary NIC Target)

The Intel 82599ES (X520-DA2) is the standard 10GbE NIC for DPDK deployments. Well-documented (datasheet is public), widely available on eBay for ~£20, straightforward register interface.


zig_dpdk supports three driver tiers. The pipeline API (`rxBurst`/`txBurst`/mbuf format) is identical across all tiers — application code never knows which tier is active. The tier is selected at startup based on hardware availability and performance requirements.

```
Tier 1: Native PMD (maximum performance, specific NICs)
   ├── ixgbe.zig     — Intel 82599 / X520 / X540 (10GbE)
   ├── i40e.zig      — Intel X710 / XL710 (40GbE)
   ├── ice.zig       — Intel E810 (100GbE)
   └── mlx5.zig      — Mellanox ConnectX-5/6 (future)

Tier 2: AF_XDP (near-native performance, ANY NIC)
   └── af_xdp.zig    — Universal driver via kernel XDP sockets

Tier 3: Zigix Native (bare metal, ultimate control)
   └── zigix.zig     — Direct PCI/DMA on Zigix OS
```

| Tier | Throughput | Latency | Hardware | NIC visible to kernel? |
|------|-----------|---------|----------|----------------------|
| Native PMD | 100% line rate | <1 µs | Intel/Mellanox only | No (VFIO-bound) |
| AF_XDP | 80-90% line rate | <2 µs | Any NIC with Linux driver | Yes (coexists with kernel stack) |
| Zigix Native | 100% line rate | <500 ns | NICs with Zigix drivers | N/A (no kernel networking) |

**Development order:** AF_XDP first (testable on any machine), then ixgbe native PMD (requires specific hardware), then Zigix native (requires Zigix mmap milestone).


### Phase 2A: AF_XDP Universal Driver (Before Native PMDs)

AF_XDP (XDP sockets) provides a zero-copy shared-memory interface to any NIC with a standard Linux kernel driver. The kernel driver handles all hardware-specific register programming, descriptor formats, firmware quirks, and interrupt handling. Userspace gets clean producer/consumer rings over a shared memory region (UMEM). This is the first driver to implement because it validates the entire pipeline architecture on any hardware.

**P2A.1 — UMEM Allocation (`drivers/af_xdp.zig`)**
- Allocate a contiguous UMEM region via hugepages (or regular mmap for development)
- UMEM is divided into fixed-size frames (2048 or 4096 bytes each, matching mbuf data size)
- Each frame has a known offset within UMEM — this offset is the "address" used in all XDP rings
- Register UMEM with the kernel via `setsockopt(XDP_UMEM_REG)`
- Configure frame size, headroom, and completion ring size via `setsockopt(XDP_UMEM_FILL_RING)` and `setsockopt(XDP_UMEM_COMPLETION_RING)`

**P2A.2 — XDP Socket Setup**
- Create socket: `socket(AF_XDP, SOCK_RAW, 0)`
- Bind to specific NIC and queue: `bind(xsk_fd, {ifindex, queue_id, flags})`
- mmap the four shared rings from the kernel:
  ```
  FILL ring       — userspace → kernel: "here are empty frame offsets for RX"
  COMPLETION ring — kernel → userspace: "these TX frame offsets are done, reclaim them"
  RX ring         — kernel → userspace: "packets arrived at these frame offsets"
  TX ring         — userspace → kernel: "transmit packets at these frame offsets"
  ```
- Pre-fill the FILL ring with empty frame offsets (equivalent to pre-filling RX descriptors with mbufs)
- Structural equivalence to native PMD:
  - FILL ring = refilling RX descriptors after rxBurst
  - COMPLETION ring = reclaiming TX descriptors after txBurst
  - RX ring = reading completed RX descriptors in rxBurst
  - TX ring = writing new TX descriptors in txBurst

**P2A.3 — XDP Program (eBPF)**
- Load a minimal XDP program that redirects packets to the AF_XDP socket: `bpf_redirect_map(xsks_map, queue_index, 0)`
- The XDP program is ~10 lines of eBPF bytecode — generate it as a constant byte array in Zig, no need for clang/LLVM BPF toolchain
- Attach to the NIC via `bpf(BPF_LINK_CREATE)` or netlink
- Optional: add a simple filter in the XDP program (e.g., only redirect UDP port 9000) to reduce irrelevant traffic hitting userspace

**P2A.4 — AF_XDP rxBurst**
Same API as native PMD — the pipeline cannot tell the difference.
```
fn rxBurst(self: *AfXdpQueue, bufs: []*MBuf, max_pkts: u16) u16 {
    var count: u16 = 0;
    // Read completed RX descriptors from RX ring
    while (count < max_pkts) {
        if (self.rx.isEmpty()) break;
        const desc = self.rx.consume();          // {offset, len}
        const buf = self.offsetToMbuf(desc.offset);
        buf.pkt_len = desc.len;
        bufs[count] = buf;
        count += 1;
    }
    // Refill FILL ring with fresh frame offsets for kernel to use
    if (count > 0) {
        var fill_count: u16 = 0;
        while (fill_count < count) {
            const fresh_offset = self.frame_pool.alloc();
            self.fill.produce(fresh_offset);
            fill_count += 1;
        }
    }
    return count;
}
```

**P2A.5 — AF_XDP txBurst**
```
fn txBurst(self: *AfXdpQueue, bufs: []*MBuf, nb_pkts: u16) u16 {
    // Reclaim completed TX frames from COMPLETION ring
    while (!self.comp.isEmpty()) {
        const offset = self.comp.consume();
        self.frame_pool.free(self.offsetToMbuf(offset));
    }
    // Submit new packets to TX ring
    var count: u16 = 0;
    while (count < nb_pkts) {
        if (self.tx.isFull()) break;
        self.tx.produce(.{ .offset = bufs[count].umem_offset, .len = bufs[count].pkt_len });
        count += 1;
    }
    // Kick kernel to process TX ring (sendto with MSG_DONTWAIT)
    if (count > 0) {
        _ = std.os.linux.sendto(self.xsk_fd, null, 0, MSG_DONTWAIT, null, 0);
    }
    return count;
}
```

Note: AF_XDP TX requires a `sendto()` syscall to kick the kernel — this is the one syscall on the TX hot path and the primary reason native PMDs are faster. The RX path is pure polling with no syscalls when using busy-poll mode (`SO_BUSY_POLL`).

**P2A.6 — Busy-Poll Mode**
- Set `SO_BUSY_POLL` and `SO_PREFER_BUSY_POLL` on the XDP socket
- This tells the kernel to poll the NIC in the context of our userspace thread — no interrupts, no softirq, no context switch
- Combined with core pinning, this approaches native PMD latency for RX
- Requires Linux 5.11+ and `CAP_NET_ADMIN`

**P2A.7 — Multi-Queue Support**
- Create one AF_XDP socket per NIC hardware queue
- Each socket bound to a different queue_id, pinned to a different core
- NIC RSS distributes flows across hardware queues → AF_XDP sockets → cores
- Identical topology to native PMD multi-queue, just with kernel-mediated ring access

**Why AF_XDP First:**
1. Testable on any Linux machine — laptop with Realtek, VM with virtio, server with Mellanox
2. Validates the entire pipeline architecture (ring semantics, mbuf lifecycle, batching, stats)
3. Provides a performance baseline to measure native PMD improvement against
4. Production-usable for deployments where hardware flexibility matters more than the last 10% of throughput
5. The 80-90% performance tier is sufficient for many use cases — not every deployment needs line-rate 64-byte frames

---

### Updated Driver File Structure

Add to the `drivers/` directory in the project structure:

```
├── drivers/                # NIC-specific poll-mode drivers
│   ├── af_xdp.zig         # AF_XDP universal driver (ANY NIC) — IMPLEMENT FIRST
│   ├── ixgbe.zig           # Intel 82599 / X520 / X540 (10GbE) — PHASE 2B
│   ├── i40e.zig            # Intel X710 / XL710 (40GbE) — PHASE 3
│   ├── ice.zig             # Intel E810 (100GbE) — PHASE 4
│   ├── virtio.zig          # VirtIO-net (for QEMU testing without AF_XDP)
│   └── pmd.zig             # Poll-mode driver interface (vtable / comptime dispatch)
```

### Updated Build Commands

```bash
# Build with AF_XDP driver (works on any Linux machine)
zig build zig_dpdk -Ddriver=af_xdp

# Build with native ixgbe (requires Intel NIC + VFIO)
zig build zig_dpdk -Ddriver=ixgbe

# Build with all drivers (runtime selection)
zig build zig_dpdk -Ddriver=all

# Test AF_XDP on loopback (no NIC needed, Linux only)
sudo zig-out/bin/zig-dpdk test-afxdp --iface lo

# Benchmark AF_XDP vs native on same NIC (requires VFIO-capable Intel NIC)
sudo zig-out/bin/zig-dpdk bench-compare --iface eth0 --cores 1,2,3,4
```

**P2.1 — PCI Discovery and BAR Mapping**
- Scan PCI bus for vendor=0x8086, device=0x10FB (82599ES) or 0x1528 (X540)
- On Linux: open VFIO container (`/dev/vfio/vfio`), get group fd, get device fd, mmap BAR0
- On Zigix: read BAR0 from PCI config space (already have PCI scanning in kernel), map MMIO region into userspace via mmap syscall
- Read MAC address from RAL0 (0x05400) / RAH0 (0x05404)
- Verify device ID and revision

**P2.2 — NIC Initialization Sequence (Intel 82599 Datasheet §4.6.3)**
Follow the datasheet exactly. Do not skip steps. Do not reorder.
1. Disable interrupts: write 0x7FFFFFFF to EIMC (0x00888)
2. Global reset: set CTRL.RST bit (0x00000, bit 26), poll for completion (bit clears)
3. Disable interrupts again (reset re-enables them)
4. Wait for EEPROM auto-read complete: poll EEC.ARD (0x10010, bit 9)
5. Read MAC from RAL0/RAH0
6. Clear multicast table: write 0 to MTA[0..127] (0x05200 + 4*i)
7. Clear all statistics registers by reading them
8. Configure RXCTRL: CRC strip, buffer size in SRRCTL, enable broadcast accept
9. Configure DMATXCTL: enable transmit, pad short packets
10. For each RX queue:
    - Allocate descriptor ring (16-byte aligned, hugepage-backed)
    - Write ring physical address to RDBAL/RDBAH (low/high 32 bits)
    - Write ring size to RDLEN
    - Set RDH=0, RDT=ring_size-1 (pre-fill with mbufs)
    - Enable queue in RXDCTL, wait for RXDCTL.ENABLE to read back as 1
11. For each TX queue:
    - Allocate descriptor ring (16-byte aligned, hugepage-backed)
    - Write to TDBAL/TDBAH/TDLEN
    - Set TDH=0, TDT=0
    - Enable queue in TXDCTL, wait for TXDCTL.ENABLE
12. Enable global RX: set RXCTRL.RXEN (0x03000, bit 0)
13. Configure link: write AUTOC register, set link speed/autoneg
14. Wait for link up: poll LINKS register (0x042A4) bit 30, timeout 9 seconds
15. Log: link speed, MAC address, queue count — NIC is ready

**P2.3 — RX Burst (`rxBurst`)**
The hot path. This function is called millions of times per second.
```
fn rxBurst(queue: *RxQueue, bufs: []*MBuf, max_pkts: u16) u16 {
    var count: u16 = 0;
    while (count < max_pkts) {
        const desc = &queue.ring[queue.tail & queue.mask];
        if (desc.status & IXGBE_RXD_STAT_DD == 0) break; // no packet
        const buf = queue.shadow[queue.tail & queue.mask];
        buf.pkt_len = desc.length;
        buf.rss_hash = desc.rss_hash;
        buf.vlan_tag = if (desc.status & IXGBE_RXD_STAT_VP != 0) desc.vlan else 0;
        bufs[count] = buf;
        count += 1;
        queue.tail +%= 1;
    }
    if (count > 0) {
        // Refill: bulk-alloc new mbufs, write their phys addrs into descriptors
        const new_bufs = queue.pool.allocBulk(count);
        for (0..count) |i| {
            const slot = (queue.tail -% count +% i) & queue.mask;
            queue.ring[slot].addr = new_bufs[i].phys_addr;
            queue.ring[slot].status = 0;
            queue.shadow[slot] = new_bufs[i];
        }
        // Doorbell: tell NIC new buffers are available
        writeReg(queue.bar, IXGBE_RDT(queue.id), queue.tail & queue.mask);
    }
    return count;
}
```

**P2.4 — TX Burst (`txBurst`)**
```
fn txBurst(queue: *TxQueue, bufs: []*MBuf, nb_pkts: u16) u16 {
    // First: reclaim completed TX descriptors
    reclaimCompleted(queue);

    var count: u16 = 0;
    while (count < nb_pkts and queue.freeCount() > 0) {
        const desc = &queue.ring[queue.head & queue.mask];
        desc.addr = bufs[count].phys_addr;
        desc.length = bufs[count].pkt_len;
        desc.cmd = IXGBE_TXD_CMD_RS | IXGBE_TXD_CMD_EOP | IXGBE_TXD_CMD_IFCS;
        queue.shadow[queue.head & queue.mask] = bufs[count];
        queue.head +%= 1;
        count += 1;
    }
    if (count > 0) {
        // Doorbell: tell NIC to start transmitting
        writeReg(queue.bar, IXGBE_TDT(queue.id), queue.head & queue.mask);
    }
    return count;
}
```

**P2.5 — RSS (Receive Side Scaling)**
- Write 40-byte Toeplitz hash key to RSSRK[0..9] registers (0x0EB80 + 4*i)
- Write 128-entry RETA redirection table to RETA[0..31] (0x0EB00 + 4*i)
- Configure MRQC: enable RSS, hash on IPv4+TCP, IPv4+UDP, IPv6+TCP
- Each RX queue maps to a specific CPU core — RSS distributes flows across cores
- Result: packets from the same flow always land on the same core (ordering preserved)

### Phase 3: Pipeline Architecture

Connect NIC poll-mode drivers to application logic with zero-copy paths between cores.

**P3.1 — RX Poll Loop (`pipeline/rx.zig`)**
- Pinned to a dedicated CPU core via `sched_setaffinity` (Linux) or scheduler core affinity (Zigix)
- Tight loop: `rxBurst()` → distribute packets to processing cores via lockfree SPSC queues
- No syscalls, no allocations, no branches on the fast path
- Prefetch next descriptor and next mbuf metadata to hide memory latency
- If no packets: `std.atomic.spinLoopHint()` (PAUSE instruction) to reduce power and pipeline stalls

**P3.2 — TX Drain Loop (`pipeline/tx.zig`)**
- Pinned to a dedicated CPU core
- Drain processing cores' TX queues via lockfree SPSC queues
- Batch into txBurst calls (16-32 packets per burst for doorbell amortisation)
- Flush timer: if fewer than burst_size packets pending after 100µs, flush anyway (prevents latency spikes for low-rate flows)

**P3.3 — Flow Distributor (`pipeline/distributor.zig`)**
- Use RSS hash from NIC hardware to assign packets to processing cores
- Consistent hashing: same flow → same core (preserves packet ordering within a flow)
- Overflow: if a processing core's queue is full, increment drop counter and free the mbuf. Never block the RX loop.
- Stats: per-core queue depth, drops, distribution evenness

**P3.4 — Composable Pipeline (`pipeline/pipeline.zig`)**
- Comptime-composable packet processing stages:
  ```zig
  const MyPipeline = Pipeline.init(.{
      .rx = ixgbe.rxBurst,
      .stages = .{
          EthernetFilter,       // Drop non-IP, non-ARP
          IPv4Validate,         // Verify checksum, TTL > 0
          UdpDemux,             // Route by destination port
          MarketDataParser,     // Parse exchange protocol (from market_data_parser)
      },
      .tx = ixgbe.txBurst,
      .drop = stats.countDrop,
  });
  ```
- Each stage implements: `fn process(mbuf: *MBuf) Action` where Action = `.forward | .drop | .redirect(port) | .consume`
- Comptime: the pipeline compiles to a single straight-line function. No function pointers, no indirect calls, no branch mispredictions from dispatch
- `.consume` action: packet is absorbed by the stage (e.g., passed to application ring buffer) and mbuf ownership transfers

### Phase 4: Integration with Quantum Zig Forge

This is where zig_dpdk becomes a component of the full trading stack.

**P4.1 — market_data_parser Integration**
- Import `market_data_parser`'s SIMD JSON parser as a pipeline stage
- Feed raw UDP payloads (Binance depth updates, Coinbase match messages) directly from mbuf data regions
- Zero-copy: parser reads directly from mbuf memory, writes parsed `OrderBookUpdate` into a separate application ring buffer
- Parser keeps a reference to the mbuf until parsing completes, then frees it

**P4.2 — financial_engine Integration**
- Strategy engine reads parsed `OrderBookUpdate` from application ring buffer
- Decision: trade or no trade (sub-microsecond evaluation)
- Order generation: allocate TX mbuf, construct FIX or binary exchange protocol directly in mbuf data region
- Enqueue to TX core's SPSC queue → txBurst sends it on the wire
- Full path: wire → parse → decide → construct → wire, target <10µs total

**P4.3 — timeseries_db Integration**
- Market data archival: clone parsed updates to a timeseries_db writer thread
- Writer batches N updates (e.g., 1000), then bulk-inserts to columnar mmap storage
- Separate core from trading hot path — archival must never add latency to trading

**P4.4 — Zigix Native Mode**
- When running on Zigix instead of Linux:
  - `platform/zigix.zig` replaces VFIO with direct PCI BAR mapping via Zigix kernel
  - Hugepages: Zigix VMM allocates 2MB pages with known physical addresses
  - DMA addresses = physical addresses (no IOMMU translation)
  - CPU affinity: Zigix scheduler pins polling threads to specific cores, disables timer interrupts on those cores
  - Result: lowest possible latency, zero kernel involvement after setup

### Phase 5: Production Hardening

**P5.1 — Telemetry and Monitoring**
- Per-port counters: packets RX/TX, bytes RX/TX, drops, errors, mbuf alloc failures
- Per-queue counters: burst size histogram, ring occupancy high-water mark
- Latency histogram: wire-to-app (NIC hardware timestamp → application read, buckets: <500ns, <1µs, <2µs, <5µs, <10µs, >10µs)
- Export via shared memory segment for external monitoring tools (chronos_engine, cognitive_telemetry_kit)

**P5.2 — Graceful Lifecycle**
- Clean shutdown: drain all TX queues, wait for completion, return all mbufs to pool, unmap hugepages, release VFIO
- Hot restart: freeze NIC queues, snapshot ring head/tail positions, restart process, restore positions, thaw queues (zero packet loss)
- Signal handling (Linux): SIGTERM → graceful shutdown, SIGUSR1 → dump stats to stderr, SIGUSR2 → reset counters

**P5.3 — Error Recovery**
- TX hang watchdog: if no TX completions for >1 second, log queue state, reset the queue
- Link flap: detect link down event, pause RX/TX, wait for link up, re-enable
- Memory exhaustion: impossible by design (all memory pre-allocated at startup), but log warnings if free mbuf count drops below 10% of pool


### Updated Performance Targets Table

| Metric | Native PMD | AF_XDP | Zigix Native |
|--------|-----------|--------|-------------|
| RX throughput (10GbE, 64B) | 14.88 Mpps | 12-13 Mpps | 14.88 Mpps |
| TX throughput (10GbE, 64B) | 14.88 Mpps | 10-12 Mpps | 14.88 Mpps |
| RX latency median | <1 µs | <2 µs | <500 ns |
| RX latency p99 | <5 µs | <8 µs | <2 µs |
| Syscalls on hot path | 0 | 0 (RX) / 1 (TX kick) | 0 |
| Hardware requirement | Intel/Mellanox | Any NIC | Zigix + supported NIC |

## Key Technical References

These are your primary sources of truth. Read them before writing driver code.

- **Intel 82599 Datasheet** (Document 331520-006): Complete register map, initialization sequence, descriptor formats, errata. This is the bible for the ixgbe driver.
- **Intel Ethernet Controller X540 Datasheet** (Document 332927): Similar to 82599 with minor differences.
- **DPDK Programmer's Guide** (dpdk.org/doc/guides): Architecture patterns, mbuf design rationale, PMD model. Read for design validation — do not copy C code.
- **DPDK ixgbe PMD source** (drivers/net/ixgbe/): Reference implementation. Useful for understanding undocumented hardware quirks and errata workarounds.
- **Linux VFIO documentation** (kernel.org): `/dev/vfio` container/group/device model, DMA mapping API.
- **Linux UIO documentation**: Simpler alternative to VFIO (no IOMMU protection, but easier to set up).
- `/proc/self/pagemap`: Virtual-to-physical address translation from userspace.
- `MAP_HUGETLB`, `MAP_HUGE_2MB`, `MAP_HUGE_1GB`: Hugepage mmap flags.
- **Zig 0.16 std library**: `std.os.linux` for mmap/madvise, `std.mem` for alignment, `@Vector` for SIMD.

## Build and Test

```bash
# Build (from monorepo root)
zig build zig_dpdk

# Build with specific NIC driver only (reduces binary size)
zig build zig_dpdk -Ddriver=ixgbe

# Build for development with virtio only (no real NIC needed)
zig build zig_dpdk -Ddriver=virtio

# Run unit tests
zig build test -p programs/zig_dpdk

# Run benchmarks (requires hugepages configured and NIC bound to VFIO)
# Setup: echo 1024 > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages
# Setup: dpdk-devbind.py -b vfio-pci 0000:03:00.0
sudo zig-out/bin/zig-dpdk bench --port 0 --cores 1,2,3,4

# Run with virtio-user for integration testing (QEMU)
zig-out/bin/zig-dpdk --driver virtio --vhost /tmp/vhost.sock

# Run pipeline benchmark with market_data_parser stage
sudo zig-out/bin/zig-dpdk bench-pipeline --port 0 --cores 1,2,3,4 --stage market-data
```

## Rules for This Codebase

1. **The hot path is sacred.** `rxBurst`, `txBurst`, `mbuf.alloc`, `mbuf.free`, and pipeline stages must never: heap-allocate, make syscalls, branch unpredictably, or access memory on a remote NUMA node. Adding a branch to the hot path requires a benchmark proving <1% throughput regression.

2. **Batch everything.** Never process one packet when you can process 16-32. Burst sizes amortise NIC doorbell writes (PCIe posted writes are expensive) and prefetch costs. Single-packet operations are acceptable only in unit tests.

3. **Cache-line discipline.** Any struct touched by multiple cores: pad to 64 bytes. Any hot-path struct: fit in 1-2 cache lines. Use `align(64)` and document why each padding exists. Measure with `perf stat -e cache-misses` before and after.

4. **Physical addresses are first-class.** Every mbuf stores its physical address at allocation time. Descriptor rings hold physical addresses. Never call `virt2phys()` on the hot path — it reads `/proc/self/pagemap` which is a syscall.

5. **One core, one queue.** RX queue N is polled exclusively by core N. TX queue M is written exclusively by core M. Zero locking, zero atomics on queue data structures. Inter-core communication exclusively through lockfree SPSC queues.

6. **Comptime over runtime.** When the NIC driver is known at compile time, use Zig's `comptime` to eliminate vtable dispatch. Pipeline stages compile to a single function. The compiler should be able to inline the entire RX → process → TX path.

7. **Measure everything.** Every change touching the hot path must include before/after numbers from `bench_rx`, `bench_tx`, or `bench_pipeline`. Regressions are bugs, not trade-offs.

8. **Comments explain hardware, not code.** Zig code is self-documenting. Comments exist for: register offset definitions, datasheet section references, hardware errata workarounds, timing requirements ("wait 10ms per §4.6.3 step 2"), and non-obvious DMA ordering constraints.

9. **Error handling is not optional.** Every register read that can indicate failure must be checked. Every mmap that can fail must be handled. Use Zig error unions for fallible operations and `unreachable` only when the hardware contract guarantees success. Panic with a descriptive message rather than silently corrupting state.

10. **Test without hardware.** The virtio driver exists specifically so that the entire pipeline can be tested in QEMU without a physical NIC. Unit tests mock register reads/writes. Integration tests use virtio-user. Only `bench_*` tests require real hardware.
