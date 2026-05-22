# Agent fan-out v1 — design note

Status: draft for review. Locks the protocol surface that the first
fan-out PR (synchronous `spawn_agents` tool through the existing agent
loop, fake provider, tree-printer) builds against — and pins the open
product decision (approval policy) that must land before any code does.

The thesis: when an agent fans out into N sub-agents — each its own LLM
conversation, its own context window, its own cost meter — that fan-out
is **a tool call**, not a new layer beside the agent loop. The parent
agent emits a `tool_use` for `spawn_agents`; the executor of that tool
runs N child agent loops to completion and returns one `tool_result`
whose `content` is a structured summary the parent reads. The TUI's
live pane fan-out is exactly the visual representation of that
in-progress tool-call block: when it completes, the panes collapse to
the result, like any other tool block.

This shape adds zero surface area to the agent loop in `agent.zig` —
the batch tool-execution path at `agent.zig:564-571` already collects N
tool_calls per turn, runs them, and feeds N tool_results back as one
user turn. `spawn_agents` slots into `tools.execute` as one more entry;
the parallelism hides entirely inside that one tool's executor.

This doc does not specify pane layout, the TUI's degradation rule for
large fan-outs (≤3 mini-chats vs focused-pane-plus-status-strip), or
the rendering of live tool-call blocks. Those land per-PR with their
own scoping. v1 locks the protocol; the UI extends the same contract.

---

## 0. Open question — your call

**What approval policy do backgrounded sub-agents operate under when
they want to invoke a writable tool (`write_file`, `edit_file`,
`bash`)?** This is a product decision with a security dimension. It
shouldn't be defaulted into existence by whichever code path lands
first, and it shapes everything below it.

Concretely: a research fan-out spawns six children. One of them, three
turns into its own conversation, decides it wants to run `git push
--force`. What happens?

### Option A — Frozen policy, no prompts (recommended)

Sub-agents inherit the parent's `Approvals` set at spawn time as a
**read-only snapshot**. They cannot prompt the human and they cannot
mutate the policy. Any writable tool call that isn't pre-approved
returns a synthetic `ToolResult` of `is_error=true, content="action
denied: requires human approval; sub-agents cannot prompt"`, and the
child agent has to either give up or find a different path.

Why: a fan-out's whole point is to do work *without* a human in the
loop. If backgrounded children can each queue a destructive-action
approval, the human becomes the bottleneck the fan-out was supposed to
remove, and the UX is "eight panes scream for attention." Frozen
inheritance keeps mutating power explicitly with the parent and the
human, where they were before the fan-out started.

### Option B — Serialized prompt broker

Sub-agents *can* prompt, but all writable-tool prompts route through
one orchestrator-owned UI queue. The TUI focus jumps to the requesting
pane; the human sees `[research-3] wants to run: git push --force`;
approves or denies; the child unblocks.

Why not: every fan-out becomes interactive again. The human is now
context-switching across N children's confirmation prompts mid-task.
It's the right mechanism if Option A turns out to be too restrictive
in practice, but it's the *wrong* default.

### Option C — Sub-agents are sandboxed read-only

Sub-agents can only call read-only tools (`read_file`, `ls`, `grep`,
`get_agent_transcript`). Any writable tool — even pre-approved — is
unavailable in child context. If mutation is required, the parent
takes the action after the children return.

Why: cleanest safety story. The fan-out is research-shaped by
construction. Mirrors map-reduce conventions where mappers don't have
side effects.

Why not: too restrictive for some genuine use cases — e.g. "edit these
ten files in parallel, each child handles one." That work *wants* to
be parallel and *wants* to mutate, and Option C forces it serial
through the parent.

### Recommendation

Ship Option A as v1. It preserves the fan-out's UX (no interactive
breaks), keeps mutation under human control via the parent's
pre-approved set, and degrades gracefully — when a child needs
something not pre-approved, the parent sees that in the merge payload
and can re-issue the action itself with a human prompt. Revisit if
real use cases push back. Option C is a one-line tightening of A
(reject writable tools always, not just unapproved ones) and is the
right escape hatch if "frozen approval" turns out to leak too much
authority through pre-approved bash rules.

**Everything below assumes Option A.** If you pick B or C, sections 2
and 4 change slightly — the merge payload grows a "pending_approval"
status under B, and the `spawn_agents` schema gains a sandbox flag
under C — but the rest holds.

