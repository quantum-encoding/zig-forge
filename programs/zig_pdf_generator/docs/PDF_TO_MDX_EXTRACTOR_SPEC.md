# Spec: PDF → MDX Extractor (upgrade `zig_pdf_generator`)

**Status:** **P1 implemented** (`src/pdf_extract.zig`) · **Target:** Zig 0.16.0 · **Owner:** zig-forge
**For:** a Zig coding agent implementing the feature in this repo.

> **Implementation notes (P1 shipped):**
> - Core lives in `src/pdf_extract.zig`; public API `extractToMdx(gpa, pdf, opts) → {mdx, meta}`.
> - CLI: `pdf-gen extract <in.pdf> [-o out.mdx] [--meta]` (+ stdin→stdout pipe). FFI/WASM:
>   `zigpdf_extract_mdx` / `zigpdf_extract_meta_json` (same ptr+len shape as `zigdocx_docx_to_md`).
> - Done in P1: classic xref **and** xref streams + ObjStm (+ brute-scan rebuild on broken xref),
>   FlateDecode/ASCIIHex/ASCII85/RunLength + PNG/TIFF predictors, page-tree inheritance, content
>   interpreter, WinAnsi/`ToUnicode`/`Differences` (compact AGL), single-column reading order with
>   gap-spacing + de-hyphenation, heading inference, scanned-PDF `needs_ocr` detection, encrypted →
>   clean signal (no crash). Verified: round-trips a generated invoice + a qpdf object-stream copy
>   to **byte-identical** MDX; 206 fuzz cases (garbage/truncation/byte-flip) → **0 panics**; clean
>   under `zig-lens --strict`.
> - **Two corrections to §1/§4.2 below:** FlateDecode is *not* a heavy lift — `std.compress.flate`
>   ships inflate in Zig 0.16 (this is what P1 uses). And `pdf_crypt.zig` is **AES-256 `/V5 /R6` only**
>   — it has *no* RC4 or AESV2 primitives, so the encryption work in §4.2 is largely new code, not
>   reuse; it remains deferred to P3.
> - **Naming (CLAUDE.md rule 2):** by explicit decision the program is now bidirectional (generate
>   **and** extract) while keeping the `zig_pdf_generator` name. It is a CLI/FFI tool, not a promoted
>   canonical *library*, so the four-gate library rule doesn't apply; the name covers the dominant
>   (generate) direction and the `extract` verb is self-describing.

**P2 + P3 now shipped:**
- **Multi-column reading order** — vertical-gutter detection (straddle-free difference-array scan,
  O(frags+bins)) splits each page into column bands, emitted top-to-bottom in full before the next.
- **Lists** — bullet glyphs (•‣◦▪·∙ / `- ` / `* `) and ordered markers (`N.`/`N)` + space) →
  `- `/`1. ` with x-indent nesting.
- **Tables** — cells (text split at >1.4 em gaps) → GFM when ≥2 rows share ≥2 aligned columns; weak
  alignment falls through to plain text (guard rail, never a junk table).
- **Links** — `/Annots /Link /A /URI` overlapping a cell → `[text](uri)`.
- **Encryption** — empty user password: RC4 (/R 2,3,4), AES-128 (/V4 AESV2), AES-256 (/V5 R6 via the
  audited `pdf_crypt`). Decrypted at object resolution (strings + streams + ObjStm); password-required
  PDFs get an honest stub.
- **Type0/CID widths** (`/W`+`/DW`, Identity) — fixes glyph-positioned manuals.
- **Form XObjects** recursed (text no longer lost) and **image extraction** — `Do` counts images;
  `--images`/`extract_images` writes JPEG/JPEG2000 to an `images/` sidecar and emits `![image](…)`
  refs in reading order (raw/Flate images counted + `![image](#)` placeholder; PNG-wrapping is P4).

Validated against a 91-PDF real-world corpus (ARM TRMs incl. a 1528-page manual, OrangePi BIOS/Linux
manuals, ACM two-column papers, scanned + Hindi/Type0 docs, a real RC4-encrypted Canon manual):
**0 crashes**, encrypted PDFs decrypt byte-identical to plaintext, 25 unit tests, `zig-lens --strict`
clean, whole corpus in ~2–3 s.

**P4 remainder (not implemented):** full Type0/CID decode for non-`ToUnicode` predefined CMaps,
PNG-wrapping of raw/Flate images, LZW filter, incremental-update merge nuances, page-rotation-aware
link/image coordinates, parallel-page performance.

---

## 1. Motivation

