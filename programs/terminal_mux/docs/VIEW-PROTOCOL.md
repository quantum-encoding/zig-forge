# zterm view protocol, v1

The wire form of the render contract a front end needs to draw a pane that a
`zterm server` owns: grid state out, input in, on one connection. It is the
same contract the in-process C ABI (`src/capi.zig`, `include/terminal_mux.h`)
gives the Swift/Metal host — cells, cursor, modes, title, bell, clipboard —
carried over the socket so the shells live in the server and survive the
front end.

`zterm attach` is a client of this protocol (it renders to a host terminal
with ANSI). A GUI front end renders the same frames to pixels.

**There is exactly one terminal emulator: zterm's.** A client never parses
VT sequences from the pane, never answers terminal queries (DA, CPR, OSC
10/11 — the server answers them), and never computes character widths — each
cell arrives with its width.

## Connection

Connect to the server's unix socket (the control socket `$ZTERM_SOCKET`, or
the baton runner door `<fleet home>/var/zterm.sock` — both accept every
request shape). Send one line:

```json
{"cmd":"view","pane":1,"rows":40,"cols":120}
```

`pane` is zterm's own pane id (`zterm cli list`) — not the 1000000+n form
baton uses to keep zterm and WezTerm pane numbers apart.

`rows`/`cols` are optional; when given, the pane is resized to them (see
"Size" below). The connection then stays open in both directions. Every
message either way is **one JSON object followed by `\n`**. Unknown message
types and unknown keys MUST be ignored (additive evolution without a version
bump). A breaking change bumps `v`.

If the pane does not exist the server answers
`{"t":"error","error":"no such pane"}` and closes.

## Server → client

### `hello` — once, first

```json
{"t":"hello","v":1,"pane":1}
```

### `frame` — the pane's state

```json
{"t":"frame","pane":1,"seq":7,"full":false,
 "rows":40,"cols":120,"live_top":1234,"oldest":230,
 "lines":[{"y":3,"spans":[{"x":0,"text":"$ ls","fg":2,"a":1}]}],
 "cursor":{"x":4,"y":3,"visible":true,"shape":0,"blink":true},
 "modes":{"app_cursor":false,"bracketed_paste":true,"alt_screen":false,
          "mouse":"none","mouse_sgr":false,"focus":false},
 "title":"zsh"}
```

- `seq` increases by one per frame on this connection.
- `full: true` — `lines` holds **every** row; clear everything first. Sent
  first, after any resize, after the alternate screen switches, and whenever
  the server could not deliver incremental frames (see "Backpressure").
- `full: false` — `lines` holds only rows that changed; all other rows are
  unchanged. `lines` may be empty when only the cursor, modes or title moved.
- Each entry in `lines` describes its row **completely**: draw its spans and
  clear the rest of the row to the default background.
- `rows`, `cols`, `cursor`, `modes` and `title` are present in every frame
  (they are small; a client need not diff them).
- `live_top` is the absolute line number of grid row 0, `oldest` the oldest
  history line still held (see `history`). On the alternate screen
  `oldest == live_top` (no history).
- Frames are never sent mid-way through an application's synchronized update
  (DEC mode 2026): the server holds the frame until the block closes, or 250
  ms pass.

**Spans.** A row is a list of spans, each placed at column `x`:

| key    | meaning |
|--------|---------|
| `x`    | start column (0-based) |
| `text` | UTF-8 text |
| `w`    | `2` for a wide cell (CJK, most emoji): the span is ONE character occupying columns `x` and `x+1`. Absent: every character in `text` is one column wide. |
| `fg`, `bg` | absent = default colour; a number 0–255 = palette index; a string `"#rrggbb"` = truecolour |
| `a`    | attribute bits, absent = none: 1 bold · 2 dim · 4 italic · 8 underline · 16 blink · 32 inverse · 64 invisible · 128 strikethrough |

Columns not covered by any span are blank with the default background.
Trailing blanks are omitted. A client places each span at its `x` — never at
"wherever the previous span ended" — so a font whose width table disagrees
with zterm's cannot shift the rest of the row.

