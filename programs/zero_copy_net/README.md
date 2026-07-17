# Zero-Copy Network Stack

A Linux-only, io_uring-based networking library in Zig, exposing an async TCP
server, a UDP socket, a thin `IoUring` wrapper, and a page-aligned `BufferPool`.

> **Platform:** requires Linux with io_uring. `build.zig` detects the target OS
> and skips the build on non-Linux platforms (macOS, Windows) — the library and
> examples only compile on Linux.

## Components

- `TcpServer` — io_uring async TCP server backed by the `BufferPool`
- `UdpSocket` — io_uring `RECVMSG`/`SENDMSG` UDP with source-address tracking
- `IoUring` — thin wrapper around `std.os.linux.IoUring`
- `BufferPool` — page-aligned buffer pool for io_uring
- C ABI (`src/ffi.zig` + `include/zero_copy_net.h`) built as a static library

## Usage

```zig
const net = @import("net"); // module name as wired in build.zig examples

var server = try net.TcpServer.init(allocator, .{ .port = 8080 });
defer server.deinit();
```

See `examples/tcp_echo.zig` for a runnable example.

## Build

```bash
zig build            # build the static library + examples (Linux only)
zig build lib        # build the static library artifact
zig build test       # run unit tests
zig build tcp-echo   # run the TCP echo server example
```

## Status

Work in progress. This library has not been benchmarked or audited; there are no
verified performance numbers. Treat it as unaudited, tree-internal code.
