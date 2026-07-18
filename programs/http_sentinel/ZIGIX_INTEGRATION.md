# Running HTTP Sentinel on Zigix

Status of the effort to run the pure-Zig HTTP Sentinel client as a Zigix
userspace program, and the plan for the Zigix-side work that remains.

## The key architectural finding

The original assumption (see the `recon` target comment in `build.zig`) was that
running on Zigix would require writing a **freestanding `std.Io` vtable** to
replace `std.os.linux`. That is *not* the shortest path.

Zigix already implements the **Linux syscall ABI** — including the `syscall`
instruction that `std.os.linux` emits on x86_64 (`kernel/arch/x86_64/syscall_entry.zig`),
Linux syscall numbers, and the Linux calling convention. It also has a real
from-scratch TCP/IP stack with BSD socket syscalls, `clone`/`futex` threads,
anonymous `mmap`, and DHCP/DNS. That is enough to run a **stock
`std.http.Client` over `std.Io.Threaded`** with *no custom vtable at all* — the
client is compiled `os_tag = .linux, abi = .none, link_libc = false` and run as
an ordinary static ELF whose syscalls Zigix already services.

So the integration is: **build the client as a Linux-ABI userspace ELF and run
it on Zigix**, not "port the client to a bespoke OS backend."

## What is proven today (milestone 1: plaintext HTTP)

`zig build zigix` produces `zig-out/bin/zigix-sentinel-demo` — a statically
linked, no-`PT_INTERP`, no-dynamic-deps x86-64 ELF (`src/zigix_demo.zig`) that
drives `HttpClient` through a **single-threaded** `std.Io` (matching Zigix's
BSP-only scheduler) via the new `HttpClient.initWithIo` seam.

Because the binary is literally Linux syscalls, it was smoke-tested on host
Linux and completed a full plaintext GET (`status=200`, real body bytes). The
**client side of milestone 1 is therefore correct**; any failure on Zigix now
isolates cleanly to a kernel gap below rather than to the client.

The 213 syscall sites the client pulls in were extracted from the recon build.
Every one of them maps to a syscall Zigix's dispatch table already implements
(`kernel/proc/syscall_table.zig`): the socket family (41/42/44/45/…), `futex`
(202), `clone` (56), `mmap`/`munmap` (9/11), `openat`/`read`/`write`/`close`,
`clock_gettime` (228), `getrandom` (318). Nothing the client needs is `ENOSYS`.

## Client-side upgrades made in this pass

1. **`HttpClient.initWithIo(allocator, io)`** (`src/http_client.zig`) — dependency
   inject the `std.Io` handle instead of always constructing a `std.Io.Threaded`
   internally. Ownership is tracked (`io_threaded: ?*…`) so `deinit` never tears
   down an Io it does not own. `init` is unchanged for existing callers.
2. **`setCertValidationTime` / `setCaBundle`** — the HTTPS bring-up seam. Pinning
   `client.now` fixes cert-validity checks against Zigix's boot-relative clock
   *and* suppresses the filesystem CA rescan; `setCaBundle` supplies trust
   anchors explicitly since the rescan is skipped.
3. **`zigix` build target** (`build.zig`) — `os_tag=.linux, abi=.none, link_libc=false`,
   installable, with `-Dzigix-url`, `-Dzigix-arch`, `-Dzigix-cert-epoch-ns`
   options. `src/zigix_demo.zig` is the runnable bring-up program.

Nothing on the pure-Zig live path uses C. The **one** `@cImport` in the whole
tree is `src/crypto/tls.zig` (a BearSSL-based WebSocket client), which is
**orphan / not imported by anything in the build graph**. It does not affect the
Zigix build, but it contradicts the "zero `@cImport`" claim and should either be
deleted or moved out of `src/`. Left in place pending a decision, since it looks
like the start of a separate HFT feature rather than dead scaffolding.

## Zigix-side gaps — the plan for what Zigix still needs

Ordered by what unblocks the most. Everything here is kernel-side; the client is
ready. Severity is relative to running a *secure* HTTPS client.

### Blockers for HTTPS (must fix)

