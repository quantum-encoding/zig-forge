# zterm view protocol, v1

The wire form of the render contract a front end needs to draw a pane that a
`zterm server` owns: grid state out, input in, on one connection. It is the
same contract the in-process C ABI (`src/capi.zig`, `include/terminal_mux.h`)
gives the Swift/Metal host — cells, cursor, modes, title, bell, clipboard —
carried over the socket so the shells live in the server and survive the
front end.

`zterm attach` is a client of this protocol (it renders to a host terminal
with ANSI, in truecolour from the server's theme — not the host's palette). A GUI front end renders the same frames to pixels.

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

`"watch":true` opens a **watch-only** view, for a dashboard that draws a
pane without driving it: it receives `hello`, frames, `marks`, `bell`,
`clipboard` and `exit` like any viewer, and may send `history`, but
`rows`/`cols` on the request are ignored (it never resizes the pane), its
`input`, `focus` and `resize` messages are dropped, and it is **not counted**
in `list`'s `viewers` — so "nobody is viewing this pane" stays true for a
front end deciding whether to take it over. A server older than this ignores
the key and treats the connection as an ordinary viewer.

If the pane does not exist the server answers
`{"t":"error","error":"no such pane"}` and closes.

### Spawning a pane with its own environment

`{"cmd":"spawn"}` takes an optional `env` object — variables for **that
pane's shell only** (the server's own environment and other panes are
untouched), each replacing an inherited variable of the same name:

```json
{"cmd":"spawn","name":"term-1a2b","cwd":"/home/me/src",
 "env":{"ZDOTDIR":"/run/user/1000/rust_gui-shell-integration","DUCK_REAL_ZDOTDIR":""}}
```

At most 32 variables; keys `[A-Z_][A-Z0-9_]*`, 1–64 bytes, and never
`ZTERM_PANE` (the server sets it) or `WEZTERM_PANE`; values strings of at
most 4096 bytes with no NUL. Anything else refuses the whole spawn with
`{"ok":false,"error":"…"}`. This is how a front end turns shell
integration (and so `marks`) on for the panes it spawns.

### Reattaching after a restart

Panes outlive their viewers: closing a view connection never kills the pane.
A front end that wants its panes back after it restarts spawns them with a
stable `name` it can derive again (`{"cmd":"spawn","name":…}`), and on start
reads `{"cmd":"list"}`: each entry carries `name`, `alive` and `viewers` — the
number of clients drawing that pane right now (view connections plus raw
`zterm attach`es; watch-only views are not counted). Take over a named pane only when it is `alive` and
`viewers` is 0, so two windows never drive one pane; a dead one is `kill`ed
and respawned. The screen arrives in the first `full` frame; ask for
`history` to refill scrollback.

## Server → client

### `hello` — once, first

```json
{"t":"hello","v":1,"pane":1,
 "theme":{"fg":"#d9dbe0","bg":"#121217","cursor":"#f5e0dc","cursor_text":"#121217",
          "bold_is_bright":true,"palette":["#000000", "…256 entries…"]}}
```

**The theme is authoritative.** Every colour on the wire resolves through it:
an absent `fg`/`bg` is the theme's `fg`/`bg`; a palette index `n` is
`palette[n]` (all 256 entries, resolved — 0–15 themed, 16–255 the xterm
cube and grey ramp); with `bold_is_bright`, a bold cell in colours 0–7 is
drawn with 8–15. It is the same theme zterm answers OSC 10/11 from, so a
client draws exactly the colours the application was told — and every client
of a pane draws the same colours. A client never substitutes its own palette.

**Inverse** (`a` bit 32) swaps the RESOLVED foreground and background —
including when either is absent (the theme default). The theme is what makes
that computable.

### `palette` — the theme changed

```json
{"t":"palette","pane":1,"theme":{…same shape as in hello…}}
```

