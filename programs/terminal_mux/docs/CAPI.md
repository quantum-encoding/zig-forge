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

### macOS ONLY: repack the archive before linking from Xcode/clang

Zig 0.16 emits Mach-O archive members with 2-byte alignment; Apple's `ld`
requires 8-byte and otherwise fails with *"not 8-byte aligned"*. After every
rebuild, repack:

```sh
../../scripts/repack-for-xcode.sh zig-out/lib/libterminal_mux.a
```

(`repack-for-xcode.sh` runs `libtool -static` to realign the members. This is a
repo-wide requirement for all native Zig static libs consumed by Xcode — see the
root `CLAUDE.md`.)

**Linux needs no repack.** The alignment constraint is specific to Apple's
Mach-O `ld`; on Linux the archive is plain ELF `ar` and links as emitted —
`cc app.c -Iinclude zig-out/lib/libterminal_mux.a` works directly with GNU
`ld`/`lld` (verified against a C consumer calling `zterm_version()`).

---

## Concept: in-process attach / detach

A session created with `zterm_create` is registered under a `uint64_t` id and
keeps running — its shell stays alive, its grid stays intact — until
`zterm_destroy`. `zterm_detach` releases the caller's logical hold without tearing
anything down; `zterm_attach(id)` re-acquires the handle. This is the embedded
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
| `const char *zterm_version(void)` | Library version string. |
| `zterm_session *zterm_create(uint16_t rows, uint16_t cols, const char *shell, uint64_t *out_id)` | Allocate a `rows`×`cols` terminal and spawn `shell` (NULL → `$SHELL`, else `/bin/zsh` on macOS) in its first pane. Writes the new id to `out_id` if non-NULL. 0 rows/cols default to 24/80. |
| `zterm_session *zterm_attach(uint64_t id)` | Re-acquire a live session by id; NULL if not found. |
| `void zterm_detach(zterm_session *)` | Release the logical hold; session keeps running. |
| `void zterm_destroy(zterm_session *)` | Kill the shell, free the terminal, unregister. Handle invalid afterward. |
| `uint64_t zterm_id(zterm_session *)` | The session's registry id. |
| `bool zterm_is_attached(zterm_session *)` | Attached (true) vs detached. |
| `size_t zterm_list(uint64_t *out_ids, size_t max)` | Write up to `max` live ids (NULL to just count); returns total count. |

### I/O
| Function | Purpose |
|---|---|
| `int zterm_pty_fd(zterm_session *)` | Active pane's PTY master fd (-1 if none). Register with a `DispatchSource`/`kqueue` readability source. |
| `long zterm_pump(zterm_session *, int timeout_ms)` | Wait up to `timeout_ms` for PTY output, read one chunk, run it through the VT emulator. Returns bytes processed, 0 on timeout, -1 on error/EOF. |
| `long zterm_drain(zterm_session *)` | Drain all currently-available PTY output (non-blocking). Returns total bytes. Call this when your readability source fires. |
| `void zterm_feed(zterm_session *, const uint8_t *data, size_t len)` | Feed raw bytes straight into the VT emulator, bypassing the PTY (deterministic throughput / replay). |
| `long zterm_send(zterm_session *, const uint8_t *data, size_t len)` | Send keystrokes to the shell. Returns bytes written or -1. |
| `int zterm_resize(zterm_session *, uint16_t rows, uint16_t cols)` | Resize pane + PTY (sends SIGWINCH). 0 / -1. |
| `bool zterm_is_alive(zterm_session *)` | Shell process still alive. |

### Grid access (rendering)
| Function | Purpose |
|---|---|
| `void zterm_grid_size(zterm_session *, uint16_t *rows, uint16_t *cols)` | Active pane grid dimensions. |
| `size_t zterm_read_cells(zterm_session *, zterm_cell *out, size_t max_cells)` | Copy the grid (row-major, `row*cols+col`) into `out`; returns cells written. |
| `void zterm_cursor(zterm_session *, uint16_t *row, uint16_t *col, bool *visible)` | Cursor position + visibility. |

`zterm_cell` is a flat 16-byte struct (`sizeof`/`alignof` asserted by a Zig test):
`ch` (Unicode codepoint), `{fg,bg}_{kind,idx,r,g,b}` (kind = `ZTERM_COLOR_*`),
`attrs` (`ZTERM_ATTR_*` bitfield), `width` (1, or 2 for wide CJK glyphs).

