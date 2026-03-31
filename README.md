# Quantum Zig Forge

A monorepo of **87 production-grade Zig programs**, **132 coreutils replacements**, and a **tri-architecture bare-metal operating system** (x86_64, ARM64, RISC-V 64) — developed by QUANTUM ENCODING LTD.

**1.2 million lines of Zig. 2,391 source files. Zero external runtime dependencies.**

## Repository Structure

```
zig-forge/
├── programs/              # 87 standalone programs and libraries
│   ├── zig_ai/            # Universal AI CLI + agent SDK with C FFI
│   ├── zig_inference/     # ML inference engine (LLaMA, Whisper)
│   ├── zigix_desktop/     # TUI window manager for Zigix OS
│   ├── zigix_monitor/     # System resource monitor for Zigix OS
│   └── ...                # 82 more programs (see full catalog below)
├── zig_core_utils/        # 132 GNU coreutils replacements
├── zig_doom/              # Zig DOOM port
├── zigix_dev/             # Zigix OS (development, private)
├── zigix-public/          # Zigix OS (public release)
├── libs/                  # Shared libraries
├── build.zig              # Root build orchestrator
├── zig-out/               # Centralized build output
│   ├── bin/               # All program binaries
│   └── lib/               # Shared libraries
└── docs/                  # Monorepo-wide documentation
```

## Full Program Catalog

### AI and Machine Learning

| Program | Description | Binary | Status |
|---------|-------------|--------|--------|
| **zig_ai** | Universal AI CLI + agent SDK — Claude, Gemini, Grok, DeepSeek, OpenAI. Agent mode with 17 tools, orchestrator DAG engine, C FFI with 40+ exports. | `zig-ai` | Complete |
| **zig_inference** | From-scratch ML inference — LLaMA text generation (GGUF) + Whisper speech-to-text (ggml). Quantized weights (Q4_0/Q8_0), mmap loading, multi-threaded matmul. | `zig-infer` | Complete |
| **cerberus** | GPU/TPU ML predictor — Keras models, TPU training, GPU vs TPU benchmarking. | (Python) | Research |
| **cognitive_telemetry_kit** | AI cognitive state monitoring — D-Bus server, SQLite persistence, Claude Code hooks, CSV export. | `chronos-hook`, `cognitive-state-server` | Complete |

### Networking and Protocols

| Program | Description | Binary | Status |
|---------|-------------|--------|--------|
| **http_sentinel** | Production HTTP client library — 9 AI providers (Claude, GPT, Gemini, Grok, DeepSeek, Vertex AI, ElevenLabs, Meshy, HeyGen), thread-safe, GZIP, C FFI. | (library) | Complete |
| **http_sentinel_ffi** | HTTP client C FFI — blocking interface, caller-provided buffers, TLS support. | `libhttp_sentinel.a` | Complete |
| **quantum_curl** | High-velocity HTTP router — multi-format ingestion (CSV/TSV/JSON/JSONL), base64 extraction for images, --output-dir, ~2ms p99 latency. | `quantum-curl` | Complete |
| **zig_reverse_proxy** | HTTP reverse proxy — round-robin/least-connections LB, health checks, WebSocket proxying. | `reverse-proxy` | Complete |
| **zig_dns_server** | Authoritative DNS server — RFC 1035, zone files, A/AAAA/CNAME/MX/NS/TXT/SOA records. | `dns-server` | Complete |
| **zig_websocket** | RFC 6455 WebSocket — frame parsing, masking, handshake, fragmentation. ~71M decode ops/sec. | `websocket-demo` | Complete |
| **warp_gate** | P2P file transfer — NAT traversal (STUN/UDP hole punch), mDNS, ChaCha20-Poly1305 encryption. | `warp` | Complete |
| **zero_copy_net** | io_uring zero-copy network stack — lock-free buffer pool, TCP server. | `tcp-echo` | WIP |
| **zig_dpdk** | Userspace network stack — AF_XDP, ixgbe PMD, hugepage allocator, poll-mode RX/TX for 10/40/100GbE. | `zig-dpdk` | WIP |

### Financial and Trading