Sent when the theme changes while the connection is open. Keys present
replace the client's copy; absent keys are unchanged. The client redraws.
(`zterm server` loads its theme once at start today, so it does not yet send
this; clients must still accept it.)

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
| `text` | UTF-8 text: a sequence of Unicode **code points**, one per cell (see "Cells" below) |
| `w`    | `2`: EVERY code point in `text` occupies two columns (CJK, most emoji) — the i-th one covers columns `x+2i` and `x+2i+1`, so a run of CJK is one span. Absent: every code point occupies one column. A span never mixes widths. |
| `fg`, `bg` | absent = the theme default; a number 0–255 = palette index (resolved through `hello`'s theme); a string `"#rrggbb"` = truecolour |
| `a`    | attribute bits, absent = none: 1 bold · 2 dim · 4 italic · 8 underline · 16 blink · 32 inverse · 64 invisible · 128 strikethrough |
| `u`    | *Reserved, not sent yet.* Underline style when underlined: `"single"`, `"double"`, `"curly"`, `"dotted"`, `"dashed"` (SGR 4:1–4:5). Absent with bit 8 set = single. |
| `uc`   | *Reserved, not sent yet.* Underline colour (SGR 58), same encoding as `fg`. Absent = the text colour. |
| `link` | *Reserved, not sent yet.* OSC 8 hyperlink target (a URL string) for the span's cells. |

Keys a client does not know are ignored, so the reserved keys can start
appearing without a version bump; a client that ignores them still draws a
correct (plainer) screen.

**Cells.** One cell holds exactly one code point — never a grapheme cluster.
zterm drops zero-width code points as it parses (combining marks, ZWJ/ZWNJ,
variation selectors), so no span contains a code point that occupies zero
columns: a client iterates code points, never graphemes, and never needs a
width table. The cost, stated plainly: `e` + U+0301 arrives as `e`, and a
ZWJ emoji sequence arrives as its separate emoji.

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
to honour it. `b64` is the base64 the application wrote (its `Pd`), always
base64 text, so a client may pass it straight to its own terminal's OSC 52.
Writes over 128 KiB of base64 are dropped by the server, never truncated. After `exit` no further frames arrive; the last frame is the
pane's final screen, and the server keeps the connection open until the client
closes it. `code`/`signal` are the child's real status, or `null` when it
could not be read (the child closed its terminal but kept running for more
than 2 s). `killed: true` means the pane was killed (`kill`, runner `stop`);
the server then closes the connection itself.

### `history` — reply to a `history` request

```json
{"t":"history","pane":1,"from":1200,"count":100,
 "lines":[{"n":1200,"spans":[...]},{"n":1201,"spans":[...]}],
 "marks":[{"n":1200,"k":"A"},{"n":1201,"k":"C"}]}
```

`n` is the absolute line number. Lines no longer held are omitted. `count`
echoes the request (clamped to 5000). `marks` are the OSC 133 marks the
server holds on lines `[from, from+count)` (see `marks` below): a client
replaces its own marks on those lines with them, so refilled scrollback gets
its command blocks back.

### `marks` — shell-integration marks (OSC 133)

```json
{"t":"marks","pane":1,"from":1200,
 "marks":[{"n":1200,"k":"A"},{"n":1200,"k":"B"},{"n":1201,"k":"C"},
          {"n":1240,"k":"D","exit":0},{"n":1240,"k":"A"}]}
```

zterm records the semantic-prompt marks a shell with integration prints
(`OSC 133 ; A|B|C|D[;exit] ST`, BEL or ST terminated; options after the
letter are ignored): `A` a prompt starts, `B` the command line starts, `C`
the command's output starts, `D` it finished, with `exit` when the shell
reported a status. Each mark sits on the absolute line (`n`, the numbering
of `live_top`/`history`) the cursor was on, on the **primary** screen only.
Marks are ordered by `n`, and on one line in the order they were written.

**One rule for every message: replace everything from `from` down.** The
client drops each mark it holds with `n >= from`, then adds the ones in the
message (all have `n >= from`). That one shape carries:

- **the whole set** — sent ahead of the first frame on every view, and again
  whenever the server discarded a backlog (see "Backpressure"). `from` is
  the oldest primary line held; it may be `[]`.
- **a change** — sent ahead of the next frame after a mark was written:
  `from` is the lowest line whose marks changed, and the message carries
  every mark from there on (usually one or two).

A mark written above marks already held means the screen was rewritten
there (`clear`, a redraw from the top): the server drops the marks on later
lines, and an earlier mark of the same kind on that line with what followed
it on the line. The tail replacement tells the client.

Marks go when the lines they sit on leave the server's scrollback, or it is
cleared (`ED 3`); no message says so — a client may drop marks below a
frame's `oldest`, or keep them for scrollback it holds itself. The server
keeps at most 4096. Building command blocks is the client's: a block runs
from an `A` to the line before the next `A`, its output from the `C`, its
status from the `D`.

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

Frames are also paced: at most one per client every `--frame-ms` (default
8 ms, ~120 Hz). The first frame after input, a focus change or a resize
reaches the pane is never held, nor is the first change after a quiet spell;
other changes inside the interval go out together in the next frame. A client must not assume one frame per write the
application made — only that the last frame shows the pane's current state.

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