### Window / pane control
| Function | Purpose |
|---|---|
| `int zterm_split(zterm_session *, int horizontal)` | Split active pane (≠0 = left/right), spawn a shell in the new pane. |
| `int zterm_new_window(zterm_session *)` | New window + shell, made active. |
| `int zterm_select_window(zterm_session *, uint8_t index)` | Switch active window. |
| `uint8_t zterm_window_count(zterm_session *)` | Window count. |
| `int zterm_focus_next_pane(zterm_session *)` | Cycle focus within the active window. |

---

## Typical host run loop

```
id = zterm_create(rows, cols, NULL, &id);
fd = zterm_pty_fd(s);
// register fd with DispatchSource(.read) — on fire:
//     zterm_drain(s);
//     n = zterm_read_cells(s, cells, rows*cols);
//     ... upload `cells` to the renderer ...
// on key event:    zterm_send(s, bytes, len);
// on view resize:  zterm_resize(s, rows, cols);
// on teardown:     zterm_destroy(s);
```

---

## Linking from Swift

### Xcode (bridging header)
1. Add `libterminal_mux.a` to *Build Phases → Link Binary With Libraries*.
2. *Build Settings → Header Search Paths* → the `include/` dir.
3. In the bridging header: `#import "terminal_mux.h"`.
4. Functions are then callable directly (`zterm_create(...)`, etc.).

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
guard let s = zterm_create(40, 120, nil, &id) else { fatalError() }
defer { zterm_destroy(s) }

let cmd = "ls -la\n"
_ = cmd.withCString { zterm_send(s, $0, strlen($0)) }

// drive from a DispatchSource on zterm_pty_fd(s); on fire:
zterm_drain(s)
var cells = [zterm_cell](repeating: zterm_cell(), count: 40*120)
let n = zterm_read_cells(s, &cells, cells.count)   // upload to renderer
```

---

## Benchmark

```sh
zig build bench -Doptimize=ReleaseFast
```

Reports throughput on a monotonic clock:

1. **emulator mixed** — SGR-heavy synthetic stream (lots of `ESC[...m`); most
   bytes go through the scalar CSI state machine. The pessimistic case.
2. **emulator plain** — long printable lines (`cat`/logs/code shape); exercises
   the SIMD fast path. The optimistic case.
3. **pty ingest** — a shell emits 64 MiB (`yes | head -c`); end-to-end through
   the PTY + parser via `zterm_pump`.
4. **lifecycle** — `create`+`destroy` and `attach`+`detach` latency.

Indicative numbers (Apple Silicon, ReleaseFast):

```
[emulator mixed]  ~127 MiB/s
[emulator plain]  ~196 MiB/s
[pty ingest]      ~64 MiB/s
[attach+detach]   ~0.02 µs/op   (registry hash lookup)
```

### Parser/terminal optimizations (vs. the original ~42 MiB/s)

The hot path was lifted ~3× (mixed) / ~4.7× (plain text):

- **SIMD ASCII fast path** (`Pane.processOutput`): while the parser is in ground
  state, input is swept in 16-byte `@Vector(16, u8)` chunks. A chunk that is
  entirely printable ASCII (`0x20..0x7E`) bypasses the state machine and is
  bulk-written to the grid via `Terminal.putPrintableRun` (autowrap-aware). Any
  control/non-ASCII byte drops to the scalar parser for that byte, then the
  sweep resumes.
- **O(1) circular scroll** (`Grid`): rows live in a ring indexed by `row_offset`
  (`physRow` = one conditional subtract, no division). A full-screen scroll is a
  pointer bump + clearing the newly exposed rows — no row memcpy. Sub-region
  scrolls still shift via contiguous per-row copies.
- **Zero heap allocations on the PTY path**: CSI params are a fixed `[16]u16`;
  scrollback is a single preallocated flat ring (`Scrollback`) whose `push`
  copies a scrolled-off row into the next slot with no allocator call. The old
  per-scroll `alloc` is gone.

The remaining ceiling is memory bandwidth on 16-byte `Cell` writes (plain feed
moves ~3 GB/s of cells), not dispatch — so the next lever, if needed, is a
narrower `Cell` or a vectorized template splat, not parser restructuring.
```
