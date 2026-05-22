# Errors and observability v1 — design note

Status: draft for review. Locks the error taxonomy, correlation
spine, and trace stream that the concurrency PR (bounded worker pool,
real `HttpClient` per child) must build *on top of* rather than
retrofit *into*. The cheap window to design this is before threads
land; the expensive one is after.

The framing this doc commits to: **error handling and error
observability are two different systems, and the v1 gap is
observability.** The handling model is already designed and scattered
across the prior docs — `Done{reason: error}` and `Error{kind, ...}`
in `messagelog_v1.md`, `is_error` semantics and `done(error_)` in
`agent_fanout_v1.md`, cascade-cancel as a distinct path from error,
partial-success-as-first-class in §3 of fanout. What does not exist
anywhere is the layer that lets a human (or an agent debugging
itself) answer "when this 6-child fan-out three levels deep failed at
2am, what actually happened and to which child?" Today the honest
answer is: you can't tell.

This doc threads three things together to close that gap: an error
taxonomy that `Error{kind}` in messagelog v1 and `done(reason)` in
fanout v1 enumerate against; a correlation spine
`(agent_id, turn_seq, depth)` stamped onto every error and every
trace event; and a trace stream emitted by the aggregation thread
(fanout v1 §7) as a peer to the render stream. The principle running
under all three is **no silent failures** — every error path either
surfaces to the user or to a correlated trace event, never both
swallowed. That's the lesson from the sibling Go tool, paid for in
debugging hours; we're not paying it twice.

What this doc deliberately does not do: build distributed tracing
(spans, OpenTelemetry, parent-link IDs across processes), define a
log-aggregation backend, or specify a UI for browsing traces.
Terminal tool, single process. The taxonomy + correlated structured
logs + the no-silent-failure invariant is the right weight for v1.
Spans become a later signal if real workloads need them.

---

## 0. Open question — your call

**What retry policy do streaming agent turns get, given that the
existing `RetryEngine` (`http_sentinel/src/retry/retry.zig`) is not
currently wired into the streaming code path at all?** The recon
turned this up as a live finding, not a design choice: the agent
loop calls `client.sendMessageStreamingWithEvents(...)` directly
(see `agent.zig:501`, `:956`, `:1077`, `:1094`), bypassing
`RetryEngine.execute(...)`. So today a rate-limit or transient 5xx
during a streaming turn fails immediately, with no backoff, and the
agent has to start the turn over from scratch *if* it tries again at
all — which it doesn't, because the error returns out of the agent
loop. That's a real bug surfacing as the right time to decide what
the policy *should* be.

Three options, in increasing aggressiveness:

### Option A — Network + 5xx + rate-limit auto-retry (recommended)

Wrap the streaming call in `RetryEngine.execute(...)` with the
existing `isRetryable()` classification (`errors.zig:47`): retry
network errors, HTTP 5xx (`ServiceUnavailable`, `BadGateway`,
`GatewayTimeout`, `InternalServerError`), and rate-limit
(`TooManyRequests`, `RequestTimeout`) with exponential backoff.
Surface all other errors immediately. The retry is bounded to
3 attempts; the agent turn sees one final failure or one success,
not the intermediate attempts. Each retry attempt emits a trace
event so the human can see *that* a retry happened, but the agent
loop's view is "the turn happened or it didn't."

Why: this is what the engine was built for, the classification is
already correct, and the failure modes it covers are transient
infrastructure problems that absolutely should not bubble up as
"sorry, your fan-out's child #3 died." The cost is one wrap call;
the upside is durability in the face of every real-world flake.

### Option B — Above, plus malformed-response retry

Treat SSE parse failures and unexpected event-type errors as
transient — possibly a corrupted stream byte, possibly a provider
glitch — and retry them too. The argument is that streaming HTTP is
genuinely lossy and the model didn't *fail* to think, the wire
chewed up the answer.

Why not as default: in practice, malformed-response errors are
much more often a real bug (provider changed event shape, our
parser missed a case) than a transient flake. Auto-retrying them
hides the bug behind backoff and makes the failure show up later
as "everything is just slower." Surface immediately; investigate;
add to A's list once we have evidence it's worth it.

### Option C — Above, plus tool-failure retry at the agent layer

When a tool call returns `is_error=true` (file not found, bash
non-zero, JSON parse failure on tool args), don't feed the error
back to the model — automatically retry the tool a couple of times
with the same args. The argument is that some tool errors *are*
transient (filesystem hiccup, network tool that hit a 5xx).

