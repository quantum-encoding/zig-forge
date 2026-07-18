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
accumulator** (Kitty already chunks with `m=1` continuation frames; iTerm2 is
one blob). This is the main parser change: a heap-backed, size-bounded payload
buffer that the emulator owns, distinct from the 2 KiB control buffer.

### Image store + placements (`src/terminal.zig` or a new `src/graphics.zig`)

- `ImageStore`: `id → { width, height, pixels: []RGBA }`, decoded once. Bounded
  total bytes (evict LRU or refuse past a cap — a DoS guard, same spirit as the
  OSC length bound).
- `Placement`: `{ image_id, src_crop, cell_x, cell_y, cell_w, cell_h, z, gen }`.
  Stored per-pane. Cell coordinates are **logical grid rows**, so they ride the
  ring-buffer scroll: on `scrollUp`, placements shift up and any that leave the
  top go to scrollback-or-evict, exactly like cells. This is the subtle part —
  the O(1) `row_offset` ring scroll (`terminal.zig:212`) means placements track
  *logical* rows and get resolved to physical position at read time.
- Erase (ED/EL) and overwrite of a covered cell invalidate the overlapping
  placement (bump `gen` so the renderer knows to stop drawing it).

### Decoding

- RGBA/RGB: trivial, no dependency.
- **PNG**: needs a decoder. Options: (a) a small in-tree Zig PNG decoder
  (miniz-style inflate + PNG chunks — a few hundred lines, no external dep, fits
  the repo's "pure stdlib + libc" posture); (b) decode host-side in Swift
  (`NSImage`/`CGImageSource`) and keep the emulator format-agnostic (it stores
  the raw transmitted bytes + a format tag, the host decodes). **(b) is less
  work and keeps the emulator dependency-free** — the C ABI hands the host the
  original bytes + format; the Metal view already has CoreGraphics. The
  standalone ANSI renderer would then only support raw RGB(A), which is fine.

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
| 1 | APC parser + streaming payload buffer + image store (RGBA/RGB only) + placements that survive scroll/erase; C ABI; Metal 2nd pass | a transmitted RGBA image displays at a cell, scrolls with the text, and is deleted by id — anchored by a recorded byte-stream test through `tui_diag` |
| 2 | iTerm2 OSC 1337 (host-side decode) + PNG via `CGImageSource` | `imgcat`-style blob renders |
| 3 | zig_doom `--graphics kitty` backend → full-res DOOM demo | frame streams into an aiconductor pane |
| 4 (opt) | Sixel DCS decode; standalone half-block downsample | only if a consumer needs Sixel |

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
