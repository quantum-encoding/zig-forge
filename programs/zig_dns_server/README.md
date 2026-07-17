# zig_dns_server

An authoritative DNS server written in Zig that loads RFC 1035 zone files and answers UDP and TCP queries, with a reusable library (`src/lib.zig`) exposing the wire-protocol parser/builder, zone store, DNSSEC primitives, and DoH/DoT transports.

## What it does

- **Wire protocol** (`src/protocol/`): parses and builds DNS messages — header, question, and resource-record encoding/decoding with name compression (RFC 1035).
- **Zone management** (`src/zones/`): parses RFC 1035 master zone files (`$ORIGIN`, `$TTL`, SOA, NS, A, MX, etc.) into an in-memory `ZoneStore` and answers authoritative queries from it.
- **Server** (`src/server/`): UDP listener plus an optional TCP listener, with an in-process response cache and a per-source rate limiter.
- **DNSSEC** (`src/security/`): zone-signing and validation scaffolding. Ed25519 signing is implemented on top of `std.crypto`; the ECDSA (P-256/P-384) paths are placeholders and not production-ready.
- **DoH** (`src/transport/doh.zig`): RFC 8484 request parsing (GET/POST, `application/dns-message` wire format, base64url `dns=` parameter).
- **DoT** (`src/transport/dot.zig`): DNS-over-TLS framing. The TLS handshake here is a hand-rolled placeholder and is not a complete/verified TLS implementation — treat DoT as experimental.

The CLI binary is named `dns-server`.

## Build and run

The pinned toolchain is Zig 0.16.0.

```sh
zig build              # build the dns-server executable
zig build run -- -h    # show CLI help
zig build test         # run the unit tests
```

Run with one or more zone files:

```sh
dns-server -z /etc/dns/example.com.zone
dns-server -b 127.0.0.1 -p 5353 -z local.zone
dns-server --dot --dnssec -z secure.example.zone
```

### CLI options

```
-c, --config <file>     Load configuration from file
-z, --zone <file>       Load a zone file (may be repeated)
-p, --port <port>       DNS port (default: 53)
-b, --bind <address>    Bind address (default: 0.0.0.0)
--tcp                   Enable TCP listener (on by default)
--doh                   Enable DNS over HTTPS
--dot                   Enable DNS over TLS
--dnssec                Enable DNSSEC signing
-v, --verbose           Verbose output
-h, --help              Show help
```

If no zones are loaded the server logs a warning and responds REFUSED to all queries.

## Library usage

```zig
const dns = @import("dns");

var zones = dns.ZoneStore.init(allocator);
defer zones.deinit();
_ = try zones.loadFromFile("example.com.zone");

var server = dns.Server.init(allocator, &zones, .{
    .listen_addr = "0.0.0.0",
    .port = 53,
});
defer server.deinit();
try server.start();
try server.run();
```

## Status / limitations

- ECDSA DNSSEC signing (`ecdsap256sha256`, `ecdsap384sha384`) is a placeholder — only Ed25519 signing is real.
- DoT's TLS handshake is a placeholder and does not perform certificate verification; it is not suitable for production.
- The zone parser and query path are not backed by external conformance vectors and are not audited for money- or auth-critical use.

## Tests

`zig build test` runs the unit tests in `src/lib.zig`, covering name parsing, header serialization, and query parse/build round-trips, and pulls in the sub-module tests via `refAllDecls`-style imports.