`zig_pdf_generator` currently only **writes** PDFs (JSON → PDF, via `pdf_canvas.zig`).
We need the **inverse**: read an arbitrary PDF and emit clean **MDX** (Markdown +
YAML frontmatter), matching the output contract of our sibling tool `zig_docx`
(`zigdocx_docx_to_md`). This gives the platform a **pure-Zig, WASM-able PDF text
extractor** with no external dependencies.

### Why pure-Zig/WASM (not the alternatives)

We empirically tested two existing PDF text paths on real files and both failed:

| Path | Result on real PDFs |
|---|---|
| Go `github.com/ledongthuc/pdf` | fragile; panics on standard edge cases; jumbles multi-column/tables |
| `axiom` mechanical CLI (Rust) | **garbled** a 2-column blog PDF (characters interleaved: `"DHoo w S D o o l S a o r l a"`); **panicked** on a hardware manual (`comparison function does not implement a total order`) |
| axiom **deployed** service (OCR) | works but IAM-locked, per-page OCR cost + latency + network dependency |

A correct native extractor compiled to `wasm32-wasi` runs **in-process, sandboxed,
deterministic, zero-cost** — and avoids the character-interleaving and panics above.
**Those two behaviours are the bar this spec exists to clear.**

---

## 2. Goal & non-goals

**Goal:** Given PDF bytes, produce MDX that a human (and an LLM like DeepSeek) can
read with correct **reading order**, preserved **headings/lists/tables**, and a
metadata frontmatter — for **digital (text-layer) PDFs**.

**Non-goals (this iteration):**
- **OCR** of scanned/image-only PDFs. Instead: *detect* the absence of a text
  layer and signal `needs_ocr` so the caller falls back to an OCR service. **Never
  emit garbage for a scanned page.**
- Rendering pages to images, form filling, digital-signature verification.
- Perfect table reconstruction for arbitrarily complex layouts (best-effort; see §6).

---

## 3. Deliverables & interfaces

Match the existing FFI/WASM conventions in `src/ffi.zig` / `src/wasm.zig`
(`zigpdf_*`, `wasm_allocator`, caller-frees model).

### 3.1 Library API (`src/pdf_extract.zig`, new)
```zig
pub const ExtractOptions = struct {
    extract_images: bool = false, // write image refs / sidecar later
    detect_tables: bool = true,
    detect_headings: bool = true,
};
pub const ExtractResult = struct {
    mdx: []u8,                 // markdown + YAML frontmatter
    meta: ExtractionMeta,
};
pub const ExtractionMeta = struct {
    pages: usize,
    has_text_layer: bool,      // false → needs_ocr
    needs_ocr: bool,
    images_found: usize,
    tables_found: usize,
    extraction_method: []const u8, // "zig-native"
    warnings: [][]const u8,
};
pub fn extractToMdx(alloc: std.mem.Allocator, pdf: []const u8, opts: ExtractOptions) !ExtractResult;
```

### 3.2 FFI / WASM exports (`src/ffi.zig`)
Mirror `zigpdf_generate_invoice`'s shape exactly (ptr+len in, `?[*]u8` out,
`*usize` out-len, `zigpdf_free`, `zigpdf_get_error`):
```zig
// PDF bytes in → MDX bytes out. Returns null on error (see zigpdf_get_error()).
export fn zigpdf_extract_mdx(pdf_ptr: [*]const u8, pdf_len: usize, out_len: *usize) ?[*]u8;
// Optional: JSON metadata sidecar for the last extraction.
export fn zigpdf_extract_meta_json(out_len: *usize) ?[*]u8;
```
Reuse existing `zigpdf_free`, `zigpdf_get_error`, `zigpdf_version`, `wasm_alloc`.

### 3.3 CLI (`src/main.zig`)
Add an `extract` verb (keep generation verbs intact):
```
pdf-gen extract <in.pdf> [-o out.mdx]      # file → file
cat in.pdf | pdf-gen extract > out.mdx     # stdin → stdout (binary-clean stdin, text stdout, diagnostics→stderr)
pdf-gen extract <in.pdf> --meta            # also print meta JSON to stderr
```
Follow the repo's existing UNIX stream rules (stdout clean, stderr diagnostics).

### 3.4 Build target
Add `zig build wasm` output `pdf2mdx.wasm` (or fold the export into the existing
`zigpdf.wasm` reactor — preferred, one module). Target `wasm32-wasi`, reactor
exec model (`_initialize`), as `zig_docx` does.

---

## 4. PDF parsing engine (the core)

A PDF is **not** linear text; it's an object graph whose page content is a stream
of drawing operators with explicit coordinates. Extraction = parse objects →
decode content streams → place glyphs → recover reading order → infer structure.