Why not: this is actively wrong for the qai_chat agent. Today, when
a tool fails, the model *sees* the error message in its next turn
and adapts — different path, different command, ask the user for
clarification. That's the correct loop, and the system prompt
already tells the model to "treat tool errors literally; surface
them to the user and adapt" (`agent.zig:39`). Auto-retrying the
tool silently denies the model that information and produces
confused behavior. Tool errors belong in the conversation, not in
the retry engine.

### Recommendation

Ship Option A. It fixes a real present-day bug (streaming has no
retry today), uses code that already exists and is already
correctly classified, and stays out of the agent-layer semantics
where retries belong to the model's reasoning rather than the
infrastructure. Promotions from B and C should require evidence
that A is insufficient.

**Everything below assumes Option A.** Sections §2 and §5 cite this
choice; if you pick B or C, the `retryable` field on the taxonomy
and the wire-up table in §5 shift accordingly.

---

## 1. The logging primitive

The recon found zero logging infrastructure in `qai_chat/src/` — no
`std.debug.print`, no `std.log` import, no logger module. Everything
that surfaces to the user goes through the `args.err` / `args.out`
writers in `RunArgs`, formatted in user-shape (`[turn 3: 240 in /
80 out · $0.0008]`), not in a shape any other consumer can filter
or correlate. The same recon also found `std.debug.print` used in 11
files across `http_sentinel/` — including streaming code paths in
`ai.zig`, `quantum_curl.zig`, `crypto/tls.zig`, and `engine/core.zig`.
For a CLI tool that's mildly ugly; for a TUI with concurrent
streaming agents it's actively hostile, because stderr from a
grandchild's TLS handshake would scribble across the screen.

So step one is establishing the primitive. The contract:

```zig
pub const Logger = struct {
    /// Backing writer. In CLI mode this is typically a file handle
    /// (`~/.qai/log/qai-YYYYMMDD-HHMMSS.jsonl`). In TUI mode it MUST NOT
    /// be the screen's stderr — that's reserved for the renderer.
    /// The TUI hands the logger a file or a ring buffer instead.
    sink: *std.Io.Writer,
    /// Minimum level to emit. Calls below this are no-ops.
    min_level: Level = .info,
    /// JSONL is the on-disk shape. Each call produces one line.
    /// The render-thread's status row can derive what it shows
    /// from a separately-allocated `RenderEvent`, not by tailing
    /// this stream.
    pub fn emit(self: *Logger, ev: Event) void;
};

pub const Level = enum { debug, info, warn, err };

pub const Event = struct {
    level: Level,
    /// Correlation context — see §3. Required on every emit.
    ctx: TraceContext,
    /// Short category string. Conventional values: "agent.turn.start",
    /// "agent.turn.done", "tool.exec", "tool.error", "http.retry",
    /// "stream.parse_error", "orchestrator.spawn", "orchestrator.cancel",
    /// "orchestrator.done", "orchestrator.evict_transcript".
    kind: []const u8,
    /// Free-form message. May be empty when `data` carries the payload.
    message: []const u8 = "",
    /// Optional structured payload — error kind, retry attempt count,
    /// upstream HTTP body, etc. JSON value, serialized verbatim.
    data: ?std.json.Value = null,
};
```

Three rules that come with the primitive:

**The logger sink is never the TUI's stderr.** The Application owns
both. In TUI mode the sink is a file (or a process-local ring buffer
the user can dump with `/log`). The renderer reads its own input
(post-aggregation `RenderEvent` stream); the logger writes its own
output (JSONL). They never collide. In CLI mode the sink defaults to
stderr only when stdout is the user's terminal *and* no TUI mode is
active; otherwise it defaults to a file.

**The logger is owned by the aggregation thread.** Workers do not
write to the logger directly — they emit `AgentEvent`s, the
aggregator stamps `TraceContext` (§3) and translates relevant events
into `Logger.emit` calls. This is the §7-of-fanout principle one
more time: single-threaded ownership of cross-cutting state, and
"interleaved garbage in the log file" is exactly the cross-cutting
problem the aggregator already exists to solve.

**`std.debug.print` is banned in qai_chat code paths.** Tests can
use it. CLI startup banner can use it. Anywhere inside an agent
loop, tool executor, orchestrator, or rendered TUI component must
go through `Logger.emit` (or `args.err` for *user-facing* messages,
which is a different channel — see §6). This is a code-review rule,
not a compiler enforcement. The next layer down (`http_sentinel`)
gets a softer ask documented in §7.

