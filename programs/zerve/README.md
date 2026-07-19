# zerve

A high-performance, evented HTTP/1.1 server core for Zig — non-blocking sockets,
one readiness event loop per worker, and a per-connection state machine, built to
compete with Zap/Actix on the Anton Putra throughput benchmark.

This is the design the thread-per-connection `std.http.Server` model (used by the
`zig_ai_server` gateway) structurally can't match: no thread-per-connection, no
accept lock, no per-request heap allocation at steady state.

## Concurrency model

```
                       :8080 (SO_REUSEPORT)
        ┌──────────────────┼──────────────────┐
   worker 0           worker 1            worker N-1
   own listener       own listener        own listener
   own kqueue loop    own kqueue loop     own kqueue loop
   conn freelist      conn freelist       conn freelist
```

- **SO_REUSEPORT multi-worker.** Each worker thread opens its *own* listening
  socket on the same `addr:port`. The kernel load-balances incoming connections
  across the workers — no shared accept lock, no thundering herd, near-linear
  scaling across cores (the nginx/Zap design).
- **One event loop per worker.** A readiness reactor (kqueue on macOS/BSD)
  watches the listener and every live connection. Read filters are
  level-triggered and persistent; write filters are one-shot and only armed when
  a socket write returns `EAGAIN`, so idle keep-alive connections burn zero
  wakeups.
- **Per-connection state machine.** Each connection is `read → parse → handle →
  write → keep-alive`, fully non-blocking. Partial reads/writes resume on the
  next readiness event.
- **Zero-alloc steady state.** Connection structs (with inline 16 KiB read/write
  buffers) come from a per-worker freelist, so serving an established connection
  does no heap allocation. The HTTP parser returns slices into the read buffer.

## Features

- HTTP/1.1 request line + header parsing, `Content-Length` bodies
- Keep-alive (1.1 default) and `Connection: close`, request **pipelining**
- `TCP_NODELAY`, configurable backlog and worker count
- Allocation-free response builder
- **DoS hardening:** a request head larger than the read buffer gets a `431`
  (not a busy-spin), a body that can't fit gets a `413`, a per-connection
  **idle timeout** reaps slow-loris / half-open connections, and an optional
  **`max_connections`** ceiling bounds the per-worker connection pool
- Response-header-injection guard on `Response.content_type`

## Limits & configuration

`Config` (all fields optional):

| Field | Default | Meaning |
|---|---|---|
| `host` / `port` | `0.0.0.0:8080` | Bind address (IPv4). |
| `workers` | `0` (= CPU count) | SO_REUSEPORT worker threads. |
| `backlog` | `1024` | `listen()` backlog per worker. |
| `idle_timeout_ms` | `30000` | Close a connection idle (no read progress) this long. `0` disables the sweep. The timer is monotonic-clock based, so a clock step can't defeat it; an actively-served keep-alive connection resets it on every read and is never reaped. |
| `max_connections` | `0` (= unlimited) | Per-worker live-connection ceiling. At the cap, new accepts are drained and closed immediately instead of growing the pool. |

**Hard size ceiling.** The request **head and body share a fixed 16 KiB
per-connection buffer.** A header block that exceeds it is answered with `431
Request Header Fields Too Large`; a declared body that would overflow it is
answered with `413 Content Too Large`. Both then close the connection. This is
a deliberate zero-allocation trade-off — for large uploads, terminate/spool at
a proxy in front of zerve.

## Layout

| File | Role |
|---|---|
| `src/reactor.zig` | Readiness event loop. Backend-agnostic interface (kqueue today; epoll/io_uring drop in behind the same shape on Linux). |
| `src/http.zig` | Allocation-free HTTP/1.1 request parser + response builder (with tests). |
| `src/server.zig` | Server core: SO_REUSEPORT workers, accept loop, connection state machine, freelist pool. |
| `src/lib.zig` | Public module surface (`Server`, `Config`, `Handler`, `Request`, `Response`). |
| `src/main.zig` | Benchmark binary serving `GET /api/devices`. |

## Use as a library

```zig
const zerve = @import("zerve");

fn handle(req: *const zerve.Request, res: *zerve.Response) void {
    if (req.method == .GET and req.pathEquals("/api/devices")) {
        res.json("[]");
    } else {
        res.notFound();
    }
}

pub fn main(init: std.process.Init) !void {
    _ = init;
    var server = zerve.Server.init(.{ .port = 8080 }, handle);
    try server.run(); // blocks; spawns workers = CPU count
}
```

## Build & run

```sh
zig build              # build the zerve-bench binary
zig build test         # run the parser/response test suite
zig build run          # serve on 0.0.0.0:8080 (workers = CPU count)
zig build run -- 9000  # override the port
```

Verified locally (`ab -k -n 20000 -c 100`): **~53.8k req/s, 0 failed, all
keep-alive** on the host (macOS/arm64, Debug build).

## Platform

- **macOS / BSD:** kqueue (this build).
- **Linux:** the reactor interface (`addRead` / `enableWrite` / `del` / `poll`)
  is deliberately backend-agnostic so an epoll — and later io_uring — backend
  drops in behind the same shape. Only `reactor.zig` changes.

## Scope / not yet

- No chunked **request** body decoding (responses use `Content-Length`).
- Request head **and** body must fit the 16 KiB per-connection buffer; larger
  requests are rejected with `431`/`413` (see *Limits* above), not spooled.
- No TLS (terminate at a proxy, or add a TLS layer above the connection state
  machine).
- HTTP/1.1 only.
- **Linux epoll backend not yet implemented** — the reactor interface is
  backend-agnostic and the kqueue build is macOS/BSD only today.