| Program | Description | Binary | Status |
|---------|-------------|--------|--------|
| **financial_engine** | HFT trading system ("The Great Synapse") — sub-microsecond latency, lock-free order book, Alpaca integration. | `zig-financial-engine` | Complete |
| **market_data_parser** | SIMD-accelerated exchange feed parser — 2M+ msg/sec, ~96ns/msg, Binance/Coinbase protocols. | `bench-parser` | Complete |
| **timeseries_db** | Columnar time series DB — mmap zero-copy, SIMD delta encoding, B-tree indexing, 10M+ reads/sec. | `tsdb` | Complete |
| **stratum_engine_claude** | Stratum mining engine — SIMD SHA256d, mempool monitoring, mbedTLS exchange connections. | `stratum-engine` | Complete |
| **stratum_engine_grok** | io_uring Stratum engine — zero-copy async networking, native SHA256d. | `stratum-engine-grok` | Complete |

### Cryptography and Security

| Program | Description | Binary | Status |
|---------|-------------|--------|--------|
| **simd_crypto_ffi** | AVX-512 crypto primitives — SHA256 (10GB/s), BLAKE3 (15GB/s), ChaCha20 (20GB/s), AES-GCM (25GB/s). C FFI. | `libquantum_crypto.a` | WIP |
| **zig-quantum-encryption** | Post-quantum crypto — NIST FIPS 203 ML-KEM-768, hybrid with X25519, AES-256-GCM. | (library) | WIP |
| **zig_jwt** | JWT tokens — HS256 signing, verification, decoding. | `zig-jwt` | Complete |
| **zig_secret_scanner** | Secret detection — 50+ patterns (AWS, GitHub, Stripe, etc.), entropy analysis, git hooks, SARIF output. | `zss` | Complete |
| **guardian_shield** | Linux security framework — seccomp-BPF, LD_PRELOAD, eBPF monitoring, fork bomb prevention. | `zig-sentinel` | Complete |
| **zig_jail** | Syscall sandbox — seccomp-BPF, namespaces, capability dropping, security profiles. | `zig-jail` | Complete |
| **zig_port_scanner** | TCP port scanner — multi-threaded, service detection, poll()-based non-blocking I/O. | `zig-port-scanner` | Complete |
| **electrum_ffi** | Electrum wallet FFI — scripthash computation, JSON-RPC, Bitcoin SPV. | `libelectrum_ffi.a` | Complete |
| **mempool_sniffer** | Bitcoin mempool monitor — P2P protocol, whale detection, cross-platform (io_uring/kqueue/poll). | `libmempool_sniffer_core.a` | WIP |
| **quantum_seed_vault** | Crypto seed manager — Raspberry Pi LCD HAT, BIP39, terminal UI, ARMv6 target. | `quantum-seed-vault` | WIP |

### Data Formats and Serialization

| Program | Description | Binary | Status |
|---------|-------------|--------|--------|
| **zig_json** | Text-to-JSON converter — auto-detect CSV/TSV/KV/lines, numeric detection. | `zig-json` | Complete |
| **zig_toml** | TOML parser — full spec compliance, streaming parser, datetime support. | `zig_toml_demo` | Complete |
| **zig_msgpack** | MessagePack codec — zero-allocation encoding, lazy decoding, extensions. | `msgpack-demo` | Complete |
| **zig_xlsx** | XLSX to JSON — ZIP/DEFLATE parsing, shared strings, sparse columns. | `zig-xlsx` | Complete |
| **zig_docx** | DOCX to MDX — Word document conversion, image extraction, YAML frontmatter, folder batch mode. | `zig-docx` | Complete |
| **zig_base58** | Base58 encoding — Bitcoin/IPFS compatible, Base58Check with SHA256. | `zbase58` | Complete |

### PDF and Document Generation

| Program | Description | Binary | Status |
|---------|-------------|--------|--------|
| **zig_pdf_engine** | PDF generation/parsing — text, vector graphics, images, multi-page, text extraction. | `pdf-gen`, `pdf-text` | Complete |
| **zig_pdf_generator** | Cross-platform PDF library — C FFI, WASM (452KB), invoices, proposals with native charts (pie/bar/progress), contracts, certificates, presentations. 13 WASM exports. | `zigpdf.wasm` | Complete |
| **zig_charts** | SVG + WASM charting (147KB) — 10 types: candlestick, line, bar, area, scatter, pie, gauge, heatmap, progress, sparkline. JSON API for AI integration. | `chart-demo`, `zigcharts.wasm` | Complete |
| **zig-trash** | Safe file deletion — native OS trash (macOS NSFileManager, Linux XDG). 181KB binary. Designed for AI agent deny policies. | `trash` | Complete |