### 4.1 File structure
- Parse from the **trailer up**: find `startxref` → `xref`. Support **both**
  classic `xref` tables **and** PDF 1.5+ **cross-reference streams** (`/Type /XRef`)
  and **object streams** (`/Type /ObjStm`, holds compressed indirect objects).
- Follow `/Prev` for **incremental updates** (merge, later wins).
- **Resilience:** if the xref is broken/missing, **rebuild it** by scanning the
  file for `N G obj` markers. (Malformed xref is the #1 cause of competitor
  panics — never trust it blindly.)

### 4.2 Object model & streams
- Tokenize COS objects: dict `<< >>`, array `[ ]`, name `/X`, number, boolean,
  null, literal string `( )` (with escapes + balanced parens), hex string `< >`,
  indirect ref `N G R`, stream.
- **Stream filters** (decode in order from `/Filter`): **FlateDecode** (zlib
  inflate — *mandatory*, most content & xref/obj streams use it), `ASCIIHexDecode`,
  `ASCII85Decode`, `LZWDecode`, `RunLengthDecode`. Apply **Predictor**
  (PNG predictors 10–15, TIFF predictor 2) from `/DecodeParms`.
  `DCTDecode`/`JPXDecode` = image data → skip for text.
- **Encryption:** support the common case — `/Encrypt` with empty user password,
  **RC4** and **AESV2/AESV3 (CBC)**, key derived per the standard security
  handler (reuse/extend `pdf_crypt.zig` if it has primitives). Password-protected
  (non-empty user pw) → clean error, not a crash.

### 4.3 Page tree
- Walk `/Root /Pages` → `/Kids`, honor `/Count`, **inherit** `/Resources`,
  `/MediaBox`, `/CropBox`, `/Rotate` down the tree.
- Per page: collect `/Contents` (may be an array of streams → concatenate),
  `/Resources /Font`, `/Resources /XObject`.

### 4.4 Content-stream interpreter
Tokenize operators + operands; maintain graphics + text state:
- Graphics: `q`/`Q` (save/restore), `cm` (CTM matrix).
- Text: `BT`/`ET`, `Tf` (font, size), `Td`/`TD`/`Tm`/`T*` (text matrix /
  line moves), `TL` (leading), `Tc`/`Tw` (char/word spacing), `Tz` (horiz scale),
  `Ts` (rise).
- Show: `Tj`, `TJ` (array with kerning adjustments — negative numbers = spacing),
  `'` and `"`.
- For each shown string, compute each glyph's **device-space position** =
  textMatrix × CTM, advancing by glyph widths (`/Widths`, `/MissingWidth`, or
  CID `/W`) + `Tc`/`Tw`/`TJ` adjustments.

### 4.5 Glyph → Unicode (the correctness crux)
Decode bytes → Unicode, **per font**:
1. `/ToUnicode` CMap present → parse `beginbfchar`/`beginbfrange` and map
   codes → Unicode. **Prefer this always** (handles subset fonts like `ABCDEF+Arial`).
2. Else simple-font `/Encoding`: `StandardEncoding`, `WinAnsiEncoding`,
   `MacRomanEncoding`, `PDFDocEncoding`, plus `/Differences` overrides → glyph
   name → Unicode (AGL — Adobe Glyph List; bundle a compact table).
3. **Type0 / CID fonts** (composite, multi-byte): use the CMap (`/Encoding`,
   e.g. `Identity-H`) for byte→CID, then `/ToUnicode` (or CIDSystemInfo +
   predefined CMap) for CID→Unicode.
4. No mapping available → record a warning; if a page is mostly unmapped, treat
   as **no text layer** (§6, needs_ocr) rather than emitting `cid:NNN`/garbage.

### 4.6 Reading order — **the anti-interleaving requirement**
This is where competitors failed. After collecting positioned glyph runs:
1. Merge adjacent glyphs into **fragments** (runs with continuous x advance,
   same line) inserting spaces where the gap > word-space threshold.
2. Group fragments into **lines** by y (tolerance ≈ 0.3× font size); apply page
   `/Rotate`.
3. **Column detection:** cluster fragment x-extents into column bands (e.g. gap
   analysis / 1-D k-means on x-midpoints). If ≥2 bands with a clear gutter, the
   page is multi-column → **emit each column top-to-bottom in full before moving
   to the next column.** (A single global top-to-bottom-left-to-right sort is what
   produces the `"DHoo w S D o o l"` interleaving — **do not do that**.)
4. Within a line/column, sort fragments left→right; join with single spaces;
   de-hyphenate soft line-break hyphens when the next line continues a word.

---

