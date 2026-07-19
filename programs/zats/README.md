# zats

A NATS-compatible message broker and client library written in Zig.

Implements the core [NATS protocol](https://docs.nats.io/reference/reference-protocols/nats-protocol) over TCP: publish/subscribe messaging with subject-based routing, wildcard matching, queue groups, request/reply, authentication, headers (HPUB/HMSG), and a single-node **JetStream** implementation (streams, consumers, persistence).

## Features

- **Full NATS text protocol** — INFO, CONNECT, PUB, SUB, UNSUB, MSG, HPUB, HMSG, PING/PONG, +OK/-ERR
- **Message headers** — NATS/1.0 header frames (HPUB / HMSG)
- **Subject wildcards** — `*` (single token) and `>` (full wildcard)
- **Queue groups** — round-robin delivery across group members
- **Request/reply** — inbox pattern with timeout
- **Backpressure** — slow consumer detection and disconnection
- **Authentication** — token and user/password (constant-time secret comparison)
- **JetStream** — streams, pull + push consumers, dedup, retention, memory or file/WAL storage, and a `$JS.API.*` JSON admin surface
- **Dual subscription model** — callback-based and channel-based (bounded queue)
- **Cross-platform** — macOS and Linux (poll-based I/O)
- **Zero-allocation protocol parsing** — only payloads are copied

## Building

```bash
zig build           # Build all binaries
zig build test      # Run the test suite (~164 tests)
```

Requires Zig 0.16+ (the code uses Zig 0.16 std APIs — `std.Io.Writer`, `std.json.Stringify`, `std.process.Init`).

## CLI Tools

### zats-server

```bash
zig build run-server -- --port 4222 --name myserver
zig build run-server -- --token s3cret         # with auth
zig build run-server -- --jetstream --store-dir ./data   # JetStream with file storage
```

Options:
- `--port PORT` — Listen port (default: 4222)
- `--name NAME` — Server name (default: zats)
- `--token TOKEN` — Require auth token
- `--jetstream`, `-js` — Enable JetStream (streams/consumers/persistence)
- `--store-dir DIR` — JetStream file-store directory (memory store if omitted)

### zats-pub

```bash
zig build run-pub -- hello "Hello, World!"
zig build run-pub -- -s 192.168.1.10:4222 events.login "user=alice"
```

### zats-sub

```bash
zig build run-sub -- hello
zig build run-sub -- "events.>"              # wildcard subscribe
zig build run-sub -- -s 192.168.1.10:4222 orders
```

## Library API

Import as a Zig module:

```zig
const zats = @import("zats");
```

### Client

```zig
var client = try zats.NatsClient.init(allocator, .{
    .host = "127.0.0.1",
    .port = 4222,
    .auth_token = "s3cret",  // optional
});
defer client.deinit();
try client.connect();

// Publish
try client.publish("events.login", "alice");

// Subscribe with channel (bounded queue)
const ch = try client.subscribeChannel("events.>", 1024);
while (client.connected) {
    try client.poll();
    while (ch.next()) |msg_val| {
        var msg = msg_val;
        defer msg.deinit();
        // process msg.subject, msg.payload
    }
}

// Subscribe with callback
_ = try client.subscribe("events.login", myHandler);

// Request/reply (5 second timeout)
var reply = try client.request("service.echo", "ping", 5000);
defer reply.deinit();

client.close();
```

### Server

```zig
var server = try zats.NatsServer.init(allocator, .{
    .port = 4222,
    .max_payload = 1024 * 1024,
    .auth_token = "s3cret",
});
defer server.deinit();
try server.listen();
try server.run();  // blocks until server.stop()
```

## Architecture

```
protocol.zig   — NATS wire protocol parser + encoder
connection.zig — Per-client state machine, recv buffer, send queue, backpressure
trie.zig       — Subject trie with wildcard matching (pure data structure)
router.zig     — Subscription lifecycle, queue groups, message routing
server.zig     — TCP server, event loop, client management
client.zig     — TCP client, handshake, pub/sub/request
lib.zig        — Module root, re-exports
```

### Subject Trie

O(k) lookup where k = number of dot-separated tokens. Supports:
- `foo.bar` — exact match
- `foo.*` — matches `foo.bar` but not `foo.bar.baz`
- `foo.>` — matches `foo.bar`, `foo.bar.baz`, etc.

### Backpressure

Each connection tracks `pending_bytes` against a configurable `max_pending_bytes` limit (default 64 MB). Connections exceeding the limit are disconnected as slow consumers.

## Compatibility

Standard NATS clients (Go, Rust, JavaScript, etc.) can connect to zats-server. The protocol implementation covers the core NATS text protocol, headers, and a single-node JetStream surface. Wire-level compatibility is anchored by `src/protocol_anchors.zig`, whose frames are copied byte-for-byte (including the spec's own HPUB/HMSG header/total byte counts) from the [published NATS protocol spec](https://docs.nats.io/reference/reference-protocols/nats-protocol).

Not implemented: TLS, clustering (single-node only).

## License

MIT