**Cursor.** `x`,`y` are grid coordinates. `visible` is false when the
application hid it. `shape`: `"block"`, `"underline"` or `"bar"`; `blink` as
the application asked (DECSCUSR sets both).

**Modes.** What the application asked of its terminal, so the client encodes
input the way the application expects:

- `app_cursor` — arrows are sent `ESC O A`… instead of `ESC [ A`…
- `bracketed_paste` — informational; the server brackets `paste` input itself.
- `mouse` — `"none"`, `"x10"` (press only), `"normal"` (press/release),
  `"button"` (+ drag with a button held), `"any"` (all motion). Send mouse
  input only when not `"none"`.
- `mouse_sgr` — informational; the server encodes `mouse` input itself.
- `focus` — the application wants focus in/out events (send `focus`).

### `bell`, `clipboard`, `exit`

```json
{"t":"bell","pane":1}
{"t":"clipboard","pane":1,"b64":"aGVsbG8="}
{"t":"exit","pane":1,"code":0,"signal":0}
{"t":"exit","pane":1,"killed":true}
```

`clipboard` is an OSC 52 write by the application; the client decides whether
to honour it. After `exit` no further frames arrive; the last frame is the
pane's final screen, and the server keeps the connection open until the client
closes it. `code`/`signal` are the child's real status, or `null` when it
could not be read (the child closed its terminal but kept running for more
than 2 s). `killed: true` means the pane was killed (`kill`, runner `stop`);
the server then closes the connection itself.

### `history` — reply to a `history` request

```json
{"t":"history","pane":1,"from":1200,
 "lines":[{"n":1200,"spans":[...]},{"n":1201,"spans":[...]}]}
```

`n` is the absolute line number. Lines no longer held are omitted.

## Client → server

```json
{"input":"text","data":"ls\r"}
{"input":"bytes","b64":"G1tB"}
{"input":"paste","data":"multi\nline"}
{"input":"mouse","kind":"press","button":0,"x":10,"y":4,"mods":0}
{"focus":true}
{"resize":{"rows":50,"cols":160}}
{"history":{"from":1200,"count":100}}
```

- `text` — UTF-8 written to the pane as typed input. Keys are the client's to
  encode, using `modes.app_cursor`. `bytes` carries the same thing as base64
  for input that is not UTF-8.
- `paste` — the server wraps it in `ESC[200~ … ESC[201~` when the application
  enabled bracketed paste, and never lets the text end the bracket early.
- `mouse` — `kind`: `"press"`, `"release"`, `"motion"`; `button`: 0 left ·
  1 middle · 2 right · 64 wheel up · 65 wheel down; `mods`: 4 shift · 8 alt ·
  16 ctrl; `x`,`y` grid coordinates. The server encodes it for whichever mouse
  protocol the application enabled, and drops it when mouse mode is off.
- `focus` — sent to the application (`ESC[I` / `ESC[O`) only if it asked.
- `resize` — see "Size".
- `history` — `count` lines starting at absolute line `from`.

## Size

A pane has one size. The most recent `view` (with `rows`/`cols`) or `resize`
from any client sets it; every client viewing the pane then receives a `full`
frame at the new size. A client whose window is larger than the pane draws the
pane at the top-left and leaves the rest blank.

## Backpressure

The server never blocks on a client and never drops one for being slow. It
sends a frame only when the previous frame has been fully written; changes
made meanwhile accumulate and go out together in the next frame. A client
that has fallen far behind (its unsent output exceeds the server's buffer)
gets a `full` frame when it catches up. State converges; intermediate frames
may be skipped.

## What the server does that a client must not

- Answer terminal queries (DA1/DA2, CPR, OSC 10/11 colour queries).
- Emulate: parse VT, keep the grid, compute widths.
- Encode mouse reports and bracket pastes.

## Compatibility

- The pre-v1 raw `attach <pane> [rows cols]` line request still works (a
  byte-for-byte relay for clients that emulate themselves). While a raw
  attach is open on a pane, **that client's terminal** answers terminal
  queries and the server does not, so a query is never answered twice.
- `capture` stays the one-shot text read (`{"cmd":"capture","escapes":true}`).