---

## 1. `spawn_agents` tool schema

Lives in `tools.zig` alongside `read_file`, `bash`, etc. Read-only
declaration; the *children* may invoke writable tools per the approval
policy above, but `spawn_agents` itself is not a side-effecting tool
the user needs to approve. (Approval applies to actions; spawning a
worker is not an action.)

```jsonc
{
  "name": "spawn_agents",
  "description":
    "Run N independent sub-agent conversations in parallel and collect their final answers. Use this to fan out research, code reads, or any task that decomposes into independent subtasks. Each child runs its own conversation with the same toolset (read-only by default; see approval policy). Returns a structured summary per child — use get_agent_transcript(agent_id) to inspect a child's full conversation if you need more than the summary.",
  "input_schema": {
    "type": "object",
    "properties": {
      "tasks": {
        "type": "array",
        "minItems": 1,
        "maxItems": 8,
        "items": {
          "type": "object",
          "properties": {
            "label":  { "type": "string", "description": "Short identifier for this child (e.g. 'research-pricing'). Surfaced in the pane header and the merge payload." },
            "prompt": { "type": "string", "description": "The user-prompt the child receives as its first turn." },
            "system_prompt": { "type": "string", "description": "Optional system prompt override. Defaults to the parent's." }
          },
          "required": ["label", "prompt"]
        }
      },
      "max_turns_per_child": {
        "type": "integer",
        "default": 8,
        "description": "Hard cap on agent-loop iterations per child. Children that don't terminate by then return with status 'turn_limit'."
      }
    },
    "required": ["tasks"]
  }
}
```

`maxItems: 8` is a deliberate ceiling for v1 — large enough for real
fan-outs, small enough that the TUI's degradation regime (≤3 full
panes, >3 focused-pane-plus-strip) covers every case. The bounded
worker pool's `max_concurrent_agents` should match this; a larger
ceiling without a wider pool just queues, defeating the parallelism.

`max_turns_per_child` defaults below `MAX_AGENT_TURNS` (currently 12,
`agent.zig:18`) because children that fan out further compound; an
8-turn cap per level still allows substantial recursive work without
cost explosions. One caveat to remember when tuning this: a child that
itself fans out spends turns on the `spawn_agents` round-trip (one turn
emits the tool_use, one turn consumes the tool_result), so a child with
a budget of 8 turns that fans out once has six effective working turns,
not eight. If recursive children feel starved in testing, this is the
knob.

---

## 2. `AgentEvent` topology stream

The orchestrator owns this stream. Child agent loops emit events
through a callback supplied at spawn time; **the events go into a
single MPSC queue with exactly one consumer — the aggregation thread
(see §7).** The aggregation thread is the only piece of code that
touches child-lifecycle state; the renderer, the parent worker, and
any other interested party receive *handoffs* from the aggregator, not
direct reads off this queue.

```zig
pub const AgentId = u64;

pub const AgentEvent = union(enum) {
    /// A new sub-agent has been registered with the orchestrator. Emitted
    /// immediately on spawn, before the child's first turn begins.
    spawned: struct {
        id: AgentId,
        parent_id: ?AgentId,          // null only for the root agent
        label: []const u8,             // from the `label` field of the spawn task
        depth: u8,                     // 0 = root, 1 = parent-of-children, etc.
    },

    /// A stream event from this child's current turn. The inner StreamEvent
    /// is the existing per-token / per-block event the MessageLog already
    /// knows how to apply (hs.ai.common.StreamEvent). The layout layer routes
    /// this to the right pane by (id, turn_seq).
    progress: struct {
        id: AgentId,
        turn_seq: u32,
        inner: hs.ai.common.StreamEvent,
    },

    /// One turn completed for this child. Usage is per-turn; the orchestrator
    /// rolls it up into the child's running total.
    turn_done: struct {
        id: AgentId,
        turn_seq: u32,
        usage: TurnUsage,
    },

    /// This child has terminated. `reason` discriminates how — natural stop,
    /// cancelled by user, killed by parent cancel, turn-limit hit, or error.
    /// `summary` is the child's contribution to the merge payload (see §4).
    done: struct {
        id: AgentId,
        reason: enum { ok, cancelled, turn_limit, error_ },
        total_usage: TurnUsage,
        summary: AgentSummary,         // owned until the aggregator drains; see below
    },
};

pub const TurnUsage = struct {
    input_tokens: u32,
    output_tokens: u32,
    cost_usd: f64,
};
```

