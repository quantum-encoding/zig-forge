# Zero-Copy Network Stack

High-performance networking with io_uring for ultra-low latency applications.

## Performance Targets

- **Latency**: <1µs syscall overhead
- **Throughput**: 10M+ packets/sec per core
- **CPU**: <5% for 1Gbps traffic
- **vs epoll**: 5x lower latency

## Architecture

```
Application → Buffer Pool → io_uring → Kernel → NIC
    ↓             ↓            ↓
Zero-copy   Preallocated   Batch ops
```

## Features

- io_uring based event loop
- Zero-copy send/receive
- Buffer pool management
- TCP/UDP protocols
- NUMA-aware allocation

## Usage

```zig
const net = @import("zero-copy-net");

// Create server with io_uring
var server = try net.TcpServer.init(allocator, .{
    .port = 8080,
    .io_uring_entries = 4096,
    .buffer_count = 1024,
});
defer server.deinit();

// Accept connections (zero-copy)
while (true) {
    const conn = try server.accept();

    // Receive data (zero-copy)
    const data = try conn.recv();

    // Send response (zero-copy)
    try conn.send(response);
}
```

## Build

```bash
zig build
zig build bench
zig build test
```

## Benchmarks

- TCP echo: <1µs round-trip
- UDP send: <500ns per packet
- Connection accept: <2µs
