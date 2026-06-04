# terminal_mux — in-process C ABI (`libterminal_mux`)

A libghostty-style embedding surface. A host application links the static
library and drives the multiplexer core (PTY + VT100 emulator) **in-process** —
no socket, no daemon. The PTY and the VT emulator run inside the caller's
address space; the host owns the run loop and the text/GPU rendering. This is
the model the Swift/SwiftUI front-end uses to evaluate an Apple-native terminal
(the same Zig-core + Swift-UI split as Ghostty).

The header is [`include/terminal_mux.h`](../include/terminal_mux.h); it is the
source of truth for the ABI and is kept in lock-step with
[`src/capi.zig`](../src/capi.zig).

---

## Build

```sh
cd programs/terminal_mux
zig build -Doptimize=ReleaseFast          # → zig-out/lib/libterminal_mux.a + zig-out/include/terminal_mux.h
```

### macOS: repack the archive before linking from Xcode/clang

Zig 0.16 emits Mach-O archive members with 2-byte alignment; Apple's `ld`
requires 8-byte and otherwise fails with *"not 8-byte aligned"*. After every
rebuild, repack:

```sh
../../scripts/repack-for-xcode.sh zig-out/lib/libterminal_mux.a
```

(`repack-for-xcode.sh` runs `libtool -static` to realign the members. This is a
repo-wide requirement for all native Zig static libs consumed by Xcode — see the
root `CLAUDE.md`.)

---

## Concept: in-process attach / detach

A session created with `tmux_create` is registered under a `uint64_t` id and
keeps running — its shell stays alive, its grid stays intact — until
`tmux_destroy`. `tmux_detach` releases the caller's logical hold without tearing
anything down; `tmux_attach(id)` re-acquires the handle. This is the embedded
analogue of `tmux attach`: one UI surface can detach and a later surface can
reattach to the same live session.

**Threading.** The registry calls (`create`/`attach`/`detach`/`destroy`/`list`)
are mutex-guarded and thread-safe. Per-session calls (`pump`/`drain`/`feed`/
`send` and the grid accessors) are **not** internally locked — drive a single
session handle from one thread at a time. The intended model is one session per
UI surface.

---

## API reference

### Lifecycle
| Function | Purpose |
|---|---|
| `const char *tmux_version(void)` | Library version string. |
| `tmux_session *tmux_create(uint16_t rows, uint16_t cols, const char *shell, uint64_t *out_id)` | Allocate a `rows`×`cols` terminal and spawn `shell` (NULL → `$SHELL`, else `/bin/zsh` on macOS) in its first pane. Writes the new id to `out_id` if non-NULL. 0 rows/cols default to 24/80. |
| `tmux_session *tmux_attach(uint64_t id)` | Re-acquire a live session by id; NULL if not found. |
| `void tmux_detach(tmux_session *)` | Release the logical hold; session keeps running. |
| `void tmux_destroy(tmux_session *)` | Kill the shell, free the terminal, unregister. Handle invalid afterward. |
| `uint64_t tmux_id(tmux_session *)` | The session's registry id. |
| `bool tmux_is_attached(tmux_session *)` | Attached (true) vs detached. |
| `size_t tmux_list(uint64_t *out_ids, size_t max)` | Write up to `max` live ids (NULL to just count); returns total count. |

### I/O
| Function | Purpose |
|---|---|
| `int tmux_pty_fd(tmux_session *)` | Active pane's PTY master fd (-1 if none). Register with a `DispatchSource`/`kqueue` readability source. |
| `long tmux_pump(tmux_session *, int timeout_ms)` | Wait up to `timeout_ms` for PTY output, read one chunk, run it through the VT emulator. Returns bytes processed, 0 on timeout, -1 on error/EOF. |
| `long tmux_drain(tmux_session *)` | Drain all currently-available PTY output (non-blocking). Returns total bytes. Call this when your readability source fires. |
| `void tmux_feed(tmux_session *, const uint8_t *data, size_t len)` | Feed raw bytes straight into the VT emulator, bypassing the PTY (deterministic throughput / replay). |
| `long tmux_send(tmux_session *, const uint8_t *data, size_t len)` | Send keystrokes to the shell. Returns bytes written or -1. |
| `int tmux_resize(tmux_session *, uint16_t rows, uint16_t cols)` | Resize pane + PTY (sends SIGWINCH). 0 / -1. |
| `bool tmux_is_alive(tmux_session *)` | Shell process still alive. |