## 5. MDX reconstruction

Emit GitHub-flavoured Markdown with a YAML frontmatter block (match `zig_docx`,
which opens with `---\n…\n---`):

```mdx
---
title: <from /Info /Title or first heading>
pages: 12
source: <filename>
extraction_method: zig-native
has_text_layer: true
---

# Heading
paragraph text…
```

- **Frontmatter:** title/author/created from `/Info`; `pages`, `extraction_method`,
  `has_text_layer`, `needs_ocr`.
- **Headings:** infer level from font size buckets relative to the modal body size
  (largest ⇒ `#`, next ⇒ `##`, …) and/or bold weight. Cap at `####`.
- **Paragraphs:** consecutive lines with normal leading → one paragraph; blank
  line between paragraphs (detect via larger vertical gap).
- **Lists:** lines beginning with bullet glyphs (`•‣◦-–*`) or `\d+[.)]` →
  `- ` / `1. `, preserve nesting via x-indent.
- **Tables:** detect when ≥2 consecutive lines share ≥2 aligned column x-positions
  → emit a GFM table. **Guard rail:** if alignment confidence is low, emit the
  rows as **plain text/paragraphs — never fabricate a junk table** (axiom emitted
  jumbled `| … | … |` rows; that is a *failure*, not a feature).
- **Links:** page `/Annots` of `/Subtype /Link` with `/A /URI` overlapping text →
  `[text](uri)` (optional, Phase 3).
- **Images:** Phase 1 may emit a placeholder `![image](#)` or omit; Phase 3 may
  extract to `images/` like `zig_docx` (`extract_images` option).

---

## 6. Scanned / no-text-layer detection
If, after parsing all pages, extracted printable chars per page is ≈0 while pages
contain large image XObjects → set `has_text_layer=false`, `needs_ocr=true`,
return minimal MDX (frontmatter + a note). The Go caller routes these to OCR.
**Empty-but-honest beats garbage.**

---

## 7. Robustness (hard requirements)
- **No panics, ever.** All failure → `error.X` surfaced via `zigpdf_get_error()`.
  No `unreachable`, no unchecked slicing, no unstable sort comparators (the axiom
  panic was an invalid sort order — ensure comparators are total).
- Bounded recursion (object-ref cycles → visited set), bounded memory, size caps,
  malformed-stream tolerance (skip the bad object, warn, continue).
- Deterministic output for the same input.

---

## 8. Test corpus & acceptance

Put fixtures in `pdf-chart-tests/extract/` (or `examples/extract/`). Use the
**exact files that broke the competitors:**

| Fixture | Must demonstrate |
|---|---|
| `solar-blog.pdf` (multi-column design) | **No character interleaving**; correct column reading order |
| `opi-bios-manual.pdf` (broke axiom) | **No panic**; clean single-column text |
| ARM TRM (large, technical, tables) | scales; tables→GFM or clean text; reasonable speed |
| a scanned PDF | `has_text_layer=false`, `needs_ocr=true`, no garbage |
| a `/ToUnicode`-less subset-font PDF | falls back to encoding tables, readable |
| an empty-user-password encrypted PDF | decrypts + extracts |

**Acceptance:** for each digital fixture, output is human-readable, reading order
correct, headings/lists detected; tables are correct **or** plain text (never
junk); zero panics; deterministic. Add `zig build test` unit tests for: inflate +
predictors, xref-stream + ObjStm parsing, ToUnicode CMap, column detection,
encoding tables.

---

## 9. Phasing (ship incrementally)
1. **P1 — digital single-column:** xref (classic+stream) + ObjStm, FlateDecode +
   predictors, page tree, content interpreter, WinAnsi/ToUnicode, reading order
   (single column), paragraphs + headings, frontmatter, CLI `extract`, no-panic.
2. **P2 — layout:** multi-column reading order, lists, de-hyphenation, scanned
   detection (`needs_ocr`).
3. **P3 — rich:** tables, Type0/CID fonts, links, image extraction, encryption.
4. **P4 — polish:** Mac/Standard encodings, LZW/ASCII85/RunLength filters,
   incremental-update merge, performance (parallel pages).

---

## 10. Go integration (downstream, not in this repo)
The backend will call `zigpdf_extract_mdx` via **Wazero** (CGO-free), memory-pointer
model — identical harness to the planned `zig_docx.wasm` (`zigdocx_docx_to_md`)
integration: `wasm_alloc` input buffer → copy PDF bytes → call → read `out_len` +
returned ptr from linear memory → copy MDX out → `zigpdf_free`. Keeping the FFI
signature identical to `zig_docx` lets one Go helper drive both modules.
