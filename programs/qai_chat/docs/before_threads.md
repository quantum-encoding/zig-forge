# Before-threads audit checklist

Status: living document. Things that are *fine today* under the
single-threaded substrate but turn into landmines the moment the
bounded worker pool from `agent_fanout_v1.md` §7 lands. Each item
either has an owner doc that already specifies the fix, or is a new
finding that needs one. Audit this list before the threaded PR
ships; don't audit it *after* and discover the bugs through
production incidents.

The category these all share: **file-scoped or process-scoped
mutable state that one agent can touch today and N agents will race
on tomorrow.** Threading turns "no current path triggers it" from a
defensible posture into a debugging session.

## File-scoped mutable caches

### `pricing.entries` / `pricing.entries_arena`

- **Location:** `src/pricing.zig:77-78` — file-scoped `?[]Entry` and
  `?std.heap.ArenaAllocator`.
- **Today:** populated lazily on first `lookup()` call, lives for
  the process lifetime, reclaimed at exit. Single-allocator
  ownership — whichever allocator first calls `lookup` owns the
  arena forever.
- **Under threads:** N concurrent agents each call `lookup()`. The
  `if (entries) |e| return e;` fast-path is a race against any
  other thread mid-`ensureLoaded`. Worse: each agent may be using a
  per-agent allocator (per the per-agent partitioning principles
  from fanout v1 §5), and `entries_arena` ends up tied to whichever
  thread won the load race — a use-after-free waiting on a thread
  that exits first.
- **Fix before threads:** options in increasing aggressiveness —
  (a) wrap the lazy init in a `std.once.Once`-style guard *and*
  switch the cache allocator to a long-lived process allocator
  passed in once at startup, not the per-call gpa;
  (b) precompute the table eagerly at startup (10s of entries,
  parsing is microseconds, cache the result in a comptime-friendly
  static);
  (c) eliminate the cache and reparse on every lookup (`csv_data` is
  ~40 lines, parse cost is trivial vs. an LLM round-trip).
  Recommendation: (b) — simplest, removes the mutable-state problem
  entirely, makes `lookup` a pure function.
- **Temporary mitigation in place:** `main.zig` calls
  `defer agent.deinitPricingCache()` at the top of `main()` so
  Debug builds don't print leak diagnostics on every exit. This is
  a band-aid — it only fires on graceful exit and only matters
  because Debug uses a leak-tracking allocator. The threaded PR
  still needs the structural fix (b) above, because the band-aid
  doesn't address the file-scoped-state-shared-across-threads
  class.

## State already flagged by other docs

### `agent.UsageStats` — sharing across agents

- **Owner doc:** `agent_fanout_v1.md` §5 ("Cost is owned at the
  leaf, aggregated up the tree").
- **Status:** principle locked. Each agent owns its own
  `UsageStats`; the orchestrator aggregates at fan-in. No mutex on
  a shared instance.
- **Audit before threads:** verify the orchestrator never passes a
  parent's `*UsageStats` into a child's `RunArgs`. Grep for shared
  pointer aliasing.

### `agent.Approvals` — sharing across agents

- **Owner doc:** `agent_fanout_v1.md` §0 (approval policy, Option A
  recommended).
- **Status:** principle locked. Sub-agents inherit a **read-only
  snapshot** of the parent's approval set at spawn time. The
  `rememberPath`/`rememberCommand`/`rememberBashRule` mutators
  (`agent.zig:113-129`) are never called from child context.
- **Audit before threads:** verify child agents are passed
  approvals via a snapshot-by-value, not a pointer. The current
  `RunArgs.approvals: *Approvals` shape will need a const-only
  flavor for children, or the orchestrator constructs per-child
  approvals as copies.

### `HttpClient.last_sse_error_body` — single-slot side channel

- **Owner doc:** `errors_and_observability_v1.md` §2, §9 (deliverable
  #2).
- **Status:** retirement specified. Replaced by structured
  `AgentError.body_snippet` owned per-error.
- **Audit before threads:** the retirement PR must land *before*
  threads (because per-client survival doesn't generalize once
  errors flow through an aggregator queue that may interleave).
  Cross-check: errors v1 PR #2 in the sequencing chain.

### `ClientPool` allocator requirement

- **Owner doc:** `agent_fanout_v1.md` §7 (one-line note in the
  cancel section, search "thread-safe").
- **Status:** noted but not enforced.
- **Audit before threads:** the allocator passed to
  `ClientPool.createClient` must itself be thread-safe
  (`std.heap.smp_allocator` or `GeneralPurposeAllocator{}`, not an
  arena). Add an assertion at orchestrator setup or a doc-comment
  on the pool API.

### `http_sentinel` `std.debug.print` scattering

- **Owner doc:** `errors_and_observability_v1.md` §7.
- **Status:** posture decided — qai_chat redirects stderr at TUI
  startup; library prints land in a file/ring buffer, not on the
  screen.
- **Audit before threads:** confirm the stderr redirect happens
  *before* any worker thread is spawned. A worker that starts
  writing `std.debug.print` output to the original stderr fd
  before the redirect lands will scribble across the screen even
  once the redirect installs (TLS handshake on a fresh `HttpClient`
  is the likely culprit).

## How to use this list

This is a pre-flight checklist for the threaded PR, not a backlog.
Each item should be either *resolved* (the fix landed) or
*explicitly waived* (we decided it's fine for v1 with a stated
reason) before any worker thread spawns. Adding new items here is
encouraged — every file-scoped `var` in code touched between now
and threads should get evaluated against this same question: *what
happens when N agents hit this concurrently?*

When the threaded PR is in review, this doc is the checklist its
PR description points at. Each item ships green or doesn't ship.

## Discovery procedure for the unknown ones

The list above catalogs *known* file-scoped state. The dangerous
one is the `var` nobody's flagged yet — `pricing.entries` itself
was found by accident (wiring the test step lit up its leak under
`std.testing.allocator`), not by audit. Don't rely on accidents.

Before the threaded PR, run the mechanical sweep:

```sh
# qai_chat — every module-scope mutable declaration
grep -rnE '^var |^pub var ' programs/qai_chat/src/

# http_sentinel hot paths the agent loop touches (AI clients,
# HTTP client, retry engine, pool layer)
grep -rnE '^var |^pub var ' \
    programs/http_sentinel/src/ai/ \
    programs/http_sentinel/src/http_client.zig \
    programs/http_sentinel/src/retry/ \
    programs/http_sentinel/src/pool/
```

Evaluate each hit against the N-agents question. Most module-scope
`var`s in Zig are either `const`-by-convention misnamed (no
mutation) or local-test scaffolding (no production access). The
remainder is the audit target. Add anything new to the list above
with the same shape: location, today's behavior, under-threads
hazard, fix-before-threads recommendation.

This list is the known set; the grep is what finds what we forgot.