### Infrastructure and Libraries

| Program | Description | Binary | Status |
|---------|-------------|--------|--------|
| **memory_pool** | Fixed-size allocator — O(1) alloc/dealloc, free-list, <10ns target. | (library) | WIP |
| **lockfree_queue** | Lock-free queues — SPSC + MPMC, cache-line padded, wait-free producer. | (library) | WIP |
| **async_scheduler** | Work-stealing scheduler — Chase-Lev deque, thread pool, task priorities. | `bench-scheduler` | WIP |
| **zig_metrics** | Prometheus metrics — atomic counters, gauges, histograms, text export. | `metrics-demo` | Complete |
| **zig_ratelimit** | Rate limiting — 6 algorithms (token bucket, leaky bucket, GCRA, sliding window, fixed window). | `ratelimit-demo` | Complete |
| **zig_bloom** | Probabilistic data structures — Bloom filter, counting Bloom, Count-Min Sketch, HyperLogLog. | `bloom-demo` | Complete |
| **zig_uuid** | UUID generation — v1 (time), v4 (random), v7 (sortable). RFC 4122 compliant. | `zuuid` | Complete |
| **zig_token_service** | Auth token service — composable demo integrating UUID + JWT + rate limiting + Bloom + metrics. | `token-service` | Complete |
| **zig_humanize** | Human-readable formatting — bytes, durations, numbers, ordinals. | (library) | Complete |
| **zig_cron** | Task scheduler — interval-based (5s/1m/1h/1d), signal-based shutdown. | `zig-cron` | Complete |
| **zig_watch** | File watcher — poll-based change detection, extension filtering, command execution. | `zig-watch` | Complete |
| **distributed_kv** | Raft KV store — leader election, WAL with CRC32, TTL, CAS, watch/subscribe. | `kv-server`, `kv-client` | Complete |
| **wasm_runtime** | WebAssembly runtime — MVP spec, WASI preview1, stack VM, multi-module linking. | `wasm` | Complete |

### Developer Tools

| Program | Description | Binary | Status |
|---------|-------------|--------|--------|
| **zig_lens** | Code analysis — Zig/Rust/C/Python/JS structural analysis, dependency graphs, cycle detection. | `zig-lens` | Complete |
| **zig_silicon** | Hardware visualization — Zig-to-assembly mapping, register SVG diagrams, HTML docs. | `zig-silicon` | Complete |
| **zig2asm** | Assembly emitter — Zig to .s/.ll/.o with target shortcuts (arm64, x86, wasm, riscv). | `zig2asm` | Complete |
| **zig-code-query-native** | Zig stdlib explorer — function search, call graph traversal, C FFI. | `zig-code-query` | WIP |
| **zig-ingest** | Code graph ingestion — Zig source parsing, SurrealDB integration. | `zig-ingest` | WIP |
| **zdedupe** | Duplicate finder — BLAKE3/SHA256 hashing, multi-threaded, folder comparison, JSON/HTML output. | `zdedupe` | WIP |
| **register_forge** | SVD to Zig codegen — ARM SVD files to type-safe register definitions. | `register-forge` | WIP |

### Hardware and Embedded

| Program | Description | Binary | Status |
|---------|-------------|--------|--------|
| **zig_hal** | Hardware abstraction layer — MMIO register access, STM32F4, RP2040, ESP32-C3 targets. | `libzig_hal.a` | Complete |
| **zig_tui** | Terminal UI framework — widgets, layouts, mouse support, 36 source files. Foundation for Zigix tools. | `tui-demo` | Complete |
| **audio_forge** | Real-time audio DSP — lock-free ring buffer, SIMD EQ/compression/reverb, ALSA/PipeWire/JACK. Pure Zig codecs (WAV/FLAC/MP3). | `audio-forge` | WIP |

### System Administration and Monitoring