Two notes that affect the implementation:

The `progress` event wraps the existing `hs.ai.common.StreamEvent` —
the keying contract from MessageLog v1 (`(turn_seq, block_index)`)
extends cleanly to `(agent_id, turn_seq, block_index)`. The layout
layer's job reduces to "route events to the right pane's MessageLog
via its existing `apply(event, turn_seq)` contract." No new rendering
primitives.

The `done` event carries the `summary` directly. The aggregation
thread drains the event, copies what each downstream party needs
(into the child's registry entry, into the parent's pending merge
payload, and as a separately-allocated `RenderEvent` forwarded to the
renderer), then frees the original. There is no shared-lifetime
puzzle, no refcounting, no broadcast queue — one drainer, explicit
handoffs. This is the single-ownership principle that §7 and §8 build
on; the layout manager stays stateless and testable with the
golden-frame harness because all it ever sees is the post-aggregation
`RenderEvent` stream.

---

## 3. Merge payload — agent-context channel

When `spawn_agents` returns, its `ToolResult.content` is a JSON array,
one entry per child, in the order children appeared in `tasks`. This
is the **only** thing the parent LLM sees; transcripts stay outside
its context window unless it explicitly pulls one via §4.

```jsonc
[
  {
    "agent_id": 17,
    "label": "research-pricing",
    "status": "ok",                  // ok | cancelled | turn_limit | error
    "message": "<final assistant text from the child>",
    "usage": { "input_tokens": 1240, "output_tokens": 380, "cost_usd": 0.0034 },
    "tool_calls_made": 4              // count only; details require get_agent_transcript
  },
  {
    "agent_id": 18,
    "label": "research-margins",
    "status": "error",
    "message": "child terminated: ApiRequestFailed",
    "usage": { "input_tokens": 240, "output_tokens": 0, "cost_usd": 0.0004 },
    "tool_calls_made": 0
  }
]
```

Three principles this payload locks:

**Bounded by construction.** No field grows with the child's transcript
length except `message`, which is the child's final assistant text
(typically a paragraph). Even a fan-out of eight children each running
twelve turns produces a merge payload measured in low kilobytes — not
the tens-of-kilobytes a transcript inline would produce.

