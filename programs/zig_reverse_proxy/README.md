# zig_reverse_proxy

An HTTP/1.1 reverse proxy library and CLI (`edge-proxy`) written in Zig 0.16, providing request routing, backend connection pooling, load balancing, and a small middleware chain.

## What it does

- **HTTP/1.1 parsing** (`src/http/parser.zig`) — request/response parsing and a response builder.
- **Routing** (`src/proxy/router.zig`) — match requests by path (prefix/exact/pattern), host, and method to a backend pool, static response, redirect, or edge handler.
- **Backend pools** (`src/proxy/backend.zig`) — grouped upstream backends with connection pooling and health-status tracking.
- **Load balancing** (`src/proxy/loadbalancer.zig`) — strategies including round-robin.
- **Middleware** (`src/middleware/chain.zig`) — a composable chain with logging, CORS, rate-limit, and security-headers middleware.
- **WASM edge scaffold** (`src/wasm/edge.zig`) — request/response bindings and a module cache for edge functions. **Note:** the WASM host does not yet execute modules — the handler currently returns a default/placeholder response and the integration with a WASM runtime is a documented `TODO`.

## Build

The only supported toolchain is Zig 0.16.0.

```sh
zig build            # build the edge-proxy executable
zig build run -- --config proxy.json
zig build test       # run the library unit tests
```

## Status

This is an in-tree, unaudited library. Per the repository `CLAUDE.md`, treat it as
quarantined for money-/auth-touching consumers until it appears on the canonical
promoted list. Known open issues (see the upgrade roadmap) include body-truncation
on large responses, missing `Content-Length`/`Transfer-Encoding` conflict rejection
(request-smuggling surface), and connection-pool lifetime bugs.
