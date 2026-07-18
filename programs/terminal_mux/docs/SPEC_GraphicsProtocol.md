# terminal_mux — inline graphics protocol (scope)

Goal: let programs draw real pixels in the embedded terminal — image previews,
plots, DOOM at full resolution — instead of the half-block approximation. The
emulator captures image data and placements; the host renderers (aiconductor
and CosmicDuck Metal views, the standalone ANSI renderer) paint them as a layer
over the glyph grid.

Status: **scoping** — no code yet. This doc is the decision-ready plan.

## What the terminal must do

A terminal graphics protocol has three jobs, and they're separable:

1. **Transmit** — receive pixel data (RGB/RGBA/PNG) over an escape sequence,
   decode it, and hold it in an image store keyed by an id.
2. **Place** — put an image (or a crop of it) at a cell position, with a size
   in cells and a z-order relative to the text. One image can have many
   placements.
3. **Lifecycle** — placements move when the grid scrolls, get erased when their
   cells are cleared, and are deleted on request or when the image is freed.

The cell grid is unchanged. Images are an **overlay indexed by grid position**,
not a new kind of cell — `tmux_cell` stays 16 bytes and the C ABI struct layout
is untouched (the repo rule about not breaking `CCell`/consumers holds).

## Which protocols

| Protocol | Transport | Verdict |
|---|---|---|
| **Kitty graphics** | APC (`ESC _ G …payload… ESC \`) | **Primary.** RGB/RGBA/PNG, id-keyed images, cell-addressed placements, crops, z-index, delete-by-id. GPU-native: upload once as a texture, place many times. What ghostty/kitty use. |
| **iTerm2 inline images** | OSC 1337 (`ESC ] 1337;File=…:base64 ST`) | **Phase 2, cheap.** One-shot "show this image here at this size." No ids/placements. Widely emitted by CLI tools (`imgcat`, matplotlib's iterm backend). Small addition once the image store exists. |
| **Sixel** | DCS (`ESC P q …bands… ESC \`) | **Optional / later.** Legacy, palette-indexed, 6-pixel bands, awkward to decode, but the widest *program* support (gnuplot, mpv, some TUIs). Only if a consumer needs it. |

Recommendation: **Kitty first** (most capable, and DOOM/plots/agent-output all
fit it cleanly), **iTerm2 second** (trivial once the store exists), **Sixel only
on demand**.

## Architecture

```
 bytes → parser → image store ───────────────► C ABI ──► host renderer
         (APC/    (id → decoded RGBA)                    (Metal: 2nd draw pass;
          OSC/    placements[] (id, crop,                 ANSI: half-block or skip)
          DCS)     cell x/y/w/h, z, gen)
