# MessageLog v1 — API scoping

Status: draft for review. Locks the API surface that the prereqs PR
(FakeProvider + JSONL fixture format) and milestone 1 (`qai --tui` with
dumb append-only MessageLog) build against.

This doc deliberately does not specify markdown / code highlighting /
tool-call rendering / virtualization / ANSI passthrough — those land
per-PR with their own scoping. The MessageLog v1 contract is plain-text
shaped; richer rendering extends without breaking it.

---

## 1. Render contract

```zig
pub const MessageLog = struct {
    /// Begin a new user-driven turn. Renders the user message immediately
    /// (don't wait for assistant) and advances internal turn_seq. Bridge
    /// calls this the moment the user submits — before any HTTP request.
    pub fn beginUserTurn(self: *Self, text: []const u8) !void;

    /// Apply one StreamEvent attributed to a turn. Bridge forwards every
    /// event from the provider verbatim. MessageLog is the only place
    /// that knows about block lifecycle, heights, scroll, selection.
    pub fn apply(self: *Self, event: hs.ai.common.StreamEvent, turn_seq: u32) !void;

    /// User cancelled mid-stream (Ctrl+C). Mark all blocks open within
    /// turn_seq as `cancelled` and emit no further state changes for it.
    /// Idempotent: repeated calls for the same turn_seq are no-ops.
    pub fn cancel(self: *Self, turn_seq: u32) void;

    /// Render into a tui.Buffer rect. Caller (the Application) owns the
    /// buffer and the rect; MessageLog reads its own state and writes cells.
    pub fn renderInto(self: *Self, buf: *tui.Buffer, viewport: tui.Rect, sel: ?Selection) void;

    /// Input dispatch from the Application's event handler. Returns true
    /// when MessageLog handled the event (scroll, hit-test, etc.).
    pub fn handleEvent(self: *Self, event: tui.Event) bool;

    /// Hit-test a viewport-relative cell. Application owns Selection state;
    /// MessageLog only knows how to translate cell → block address.
    pub fn hitTest(self: *const Self, viewport: tui.Rect, point: tui.Position) ?Address;

    /// Status-bar queries — cheap, no allocations.
    pub fn isAnchored(self: *const Self) bool;
    pub fn currentTurnSeq(self: *const Self) u32;
};

pub const Address = struct { turn_seq: u32, block_index: u32, char_offset: u32 };
pub const Selection = struct { anchor: Address, head: Address };
```

The seam: bridge knows nothing about blocks, heights, or scroll state.
MessageLog is the only place those concepts exist. This lets us swap
rendering implementations later (e.g. a `gpu/` variant for `wezterm`'s
sixel mode) without touching the streaming layer.

## 2. Block lifecycle

Per-block state:

```zig
const BlockState = enum {
    streaming,   // events arriving; tail item; bottom-anchor active
    complete,    // block_stop seen; height cached; never mutates again
    cancelled,   // turn cancelled while still streaming; visually marked
    failed,      // Done{error} arrived; visually marked with error reason
};
```

Visual treatment:

| State        | Treatment                                                         |
|--------------|-------------------------------------------------------------------|
| `streaming`  | active cursor at tail; no border decoration                       |
| `complete`   | normal rendering                                                  |
| `cancelled`  | dim left-edge marker `┊`; trailing `… [cancelled]` row            |
| `failed`     | red left-edge marker `┊`; trailing `[error: <stop_reason>]` row   |

The `Done{cancelled}` rule from the cancel discussion: the consumer
stops draining new `text_delta`s the moment cancel is signalled but
keeps draining structural events so blocks finalize cleanly. Any block
still in `streaming` when `Done{cancelled}` arrives transitions to
`cancelled`, NOT `complete`. The user always sees the difference
between "model finished" and "I cancelled mid-thought."

`message_stop` stays sacred — only fires on real provider-side stop.
The new `Done` variant carries the cancel/error path. Both can arrive
in the same turn: provider says `message_stop` (token usage banked) and
then we synthesise `Done{complete}` to formally close the turn for the
MessageLog. On cancel, no `message_stop` ever arrives — only `Done{cancelled}`.

## 3. Height cache invariants

Cache: `BlockHeights = AutoArrayHashMap(Address, u16)`.

Three invalidation triggers:

1. **Terminal width change** (SIGWINCH → resize event from Application).
   Wipe the entire cache. All blocks recompute height on next render.
2. **Streaming update to a block.** Invalidate that block's entry; on
   next render its height is recomputed from current content.
3. **Block finalization** (`block_stop` for normal, cancel/error for
   abnormal). Recompute and store the final height; entry is now
   considered immutable until trigger 1.

Edge case — a streaming block's height **shrinks** between frames (rare
but possible when a markdown renderer reflows on close-fence): the
bottom-anchor logic re-pins to bottom, never jumps to preserve visual
position. Rationale: anchored mode's invariant is "show the latest
content;" jumping to preserve a scroll offset would defeat the anchor.
In free-scroll mode the same shrink happens silently — the block
collapses upward, no scroll offset adjustment.

The cache lives in the MessageLog, keyed by `Address`. It is NOT
exposed in the public API. Tests assert the cache is consistent with
re-rendering after invalidation — never accessed directly.

## 4. Anchor mode

Two modes:

- **anchored** — viewport pinned to bottom. Streaming text appears live.
- **free** — user has scrolled up. Streaming continues but viewport
  stays put.

