# jesternet-server

The Zig backend for jesternet. Speaks the same contract as the
TypeScript reference at `/Users/director/work/websites/jesternet-astro`,
verified by the conformance suite at `contract-tests/` in that repo.

## Status

Scaffold only (task #59). The HTTP shell + auth pipeline + store/WAL
land in tasks #60–#62; the git-correctness modules (imported from
zigit) land in #63 (blocked on the conformance suite going green
against the Workers reference); handlers tie the layers together
in #64.

See `CONTRACT.md` and `CONFORMANCE.md` in the jesternet-astro repo
for the contract this server implements.

## Build

```
zig build         # exe at zig-out/bin/jesternet-server
zig build run     # build + run with current scaffold output
zig build test    # run module tests
```

## Layout

```
src/
├── main.zig          accept loop, ConnCtx, graceful shutdown
│                       (lifted from zig_ai_server; see audit's
│                        caveat-3 — defaults re-examined against
│                        jesternet's contract, not inherited).
├── router.zig        path-dispatch, Response struct, SSE handled flag.
├── stream.zig        SSE chunked-response writer (lifted as-is).
├── auth/
│   ├── pipeline.zig  Bearer-PAT-or-session fail-closed gate.
│   └── tokens.zig    jnpat_<id>_<hex> + per-repo (owner,name) scope.
├── store/
│   ├── store.zig     SpinLock + in-memory + WAL pattern from AI server.
│   │                 Rows: refs, pull_requests, repos, sessions, events.
│   ├── wal.zig       Two append paths: durable-before-ack for ref
│   │                 updates + commit.pushed events; batched fsync
│   │                 for audit logs + metrics. See audit caveat-2.
│   └── types.zig     Row types matching scripts/schema.sql.
├── events.zig        Events table mounted on WAL primitive.
│                       insertEvent → durable seq;
│                       replayFrom(since) → SSE handler input.
├── git/              Thin wrappers over zigit:
│   ├── objects.zig     byte-exact encoder (anchored to git mktree)
│   ├── pack.zig        parser + writer, OFS_DELTA, deltify cache
│   ├── refs.zig        decideRefUpdate state machine
│   ├── merge.zig       3-way merge with fabrication-refusal
│   ├── blame.zig
│   └── diff.zig
└── handlers/
    ├── source.zig         Layer A — POST /api/source/{method}
    ├── smart_http.zig     Layer B — info/refs, upload-pack, receive-pack
    ├── prs.zig            Layer C — PRs (open/close/reopen/comment/merge)
    ├── notifications.zig  Layer C — recent, seen, stream (SSE durable replay)
    ├── settings.zig       Layer C — PATCH /api/repos/.../settings
    └── tokens.zig         Layer C — token CRUD
```

## Audit caveats (from ZIG_PORT_AUDIT.md)

1. **Single-process atomicity.** The mutex+WAL pattern gives
   serializability *within one process*. v1 is single-process; adding
   workers later is a correctness review, not a `--workers=N` flag.

2. **fsync-before-ack on ref updates and commit.pushed events.** Ack-
   before-fsync would lose acknowledged pushes on crash AND break
   the SSE durable-replay canary under crash. Two WAL paths:
   `appendDurable` (fsync before return) for the hot durable paths,
   `appendBatched` (background fsync) for audit logs + metrics.

3. **The shell carries the AI server's contract, not jesternet's.**
   Lift main.zig / router.zig / auth_pipeline.zig structure;
   re-examine every header, default, error shape against
   `CONTRACT.md`. CORS, JSON content-type, the `{error, message}`
   body shape (vs the AI server's `{error, kind}`) — all checked
   at graft time, not inherited.