| Program | Description | Binary | Status |
|---------|-------------|--------|--------|
| **chronos_engine** | Sovereign Clock — PHI-synchronized timestamps, D-Bus, cognitive state tracking. | `chronosd`, `chronos-stamp` | Complete |
| **duck_agent_scribe** | Agent accountability — lifecycle logging, turn tracking, batch manifests. | `duckagent-scribe` | Complete |
| **duck_cache_scribe** | Git sync daemon — inotify file watching, debounced commits, chronos timestamps. | `duckcache-scribe` | Complete |
| **claude-shepherd** | Claude Code orchestrator — multi-instance management, permission policies, D-Bus, eBPF. | `claude-shepherd` | WIP |
| **terminal_mux** | Terminal multiplexer — PTY management, pane splitting, 10K scrollback, Unix socket IPC. | `tmux` | Complete |

### Compute and Research

| Program | Description | Binary | Status |
|---------|-------------|--------|--------|
| **variable_tester** | Distributed variable tester — Queen-Worker swarm, lockfree SPSC, dlopen test plugins. | `queen`, `worker`, `forge` | Complete |
| **hydra** | GPU parallel search — CPU Queen + GPU executor (CUDA/TPU via dlopen), SIMD batch preparation. | `hydra` | WIP |

### Zigix OS Integration

| Program | Description | Binary | Status |
|---------|-------------|--------|--------|
| **zigix_desktop** | TUI window manager — tiled windows, PTY terminal emulation, PC-98 amber theme. Dual-use: Linux (full zig_tui + terminal_mux) or Zigix freestanding (13KB RISC-V ELF). | `zigix-desktop` | Complete |
| **zigix_monitor** | System dashboard — CPU/memory/disk/network, tabbed interface, /proc integration. | `zigix-monitor` | Complete |

### Cross-Platform Build Artifacts

| Program | Description | Status |
|---------|-------------|--------|
| **ios-libs** | Pre-compiled iOS static libraries (arm64 + simulator) for 10 Zig libraries. | Artifacts |
| **simd_crypto [TODO]** | SIMD crypto stubs — SHA256, AES-NI, ChaCha20. Signatures defined, implementations pending. | Stubbed |

---

## Zigix — Bare-Metal Operating System

**Zigix** is a bare-metal x86_64/ARM64/RISC-V 64-bit operating system written entirely in Zig, with **36 completed milestones** (16 kernel + 20 userspace) and **133 userspace binaries** on disk. Boots on GCE bare-metal (AMD Turin, Arm Axion Neoverse V2) and QEMU. Runs GNU Make + Zig compiler natively.

### Kernel Highlights

| Feature | Details |
|---------|---------|
| **Architectures** | x86_64 (Limine bootloader, SMP 16-core) + ARM64 (GCE Axion, GICv3) + RISC-V 64 (QEMU virt, Sv39) |
| **Source files** | 200+ Zig files across 3 architectures |
| **Syscalls** | 97 handlers (x86_64), 46 (aarch64), 30+ (riscv64), Linux ABI compatible |
| **Processes** | 512 slots (x86/arm64), 256 (riscv64), fork/execve/clone+threads, futex, signals |
| **Memory** | 4-level paging (x86), Sv39 3-level (riscv64), demand paging, CoW fork, mmap/mprotect/munmap |
| **Filesystems** | ext2/ext3 (journal replay)/ext4 (extents, 64-bit blocks), tmpfs, procfs, devfs, ramfs |
| **Networking** | Full TCP/IP: Ethernet, ARP, IPv4, ICMP, UDP, TCP, DNS, HTTP/HTTPS |
| **Shell** | Line editing, builtins, pipes, job control (Ctrl-C/Z, fg/bg), if/for/while scripting |
| **Multi-user** | /etc/passwd auth, uid/gid switching, zlogin |
| **Servers** | zsshd (curve25519 + chacha20-poly1305 + ed25519), zhttpd (static files) |
| **Self-hosting** | 165 MB Zig compiler running demand-paged from ext2 disk |

### Kernel Milestones (M1-M16)