---

## 2. Error taxonomy

The bottom layer is `HttpError` from `http_sentinel/src/errors.zig`
— already exists, already classified by `isRetryable()`,
transport-shaped. We do not redefine it. We layer on top.

The agent-and-orchestrator-visible error type:

```zig
pub const AgentError = union(enum) {
    /// Transport-level (wraps HttpError). Includes connection-level
    /// failures, DNS, TLS, request timeouts.
    network: struct {
        underlying: HttpError,
        retryable: bool,           // from isRetryable() at construction
    },

    /// HTTP 401/403. Almost always a config problem — bad or expired
    /// API key. Not retryable, surface immediately.
    auth: struct {
        provider: []const u8,
        status: std.http.Status,
        body_snippet: []const u8,   // first ~512 bytes of upstream body, owned
    },

    /// HTTP 429 or provider-specific rate-limit response shape.
    /// Retryable under Option A.
    rate_limit: struct {
        provider: []const u8,
        retry_after_ms: ?u64,       // parsed from Retry-After when present
    },

    /// HTTP 5xx or provider-specific overload signal (Anthropic's
    /// "overloaded_error", OpenAI's "server_error"). Retryable.
    provider_overloaded: struct {
        provider: []const u8,
        status: std.http.Status,
        body_snippet: []const u8,
    },

    /// HTTP 4xx that's not auth or rate-limit — the request itself is
    /// malformed. Not retryable. Surface and abort the turn.
    bad_request: struct {
        provider: []const u8,
        status: std.http.Status,
        body_snippet: []const u8,
    },

    /// Provider's response stream didn't parse. Could be a transient
    /// wire corruption or a real shape mismatch. NOT auto-retried under
    /// Option A — surface immediately with enough context to debug.
    malformed_response: struct {
        provider: []const u8,
        offset: usize,              // byte offset within the stream
        event_type: ?[]const u8,    // last successfully-parsed event kind, if any
        snippet: []const u8,        // the unparseable bytes (cap ~256)
    },

    /// Provider signaled the prompt exceeds the model's context window.
    /// Recognized via provider-specific error shape. Not retryable;
    /// caller may degrade by truncating history.
    context_length_exceeded: struct {
        provider: []const u8,
        model: []const u8,
        used_tokens: ?u32,
        limit_tokens: ?u32,
    },

    /// Provider's safety system rejected the request or the response.
    /// Not retryable.
    content_filtered: struct {
        provider: []const u8,
        category: ?[]const u8,      // provider-specific reason string
    },

    /// Local tool execution failed (file-not-found, bash non-zero,
    /// unparseable JSON args). NOT retried automatically (see Option C
    /// rejected) — the error message becomes a `tool_result` so the
    /// model can adapt.
    tool_failure: struct {
        tool_name: []const u8,
        reason: []const u8,         // the message the model will see
    },

    /// User cancelled. Not a failure; categorized for taxonomy
    /// completeness so `done(cancelled)` and `done(error_)` can be
    /// uniformly inspected as `AgentError | null`.
    cancelled: struct {
        scope: enum { pane, subtree, global },
    },

    /// Agent loop hit `MAX_AGENT_TURNS` or `max_turns_per_child`.
    /// Not retryable; degrade per §3 of fanout v1 (return partial
    /// `message`, status `turn_limit`).
    turn_limit: struct {
        cap: u32,
    },

    /// Fan-out exceeded the recursion depth cap (fanout v1 §6).
    fanout_depth_exceeded: struct {
        attempted_depth: u8,
        cap: u8,
    },

    /// `get_agent_transcript` against an id that was evicted under the
    /// tree-scoped lifetime rule (fanout v1 §4).
    transcript_evicted: struct {
        agent_id: u64,
    },

    /// Programming error, assertion failure, OOM during an event we
    /// could not unwind cleanly. Surface and abort the whole agent.
    /// Should fire a `warn` or `err`-level log with full stack context.
    internal: struct {
        what: []const u8,
    },
};

/// Cheap accessor used by the retry engine and the merge-payload
/// classifier. Independent of `HttpError.isRetryable()` only at the
/// level above: e.g. `bad_request.status == 422` is not retryable
/// even though the transport call technically returned successfully.
pub fn isRetryable(self: AgentError) bool {
    return switch (self) {
        .network => |n| n.retryable,
        .rate_limit, .provider_overloaded => true,
        else => false,
    };
}
```