**Partial success is first-class.** A failed or cancelled child does
not poison the fan-out; the parent gets every successful child's
result plus a structured error for the failures, and decides what to
do. This is the map-reduce idiom — the alternative ("one fails, all
fail") is hostile to research-shaped work.

**`is_error` on the outer `ToolResult` is true iff no child returned
a usable result.** Concretely: `is_error=true` when every entry has
status `error` *or* `cancelled` — both shapes mean "the parent asked
for work and got nothing it can build on." `cancelled` is the human's
choice, not a failure of the tool, but from the parent LLM's
reasoning perspective an all-cancelled fan-out and an all-errored
fan-out are the same situation, and you do not want the parent
confidently building on empty results because the human's cancellation
was technically not an error. Mixed outcomes (any single success)
return `is_error=false` with per-child status in the payload — the
*spawn_agents call itself* succeeded; some children just didn't
contribute. When `is_error=true`, `content` is still the array as
described, but with a leading explanatory `message` field on the
outer object — e.g. "all children cancelled by human" or "all children
errored: see per-child status."

**`turn_limit` is degraded-useful, not failed.** A child that hits its
turn cap still emits `done` with `reason: turn_limit` and a `message`
field set to its last assistant text. The parent reads that and may
choose to follow up, retry with a higher cap, or accept the partial
work. A `turn_limit`-only fan-out (every child hit the cap, none
errored or cancelled) does *not* set `is_error=true` — the parent got
back partial answers from every child, which is usable degraded work,
not nothing.

---

## 4. `get_agent_transcript` — escape hatch

Separate tool, not a bigger merge payload:

```jsonc
{
  "name": "get_agent_transcript",
  "description":
    "Fetch the full conversation transcript of a previously-spawned sub-agent by its agent_id. Use sparingly — child transcripts can be large and reading one consumes context window proportional to its length. Prefer the summary in the spawn_agents result; only fetch a transcript when the summary is insufficient for your next decision.",
  "input_schema": {
    "type": "object",
    "properties": {
      "agent_id": { "type": "integer" },
      "include_tool_calls": { "type": "boolean", "default": true }
    },
    "required": ["agent_id"]
  }
}
```

Why a separate tool, not an option on `spawn_agents`:

Every time a transcript ends up in the parent's context, it's a
deliberate, visible decision the parent agent made — not an implicit
side effect of fanning out. The cost shows up as a discrete tool call
the human can see and reason about. Conflating it into the merge would
make the expensive path the default path, the same trap the original
MessageLog v1 doc avoided around `message_stop`.

The aggregation thread keeps each completed child's transcript in a
process-local registry keyed by `agent_id`. **Lifetime is tree-scoped,
not conversation-scoped:** a child's transcript is fetchable only
while its direct parent's `spawn_agents` tool-call is still open. The
moment the parent's `ToolResult` is built and returned to the parent's
agent loop, that parent's children — and their grandchildren, and so
on down the subtree — are evicted from the registry as a single
sweep. `get_agent_transcript` against an evicted id returns an error
the calling agent has to handle.

This rule is cleaner than a flat size cap and falls out of the
structure: a transcript is inspectable for exactly as long as its
visual pane could be, which matches the "panes collapse on done"
framing from the introduction. It also bounds memory naturally by tree depth
× per-level fan-out × per-child transcript size, rather than letting
the registry grow with conversation length. A 4-deep × 8-wide tree
caps the live transcript count at the sum of a geometric series, not
unbounded conversation history.

An 8 MB total-registry cap remains as a backstop for pathological
cases — a single child producing an enormous transcript — at which
point the oldest entry within the live tree is evicted with the
caveat that this should essentially never fire under realistic
workloads. If it does fire repeatedly, that's a signal we need a
per-child transcript size limit, not a larger global cap.

---

## 5. Cost is owned at the leaf, aggregated up the tree

Each agent (root included) owns its own `UsageStats`. There is no
shared `UsageStats` instance across siblings or up the parent chain.
When a child completes, the orchestrator:

  1. Includes the child's `total_usage` in the `done` event.
  2. Includes the child's `total_usage` in its entry of the
     `spawn_agents` merge payload.
  3. Adds the child's `total_usage` to the parent's running tally —
     so the parent's "[turn N: in/out · $cost]" line at
     `agent.zig:883` reflects the *subtree* total, not just the
     parent's own turn.

This is what makes "cost rolls up" actually meaningful — a fan-out's
cost line shows the human what the whole subtree cost, while the
per-child entries in the merge payload break it down. Mutex-sharing a
single `UsageStats` across children would serialize the one piece of
state you most want to see broken out per-child.

The mechanical change in `agent.zig:UsageStats`: nothing — its
existing per-(provider, model) bucketing is fine. The orchestrator
just maintains one `UsageStats` per live agent and aggregates at
fan-in. The struct stays single-threaded.

---

## 6. Recursion

A sub-agent runs the same `agent.zig` loop as the root, so it can call
`spawn_agents` itself. The tree is arbitrary-depth — this is a
feature, not a bug, and the protocol handles it without special
cases:

- **`AgentEvent.spawned`** already carries `depth` and `parent_id`;
  the layout layer can flatten with depth indication beyond some
  threshold, or nest panes, per its own degradation rule.
- **Cost roll-up** is recursive by construction — a grandchild's
  usage rolls into its parent (the child), which rolls into the root.
  Each level just adds what its children reported.
- **Merge payload** is per-level — a recursive `spawn_agents` produces
  its own merge payload that becomes the *grandchild's* `message`
  field's content as far as the root is concerned. The root never sees
  the grandchild directly; it sees the child's summary, which may
  reference the fact that the child itself fanned out.

The one hard cap: **max recursion depth = 4** for v1. A child of a
child of a child can still spawn, but a fourth-level child cannot
call `spawn_agents` — the tool returns `is_error=true, content="max
fan-out depth (4) exceeded"`. This is mostly a safety rail against
runaway combinatorial spawning; revisit if real workloads need
deeper trees.

---

## 7. Cascade cancel

The whole concurrency story collapses into one principle: **a single
aggregation thread owns all child-lifecycle state. Cancel is just
another message on the same queue as `done`.** No atomic flag is set
from any thread other than the aggregator. No bookkeeping happens off
the aggregator's serial loop. This removes the race the prior draft
gestured at — there is no race because there are no concurrent
writers to child state.

The queue's message type is a superset of `AgentEvent`:

```zig
pub const OrchestratorMessage = union(enum) {
    /// Emitted by worker threads (the agent loops).
    event: AgentEvent,

    /// Emitted by the UI thread on Ctrl+C, double-Ctrl+C, Esc, or
    /// by the aggregator itself when a parent's `spawn_agents` call
    /// is cancelled by an upstream signal (cascade).
    cancel: struct {
        /// Subtree root. The aggregator walks the live registry
        /// from this id downward and arms each descendant's stream-
        /// abort flag. `id == root` is "cancel everything."
        id: AgentId,
    },
};
```

The aggregation thread's loop is:

```text
loop {
    msg = queue.recv();
    switch (msg) {
        .event => |e| handleEvent(e),       // mutate registry, fire signals, forward to renderer
        .cancel => |c| handleCancel(c.id),  // walk registry, set abort flags
    }
}
```

Both kinds of message are processed in queue order on one thread, so
"naturally finished" and "cancellation requested" are serialized
events with a well-defined outcome:

- If `done(ok)` arrives before `cancel`: child is already removed
  from the live registry when `cancel` walks the tree. The cancel for
  that id is a no-op on a dead child. No double-accounting.
- If `cancel` arrives before `done`: the aggregator sets the child's
  abort flag. The child's worker thread sees it in its stream
  callback, aborts SSE, the agent loop emits `done(cancelled)` up,
  the aggregator processes that next.
- If both fire and we cannot tell which "actually" came first: the
  one we pulled off the queue first wins, deterministically. There is
  no ambiguity to resolve because the queue *is* the order.

Per-child state on the aggregator's side:

```zig
const LiveChild = struct {
    id: AgentId,
    parent_id: ?AgentId,
    depth: u8,
    thread: std.Thread,
    /// Set by the aggregator's `handleCancel`. Read by the child's
    /// `streamEventCb` (agent.zig:389) at the top of each event —
    /// if true, return `false` to abort the SSE loop.
    abort: std.atomic.Value(bool),
    /// Set by the aggregator when this child's `done` arrives.
    /// Fired exactly once, after the merge payload entry is built,
    /// to wake any parent waiting on its `spawn_agents` completion.
    /// See §8.
    completion: std.Thread.ResetEvent,
    /// Where the child's transcript lives until tree-scoped eviction
    /// (§4) takes it away.
    transcript: *TranscriptBuffer,
};
```

The `abort` field is the *only* atomic in the design, and it's
strictly single-writer (the aggregator) and single-reader (the
child's stream callback). That asymmetry is what lets us avoid every
other concurrency primitive — locks, mutexes, condvars on the
registry — and have a coherent story.

Three cancel scopes are now trivial to express:

- **Single-pane cancel** (focused pane, Ctrl+C): UI enqueues
  `cancel{id = focused_child}`. Aggregator arms one flag. Siblings
  untouched.
- **Subtree cancel** (parent's `spawn_agents` was cancelled, or its
  whole tree got cancelled from above): UI enqueues `cancel{id =
  subtree_root}`. Aggregator walks the registry from that node down,
  sets every descendant's `abort`. Children's `done(cancelled)`
  events stream back through the queue and are processed in order.
- **Global cancel** (root-level, e.g. double-Ctrl+C): `cancel{id =
  root}`. Same mechanism.

The merge payload reflects whatever each child actually reported. A
cancelled child that had completed three turns before its `abort`
fired still contributes its last assistant message and accumulated
cost — its `done(cancelled)` event was built by the child agent loop
on the way out and includes everything it had. Per §3, all-cancelled
fan-outs set `is_error=true`; mixed-with-success fan-outs do not.

---

## 8. Render-thread invariant and the three roles

The system has three role categories. Stating them now so nobody
accidentally collapses two into one:

- **Worker threads** run agent loops. The root agent runs on the
  primary worker; each child runs on its own worker (bounded pool,
  §9). Workers emit `AgentEvent`s to the orchestrator queue and read
  their `LiveChild.abort` flag from the stream callback. They do not
  read the registry. They do not track other children. They do not
  wake each other.
- **The aggregation thread** is the single owner of child-lifecycle
  state. It is the *only* consumer of the orchestrator queue. It
  mutates the live registry, fires `LiveChild.completion` ResetEvents
  when a `done` lands, sets `abort` flags on `cancel`, evicts
  transcripts on parent-tool-call return, and forwards
  post-aggregation `RenderEvent`s to the renderer's separate channel.
- **The render thread** consumes only the post-aggregation
  `RenderEvent` stream. It never touches the live registry, never
  reads child state, never sees raw `AgentEvent`s. Its only job is to
  drain its channel and update the screen.

Two invariants follow:

**No agent loop, parent or child, ever runs on the render thread.**
If a parent agent loop ran on the renderer, its synchronous wait for
children would freeze the UI. With the parent on a worker, it sleeps
while children stream; the renderer keeps draining `RenderEvent`s
from all children's panes live; when the aggregator counts the last
child's `done` for that parent's `spawn_agents` call, it builds the
merge payload, stores it where the parent can read it, and fires the
parent's `LiveChild.completion`. The parent wakes, picks up the merge
payload, and its `ToolResult` flows back into its own pane's
MessageLog through the existing tool path.

**The parent worker's "are we done" signal is single-sourced from the
aggregator.** The blocking primitive is `std.Thread.ResetEvent` on
`LiveChild.completion`, fired exactly once by the aggregator after it
has counted every direct child's `done` for that parent's
`spawn_agents` call and built the merge payload. The parent worker
does not poll the registry. The parent worker does not count children
itself. There is one place where "done" is decided, and the parent
worker is a notified party, not a tracker. This is the §7 principle
applied to wake-up: the aggregator owns lifecycle; everyone else is
told.

In CLI mode (no TUI), the render thread collapses away — the
aggregator can write `RenderEvent`s directly to stdout (or to a
tree-printer per the §9 first-PR scope) in the same loop where it
drains the queue. The aggregation/render split only matters once
there are actual panes to update concurrently with streaming.

---

## 9. First PR scope

**Build `spawn_agents` synchronously, through the existing tool path,
with a fake provider, no threads, no panes.**

Concretely:

1. Add `spawn_agents` and `get_agent_transcript` to `tools.zig` with
   the schemas from §1 and §4. Mark them read-only (`is_writable = false`).
2. Add `tools.execute` branches for both. `spawn_agents`'s executor
   loops over `tasks` **serially** (no threads), running each child
   through `agent.run` with the fake provider, collecting summaries,
   returning the merge payload as a JSON string.
3. Add a tiny `tree_printer` debug renderer that takes the
   `AgentEvent` stream and prints it as indented text:
   `spawn → progress → turn_done → done → merge` at each depth.
4. Add a fixture-driven test that feeds a scripted parent prompt
   ("spawn three children: A, B, C") through the existing agent loop
   against the fake provider, verifies the `spawn_agents` tool fires,
   verifies the three children run, verifies the merge payload
   matches a golden file, and snapshots the `tree_printer` output.

What this PR proves:

- The fan-out-is-a-tool seam works through the *real* agent loop, not
  a parallel harness. If the seam is wrong, this test catches it
  before any concurrency exists.
- The merge payload shape is sufficient for the parent to make a
  meaningful follow-up turn (golden file includes the parent's
  follow-up; if the summary is too thin, the parent gets stuck).
- `get_agent_transcript` works against the in-process registry.
- Recursion works (one of the three children itself calls
  `spawn_agents`, exercising the depth-tracking and cost roll-up).
- Cancel works (one fixture cancels mid-fan-out and checks the
  `done{cancelled}` event propagates and the merge payload reflects
  partial results).

What this PR does **not** do:

- No threads. No real `HttpClient`. No panes. No live rendering.
- No approval policy enforcement code (Option A is a one-line policy
  check on writable-tool execution inside child context; gets added
  with the second PR).
- No bounded worker pool — that's the second PR, behind a feature
  flag, with real provider calls.

Sequencing rationale: the hard part is the protocol (merge payload,
event shape, recursion, cancel), not the plumbing (threads, pools).
You want the protocol wrong in a 200-line test harness, not in a
threaded renderer.

---

## Cross-references

- `messagelog_v1.md` — the `apply(event, turn_seq)` contract this
  doc extends to `(agent_id, turn_seq, block_index)`. No changes to
  that doc required; the existing contract works per-pane.
- `agent.zig:564-571` — the batch tool-execution path that
  `spawn_agents` slots into without new agent-loop surface.
- `pool/client_pool.zig` — client-per-worker factory; future home of
  the child-worker `HttpClient` allocations once the threaded PR lands.