| # | Milestone | Description |
|---|-----------|-------------|
| M1 | Boot + serial | Limine bootloader, framebuffer, serial debug output |
| M2 | GDT/IDT/PIC/PIT | Global descriptor table, interrupt handlers, timer ticks |
| M3 | Physical memory | Page frame allocator, reference counting, contiguous allocation |
| M4 | Virtual memory | 4-level paging (PML4), HHDM, kernel/user address spaces |
| M5 | Ring 3 userspace | TSS, user/kernel transitions, system call via `int 0x80` |
| M6 | Preemptive scheduler | Round-robin, timer-driven preemption, 64 process slots |
| M7 | Syscall table | 97 handlers (x86_64), 46 (aarch64), Linux ABI compatible |
| M8 | VFS + ramfs | Virtual filesystem layer, mount table, in-memory filesystem |
| M9 | ELF loader | ELF64 loading, demand-paged segments, shebang support |
| M10 | Process lifecycle | fork, execve, waitpid, pipes, blocking I/O |
| M11 | Block device | virtio-blk driver, descriptor rings, DMA transfers |
| M12 | ext2 filesystem | Read-only ext2, inode/block groups, directory traversal |
| M13 | Demand paging + CoW | Page fault handler, lazy allocation, copy-on-write fork |
| M14 | Threads + futex | `clone(CLONE_VM\|CLONE_THREAD)`, futex wait/wake queues |
| M15 | mmap | Anonymous + file-backed mappings, mprotect, munmap, VMA splitting |
| M16 | Signals | rt_sigaction, rt_sigprocmask, signal trampoline, SIGINT/SIGTSTP/SIGCHLD |

### Userspace Milestones (U1-U20)

| # | Milestone | Description |
|---|-----------|-------------|
| U1 | Shell (zsh) | Line editing, builtins (cd/pwd/echo/export/fg/bg/jobs), fork+exec |
| U2 | Cross-compiled utilities | 126 musl static binaries + 7 freestanding programs |
| U3 | Init system (zinit) | PID 1, fork+exec shell, reap children, respawn on exit |
| U4 | TCP/IP networking | virtio-net driver, Ethernet/ARP/IPv4/ICMP/UDP/TCP stack, sockets |
| U5 | DNS + zcurl | DNS resolver (UDP), HTTP/1.0 client (TCP), fetch real websites |
| U6 | Shell pipes + zgrep | Multi-stage pipelines, file redirection, pipe-based utilities |
| U7 | Signals + job control | SIGINT/SIGTSTP, process groups, Ctrl-C/Z, fg/bg/jobs |
| U8 | /proc + /dev | procfs (status, exe, maps, uptime, meminfo), devfs (null, zero, urandom) |
| U9 | Mass utility import | 133 binaries in /bin/ from zig_core_utils |
| U10 | Environment + PATH | export, $VAR expansion, PATH lookup, .profile sourcing |
| U11 | Framebuffer console | Limine framebuffer, VGA font rendering, VT100 escape codes, 16-color ANSI |
| U12 | PS/2 keyboard | IRQ 1 scancode handling, Set 1 translation, shift/ctrl/caps tracking |
| U13 | tmpfs | In-memory writable /tmp, create/write/unlink/truncate |
| U14 | ext2 write support | Persistent block/inode allocation, create/delete files, sync syscall |
| U15 | Multi-user + login | uid/gid, /etc/passwd, permission checks, zlogin |
| U16 | Shell scripting | if/then/fi, for/do/done, while, test/[], $?, \|\|, $() substitution, shebang |
| U17 | Zig compiler port | Streaming demand-paged ELF, 165 MB binary, `zig build-exe` on Zigix |
| U18 | SSH server (zsshd) | curve25519-sha256 key exchange, chacha20-poly1305, ed25519, password auth |
| U19 | HTTP server (zhttpd) | Static file serving, directory listing, Content-Type detection |
| U20 | Zero-copy networking | Shared ring architecture, zcnet syscalls, sub-microsecond packet polling |

### Completed Post-Roadmap

| Milestone | Description |
|-----------|-------------|
| ext3 journal | Journal replay (9/9 tests pass), transaction write path, crash recovery |
| ext4 support | Extents, 64-bit block groups, delayed allocation, flex_bg, mballoc |
| SMP | 16-core scheduling with per-CPU runqueues, work stealing |
| RISC-V 64 | Full port — Sv39 MMU, virtio-blk, ext2, fork/exec/wait4, CoW, shell from disk |
| Linux build | GNU Make + zig cc compiling Linux 6.12.17 tinyconfig on Zigix |

### Planned Milestones

| Milestone | Description |
|-----------|-------------|
| U21 | Run Quantum Zig Forge programs on bare metal (timeseries_db, market_data_parser, zig-ai) |
| Linux kernel | Complete Linux kernel compilation on Zigix (currently reaches CC targets) |
| Self-hosting | Compile Zigix kernel on Zigix itself |