A few load-bearing notes:

**`body_snippet` replaces `last_sse_error_body`.** The current side
channel on `HttpClient` (the single-slot `?[]u8` that gets clobbered
by every new error and is read once by `agent.zig:901`) goes away.
Errors carry their body context structurally, owned by the
`AgentError` value, freed when the error is logged and converted
into a `done(error_)` event. Multi-agent safe by construction
because each error is its own owned value.

**`cancelled` is in the union for uniformity, not because it's an
error.** A child's `done.reason` becomes an `?AgentError` —
`null` for `ok`, `cancelled`/`turn_limit`/anything else otherwise.
This lets the merge-payload builder (fanout §3) and the trace-event
emitter inspect both shapes through one switch.

**There is no `unknown` or `other` variant.** Adding one is the
fastest way to make this taxonomy useless — every uncategorized
path ends up there and nothing gets a real category. If a real
error doesn't fit, the right move is to add a variant, not a
catch-all.

---

## 3. Correlation context

Every `AgentError` is emitted alongside, and every log event
carries, a single struct:

```zig
pub const TraceContext = struct {
    /// The agent that produced this event. 0 = root.
    agent_id: AgentId,
    /// 1-based turn within that agent's loop. 0 before the first
    /// turn starts.
    turn_seq: u32,
    /// Tree depth at spawn time. 0 = root.
    depth: u8,
    /// Parent in the fan-out tree. `null` only for the root.
    parent_id: ?AgentId,
    /// Optional sub-turn locality — content block within the current
    /// turn. Set when an error is attributable to a specific tool_use
    /// block or text block; null otherwise.
    block_index: ?u32 = null,
    /// Optional HTTP request id from the provider when one is
    /// surfaced (Anthropic's `x-request-id`, OpenAI's `x-request-id`
    /// header). Lets a human cross-reference our logs with the
    /// provider's dashboard.
    request_id: ?[]const u8 = null,
};
```

This is the cheapest part of the whole observability design and the
most load-bearing one. With it, every log line and every error in a
6-child fan-out three levels deep is filterable to *that child's*
story by grepping `agent_id`. Without it, concurrent logs are
interleaved garbage. The fact that the design only works with the
fanout-v1 aggregator already centralizing every event is why this is
near-free *now* and very expensive after the threaded PR lands —
retrofitting requires touching every emit site under whatever
schedule pressure that PR brings.

**The aggregator is the single stamping point.** Workers emit
`AgentEvent` *without* `TraceContext` (the context is derivable from
the worker's known `agent_id` and the event's `turn_seq`); the
aggregator constructs `TraceContext` from the live registry when it
processes the event and stamps it onto both the outgoing trace
event and any `AgentError` value forwarded into the merge payload.
That centralization means a worker cannot lie about its own context
(the registry is the truth), and depth/parent_id stay consistent
even if a child re-spawned under recursion.

---

## 4. The trace stream

The aggregation thread emits two output streams: the **render
stream** (defined in fanout v1 §8, consumed by the render thread,
compact, presentation-shaped) and the **trace stream** (defined
here, consumed by the logger, structured, debug-shaped). They are
peers, not derivatives of each other.

```zig
pub const TraceEvent = struct {
    ctx: TraceContext,
    kind: []const u8,                  // see Logger.Event.kind
    level: Logger.Level = .info,
    /// Non-error event payload (turn start: model + max_tokens;
    /// turn done: usage). Mutually exclusive with `error_`.
    data: ?std.json.Value = null,
    /// Set on error-classifying events (`*.error`, `http.retry.*`).
    /// Owned by the TraceEvent; freed after Logger.emit returns.
    error_: ?AgentError = null,
};
```

What gets emitted, with the canonical `kind` strings already
referenced in §1:

- `orchestrator.spawn` — every `AgentEvent.spawned` becomes one
  trace at `info` carrying `label`, `parent_id`, `depth`.
- `orchestrator.done` — every `AgentEvent.done` becomes one trace
  at `info` (`reason: ok`/`turn_limit`) or `warn` (`reason:
  cancelled`) or `err` (`reason: error_`, with `error_` field
  populated). `total_usage` goes in `data`.
- `orchestrator.cancel` — every `OrchestratorMessage.cancel`
  processed by the aggregator. Carries the subtree root and the
  count of descendants whose `abort` flag was armed.