```

### Phase-1 Kitty surface — EXPLICIT SUBSET (whitelist)

"Implement the Kitty protocol" is the instruction that makes an agent build the
animation subsystem. Phase 1 implements **exactly** this and nothing else:

- **Actions:** `a=t` (transmit only), `a=T` (transmit + place at cursor),
  `a=p` (place an already-transmitted image by id `i=`), `a=d` (delete —
  `d=i` by image id, `d=a` all). No `a=f`/`a=a` (animation), no `a=c` (compose).
- **Formats (`f=`):** `f=24` (RGB), `f=32` (RGBA), `f=100` (PNG, host-decoded).
  Reject others.
- **Transmission medium (`t=`):** `t=d` (direct, base64 in the escape) only.
  **No** `t=f`/`t=t`/`t=s` (file / temp-file / shared-memory) — those are file-
  system/IPC surface we don't want yet.
- **Chunking:** `m=1` continuation frames accumulated until `m=0` — required,
  because a single escape can't carry a big image.
- **Placement geometry:** `c=`/`r=` (size in cells), `i=` (id). Cursor-cell
  anchored.
- **Unknown keys: ignored-but-CONSUMED.** A real program emits keys we don't
  handle (`q=`, `X=`, `Y=`, `z=`…); the parser must skip them without wedging or
  misreading the payload. Never treat an unknown key as payload.
- **Everything else** (Unicode placeholders `U=1`, z-index stacking, unicode
  image cells, references) — **out of scope**, silently accepted-and-ignored.

### Parser (`src/parser.zig`)

The plumbing is already stubbed:
- **APC** (Kitty) currently hits `sos_pm_apc_string` which *ignores content*
  (`parser.zig:288-290`). Add an `apc_string` accumulation buffer (like the OSC
  buffer) and, on ST, emit an `apc_dispatch` action carrying the raw payload.
- **DCS** (Sixel) has `dcs_hook`/`dcs_put`/`dcs_unhook` actions that are already
  routed but no-op (`parser.zig:727-734`). Sixel would fill those in.
- **OSC** (iTerm2) already dispatches; add the `1337;File=` branch.

Payloads are large (a full-screen RGBA image is megabytes). The OSC/APC buffers
are fixed 2 KiB today — image transmission needs a **streaming/chunked
accumulator** (Kitty chunks with `m=1`; iTerm2 is one blob). This is the main
parser change: a heap-backed, size-bounded payload buffer the emulator owns,
distinct from the 2 KiB control buffer.

> **This is the one parser change with blast radius** — every byte flows through
> the state machine it touches. **Hard acceptance gate:** replay the existing
> regression fixtures — `vt_tier1_anchors.zig`, `tui_render_anchors.zig`, and the
> `tests/fixtures/*.bin` streams via `tui_diag` — through the modified parser and
> **diff the resulting grids. Zero change for every non-graphics stream.** The
> harness from the renderer work makes this nearly free, and it is the guard
> against the graphics feature regressing the terminal we just fixed. A byte that
> is not part of a well-formed APC/DCS/OSC-image sequence must reach the grid
> byte-identically to today.

### Image store + placements (`src/terminal.zig` or a new `src/graphics.zig`)

- `ImageStore`: `id → { width, height, pixels: []RGBA }`, decoded once. Bounded
  total bytes (evict LRU or refuse past a cap — a DoS guard, same spirit as the
  OSC length bound).
- `Placement`: `{ image_id, src_crop, anchor_line, col, cell_w, cell_h, z, gen }`.
  This is the part that decides whether the feature works or is a toy — images
  that don't scroll with content are useless for the real use cases (a plot in a
  REPL, an inline preview). **Design: anchor to an absolute line index, not a
  grid-relative row.** `anchor_line` is the scrollback-absolute line number the
  image's top sits on (the same monotonic numbering the scrollback ring already
  implies). Then:
  - **Scroll is O(1)** — the viewport-top line number moves; placements are not
    touched. The renderer resolves each placement's on-screen row at read time
    as `anchor_line − viewport_top_line`, which the render loop already iterates
    placements for. No per-scroll rescan. (A per-scroll rescan over the list
    would also be fine at realistic counts — dozens — but anchoring avoids it
    entirely and is simpler to reason about.)
  - **Scrolls off the top:** a placement dies when `anchor_line` drops below the
    oldest retained scrollback line (its content is gone from history) — evict
    it and free the image if no other placement references it.
- Erase (ED/EL) and overwrite of a covered cell invalidate the overlapping
  placement (bump `gen` so the renderer stops drawing it and releases the GPU
  texture — see the delete/VRAM note in the ABI section).

### Lifecycle failure modes — SPEC TESTS BEFORE CODE

These four are the engineering; everything else is plumbing. Each gets a unit
test against the emulator (Zig) before the feature is wired, plus a recorded-
stream anchor via `tui_diag`:

1. **Scroll off the top of scrollback.** Place an image, scroll past it beyond
   the scrollback depth → placement evicted, image freed (no other ref),
   generation bumped. Assert the placement count returns to 0 and the image
   store shrank.
2. **Partial viewport clip.** An image whose cell rect extends above the top row
   or below the bottom row → the ABI reports the *clipped* on-screen rect (and
   the src crop the host should sample), never negative/out-of-bounds cells.
3. **Resize / reflow under a placement.** Grid resize (cols and rows) with a
   live placement → the placement's cell size is unchanged (images are sized in
   cells at place-time, not reflowed), its anchor_line survives, and its
   on-screen position recomputes against the new geometry. Assert no crash and a
   sane clipped rect at the new size.
4. **Alt-screen switch (the one that bites the DOOM demo).** Placements are
   stored **per-screen**, riding the same swap as the grid: entering the alt
   screen swaps to a fresh (empty) alt placement set; exiting **discards** the
   alt placements and restores the primary set byte-for-byte. DOOM runs in the
   alt screen — its per-frame placements must **never** leak back to the primary
   screen. Assert: place on primary, enter alt, place there, exit alt → primary
   sees only its original placement, alt placements gone and their images freed.

### Decoding — DECISION LOCKED: host-side

The emulator stays a **byte-pipe + geometry tracker**. It stores the raw
transmitted bytes + a format tag (`0=RGBA, 1=RGB, 2=PNG, 3=iterm-blob`); it does
**not** decode. The C ABI hands the host the original bytes; the host decodes
(`CGImageSource` on Apple — hardware-accelerated, already in every host process,
covers every format Kitty's `f=100` carries).

Why this is right *for this codebase specifically*: decoding PNG in Zig means
either vendoring a decoder (a dependency + attack surface + maintenance the
dependency-free core exists to avoid) or shipping raw pixels through the ABI
anyway. The standalone/ANSI consumer also can't *use* decoded pixels, so forcing
a decode obligation into the core taxes a consumer that gets nothing for it.

**Consequence to accept knowingly (do NOT "fix" later by moving decode into the
core):** the ABI hands over *compressed* bytes + a format tag, so **every
consumer must decode**. A future non-Apple consumer (e.g. a Linux host — one
already pushes to this origin) needs its own decoder (libpng/stb/zig-png of its
choosing). That is the correct trade: the core stays portable and dependency-
free; decode lives where the platform already has an accelerated decoder.

RGBA/RGB need no decode anywhere — the standalone ANSI renderer supports those
directly (half-block downsample), PNG only where a host decoder exists.

### C ABI additions (`src/capi.zig`, `include/terminal_mux.h`)

New calls, all additive (no existing symbol/struct changes):

```c
// How many placements are visible in the active pane right now.
size_t   tmux_placement_count(tmux_session *h);
// Geometry + image handle for placement idx (cell coords within the pane).
int      tmux_placement_at(tmux_session *h, size_t idx, tmux_placement *out);
// The image bytes for a handle (format tag: 0=RGBA,1=RGB,2=PNG,3=iterm-blob).
size_t   tmux_image_data(tmux_session *h, uint32_t image_id,
                         uint8_t *out, size_t max, tmux_image_info *info);
// Monotonic counter; bumps when placements/images change, so the host only
// re-uploads textures when something actually moved (cheap idle path).
uint64_t tmux_graphics_generation(tmux_session *h);
```

`tmux_placement` = `{ image_id, cell_x, cell_y, cell_w, cell_h, src_x, src_y,
src_w, src_h, z }` — a new extern struct, additive.

**Freed-image signalling (the VRAM-leak guard — required for the DOOM demo).**
DOOM transmits one image per frame at ~35 fps and deletes the previous, so the
host uploads a texture per frame. If `a=d` only does emulator-side bookkeeping,
the host never learns to `release()` the `MTLTexture` and leaks VRAM at 35
textures/sec. So the ABI must let the host reclaim GPU memory:

```c
// Image ids freed since the last call (a=d, eviction, or overwrite), so the
// host can drop the matching MTLTextures. Read-and-clear, like tmux_take_bell.
size_t tmux_take_freed_images(tmux_session *h, uint32_t *out_ids, size_t max);
```

The host's per-image `MTLTexture` cache is keyed by `image_id`; every id from
`tmux_take_freed_images` releases its entry. This closes the transmit-per-frame
loop: place → upload → delete → free, steady-state VRAM. (`tmux_graphics_
generation` tells the host *something* changed; `tmux_take_freed_images` tells it
*what to release* — both are needed.)

### Host renderer (Metal — `MetalTerminalView.swift`)

The draw path today is one instanced glyph-quad pass
(`drawPrimitives … instanceCount: count`, `MetalTerminalView.swift:529`). Add:

1. After the frame's cells are composed, read placements via the new ABI. On a
   `tmux_graphics_generation` change, upload each referenced image as an
   `MTLTexture` (cache by image_id; decode PNG with `CGImageSource`).
2. A **second draw pass** before `endEncoding`: for each placement, one textured
   quad at its cell rect (pixel rect = cell rect × cellPx), sampled from the
   image texture's crop. Z-order: placements with z<0 draw before glyphs, z≥0
   after. A tiny second pipeline (`image_vertex`/`image_fragment` in the
   `.metal` file) — passthrough UV + sample.
3. Cells covered by a z≥0 placement should skip their glyph (or the image just
   paints over them — simpler, and matches Kitty's model).

The frame-ring + semaphore already in place (the static-fix work) covers the
image textures too, as long as texture uploads happen before the encoder for
that frame.

### Standalone ANSI renderer (`src/render.zig`)

Can't paint true pixels to a host terminal it doesn't own. Two honest options:
(a) **downsample to half-blocks** (reuse zig_doom's exact technique — `▀` with
fg=top, bg=bottom) so images at least appear; (b) draw a placeholder box. Half-
block is the better story and it's a known quantity in this codebase.

## DOOM as the proof

zig_doom's TUI backend already emits `▀` half-blocks — it renders in the
embedded terminal *today* (and the recent vector block-element fix made those
crisp). With the Kitty path, zig_doom could instead transmit its 320×200 RGBA
framebuffer each frame as a single placement at (0,0) — **full-resolution DOOM
in the embedded terminal**, no half-block quantization. That's the end-to-end
acceptance demo: `zig_doom --graphics kitty` piped into an aiconductor pane.

## Phasing

| Phase | Deliverable | Gate |
|---|---|---|
| 1 | APC parser (Kitty subset whitelist above) + streaming payload buffer + image store (RGBA/RGB only) + line-anchored placements surviving scroll/erase/resize/alt-screen; C ABI incl. `tmux_take_freed_images`; Metal 2nd pass | (a) the 4 lifecycle failure-mode tests pass; (b) **parser regression-diff gate**: existing fixtures replay grid-identical; (c) a transmitted RGBA image displays at a cell, scrolls with text, deletes by id, and its texture is released — recorded-stream test through `tui_diag` |
| 2 | iTerm2 OSC 1337 (host-side decode) + PNG via `CGImageSource` | `imgcat`-style blob renders |
| 3 | zig_doom `--graphics kitty` backend → full-res DOOM demo | frame streams into an aiconductor pane at steady-state VRAM (transmit+delete per frame frees textures) |
| 4 (opt) | Sixel DCS decode; standalone half-block downsample | only if a consumer needs Sixel |

**Sixel:** left unbuilt until something actually run emits it — it's the most
parser work (palette, 6-pixel bands, run-length) for the least modern payoff.

## Risks / decisions to lock first

- **Memory bound.** Images are big; the store needs a hard cap + eviction (DoS
  guard). Decide the cap (e.g. 64 MiB/pane) before Phase 1.
- **Scroll semantics.** Placements-track-logical-rows is the one genuinely
  tricky bit; it must be unit-tested against the ring `row_offset` scroll the
  same way the cell grid is.
- **Decode location.** Recommend host-side (keeps the emulator dependency-free);
  the emulator stays a byte pipe + geometry tracker. Lock this — it shapes the
  ABI (hand over bytes+format, not decoded pixels).
- **FFI discipline.** All additions are new symbols/structs; zero changes to
  `CCell`/`CTheme`/existing calls, so both Swift consumers keep building. New
  calls are opt-in — a consumer that ignores them renders exactly as today.

## Not in scope

Animation (Kitty `a=a`), Unicode placeholders (`U+10EEEE` image cells),
image-to-image references, and remote/file transmission media (`t=f`/`t=t`) —
all deferrable; Phase 1 is direct RGBA transmit + place + scroll + delete.
