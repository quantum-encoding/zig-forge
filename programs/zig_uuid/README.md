# zig_uuid

A small Zig 0.16 library and CLI for generating and parsing RFC 4122 UUIDs. It supports version 1 (time-based), version 3 (MD5 name-based), version 4 (random), version 5 (SHA-1 name-based), and version 7 (Unix-timestamp, sortable), plus parsing, formatting (lowercase, uppercase, and URN), and version/variant inspection.

## Library

The `uuid` module (`src/uuid.zig`) exposes the `UUID` struct and generator functions:

```zig
const uuid = @import("uuid");

const id = uuid.v4();          // random
const sortable = uuid.v7();    // timestamp-based, lexically sortable
const timed = uuid.v1();       // time-based (random node)
const named = uuid.v5(uuid.namespace_dns, "example.com"); // SHA-1 name-based

const parsed = try uuid.parse("6ba7b810-9dad-11d1-80b4-00c04fd430c8");
```

Additional helpers include `v1WithNode`, `v3`, `v7WithTimestamp`, batch generators (`v4Batch`, `v7Batch`), the `namespace_dns` / `namespace_url` / `namespace_oid` / `namespace_x500` constants, and per-UUID methods (`toString`, `toStringUpper`, `toUrn`, `getVersion`, `getVariant`, `getTimestamp`, `compare`, `eql`, `hash`, `isNil`).

## CLI

The `zuuid` tool (`src/main.zig`) generates and inspects UUIDs:

```
zuuid              Generate a v4 UUID
zuuid v1           Generate a v1 UUID (time-based)
zuuid v7           Generate a v7 UUID (timestamp, sortable)
zuuid -n 10 v7     Generate 10 v7 UUIDs
zuuid parse <uuid> Parse and inspect a UUID
```

## Build

```
zig build            # build the static library and CLI
zig build run -- v7  # run the CLI
zig build test       # run unit tests
zig build bench      # run benchmarks
```