### Custom Userspace Programs

| Binary | Size | Description |
|--------|------|-------------|
| `zinit` | 5 KB | Init system (PID 1), fork+exec shell, respawn |
| `zsh` | 5 KB | Shell with line editing, builtins, if/for/while scripting |
| `zlogin` | 6 KB | /etc/passwd authentication, uid/gid switching |
| `zcurl` | 7 KB | HTTP/1.0 client with DNS resolution |
| `zping` | 5 KB | ICMP ping with microsecond RTT |
| `zgrep` | 5 KB | Pattern matching for pipelines |
| `zhttpd` | 9 KB | HTTP server, static files, directory listing |
| `zsshd` | 22 KB | SSH server (curve25519, chacha20-poly1305, ed25519) |
| `zbench` | 8 KB | Network benchmark, zero-copy ring testing |

---

## zig_core_utils — 132 GNU Coreutils Replacements

High-performance Zig implementations of GNU coreutils optimized for modern hardware with parallel processing, SIMD acceleration, and zero-copy I/O.

### Feature Parity

| Status | Count | Description |
|--------|-------|-------------|
| **Full** | 72 (55%) | All or nearly all GNU options implemented |
| **Partial** | 48 (36%) | Core functionality complete, some options missing |
| **Basic** | 12 (9%) | Minimal implementation |

### Categories (132 utilities)

| Category | Count | Utilities |
|----------|-------|-----------|
| **File Operations** | 16 | `zcat` `zcp` `zdd` `zln` `zlink` `zls` `zmv` `zrm` `zrmdir` `zmkdir` `zmkfifo` `zmknod` `ztouch` `ztruncate` `zshred` `zinstall` |
| **Text Processing** | 19 | `zawk` `zcut` `zfmt` `zfold` `zgrep` `zhead` `zjoin` `znl` `zpaste` `zsed` `zsort` `zsplit` `ztac` `ztail` `ztr` `zuniq` `zwc` `zxargs` `zexpand` |
| **System Info/User** | 22 | `zarch` `zdate` `zdf` `zdu` `zenv` `zfree` `zgroups` `zhostid` `zhostname` `zid` `zlogname` `znproc` `zprintenv` `zps` `zpwd` `zsys` `ztty` `zuname` `zuptime` `zusers` `zwho` `zwhoami` |
| **Encoding/Hashing** | 11 | `zbase32` `zbase64` `zbasenc` `zb2sum` `zcksum` `zhashsum` `zmd5sum` `zsha1sum` `zsha256sum` `zsha512sum` `zsum` |
| **Path/Name Utils** | 8 | `zbasename` `zdirname` `zpathchk` `zreadlink` `zrealpath` `zstat` `ztest` `zexpr` |
| **Process/Permission** | 13 | `zchgrp` `zchmod` `zchown` `zchroot` `zkill` `znice` `znohup` `zpgrep` `zpkill` `zruncon` `zstdbuf` `zsudo` `ztimeout` |
| **Misc Utilities** | 22 | `zcomm` `zcsplit` `zecho` `zunexpand` `zfactor` `zfalse` `ztrue` `zmktemp` `znumfmt` `zod` `zpr` `zprintf` `zptx` `zseq` `zshuf` `zsleep` `zsync` `ztee` `ztsort` `zunlink` `zyes` `zsss` |
| **Extended/Custom** | 21 | `zbackup` `zbench` `zcurl` `zfind` `zgzip` `zjq` `zmore` `zping` `zregex` `zstty` `ztar` `ztime` `ztree` `zvdir` `zxz` `zzstd` `zcopy` `zpaste` `zuptime` `zfree` `zsys` |

### Performance

| Tool | GNU | Zig | Speedup | Technique |
|------|-----|-----|---------|-----------|
| `find` | 21.1s | **2.1s** | **10.2x** | MPMC queue + getdents64 |
| `sha256sum` | 0.388s | **0.111s** | **3.5x** | SIMD message schedule |
| `du` | ~3s | **~1s** | **~3x** | Parallel traversal |
| `jq` | 61ms | **31ms** | **2x** | Buffered I/O |
| `tree` | 14ms | **9ms** | **1.5x** | Buffered I/O |

Tested on Samsung 990 EVO Pro NVMe (7400 MB/s) with 17,854 files.