- `orchestrator.evict_transcript` — every tree-scoped eviction
  (fanout §4) at `debug`. High-volume in deep trees; useful only
  when diagnosing transcript-fetch failures.
- `agent.turn.start` / `agent.turn.done` — bookends per turn,
  carrying model + token counts + cost.
- `tool.exec` — every tool dispatch, at `info` for read-only and
  `warn` for writable (to flag side effects).
- `tool.error` — every `tool_failure`, at `warn`.
- `http.retry` — every retry attempt made by the engine (§5), at
  `warn`. Carries attempt index, backoff delay, the
  `AgentError` that triggered the retry.
- `stream.parse_error` — `malformed_response` at `err`. Always
  surfaces, never auto-retried under Option A.

The aggregator does *not* emit a trace for every `progress` event —
that would be one trace per token and the log file is useless. The
render stream handles per-token presentation; the trace stream
handles structural events.

CLI mode collapses the two streams: the aggregator writes
`RenderEvent`s to stdout in the same loop where it `Logger.emit`s
trace events to the configured sink. TUI mode keeps them genuinely
separate (different channels, different consumers, different output
shapes).

---

## 5. Retry policy wiring

Under Option A (§0), the streaming agent call gets wrapped:

```zig
// Today (agent.zig:501, :956, :1077, :1094):
client.sendMessageStreamingWithEvents(prompt, history, cfg, cb, &state)
    catch |e| { /* surface and return */ };

// After this PR:
var retry_engine = hs.retry.RetryEngine.init(args.gpa, .{
    .max_attempts = 3,
    .initial_backoff_ms = 500,
    .max_backoff_ms = 8000,
    .jitter = true,
});
retry_engine.executeStreaming(
    &client,
    &.{ .prompt = prompt, .history = history, .cfg = cfg, .cb = cb, .state = &state },
    on_retry,    // closure that emits `http.retry` trace events
) catch |e| { /* surface AgentError and return done(error_) */ };
```

What the engine maps to `AgentError`:

| Outcome from streaming call           | `AgentError` variant            | Retry? |
| ------------------------------------- | ------------------------------- | ------ |
| `error.ConnectionRefused`, network    | `.network { retryable: true }`  | Yes    |
| `error.Unauthorized` (401)            | `.auth`                         | No     |
| `error.Forbidden` (403)               | `.auth`                         | No     |
| `error.TooManyRequests` (429)         | `.rate_limit`                   | Yes    |
| `error.InternalServerError` (5xx)     | `.provider_overloaded`          | Yes    |
| `error.BadGateway` (502)              | `.provider_overloaded`          | Yes    |
| `error.ServiceUnavailable` (503)      | `.provider_overloaded`          | Yes    |
| `error.GatewayTimeout` (504)          | `.provider_overloaded`          | Yes    |
| `error.BadRequest` (400)              | `.bad_request`                  | No     |
| `error.UnprocessableEntity` (422)     | `.bad_request`                  | No     |
| Provider "overloaded" in body         | `.provider_overloaded`          | Yes    |
| Provider "context_length_exceeded"    | `.context_length_exceeded`      | No     |
| Provider safety rejection             | `.content_filtered`             | No     |
| SSE parse failure (any offset)        | `.malformed_response`           | No     |
| Tool executor returns error           | `.tool_failure`                 | No     |
| `MAX_AGENT_TURNS` reached             | `.turn_limit`                   | No     |
| Aggregator armed `abort` mid-stream   | `.cancelled`                    | No     |

Two rules the table encodes:

**`retryable` on `AgentError` is the source of truth, not the
`HttpError`.** The taxonomy classifier (which builds the
`AgentError` from the underlying error and the response body) is
where retry policy is decided. The retry engine asks
`AgentError.isRetryable()`, not `HttpError.isRetryable()`. This lets
us downgrade — e.g., classify a 503 as `bad_request` if the body
makes clear it's a permanent rejection wearing a 503 mask — without
changing the engine.

**Provider-body parsing happens once, in the classifier, before
retry decisions.** A 5xx that says `"overloaded"` in the body is
retryable; one that says `"context length exceeded"` is not. The
classifier reads the body, builds the right `AgentError` variant,
and the retry engine sees only its `isRetryable()` result. No
double-parsing, no second pass.