### Grid access (rendering)
| Function | Purpose |
|---|---|
| `void tmux_grid_size(tmux_session *, uint16_t *rows, uint16_t *cols)` | Active pane grid dimensions. |
| `size_t tmux_read_cells(tmux_session *, tmux_cell *out, size_t max_cells)` | Copy the grid (row-major, `row*cols+col`) into `out`; returns cells written. |
| `void tmux_cursor(tmux_session *, uint16_t *row, uint16_t *col, bool *visible)` | Cursor position + visibility. |

`tmux_cell` is a flat 16-byte struct (`sizeof`/`alignof` asserted by a Zig test):
`ch` (Unicode codepoint), `{fg,bg}_{kind,idx,r,g,b}` (kind = `TMUX_COLOR_*`),
`attrs` (`TMUX_ATTR_*` bitfield), `width` (1, or 2 for wide CJK glyphs).

### Window / pane control
| Function | Purpose |
|---|---|
| `int tmux_split(tmux_session *, int horizontal)` | Split active pane (≠0 = left/right), spawn a shell in the new pane. |
| `int tmux_new_window(tmux_session *)` | New window + shell, made active. |
| `int tmux_select_window(tmux_session *, uint8_t index)` | Switch active window. |
| `uint8_t tmux_window_count(tmux_session *)` | Window count. |
| `int tmux_focus_next_pane(tmux_session *)` | Cycle focus within the active window. |

---

## Typical host run loop

```
id = tmux_create(rows, cols, NULL, &id);
fd = tmux_pty_fd(s);
// register fd with DispatchSource(.read) — on fire:
//     tmux_drain(s);
//     n = tmux_read_cells(s, cells, rows*cols);
//     ... upload `cells` to the renderer ...
// on key event:    tmux_send(s, bytes, len);
// on view resize:  tmux_resize(s, rows, cols);
// on teardown:     tmux_destroy(s);
```

---

## Linking from Swift

### Xcode (bridging header)
1. Add `libterminal_mux.a` to *Build Phases → Link Binary With Libraries*.
2. *Build Settings → Header Search Paths* → the `include/` dir.
3. In the bridging header: `#import "terminal_mux.h"`.
4. Functions are then callable directly (`tmux_create(...)`, etc.).

### SwiftPM (system library target)
`Sources/CTerminalMux/module.modulemap`:
```
module CTerminalMux {
    header "terminal_mux.h"
    link "terminal_mux"
    export *
}
```
Add `unsafeFlags(["-L<path>/zig-out/lib","-I<path>/zig-out/include"])` (or vend a
`.xcframework`). Remember the repack step above before bundling the `.a`.

### Minimal Swift usage
```swift
import CTerminalMux

var id: UInt64 = 0
guard let s = tmux_create(40, 120, nil, &id) else { fatalError() }
defer { tmux_destroy(s) }

let cmd = "ls -la\n"
_ = cmd.withCString { tmux_send(s, $0, strlen($0)) }

// drive from a DispatchSource on tmux_pty_fd(s); on fire:
tmux_drain(s)
var cells = [tmux_cell](repeating: tmux_cell(), count: 40*120)
let n = tmux_read_cells(s, &cells, cells.count)   // upload to renderer
```

---

## Benchmark

```sh
zig build bench -Doptimize=ReleaseFast
```

Reports three things, all on a monotonic clock:

1. **emulator feed** — bytes/sec pushed straight through the VT parser into the
   grid (`tmux_feed`), the pure core hot path.
2. **pty ingest** — a shell emits 64 MiB (`yes | head -c`); throughput through
   the PTY + parser via `tmux_pump`.
3. **lifecycle** — `create`+`destroy` and `attach`+`detach` latency.

Indicative numbers (Apple Silicon, ReleaseFast):

```
[emulator feed]   ~40 MiB/s        (per-byte parser dispatch — the bottleneck)
[pty ingest]      ~20 MiB/s
[create+destroy]  ~80 ms/op        (forks + execs a real zsh, which sources rc files)
[attach+detach]   ~0.02 µs/op      (registry hash lookup)
```

> **Note on the emulator number.** ~40 MiB/s is the *existing* VT parser's
> ceiling — it dispatches one byte at a time (`parser.feed(byte)` +
> `applyAction` per byte). A production Apple-native terminal will want a
> SIMD/batched parser (Ghostty-class implementations hit GB/s). The C ABI and
> PTY plumbing are not the bottleneck; the benchmark exists precisely to make
> that visible. Treat the emulator-feed figure as the headline target to beat.
```