Transitions:

- **anchored → free**: any upward scroll input (PgUp, Up arrow with
  scroll, mouse wheel up).
- **free → anchored**: explicit only. Default key: `Ctrl+End`. Slash
  command alias: `/bottom`. **No auto-return** when the user happens
  to scroll near the bottom — explicit-only avoids the worst TUI
  failure mode (surprising scroll jumps on streaming bursts).

Status bar shows `[anchored]` or `[free, +N lines]` so the mode is
visible. Cancellation does not change mode.

## 5. Keying

- `turn_seq: u32` is generated by the **bridge**, not the MessageLog.
  Starts at 0, increments on each `beginUserTurn` call. Never
  decrements. The MessageLog stores it as carried; doesn't synthesise.
- `block_index: u32` is taken verbatim from `StreamEvent.*.index` (the
  upstream content-block index). Provider-supplied; MessageLog does
  not renumber.
- A **cancelled turn keeps its seq.** The next `beginUserTurn` gets
  seq+1. Resume from disk replays seqs in order; gaps would indicate
  a corrupt log, not a deleted turn.
- Per-block address: `(turn_seq, block_index)`. Used as the key for
  the height cache, hit-test results, and selection anchors.

## 6. Selection

Selection state is **owned by `Application`**, not by MessageLog.

MessageLog exposes:
- `hitTest(viewport, point) → ?Address` — pure function of state +
  viewport. Cheap, allocation-free.
- `renderInto(buf, viewport, sel: ?Selection)` — render with optional
  highlight overlay.

Application owns the `Selection` struct, the active drag, and the
clipboard handoff. Slash-command overlays (`/help` dropdown, `/sessions`
list) get their own Selection without conflict because MessageLog
holds no selection state.

Implementation in v1: `hitTest` returns `null` (stub); `renderInto`
ignores `sel`. The signatures exist so the prereqs PR's fixture format
can include selection-driven test cases without API churn.

## 7. Event log retention

The MessageLog holds an in-memory log of every `StreamEvent` plus user
inputs as `LogEntry { kind: enum { user, event }, turn_seq: u32, payload }`.

**v1: unbounded.** Sessions don't run long enough in normal use to hit
memory pressure, and we want real workload data before optimising.

**Known-issue / metric.** When `LogEntry` count exceeds ~50k or
total size exceeds ~100 MB (whichever first), we add a ring buffer +
spillover-to-disk. That's a future PR, not v1.

**Architectural decision (lock now to avoid retrofits later):**
when session persistence lands — and it will — **disk is the source of
truth; in-memory log is a cache.** Concretely:

- `qai --tui` writes a JSONL tee to `~/.qai/sessions/<id>.events.jsonl`
  on every `beginUserTurn` and every `apply()`. Append-only, fsync per
  turn (not per event — too slow).
- `qai --tui --resume <id>` reads JSONL and replays into MessageLog via
  `apply()`. The replay path is the same as live streaming.
- The auto-save markdown at `~/.qai/projects/<cwd>/<ts>-<provider>.md`
  remains a human-readable snapshot, generated by walking history at
  exit. It is not the source of truth.
- The in-memory log is rebuildable from disk; on memory pressure, drop
  the oldest entries first and reload them from JSONL on scrollback.

The decision we are deliberately NOT making: "in-memory is truth, disk
is backup." That's a different architecture and it doesn't scale to
multi-day sessions.

In v1, only the in-memory side exists. The JSONL tee lands in a later
PR — but the bridge contract permits it without redesign because every
event passing into `apply()` is exactly what would be teed.

## 8. Out of scope (per gradient-deferred-per-PR)

The following each get their own scoping doc when the PR is queued:

- **Markdown rendering** — fenced blocks, headings, lists, links.
- **Code highlighting** — language-aware; start with backtick-fence
  language tag, not full Treesitter.
- **Tool-call rendering** — collapsible blocks with live-updating
  contents during agent execution. The hard one. Tool-call blocks
  have lifecycle distinct from text blocks (id-based, not index-based;
  approval state visible inline; result block expandable).
- **Virtualization** — only render visible viewport rows; on-demand
  reload from event log when scrolled offscreen entries are evicted.
- **ANSI passthrough** — for bash-tool output. terminal_mux's VT100
  parser earns its place here.

The MessageLog v1 API is plain-text shaped. Each gradient PR extends it.
Extensions are allowed to add internal block-kind discriminators and
new render paths; they are NOT allowed to change the public contract
defined in §1.

---

## Failure modes this doc prevents

1. Bridge rendering its own widgets (e.g. tool-call panels) bypassing
   MessageLog. The single `apply()` entry point makes that mechanically
   awkward and review-flaggable.
2. Cancellation that loses the difference between "model finished" and
   "user aborted." Explicit `cancelled` block state + dim marker.
3. Surprising auto-scroll back to bottom during streaming bursts.
   Explicit `Ctrl+End` only.
4. Speculative MPSC plumbing. The keying is `(turn_seq, block_index)`;
   parallel sources later widen `block_index` to a discriminator
   without changing the API.
5. Premature markdown / code / tool-call abstractions. The plain-text
   v1 surface is small enough to be obviously correct.
6. Architectural drift between "memory is truth" and "disk is truth"
   for sessions. The decision is locked now, even though only memory
   exists in v1.

## Open questions

None blocking the prereqs PR. Any I'd raise are gradient questions and
get answered when their PR is queued.
