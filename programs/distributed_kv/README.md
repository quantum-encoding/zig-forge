# distributed_kv

A Zig library and toolset for a Raft-based distributed key-value store. It provides
the building blocks for consensus (`raft.zig`), a write-ahead log with crash recovery
(`wal.zig`), a key-value state machine with TTL, delete, and compare-and-swap
operations (`kv.zig`), an RPC server/client transport for cluster communication
(`rpc.zig`), and a client library with connection pooling (`client.zig`).

## Status

**Single-node (N=1) is functional; multi-node consensus is a work in progress and
not yet complete.** The following pieces are still unimplemented, so the store does
not yet operate as a true multi-node cluster:

- `AppendEntries` log entries are not yet serialized on the wire.
- RPC responses are not routed back into the consensus state machine.
- Server-side `client_req` dispatch is not implemented.

Treat this as an in-progress implementation, not a production-ready store.

## Platform

The `DistributedNode` runtime (tick loop, sleep) calls Linux syscalls directly via
`std.os.linux`, so running the server node is **Linux-only**. The library modules and
their unit tests build on other platforms, but the running server targets Linux.

## Build

Requires Zig 0.16.0.

```
zig build          # build the static library, kv-server, and kv-client
zig build test     # run the unit tests
zig build run      # run the KV server
zig build client   # run the KV client CLI
```

`zig build` produces:

- `distributed_kv` — a static library exposing the `raft`, `wal`, `kv`, `rpc`, and
  `client` modules plus the `DistributedNode` node wrapper (see `src/lib.zig`).
- `kv-server` — the server executable (`src/server.zig`).
- `kv-client` — the client CLI (`src/client_cli.zig`).

## Layout

| File | Purpose |
|---|---|
| `src/lib.zig` | Library root; re-exports modules and defines `DistributedNode`. |
| `src/raft.zig` | Raft consensus: leader election, log replication, terms. |
| `src/wal.zig` | Write-ahead log: segmented persistence and recovery. |
| `src/kv.zig` | Key-value state machine: set/delete/CAS, TTL expiry. |
| `src/rpc.zig` | RPC server/client and transport for cluster communication. |
| `src/client.zig` | Client library with connection pooling and failover. |
| `src/server.zig` | `kv-server` entry point. |
| `src/client_cli.zig` | `kv-client` CLI entry point. |
