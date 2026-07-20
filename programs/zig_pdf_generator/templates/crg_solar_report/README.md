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

## Two ways to generate — use the Zig-native one

**1. Zig-native (primary).** The layout is ported to `src/crg_solar_report.zig`,
which takes a small **`CrgQuote`** JSON (the ~28 per-lead fields) and emits the
20-page PDF directly — no template JSON, no Python at deploy. The 12 brand assets
are `@embedFile`d from `src/crg_assets/`, so the module is self-contained. This
is what the website should call.

```bash
cd ../..                                             # programs/zig_pdf_generator
echo '{"client":"Joe Bloggs","kw":"4.92","total_price":"7,430"}' > quote.json
zig-out/bin/pdf-gen --crg-report quote.json out.pdf  # omitted fields use the sample
```

Every field has a sensible default (the "Joe Bloggs / 4.92 kW / £7,430" sample),
so `{}` renders the sample and a partial object overrides only what it sets. The
full field list is the `CrgQuote` struct in `src/crg_solar_report.zig`: `ref`,
`client`, `address`, `postcode`, `date`, `kw`, `annual_saving`, `total_price`,
`net_price`, `total_price_dec`, `lifetime_saving`, `panel_count`, `panel_model`,
`panel_model_raw`, `panel_watt`, `battery`, `battery_kwh`, `inverter`,
`inverter_raw`, `annual_usage_kwh`, `tariff_p`, `annual_gen_kwh`, `deposit`,
`stage`, `balance`, `payback_years`, `array_sqm`.

**2. Python builder (reference / dev).** `build_report.py` is the original
layout authoring tool — it emits the full `presentation`-schema JSON that the Zig
port was verified against. Kept for reference and quick visual iteration; not
used at deploy.

```bash
python3 build_report.py                                   # -> crg_solar_report.json
../../zig-out/bin/pdf-gen --presentation crg_solar_report.json crg_solar_report.pdf
```

> **Verified:** `--crg-report {}` is **byte-identical** (same SHA-256) to the
> Python builder's output. The port also fixed a latent Python typo (`0%%`/`100%%`
> → `0%`/`100%` on page 11) so both now match the real reference.
>
> The committed sample reproduces "Joe Bloggs / 4.92 kW / £7,430" exactly,
> including its £0-savings values — the reference's MCS irradiance lookup returned
> 0; the SvelteKit port computes it correctly, so real leads show real numbers.

## Browser / WASM generation

The generator runs in the browser with no server round-trip. Build the
freestanding WASM module (no WASI shim — imports nothing from the host):

```bash
cd ../..                       # programs/zig_pdf_generator
zig build wasm-web             # -> zig-out/lib/zigpdf_web.wasm  (~3.3 MB, assets embedded)
```

Then, with the bundled loader (`zigpdf_web.js`):

```js
import { loadZigPdf } from './zigpdf_web.js';
const pdf = await loadZigPdf('/zigpdf_web.wasm');
const bytes = pdf.crgReport(JSON.stringify(quote));   // Uint8Array (%PDF…)
```

Then drive it with the bundled loader (`zigpdf_web.js`):

Wrap the bytes in `new Blob([bytes], { type: 'application/pdf' })` for download or
preview. `zigpdf_web.js` also exposes `presentation`, `invoice`, `proposal`,
`cleanQuote`, `letter`, and `orderEmail`.

> The WASM build lives in the freestanding root `src/wasm_web.zig` (the WASI
> `src/wasm.zig` pulls in the PDF extractor + path-based image loading, which
> don't compile for `wasm32-freestanding`). `image.zig`'s filesystem image path
> is compiled out on freestanding. Both roots export
> `zigpdf_generate_crg_solar_report`.

## Layout approach

The Zig module (`src/crg_solar_report.zig`) is a faithful port of `build_report.py`:

- A4 canvas (595.28 × 841.89 pt), top-left origin; layout maths in `f64`.
- Paragraphs are word-wrapped against an embedded Helvetica/Helvetica-Bold AFM
  width table (identical in both), then emitted as one text element per line —
  exact cursor control instead of relying on the engine's wrapping.
- `grid()` renders tables from shape+text primitives (per-cell background,
  alignment, colour), because the `presentation` `table` element ignores per-cell
  styling and only left-aligns.
- `center`/`right` alignment is resolved against the same AFM table and emitted
  left-aligned at a precomputed x, because the engine's own `measureTextWidth`
  mis-centres long strings.

## Assets (`../../src/crg_assets/`)

Canonical under the generator's `src/` so the Zig module can `@embedFile` them
(and so they ship inside the WASM). Extracted from the reference PDF with
`pdfimages -all` and normalised
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