The `on_retry` closure passed to the engine is how `http.retry`
trace events get correlated — it captures the worker's
`TraceContext` and emits via the aggregator queue, exactly the
same path every other trace event takes.

### Honoring `Retry-After`

The `.rate_limit` variant in §2 parses `retry_after_ms` from the
HTTP `Retry-After` header (and provider-specific equivalents like
Anthropic's `anthropic-ratelimit-requests-reset`). The recon found
that `RetryEngine` cannot consume that hint today: `calculateBackoffDelay`
(`retry/retry.zig:294`) derives the next-attempt delay purely from
`config.base_delay_ms × backoff_multiplier^attempt + jitter`, and
`is_retryable_fn` (`retry.zig:214`) returns `bool` — there is no
hook for the predicate to say "retry, but wait *this* long." So a
parsed `retry_after_ms` is dead weight unless we close the loop.

Two ways to close it:

- **Honor outside the engine (v1, recommended).** When the
  classifier builds `.rate_limit` with `retry_after_ms = Some(n)`,
  the wrapper around `RetryEngine.executeStreaming` sleeps for `n`
  milliseconds *before* re-entering the engine, and the engine's
  own backoff schedule applies on top. Non-breaking for
  `http_sentinel`; the engine stays config-driven and oblivious to
  per-call hints. The `http.retry` trace event records both the
  honored `Retry-After` value and the engine's subsequent delay so
  the human can see what actually slept.
- **Extend the engine (future).** Add a sibling to `is_retryable_fn`
  that returns `?u64` and overrides `calculateBackoffDelay` when
  present. Cleaner architecturally; out of scope for v1 because it
  touches a library-stable surface for a workload nobody has
  measured yet.

Without either, `retry_after_ms` is parsed and ignored, which is
the worst of both worlds — it looks correct in the taxonomy and
silently isn't. The v1 deliverable in §9 includes the outside-the-
engine sleep so the field carries its weight from the first
landing.

### Emission gating during retry

This is the rule that prevents a real shipped bug, so it gets its
own subsection: **per-turn agent-level emissions are gated behind
"the final attempt has been determined." Only `http.retry` trace
events fire during the retry loop.** What "agent-level emissions"
covers:

- Appending the assistant turn to `history` (`agent.zig:548`,
  `:997`, `:1137`).
- Emitting the `AgentEvent.turn_done` / `AgentEvent.done`
  events that downstream parties (aggregator, parent worker
  blocked on `LiveChild.completion`, fanout merge-payload builder)
  consume.
- Emitting the `agent.turn.done` trace event (§4).
- Adding to `UsageStats` (`agent.zig:289`).
- Executing tool calls and feeding back tool_results.

A streaming attempt that fails mid-flight and is going to be
retried must not advance any of those — the agent loop's view is
that the turn happened *once* and either succeeded or finally
failed. Intermediate attempts produce only the live-streamed text
the user sees on screen (which is fine — live UX) and a single
`http.retry` trace per attempt.

Two implementation rules follow:

- **`TurnState` resets between attempts.** `streamEventCb` writes
  text deltas live to `s.out` per attempt; the retry wrapper
  clears `state.text`, `state.tools`, `state.stop_reason`,
  `state.input_tokens`, `state.output_tokens`, `state.done`, and
  `state.saw_tool_use` before re-invoking the streaming call.
  Otherwise text from attempt 1 concatenates with attempt 2 and
  the assistant history entry corrupts, tool counts double, and
  the user sees two stop reasons.
- **The retry wrapper emits a visible boundary on each new
  attempt.** Before clearing `TurnState` and re-entering the
  stream, the wrapper writes `\n[retrying — {reason}: attempt
  N/M]\n` to `args.err`. The user has already seen attempt 1's
  partial text on their screen (it streamed live); the boundary
  marker tells them everything before it is being superseded.
  Without this, the user sees attempt 1's "Hello, I think the
  answer is..." truncated and then attempt 2's full answer
  immediately following, with no separator — ambiguous and
  alarming.

The bug this prevents: phantom `done(error_)` events emitted from
inside the retry loop while the engine is about to retry
successfully, leading to the aggregator counting a child as failed,
the parent worker waking from its `LiveChild.completion`, the
merge payload getting built with a `cancelled`/`error` entry — and
*then* the retry succeeds and the same child tries to emit a second
`done(ok)`. The aggregator's single-ownership model from fanout §7
makes this *detectable* (the second `done` lands on a child that's
already evicted from the live registry, and the aggregator can
assert), but the right place to prevent it is at the agent loop:
`done` is emitted once, after the engine has finalized its
decision. The aggregator's assertion is the second line of defense,
not the first.

---

## 6. The no-silent-failure invariant

State it as a rule, with the carve-outs explicit:

**Every error path in qai_chat code either surfaces to the user OR
emits a structured trace event with full `TraceContext`. Never
both-swallowed.**

Three carve-outs, each named so they're visible to code review:

- **Best-effort writes** explicitly marked with `catch {}` and a
  comment. The two current examples (`agent.zig:117`,
  `agent.zig:121` — approval-file save-back) are correctly written
  this way: the disk write is a cache, the in-memory state is
  authoritative, a save failure is not user-facing. Acceptable, but
  must be commented as such. New best-effort writes require the
  same explicit signal.
- **Logger sink failures.** If `Logger.emit` itself fails (disk
  full, file closed), we cannot trace that failure through the
  logger. The logger swallows its own sink errors and increments a
  process-local counter (`logger.dropped_events`) that the CLI's
  `/log` command surfaces and the test harness asserts is zero at
  end-of-run.
- **`progress` event drops** when the orchestrator queue is full
  under extreme backpressure (1000+ events in flight, real-world
  improbable). The aggregator counts drops per `agent_id`; a
  non-zero count emits one `orchestrator.event_drop` trace at
  `warn` per turn, not per dropped event. Acceptable because
  `progress` is per-token and a missed token is degraded
  presentation, not lost state.

Everything else: silent error path is a bug. The code-review
checklist asks one question on every PR — *can this error path be
hit without producing a user-visible message or a trace event?* If
yes, fix it.

This is the lesson from the sibling Go tool — exit 137 with no
stderr, swallowed broker rejections, conductor dropping deferred
tools without surfacing. The grievance list is the evidence; this
invariant is the response. Write it down so future PRs honor it
without re-deriving the reasoning.

---

## 7. http_sentinel and the soft ask

`http_sentinel` uses `std.debug.print` in 11 files including
streaming code paths (`ai.zig`, `quantum_curl.zig`,
`engine/core.zig`, `crypto/tls.zig`, `ai/vertex.zig`). For a TUI
that's catastrophic — stderr from a grandchild's TLS handshake
scribbles across the screen — but we don't own `http_sentinel`
unilaterally and a full logger rewrite there is out of scope for
v1.

The pragmatic contract:

- **qai_chat redirects stderr at TUI startup** to either the
  logger's file sink or a process-local ring buffer. Library-level
  `std.debug.print` calls land somewhere a human can find, not on
  the rendered screen. This is a one-call fix at startup.
- **http_sentinel error returns become richer over time.** Today
  they throw `HttpError` and stash bodies in `last_sse_error_body`.
  Once the classifier in §5 lands, that side channel can be
  retired — the streaming call returns `AgentError | success`
  shape via an out-parameter, and `last_sse_error_body` deletes.
  That's a small, contained change in `http_client.zig` and the
  per-provider streaming functions.
- **`std.debug.print` in `http_sentinel` is allowed but
  discouraged.** New code in that library goes through error
  returns or an injected writer; existing prints get cleaned up
  opportunistically when a file is touched for other reasons. The
  TUI stderr redirect makes this acceptable as a v1 posture.

If `http_sentinel` is later promoted to a separately-versioned
library with its own consumers, it gets its own logger. For now,
the qai_chat side handles enough of the gap that we don't have to.

---

## 8. Cross-references and seams

This doc threads back into the existing two:

- **`messagelog_v1.md`** — its `Error{kind, message}` variant
  (defined in the per-block content union of the MessageLog
  contract) now enumerates against `AgentError` (§2). `kind` is
  the variant tag; `message` is the user-facing summary (e.g.
  "rate limit — retrying in 2s" for `.rate_limit`, "context
  exceeded by ~1200 tokens" for `.context_length_exceeded`).
  Optional `data` carries the structured payload for an
  expandable "show details" affordance later.
- **`agent_fanout_v1.md`** — its `done.reason` enum
  (`ok | cancelled | turn_limit | error_`) becomes
  `done.outcome: ?AgentError` per §2's note about uniformity.
  `ok` is `null`; everything else is a populated variant. Fanout
  §3's per-child status field in the merge payload derives from
  this directly. The `is_error` rule from fanout §3
  (true iff no child returned a usable result) stays exactly as
  written.
- **`agent_fanout_v1.md` §7 aggregator** — the single thread that
  drains `OrchestratorMessage` is also the single emitter of
  `TraceEvent`s. The `LiveChild` struct gains a `TraceContext`
  field constructed at spawn so the aggregator does not rebuild
  it from scratch on every event.

---

## 9. First PR scope

Three deliverables, all landable behind the existing serial-fake-
provider harness from fanout v1 §9 *before* the threaded PR:

1. **The logger primitive (§1).** `src/logger.zig` with the
   `Logger`/`Event`/`Level` types, a JSONL file sink, level
   filtering, a process-local `dropped_events` counter. Wire it
   into the existing single-threaded agent path: every
   `args.err.print(...)` that's *structural* (turn start/done,
   tool exec, retry attempt) becomes a `Logger.emit` call; every
   one that's *user-facing narration* (`[turn N: in/out · $cost]`)
   stays on `args.err`.

2. **The `AgentError` taxonomy and `last_sse_error_body`
   retirement (§2, §7).** Define `AgentError` in
   `src/errors.zig` (new file, separate from
   `http_sentinel/errors.zig`). Build the classifier that takes
   `(HttpError, ?response_body, provider)` → `AgentError`.
   Replace the `surfaceApiError` path in `agent.zig:900` to
   build and log an `AgentError`. Add the out-parameter shape to
   the streaming AI clients (`http_sentinel/src/ai/*.zig`) so
   `last_sse_error_body` can delete. One PR, contained scope.

3. **Retry-engine wiring (§5).** Wrap the streaming call site in
   `RetryEngine.executeStreaming(...)` (new method on the
   existing engine, generic over a streaming-call closure). Map
   classifier output to `AgentError.isRetryable()`. Emit
   `http.retry` traces from the `on_retry` closure. Honor
   `Retry-After` outside the engine by sleeping in the wrapper
   before re-entering when the classifier built a `.rate_limit`
   with `retry_after_ms` set (§5, "Honoring `Retry-After`").
   Implement the emission-gate (§5, "Emission gating during
   retry"): `TurnState` resets between attempts, the wrapper
   writes a visible `\n[retrying — {reason}: attempt N/M]\n`
   boundary on `args.err`, and history append / `done` event /
   `agent.turn.done` trace / `UsageStats.add` all fire exactly
   once after the engine has finalized its decision. The fact
   that streaming isn't retried today is a real bug; this fixes
   it as part of the observability landing rather than as a
   separate concern.

What this PR set does *not* do, deliberately:

- No threads, no aggregator, no `TraceContext` stamping yet. The
  single-threaded harness has only one agent and `TraceContext`
  is `{ agent_id: 0, turn_seq: N, depth: 0, parent_id: null }`
  for every event. The full correlation spine activates when the
  threaded PR lands; the *shape* is in place before then so
  there's nothing to retrofit.
- No `TraceEvent` stream separate from logger emits (CLI mode's
  collapsed-streams shape is fine for single-thread). The
  aggregator splits them when there's an aggregator to split
  them.
- No replacement for `std.debug.print` in `http_sentinel`. The
  stderr-redirect approach in §7 is sufficient v1 posture.

Sequencing rationale (same as fanout v1): the protocol — the
taxonomy, the correlation context shape, the no-silent-failure
invariant — has to be wrong in a 300-line PR against the
single-threaded harness, not wrong in a multi-threaded renderer
under deadline. The taxonomy and the invariant in particular are
the kinds of things that look fine until ten new error paths land
and people start reaching for `catch {}` because there's no
structured alternative. The cheap window to lock them is now.

**Strict ordering within the PR set: #2 must land before #3.**
Deliverable #3 (retry-engine wiring) consumes `AgentError.isRetryable()`
as the source of truth per §5, which doesn't exist until the
classifier in #2 lands. Wiring retry against `HttpError.isRetryable()`
as a stopgap would get the priority calls wrong — a 503 with a
permanent-rejection body, an `Unauthorized` that should never
retry, a provider-specific overload signal hiding inside a 200 — all
of which the §5 table resolves at the `AgentError` layer. Don't pick
#3 to land first because "it fixes the most obviously broken thing";
the broken thing is broken less because of *missing retry* and more
because of *missing classification*, and the classification is the
load-bearing piece. #1 (the logger) is independent of both — it can
land before #2, or in parallel — but #2 strictly precedes #3.
