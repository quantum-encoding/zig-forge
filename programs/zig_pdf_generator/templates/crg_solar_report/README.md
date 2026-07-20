# CRG Solar Proposal — faithful 20-page reproduction

A pixel-faithful reproduction of CRG Direct's genuine solar proposal
(`crgdirect.co.uk/example-solar-proposal.pdf`, originally rendered by dompdf
2.0.1) built with the in-tree **`presentation`** (canvas) renderer of
`zig_pdf_generator`.

Unlike the other `crg_*.json` templates here — which use the flowing
`clean_quote`/`proposal_legacy` "sections" schema and can only produce a single
branded quote page — this one uses the absolute-positioned canvas so it can
match the real report: a full-bleed cover, embedded datasheet images, grey/blue
shaded multi-section MCS performance tables, the Google-reviews screenshot, the
accreditation logo strip, and the MD's signature.

## Build

```bash
python3 build_report.py                                   # -> crg_solar_report.json
../../zig-out/bin/pdf-gen --presentation crg_solar_report.json crg_solar_report.pdf
```

`build_report.py` is **data-driven**: every customer/system value lives in the
`QUOTE` dict at the bottom of the file (system size, price, panel/inverter/
battery model, deposit schedule, client, ref, etc.). A server action fills that
dict per lead and regenerates — the 20-page layout and brand assets are fixed.
The committed sample reproduces the reference's "Joe Bloggs / 4.92 kW / £7,430"
system exactly (including its £0-savings values — the reference's MCS irradiance
lookup returned 0; our SvelteKit port computes it correctly, so real leads will
show real numbers).

## Layout approach

- A4 canvas (595.28 × 841.89 pt), top-left origin.
- Paragraphs are word-wrapped in Python using an embedded Helvetica/Helvetica-Bold
  AFM width table, then emitted as one text element per line — this gives exact
  cursor control instead of relying on the engine's wrapping.
- `Page.grid()` renders tables from shape+text primitives (per-cell background,
  alignment and colour), because the `presentation` `table` element ignores
  per-cell styling and only left-aligns.
- Alignment (`center`/`right`) is resolved in Python against the same AFM table
  and emitted left-aligned at a precomputed x, because the engine's own
  `measureTextWidth` mis-centres long strings.

## Assets (`assets/`)

Extracted from the reference PDF with `pdfimages -all` and normalised
(non-palette 8-bit RGB/RGBA JPEG/PNG). The page-1 cover is a single
fully-designed JPEG in the original (title + logo + URL already baked in), so
it is placed full-bleed with no overlays.

| file | role |
|------|------|
| `cover_house.jpg` | page-1 full-bleed cover |
| `quote_photo.jpg` | page-3 install photo |
| `medal.png` | page-4 "good hands" ribbon |
| `reviews.jpg` | page-4 Google-reviews screenshot |
| `logo.png` | CRG SOLAR logo (details page) |
| `accreditation.png` | MCS/HIES/NICEIC/TRUSTMARK/Trustpilot strip |
| `canadian1.jpg`, `canadian2.jpg` | Canadian Solar datasheets |
| `sunsynk_inverter.jpg` | Sunsynk inverter datasheet |
| `signature.png` | Lance Pearson signature |
| `sunpath.png` | sun-path shade chart |
| `battery.jpg` | Sunsynk battery datasheet |

## Engine fixes this work required

Reproducing an image-heavy document surfaced three real bugs in
`zig_pdf_generator`, all fixed alongside this template:

1. **`document.zig deflateCompress`** — sized its output to a `.fixed()` writer
   assuming deflate never expands; near-incompressible pixel data overflowed the
   buffer and std's flate compressor swallowed the error and segfaulted. Now
   compresses into a growable `Allocating` sink.
2. **`presentation.zig renderImage`** — freed the decoded image bytes via
   `defer` while `addImage` kept a slice aliasing them, so `doc.build()` read
   freed memory → segfault on every embedded image. The renderer now retains
   the buffers until after `build()` (matching how `invoice.zig` already did it).
3. **`presentation.zig parseShapeElement`** — read `.string` unconditionally and
   panicked on an explicit `"fill_color": null` / `"stroke_color": null`. Now
   honours JSON null as "no fill / no stroke".

## Note

The reference cover, datasheets, reviews screenshot and signature are CRG Direct
brand assets reproduced here for CRG Direct's own proposal tooling.