| # | Gap | Evidence | Why it blocks | Fix |
|---|-----|----------|---------------|-----|
| 1 | **`getrandom` is a non-cryptographic LCG** (RDTSC-seeded, 256 B/call cap) | `kernel/proc/syscall_table.zig:2859-2891` | `std.crypto.tls` draws ClientHello randomness and key material from it → TLS session keys are predictable. Handshake *completes* but is insecure. | Wire a real CSPRNG: `RDRAND`/`RDSEED` on x86_64 into an entropy pool feeding `getrandom`. First, hardware instruction; later, a proper pool with reseeding. |
| 2 | **`clock_gettime` is boot-relative, no RTC** (100 Hz tick from 0 at boot; `CLOCK_REALTIME` ≠ wall time) | `kernel/proc/syscall_table.zig:1533-1568` | TLS 1.3 cert validity checks see ~1970 → reject valid certs. | Add an RTC source: read CMOS RTC on x86_64 at boot to seed `CLOCK_REALTIME`; optionally NTP later. **Interim:** the client’s `setCertValidationTime` pins a fixed epoch so bring-up can proceed before this lands. |
| 3 | **CA trust anchors** | — (packaging, not kernel) | `std.http.Client` verifies the server cert against a CA bundle it normally reads from `/etc/ssl/certs`. | Package a CA bundle on the ext image at the path std expects, **or** embed a pinned bundle and pass it via `setCaBundle`. The client seam for the embedded route already exists. |

### Reliability / correctness (fix before trusting it under load)

| # | Gap | Evidence | Impact | Fix |
|---|-----|----------|--------|-----|
| 4 | **`poll`/`ppoll` is an always-ready stub** (returns `POLLIN\|POLLOUT` unconditionally) | `kernel/proc/syscall_table.zig:3524-3573` | `std.Io.Threaded` readiness checks are meaningless; only blocking `recv`/`epoll` are reliable. Fine for one blocking request, wrong for a concurrent event loop. | Implement real readiness: tie `poll`/`select`/`epoll` to socket buffer state in the TCP stack. |
| 5 | **`setsockopt`/`getsockopt` are effectively stubs** | `kernel/proc/syscall_table.zig:2949,3005` | `TCP_NODELAY`, `SO_REUSEADDR`, timeouts silently no-op → latency/behavior surprises. | Honor at least `TCP_NODELAY`, `SO_REUSEADDR`, `SO_RCVTIMEO`/`SO_SNDTIMEO`. |
| 6 | **Small kernel socket buffers** (RX 4 KB/conn, recv staging 1472–4096 B) | `kernel/net/tcp.zig:35-45` | TLS records up to 16 KB need multiple `recv` iterations; large API responses stress the path. | Validate multi-recv correctness under TLS; consider larger per-connection buffers. |

### Throughput (later)

| # | Gap | Evidence | Impact | Fix |
|---|-----|----------|--------|-----|
| 7 | **SMP is single-core (BSP-only scheduling)** | `kernel/proc/scheduler.zig:112-113` (APs skip the timer tick — "SMP CoW race" workaround) | Threads time-slice on one core → concurrency, not parallelism. The batch/engine fan-out works but won’t scale. | Resolve the CoW race so APs can schedule application threads. Not needed for a single request; needed for the 200-way batch executor. |

## Recommended bring-up sequence

1. **Milestone 1 — plaintext HTTP on Zigix.** Copy `zigix-sentinel-demo` (built
   with a `http://` `-Dzigix-url`) onto a Zigix ext image and run it against a
   Zigix-local `zhttpd` or a LAN host. Client is proven; this validates the
   Zigix socket path end-to-end for a std program. Depends on **nothing** in the
   gap list.
2. **Milestone 2 — HTTPS handshake completes.** Fix RTC (#2) or rely on the
   pinned `setCertValidationTime`, and supply a CA bundle (#3). Expect a working
   TLS handshake. Security is still gated on #1.
3. **Milestone 3 — secure HTTPS.** Fix `getrandom` (#1). Now TLS is real. This is
   the point at which the AI-provider clients (Anthropic, Gemini, …) can make
   authenticated calls from Zigix.
4. **Milestone 4 — reliable & concurrent.** Fix `poll` readiness (#4),
   `setsockopt` (#5), socket buffers (#6); then SMP (#7) for the batch executor.

## Reproduce

```bash
cd programs/http_sentinel
zig build zigix -Dzigix-url="http://<host>/"      # milestone 1 binary
./zig-out/bin/zigix-sentinel-demo                 # runs on host Linux too (same ABI)
zig build recon                                   # re-map the std.os.linux surface
zig build test                                    # client regression suite
```
