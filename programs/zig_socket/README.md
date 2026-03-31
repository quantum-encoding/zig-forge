# Zig Socket

A cross-platform TCP/UDP socket abstraction and RFC 6455 WebSocket client library for Zig **0.16.0**. Actively maintained and updated with each new Zig release.

> **Two modules, one library**: Raw TCP/UDP sockets + WebSocket protocol in a single importable package.

**Developed by [QUANTUM ENCODING LTD](https://quantumencoding.io)**
Contact: [info@quantumencoding.io](mailto:info@quantumencoding.io)

> Currently tested against Zig `0.16.0-dev.2565+`
>
> Part of [quantum-zig-forge](https://github.com/quantum-encoding/quantum-zig-forge) -- our main development monorepo for all Zig programs and libraries.

---

## Features

### TCP Module (`tcp`)

- Cross-platform socket abstraction (Linux, macOS, BSD)
- TCP socket creation (blocking and non-blocking)
- Connect via IP parts or string address
- Send/receive with non-blocking variants
- Socket options: `TCP_NODELAY`, receive timeout, non-blocking mode
- Platform-specific syscall wrappers (no `std.posix` dependency)

### WebSocket Module (`websocket` + `ws_client`)

- RFC 6455 compliant frame parsing and building
- All opcodes: text, binary, ping, pong, close, continuation
- Frame masking/unmasking (client-to-server requirement)
- Message fragmentation and reassembly
- Handshake validation (SHA1 + Base64)
- Close codes with reason strings
- Connection state machine
- WebSocket client with TLS support via `std.Io.Threaded`

---

## Quick Start

### Installation

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .zig_socket = .{
        .url = "https://github.com/quantum-encoding/quantum-zig-forge/archive/refs/heads/master.tar.gz",
        .hash = "YOUR_HASH_HERE",
    },
},
```

Then in your `build.zig`:

```zig
const zig_socket = b.dependency("zig_socket", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zig-socket", zig_socket.module("zig-socket"));
```

### TCP Usage

```zig
const socket = @import("zig-socket");

// Create a TCP socket
const fd = try socket.createTcpSocket();
defer socket.close(fd);

// Set options
try socket.setNoDelay(fd, true);
try socket.setRecvTimeout(fd, 5000); // 5 seconds

// Connect
try socket.connect(fd, .{ 93, 184, 216, 34 }, 80);

// Send HTTP request
const sent = try socket.send(fd, "GET / HTTP/1.0\r\nHost: example.com\r\n\r\n");

// Receive response
var buf: [4096]u8 = undefined;
const n = try socket.recv(fd, &buf);
```

### WebSocket Usage

```zig
const socket = @import("zig-socket");

// Parse and build frames
var frame = try socket.Frame.init(allocator, true, .text, "Hello!");
defer frame.deinit(allocator);

const bytes = try frame.toBytes(allocator);
defer allocator.free(bytes);

// Decode received frames
const result = try socket.Frame.fromBytes(allocator, raw_bytes);
defer allocator.free(result.frame.payload);

// Validate handshake
const accept = try socket.Handshake.generateAccept(allocator, client_key);
```

### WebSocket Client

```zig
const socket = @import("zig-socket");

var client = try socket.Client.init(allocator);
defer client.deinit();

try client.connect("wss://echo.websocket.org");

try client.sendText("Hello, server!");

if (try client.receive()) |*msg| {
    defer msg.deinit();
    std.debug.print("Received: {s}\n", .{msg.text()});
}

client.close();
```

---

## Namespaced Access

Both flat and namespaced imports work:

```zig
const socket = @import("zig-socket");

// Flat (convenience re-exports)
const fd = try socket.createTcpSocket();
var frame = try socket.Frame.init(allocator, true, .text, "hi");

// Namespaced (explicit module)
const fd2 = try socket.tcp.createTcpSocket();
var frame2 = try socket.websocket.Frame.init(allocator, true, .text, "hi");
var client = try socket.ws_client.Client.init(allocator);
```

---

## Building

```bash
# Run all tests
zig build test

# Build demo and benchmarks
zig build

# Run WebSocket protocol demo
zig build demo -- demo

# Run TCP socket demo
zig build demo -- tcp

# Run benchmarks
zig build bench
```

---

## API Reference

### TCP Functions

| Function | Description |
|----------|-------------|
| `createTcpSocket()` | Create a blocking TCP socket |
| `createTcpSocketNonblock()` | Create a non-blocking TCP socket |
| `close(fd)` | Close a socket |
| `connect(fd, ip_parts, port)` | Connect to IPv4 address |
| `connectFromString(fd, ip_str, port)` | Connect via IP string |
| `send(fd, buf)` | Send data |
| `recv(fd, buf)` | Receive data (blocking) |
| `recvNonblock(fd, buf)` | Receive data (non-blocking) |
| `setRecvTimeout(fd, ms)` | Set receive timeout |
| `setNoDelay(fd, enable)` | Toggle TCP_NODELAY |
| `setNonblocking(fd)` | Set non-blocking mode |

### WebSocket Types

| Type | Description |
|------|-------------|
| `Frame` | Complete WebSocket frame with payload |
| `FrameHeader` | Frame header (FIN, opcode, length, mask) |
| `Opcode` | Frame opcodes (text, binary, ping, pong, close) |
| `CloseCode` | Standard close status codes |
| `CloseFrame` | Close frame with code and reason |
| `Handshake` | RFC 6455 handshake validation |
| `Connection` | Stateful connection handler |
| `Client` | WebSocket client (TLS support) |
| `Message` | Received message wrapper |

---

## Testing

```bash
zig build test
```

Runs ~32 tests across both modules:
- 12 TCP tests (socket creation, options, IP parsing, platform detection)
- 18+ WebSocket tests (frames, handshake, fragmentation, close codes)
- 2 client URL parsing tests

---

## License

MIT License - See LICENSE file for details

```
Copyright (c) 2026 QUANTUM ENCODING LTD
Website: https://quantumencoding.io
Contact: info@quantumencoding.io
```

---

Built for the Zig community by QUANTUM ENCODING LTD
