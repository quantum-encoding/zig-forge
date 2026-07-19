# jesternet-server

The Zig backend for jesternet. Speaks the same contract as the
TypeScript reference at `/Users/director/work/websites/jesternet-astro`,
verified by the conformance suite at `contract-tests/` in that repo.

## Status

Mid-scaffold. **Landed** (tasks #60–#62): the HTTP shell + accept loop,
the router, the fail-closed auth pipeline + token parsing, the two-path
WAL (durable-before-ack / batched), the store (in-memory rows +
versioned field-wise WAL serialization + crash recovery), the events
log with durable `Last-Event-ID` replay, the SSE writer primitive, and
the two live authenticated endpoints (`GET /api/notifications/recent`,
`POST /api/notifications/seen`).

**Not yet landed:** Layer A (source-adapter shim), Layer B (git
smart-HTTP), PRs, the SSE *stream* endpoint, and the commit-diff
endpoint all return `501` stubs. The git-correctness wrappers over
`zigit` (the `src/git/` tree below) and the `source`/`smart_http`/`prs`
handlers are **planned, not present** — no source file imports `zigit`
yet. These are marked *(planned)* in the Layout tree.

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
├── git/              (planned) Thin wrappers over zigit — NOT PRESENT YET:
│   ├── objects.zig     byte-exact encoder (anchored to git mktree)
│   ├── pack.zig        parser + writer, OFS_DELTA, deltify cache
│   ├── refs.zig        decideRefUpdate state machine
│   ├── merge.zig       3-way merge with fabrication-refusal
│   ├── blame.zig
│   └── diff.zig
└── handlers/
    ├── source.zig         (planned) Layer A — POST /api/source/{method}
    ├── smart_http.zig     (planned) Layer B — info/refs, upload/receive-pack
    ├── prs.zig            (planned) Layer C — PRs (open/close/reopen/comment/merge)
    ├── notifications.zig  Layer C — recent + seen live; stream (SSE) is a 501 stub
    ├── settings.zig       Layer C — PATCH /api/repos/.../settings (401: session-only)
    ├── tokens.zig         Layer C — token CRUD (401: session-only)
    └── iso_timestamp.zig  toISOString() clone for event `at` fields
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