---

## Building

### Build Everything

```bash
zig build
```

All binaries are placed in `zig-out/bin/` at the repository root.

### Build Specific Programs

```bash
zig build zig_ai
zig build http_sentinel
zig build quantum_curl
zig build zig_inference
zig build financial_engine
zig build market_data_parser
zig build timeseries_db
zig build distributed_kv
zig build zig_pdf_generator
zig build zig_charts
zig build wasm_runtime
zig build zig_dns_server
zig build zig_reverse_proxy
zig build warp_gate
zig build terminal_mux
zig build guardian_shield
zig build chronos_engine
zig build zig_jail
zig build zig_port_scanner
zig build stratum_engine_claude
zig build stratum_engine_grok
zig build async_scheduler
zig build zero_copy_net
zig build memory_pool
zig build lockfree_queue
zig build duck_agent_scribe
zig build duck_cache_scribe
zig build cognitive_telemetry_kit
zig build zig_pdf_engine
zig build audio_forge
zig build zig_inference
zig build zig_websocket
zig build zig_json
zig build zig_toml
zig build zig_msgpack
zig build zig_xlsx
zig build zig_docx
zig build zig_base58
zig build zig_bloom
zig build zig_uuid
zig build zig_jwt
zig build zig_metrics
zig build zig_ratelimit
zig build zig_humanize
zig build zig_cron
zig build zig_watch
zig build zig_secret_scanner
zig build zig_lens
zig build zig_silicon
zig build zig2asm
zig build zig_hal
zig build zig_tui
zig build zig_token_service
zig build zdedupe
zig build register_forge
zig build variable_tester
zig build hydra
zig build claude_shepherd
zig build zigix_desktop
zig build zigix_monitor
zig build electrum_ffi
zig build http_sentinel_ffi
zig build simd_crypto_ffi
zig build mempool_sniffer

# WebAssembly targets
zig build zig_pdf_generator_wasm
```

### Build zig_core_utils

```bash
# Individual utilities
cd zig_core_utils/zfind && zig build -Doptimize=ReleaseFast
cd zig_core_utils/zgrep && zig build -Doptimize=ReleaseFast
# ... etc for each utility
```

### Build All

```bash
zig build all
```

## Testing

```bash
zig build test
```

## Requirements

- **Zig:** 0.16.0-dev.3013+ (required)
- **OS:** Linux (required for guardian_shield, chronos_engine, zig_jail, io_uring programs), macOS/Windows (http_sentinel, most libraries)
- **Optional dependencies:**
  - `libbpf` — guardian_shield eBPF components
  - `libdbus-1` — chronos_engine, cognitive_telemetry_kit D-Bus integration
  - `mbedTLS` — stratum_engine_claude TLS/exchange connections
  - `libzmq` — financial_engine ZeroMQ IPC
  - `espeak-ng` — zig_inference Piper TTS phonemizer
  - Linux kernel 5.1+ — io_uring (zero_copy_net, stratum_engine_grok)
  - Linux kernel 3.17+ — seccomp (zig_jail)

## Statistics

| Metric | Count |
|--------|-------|
| Programs | 87 |
| Core utilities | 132 |
| Total Zig source files | 2,391 |
| Total lines of Zig | ~1.2 million |
| Zigix kernel milestones (M1-M16) | 16 |
| Zigix userspace milestones (U1-U20) | 20 |
| Zigix architectures | 3 (x86_64, ARM64, RISC-V 64) |
| Zigix syscall handlers | 97 (x86_64) + 46 (aarch64) + 30 (riscv64) |
| Zigix userspace binaries | 133 |
| WASM modules | 3 (zigpdf 452KB, zigcharts 147KB, zigix-desktop 13KB) |

## License

MIT License — See individual program LICENSE files for details.

```
Copyright 2025-2026 QUANTUM ENCODING LTD
Website: https://quantumencoding.io
Contact: rich@quantumencoding.io
```

## Adding New Programs

1. Create program directory: `programs/your-program/`
2. Add `build.zig` and source code
3. Update root `build.zig` to include your program
4. Update this README

## Development

Each program maintains its own source code (`src/`), build configuration (`build.zig`), documentation (`README.md`), examples (`examples/`), and tests. The root build system orchestrates building all programs and collects binaries into `zig-out/`.
