# zig-docx

**Universal document converter, generator, and chunker** written in pure Zig. Converts in both directions between DOCX, Markdown, PDF, XLSX, and Anthropic Claude JSON exports, generates DOCX files from Markdown or structured JSON (Fire Risk Assessments, redline proofreading sheets), and ships a section-aware chunker that produces hash-linked markdown ready for RAG pipelines.

Four artifacts from one source tree:

| Artifact | Size | Use |
|---|---|---|
| `zig-out/bin/zig-docx` | 3.6 MB | CLI binary, single static executable |
| `zig-out/lib/libzig_docx.a` | 5.8 MB | C-callable static library (Swift, Rust, Go, Python via cffi) |
| `zig-out/bin/zig_docx.wasm` | 3.1 MB | WASI reactor module for Node, edge runtimes (`zig build wasm`) |
| `zig-out/bin/zig_docx_web.wasm` | ~260 KB | Freestanding browser / Worker module — FRA, redline sheets, Markdown ↔ DOCX; zero host imports, instantiate with `{}` (no WASI shim). `zig build wasm-web`. See [Freestanding module](#freestanding-module-zig_docx_webwasm). |

No runtime dependencies for DOCX, MDX, XLSX, JSON, and chunking flows. PDF extraction shells out to `pdftotext` or `mutool`.

> The freestanding `zig_docx_web.wasm` is the build the website embeds: call
> `zigdocx_generate_fra(jsonPtr, jsonLen, outLenPtr)` (JSON → FRA `.docx` bytes),
> `zigdocx_generate_redline` (redline sheet JSON → `.docx`), and the others
> listed under [Freestanding module](#freestanding-module-zig_docx_webwasm).
> Section photo evidence is passed as base64 data URLs
> (`"data:image/png;base64,…"`) since the module has no filesystem.

---

## Supported conversions

| Input | Output | Notes |
|---|---|---|
| **DOCX** | MDX (Markdown + YAML frontmatter) | Images extracted to `images/` folder |
| **Markdown** | DOCX | Headings, lists, tables, hyperlinks, inline images, optional letterhead, two style presets |
| **PDF**  | Markdown | Via `pdftotext` (poppler) or `mutool` (mupdf) |
| **XLSX** | CSV or Markdown table | Auto-resolves shared strings and formulas |
| **JSON (Anthropic)** | Per-conversation markdown files | Claude `conversations.json` export |
| **JSON (Claude Code)** | Per-session markdown files | Claude Code transcript JSONL |
| **JSON (FRA schema)** | DOCX | Fire Risk Assessment generator with bordered tables and metadata |
| **JSON (redline sheet)** | DOCX | Proofreading sheet: each fix word-diffed, removed words red and struck, added words green; or real Word tracked changes |
| **Two DOCX** | DOCX | The redline sheet of what changed between them, paragraph by paragraph |
| **MD / TXT / MDX** | Chunked markdown | Section-aware chunker with hash-linked navigation |

Every markdown output can optionally be **chunked** into RAG-ready files.

---

## Install

### Just this program

```bash
git clone --depth 1 --filter=blob:none --sparse \
  https://github.com/quantum-encoding/zig-forge.git
cd zig-forge
git sparse-checkout set programs/zig_docx
cd programs/zig_docx
zig build
./zig-out/bin/zig-docx --help
```

### Full repo

```bash
git clone https://github.com/quantum-encoding/zig-forge.git
cd zig-forge/programs/zig_docx
zig build
./zig-out/bin/zig-docx --help
```

`zig build` produces the CLI **and** a Debug `zig-out/lib/dev/libzig_docx.a` (static library). `zig-out/lib/libzig_docx.a` is the archive other repos link; only `zig build lib` in ReleaseSmall or ReleaseFast writes it, and on macOS `scripts/build-macos-lib.sh programs/zig_docx` from the repo root (or `./build-libs.sh`) is the build to use, since it also repacks the archive for ld-prime and stamps its source identity. For the dynamic library, run `zig build dylib` (outputs `libzig_docx.dylib` on macOS, `.so` on Linux). For WASM, see the [WASM library](#wasm-library) section below.

Requires Zig 0.16.0 (stable) or later. For PDF extraction, install `poppler` (`brew install poppler` on macOS, `apt install poppler-utils` on Linux).

### Native mobile (Android / iOS / Swift)

The same C FFI (`include/zig_docx.h`) drives native apps. A SwiftPM package lives in [`swift/`](swift/) — `import ZigDocx` then `ZigDocx.fireRiskAssessment(json:) -> Data`.

**Android (NDK / JNI).** Build a static `libzig_docx.a` for every common ABI — no NDK required at build time:

```bash
zig build android          # arm64-v8a, armeabi-v7a, x86_64 → zig-out/lib/android/<abi>/
zig build android-arm64    # one ABI
```

Link each `.a` into your JNI shim from CMake (Bionic libc resolves at link time):

```cmake
add_library(zig_docx STATIC IMPORTED)
set_target_properties(zig_docx PROPERTIES IMPORTED_LOCATION
    ${CMAKE_SOURCE_DIR}/libs/${ANDROID_ABI}/libzig_docx.a)
target_link_libraries(your_jni zig_docx)
```

`zig build android-so` instead emits ready-to-ship shared `libzig_docx.so` per ABI for `System.loadLibrary`, but linking Bionic at build time needs the Android NDK available to Zig — so it is kept out of the default `android` step.

> **macOS/iOS note:** Zig 0.17 writes 8-byte-aligned Mach-O members, so no repack is needed (the 0.16-era `repack-for-xcode.sh` is retired); build consumed archives with `scripts/build-macos-lib.sh`, which proves the link with `scripts/check-apple-archive.sh`.

### WASM library

For embedding in a web app or serverless runtime, build the WASI reactor module:

```bash
zig build wasm
ls zig-out/bin/zig_docx.wasm
```

The module exports the same C FFI as the native lib — `zig_docx_md_to_docx`, `zig_docx_md_to_docx_with_images`, `zig_docx_to_markdown`, `zig_docx_to_markdown_with_images`, `zig_docx_info`, `zig_docx_fra_from_json`, `zig_docx_redline_from_json`, `zig_docx_redline_compare`, `zig_docx_alloc`, plus matching `_free` calls and `zig_docx_version`. Imports are vanilla `wasi_snapshot_preview1` syscalls — load with Node's `node:wasi`, wasmtime, wasmer, jco, or any WASI-compatible host.

`pdf` and `claude_code` modules are gated out of the WASM build (subprocess and dirent.d_name aren't available under WASI). Everything else — XML, ZIP, DrawingML, FRA, MDX — works unchanged.

#### Embedder calling pattern (Node WASI example)

The functions that return `ZigDocxResult` (a 16-byte `{data, len, error_msg}` struct) use the wasm32 sret convention: the first argument is a pointer to a caller-allocated 16-byte slot the wasm fills in. Use `zig_docx_alloc(len)` to reserve memory inside the wasm's linear memory for both the input bytes and the sret slot, then `zig_docx_free(ptr, len)` to release them.

```js
import { WASI } from 'node:wasi';
import { readFileSync } from 'node:fs';

const wasi = new WASI({ version: 'preview1', args: [], env: {} });
const wasm = await WebAssembly.compile(readFileSync('zig_docx.wasm'));
const instance = await WebAssembly.instantiate(wasm, wasi.getImportObject());
wasi.initialize(instance);
const e = instance.exports;

const md = '# Hello\n\nWorld\n';
const mdBytes = new TextEncoder().encode(md);

// 1. Reserve input + sret in wasm memory.
const mdPtr = e.zig_docx_alloc(mdBytes.length);
const retPtr = e.zig_docx_alloc(16);
new Uint8Array(e.memory.buffer).set(mdBytes, mdPtr);

// 2. Call. opts=0 (null) → frontmatter title/author/etc. used as-is.
e.zig_docx_md_to_docx(retPtr, mdPtr, mdBytes.length, 0);

// 3. Read result struct.
const dv = new DataView(e.memory.buffer);
const dataPtr = dv.getUint32(retPtr + 0, true);
const dataLen = dv.getUint32(retPtr + 4, true);
const errPtr  = dv.getUint32(retPtr + 8, true);
if (errPtr !== 0) throw new Error('conversion failed');

// 4. Copy DOCX bytes out of wasm memory before freeing.
const docx = new Uint8Array(e.memory.buffer).slice(dataPtr, dataPtr + dataLen);

// 5. Free everything (input, output, sret slot).
e.zig_docx_free(dataPtr, dataLen);
e.zig_docx_free(mdPtr, mdBytes.length);
e.zig_docx_free(retPtr, 16);
```

The same pattern works for `zig_docx_to_markdown` (input = DOCX bytes, output = MDX bytes) and `zig_docx_fra_from_json`. `zig_docx_info` returns a `ZigDocxInfo` struct (24 bytes); free it with `zig_docx_free_info(ptr)`.

#### Freestanding module (zig_docx_web.wasm)

`zig build wasm-web` builds a wasm32-freestanding module with no imports at all: `new WebAssembly.Instance(module, {})`. Every generator takes its inputs as (pointer, length) pairs in module memory and an out-length pointer last, and returns a pointer to the output bytes, or 0 with the reason from `zigdocx_get_error()` (a NUL-terminated string).

| Export | Inputs | Output |
|---|---|---|
| `zigdocx_generate_fra(json, len, outLen)` | FRA JSON | .docx |
| `zigdocx_generate_redline(json, len, outLen)` | redline sheet JSON | .docx |
| `zigdocx_redline_compare(before, beforeLen, after, afterLen, opts, optsLen, outLen)` | two .docx, optional options JSON (0, 0 for none) | .docx |
| `zigdocx_md_to_docx(md, len, outLen)` | Markdown, inline marks included | .docx |
| `zigdocx_docx_to_md(docx, len, outLen)` | .docx | Markdown |

Memory: `wasm_alloc(n)` reserves an input buffer; free every buffer you allocated and every output with `wasm_free(ptr, len)` (`zigdocx_free` is the same call), passing the length it was allocated or returned with. Each call's working memory is an arena released before it returns, so there is no reset between calls; after the first few calls the module's memory stays the same size.

```js
const { exports: ex } = new WebAssembly.Instance(module, {});
const json = new TextEncoder().encode(JSON.stringify(sheet));
const inPtr = ex.wasm_alloc(json.length);
new Uint8Array(ex.memory.buffer, inPtr, json.length).set(json);
const outLenPtr = ex.wasm_alloc(4);
const ptr = ex.zigdocx_generate_redline(inPtr, json.length, outLenPtr);
ex.wasm_free(inPtr, json.length);
if (ptr === 0) throw new Error(readCString(ex.zigdocx_get_error()));
const len = new DataView(ex.memory.buffer).getUint32(outLenPtr, true);
const docx = new Uint8Array(ex.memory.buffer, ptr, len).slice();
ex.zigdocx_free(ptr, len);
ex.wasm_free(outLenPtr, 4);
```

`zig build wasm-test` runs `tests/wasm_web.test.mjs` under Node against the built module.

#### Surfacing embedded images (DOCX with photos)

`zig_docx_to_markdown` drops embedded images on the floor — the markdown ends up referencing `./images/1-image1.png` filenames that don't exist anywhere. Use `zig_docx_to_markdown_with_images` instead to get the bytes back alongside the MDX:

```js
// sret slot is 20 bytes (5 × u32 on wasm32):
//   mdx_data, mdx_len, images, images_count, error_msg
const retPtr = e.zig_docx_alloc(20);
const docxPtr = e.zig_docx_alloc(docxBytes.length);
new Uint8Array(e.memory.buffer).set(docxBytes, docxPtr);

e.zig_docx_to_markdown_with_images(retPtr, docxPtr, docxBytes.length);

const dv = new DataView(e.memory.buffer);
const mdxPtr     = dv.getUint32(retPtr + 0,  true);
const mdxLen     = dv.getUint32(retPtr + 4,  true);
const imagesPtr  = dv.getUint32(retPtr + 8,  true);
const imagesCnt  = dv.getUint32(retPtr + 12, true);
// errPtr at retPtr + 16

const mdx = new TextDecoder().decode(
    new Uint8Array(e.memory.buffer).subarray(mdxPtr, mdxPtr + mdxLen)
);

// Each ZigDocxImage = {filename: ptr, data: ptr, len: u32} = 12 bytes.
const mem = () => new Uint8Array(e.memory.buffer);
for (let i = 0; i < imagesCnt; i++) {
    const base = imagesPtr + i * 12;
    const fnPtr = dv.getUint32(base + 0, true);
    const dPtr  = dv.getUint32(base + 4, true);
    const dLen  = dv.getUint32(base + 8, true);

    let n = 0; while (mem()[fnPtr + n] !== 0) n++;
    const filename = new TextDecoder().decode(mem().subarray(fnPtr, fnPtr + n));

    if (dPtr === 0 || dLen === 0) continue;  // image referenced but bytes missing
    const bytes = mem().slice(dPtr, dPtr + dLen);
    // filename is e.g. "1-image1.png" — write it under "./images/<filename>"
    // and the markdown's ![Image 1](./images/1-image1.png) link resolves.
    writeFileSync(`./images/${filename}`, bytes);
}

// One call frees mdx bytes, every image filename + data, the array, and any error_msg.
e.zig_docx_free_markdown_result(retPtr);
e.zig_docx_free(docxPtr, docxBytes.length);
e.zig_docx_free(retPtr, 20);
```

Verified end-to-end: a DOCX with one PNG round-trips through the WASM and the extracted PNG is byte-for-byte identical to the original. If the markdown references an image whose bytes weren't in the archive, that entry has a non-null `filename` but null `data` — the embedder should keep the markdown reference but skip writing the file.

---

## CLI usage

```
zig-docx <file> [options]
zig-docx <folder/>              Batch mode (DOCX only)
```

### Mode flags

| Flag | Description |
|---|---|
| *(default)* | Convert to the appropriate output format for the input type |
| `--info`, `-i` | Show document structure / stats without converting |
| `--list`, `-l` | List files inside a ZIP archive (DOCX / XLSX) |
| `--chunk`, `-c` | Chunk the markdown output with hash-linked navigation |
| `--markdown`, `--md` | XLSX: output markdown table instead of CSV |
| `--anthropic`, `--claude` | JSON: extract Anthropic Claude conversations export |
| `--claude-code` | JSON: extract Claude Code transcript JSONL |
| `--to-docx` | Markdown: convert MD → DOCX (uses frontmatter for metadata) |
| `--fra` | JSON: generate Fire Risk Assessment DOCX from FRA schema |
| `--redline` | JSON: generate a redline proofreading sheet (see [Redline sheet](#redline-sheet)) |
| `--compare <after.docx>` | DOCX: redline sheet of what changed from the input to `<after.docx>` |
| `--tracked` | Redline: Word tracked changes (accept / reject) instead of colours |
| `--options <sheet.json>` | `--compare`: title, key, labels and colours for the sheet |
| `--marks` | DOCX → MD: also keep colours as `[text]{color= bg=}` and redline runs as CriticMarkup (Markdown, not valid MDX) |

### Output options

| Flag | Description |
|---|---|
| `-o`, `--output <path>` | Write output to file or folder |
| `--style <minutes\|default>` | DOCX style preset: `minutes` (Arial, justified, bold+underline headings) or `default` (Calibri, blue headings). Used by `--to-docx`. |
| `--title "..."` | MDX/DOCX frontmatter title |
| `--description "..."` | MDX/DOCX frontmatter description |
| `--author "..."` | MDX/DOCX frontmatter author |
| `--date "..."` | MDX/DOCX frontmatter date |
| `--slug "..."` | MDX frontmatter slug |
| `--only-project <path>` | Claude Code mode: filter to a single project directory |

### Chunker tuning

| Flag | Default | Description |
|---|---|---|
| `--chunk-target-words` | 6000 | Target words per chunk |
| `--chunk-min-words` | 500 | Sections under this merge with the next |
| `--chunk-max-words` | 8000 | Sections over this split at paragraph boundaries |

`-h`, `--help` prints the full list.

---

## Examples

### Markdown → DOCX

Converts a markdown file to a DOCX. Frontmatter sets the document metadata; an HTML comment can specify a letterhead image to embed in the page header.

```bash
# Basic
zig-docx post.md --to-docx -o post.docx

# Letterhead in the markdown frontmatter (rendered as page header)
cat > quote.md <<'EOF'
<!-- letterhead: logo.png -->
---
title: Project Quote
author: Quantum Encoding Ltd
---

# Renovation Quote

| Item     | Cost  |
|----------|-------|
| Labour   | £2400 |
| Materials| £1100 |

Total: **£3500**.
EOF
zig-docx quote.md --to-docx -o quote.docx

# Minutes style (Arial, justified, bold+underline headings)
zig-docx meeting-notes.md --to-docx --style minutes -o minutes.docx
```

The writer supports headings, ordered/unordered lists with nested levels, hyperlinks, inline images, tables with column widths, blockquotes, code blocks (line breaks kept), and inline code. Letterhead images are sized automatically (max 6 inches wide, aspect-ratio preserved).

#### Inline marks

The same inline syntax as zig_pdf_generator's Markdown, so one text marks up the same way in a PDF and a .docx:

| Markdown | In Word |
|---|---|
| `~~struck through~~` | strike-through |
| `==highlighted==` | yellow highlighter |
| `[text]{color=red bg=#fee2e2 strike underline}` | any subset: text colour, shading, strike, underline. Colours are `#rgb`, `#rrggbb` or a name: black, white, grey/gray, red, green, blue, orange, purple, yellow, pink, lightred, lightgreen, lightblue, lightgrey/lightgray |
| `{--removed--}` | red `A00000`, struck, on light red `FDDADA` |
| `{++added++}` | green `006400`, bold, on light green `D7F5D7` |
| `{~~old~>new~~}` | the two above, side by side |
| `{==highlighted==}` | yellow highlighter |

Marks nest with each other and with `**bold**` / `*italic*` (up to 8 deep). `~~` and `==` need a non-space just inside them, so `a == b` stays as typed; so does `[x]{…}` unless every attribute is one of the four above. A backslash before one of ``\ ` * ~ = [ ] { }`` keeps the character as typed.

```markdown
Fire doors: {~~No 5~>No 7~~}. The cupboard is kept free ~~free~~ from storage.
[Check this number]{color=red bg=lightred} before it is sent.
```

### DOCX → MDX

Converts a Word document to MDX with auto-extracted title from the first `# Heading`, blank lines between paragraphs, and properly rendered lists. Struck-through runs come back as `~~text~~` and highlighted runs as `==text==`; spaces at either end of a run are written outside its marks. With `--marks` (`MdxOptions.marks`), runs in the redline look come back as `{--…--}` / `{++…++}` and any other colour, shading or underline as `[text]{color=#… bg=#… underline}`, so Markdown → DOCX → Markdown keeps them. That output is Markdown for zig_docx and zig_pdf_generator, not valid MDX: `{` opens a JSX expression.

```bash
# Basic
zig-docx post.docx -o post.mdx

# With custom frontmatter
zig-docx post.docx -o post.mdx \
  --title "My Blog Post" \
  --author "Jane Doe" \
  --date "2026-04-09" \
  --slug "my-blog-post"

# Batch convert a folder of DOCX files
zig-docx ~/Documents/blog-drafts/

# If images are present, zig-docx creates a folder with:
#   post.mdx
#   images/
#     1-image1.png
#     2-image2.jpeg
zig-docx post-with-images.docx -o blog-post/
```

### Fire Risk Assessment → DOCX

Generate an FRA Word document from a structured JSON input. The schema covers premises details, fire safety findings, action plans, and signatures.

```bash
zig-docx fra.json --fra -o fire-risk-assessment.docx
```

The output is a fully bordered, paginated DOCX with consistent styling — the same generator is exposed as `zig_docx_fra_from_json` in the FFI for embedding in form-driven web apps.

### Redline sheet

A proofreading sheet that shows each fix as before → after. The caller passes plain text; the sheet word-diffs it. In the default `redline` mode the page is A4 landscape with three columns, **Where / Now / Should be**: removed words red, struck through, on light red; added words green and bold on light green; a note in grey italics under the new text. Fixes come in groups, each under a dark row; the header row repeats on every page and no row splits across a page. With `"mode": "tracked"` the middle column is the text with real Word tracked changes (`w:del` / `w:ins` with author and date) that the reader accepts or rejects in Word, and notes get a column of their own.

```bash
zig-docx fixes.json --redline -o proofread.docx
zig-docx fixes.json --redline --tracked --author "A. Reviewer" --date 2026-11-13 -o tracked.docx

# The same sheet from two versions of a document: paragraphs are lined up by
# text and each changed paragraph is an item, grouped under its heading.
zig-docx old.docx --compare new.docx -o changes.docx [--options sheet.json] [--tracked]
```

```json
{
  "title": "Proofread: 12 Example Road (Flats 1 to 3)",
  "key": "{--Red, struck through--} is in the report now. {++Green++} is the suggested change.",
  "mode": "redline",
  "author": "Reviewer",
  "date": "2026-11-13",
  "orientation": "landscape",
  "labels": { "where": "Where", "before": "Now", "after": "Should be", "change": "Change", "note": "Note" },
  "colors": { "removed": "A00000", "removed_fill": "FDDADA", "added": "006400", "added_fill": "D7F5D7",
              "note": "555555", "group_fill": "222222", "group_text": "FFFFFF",
              "header_fill": "EDEDED", "border": "BBBBBB" },
  "groups": [
    { "name": "Flat 3", "items": [
      { "where": "Fire doors question", "before": "No  5", "after": "No  7",
        "note": "The fire door action is number 7 in this report." },
      { "where": "Action 3", "before": "kept free free from storage", "after": "kept free from storage" }
    ]}
  ]
}
```

Every key but `groups` is optional and the values above are the defaults (`title` defaults to none). `key` is inline Markdown with the marks above, in the sheet's own colours; leave it out for a default key, set `""` for none. A top-level `items` array is one group without a name row; a group with `"name": ""` has no name row either. Colours take six hex digits with or without `#`, or a colour name. `mode` is `redline` or `tracked`; `orientation` is `landscape` or `portrait`; `date` is `YYYY-MM-DD` (midnight UTC) or an ISO 8601 timestamp and is left off the tracked changes when omitted. Errors name the fault: `InvalidJson`, `ExpectedString`, `InvalidColor`, `InvalidDate`, `InvalidMode`, `InvalidOrientation`.

The sheet is laid out as a document (paragraphs and a table) and written by the same `docx_writer` as Markdown and FRA documents: rows can repeat as a header (`TableRow.header`) or refuse to split (`cant_split`), cells span columns (`col_span`), runs can be tracked changes (`Run.revision`, stamped with `DocxWriterOptions.revision_author` / `revision_date`), and pages can be landscape with their own margins (`landscape`, `margin`).

The diff works on words and the whitespace between them (longest common subsequence), then reads like a proofreader's marks: a kept stretch that is only whitespace, or no longer than the changes either side of it, is folded into one replacement ("by similar standard of" → "with a"), and a change starts at a word rather than a space.

### PDF → Markdown

Uses `pdftotext` (or `mutool` as fallback) to extract text, then auto-detects headers and converts to markdown.

```bash
# Extract to stdout
zig-docx manual.pdf

# Write to file
zig-docx manual.pdf -o manual.md

# Just show stats (pages, text size, method)
zig-docx manual.pdf -i
# → PDF: manual.pdf
#     Pages: 1529
#     Text: 4638473 bytes
#     Method: pdftotext
```

### PDF → Chunked RAG output

Extracts text, splits into sections respecting headers/code blocks/tables, and writes one markdown file per chunk with hash-linked navigation.

```bash
zig-docx manual.pdf --chunk -o chunks/

# Output structure:
#   chunks/
#     index.md              ← navigation index with hashes
#     0001_introduction.md
#     0002_architecture.md
#     0003_api_reference.md
#     ...
```

Each chunk file starts with a metadata header:

```markdown
<!-- source: manual.pdf -->
<!-- title: API Reference -->
<!-- chunk: 3/186 | hash: d4445c42... | words: 765 -->

[<< Previous](./0002_architecture.md) | [Index](./index.md) | [Next >>](./0004_examples.md)
---

# API Reference
...
```

Chunking rules:
- Splits at `#` and `##` headers always; `###` only after 50+ lines
- Never splits inside code blocks (triple backticks)
- Never splits inside markdown tables
- Merges sections under `--chunk-min-words` with the next section
- Splits sections over `--chunk-max-words` at paragraph boundaries
- Target chunk size: `--chunk-target-words`

### Markdown/text file → Chunks

You can chunk any existing markdown or text file directly:

```bash
# Chunk an existing markdown file
zig-docx notes.md --chunk -o chunks/

# Chunk a large plain text file
zig-docx big-doc.txt --chunk -o chunks/

# Tighter chunks for a small-context model
zig-docx notes.md --chunk --chunk-target-words 1500 -o chunks/

# Just get word/byte count
zig-docx notes.md -i
# → Text: notes.md
#     Bytes: 12345
#     Words: 1874
```

### XLSX → CSV or Markdown table

Parses Excel files (shared strings + formula results) and outputs CSV by default, or markdown tables with `--markdown`.

```bash
# XLSX → CSV (default)
zig-docx spreadsheet.xlsx -o data.csv

# XLSX → Markdown table
zig-docx spreadsheet.xlsx --markdown -o data.md

# Show sheet info
zig-docx spreadsheet.xlsx -i
# → Workbook: 1 sheet(s)
#     Sheet 1: "Compute Valuation" (333 cells, 8 cols × 71 rows)

# To stdout (useful for piping to AI)
zig-docx spreadsheet.xlsx | head -20
```

### Anthropic Claude export → organized markdown

Converts the official Claude data export (`conversations.json`) into one markdown file per conversation, with timestamps, sender roles, and extracted artifacts.

```bash
# Extract all conversations to a folder
zig-docx conversations.json --anthropic -o chats/

# Output:
#   chats/
#     2026-01-11_renewable_energy_app_ea94ab80.md
#     2026-01-22_light_mode_redesign_7770f653.md
#     2026-02-08_friendly_greeting_78f6336e.md
#     ...
#     artifacts/
#       2026-01-11_ea94ab80/
#         code_sample.py
#         schema.json
#       ...

# Just list conversations (index table, no extraction)
zig-docx conversations.json --anthropic -i
# → # Claude Conversations Index
#   | Date       | Title                                | Messages |
#   |------------|--------------------------------------|----------|
#   | 2026-01-11 | Renewable energy app architecture    | 186      |
#   | 2026-01-22 | Light mode theme redesign            | 8        |
#   ...
```

Each conversation markdown includes:
- Title, UUID, created/updated timestamps
- Every message with `**You**` / `**Claude**` role headers and timestamps
- Attachments extracted to `artifacts/<date>_<uuid>/`

**Performance:** Tested on a 337 MB export → 682 conversations, 11,491 messages, 5,658 artifacts in **5.7 seconds**.

### Claude Code transcript → per-session markdown

```bash
# Extract every session in the Claude Code transcript directory
zig-docx ~/.claude/projects --claude-code -o sessions/

# Filter to one project
zig-docx ~/.claude/projects --claude-code \
  --only-project /Users/me/work/myrepo \
  -o sessions/myrepo/
```

### Combining: Anthropic export → chunked RAG corpus

```bash
# Step 1: Extract conversations to markdown
zig-docx conversations.json --anthropic -o chats/

# Step 2: Chunk each conversation for RAG ingestion
for f in chats/*.md; do
  name=$(basename "$f" .md)
  zig-docx "$f" --chunk -o "rag/$name/"
done

# You now have thousands of hash-identified chunks ready for embedding
```

---

## Library API (C / WASM)

The same conversion functions exposed to the CLI are exported as a stable C ABI in `src/ffi.zig`. The static library, dylib, and WASM module all expose the same symbols:

| Function | Returns | Notes |
|---|---|---|
| `zig_docx_md_to_docx(md_ptr, md_len, opts)` | `ZigDocxResult` | Markdown → DOCX bytes. Image references fall back to their alt text — the library reads no files |
| `zig_docx_md_to_docx_with_images(md_ptr, md_len, opts, images, images_count)` | `ZigDocxResult` | Markdown → DOCX bytes **with** the pictures: the host passes the bytes, matched to each `![](…)` by whole path or filename. Referenced twice, stored once; an unmatched reference keeps its alt text |
| `zig_docx_to_markdown(docx_ptr, docx_len)` | `ZigDocxResult` | DOCX → MDX bytes (drops embedded images) |
| `zig_docx_to_markdown_with_images(docx_ptr, docx_len)` | `ZigDocxMarkdownResult` | DOCX → MDX bytes **plus** the embedded images keyed by the filenames the markdown references |
| `zig_docx_fra_from_json(json_ptr, json_len)` | `ZigDocxResult` | FRA JSON → DOCX bytes |
| `zig_docx_redline_from_json(json_ptr, json_len)` | `ZigDocxResult` | Redline sheet JSON → DOCX bytes; `error_msg` names the fault (`"Redline JSON: InvalidColor"`) |
| `zig_docx_redline_compare(before_ptr, before_len, after_ptr, after_len, opts_ptr, opts_len)` | `ZigDocxResult` | Two DOCX → redline sheet DOCX; `opts` is the sheet JSON without groups, or null/0 |
| `zig_docx_info(docx_ptr, docx_len)` | `ZigDocxInfo` | Title, author, word/paragraph/image counts |
| `zig_docx_alloc(len)` | `?[*]u8` | Allocate inside library memory (WASM embedders) |
| `zig_docx_free(ptr, len)` | `void` | Release a buffer or result `data` |
| `zig_docx_free_string(ptr)` | `void` | Release a sentinel string |
| `zig_docx_free_info(info_ptr)` | `void` | Release `ZigDocxInfo` owned strings |
| `zig_docx_free_markdown_result(ptr)` | `void` | Release a `ZigDocxMarkdownResult` (mdx, all images, error_msg) |
| `zig_docx_version()` | `[*:0]const u8` | Library version string |

`ZigDocxResult` is a 16-byte extern struct: `{ data: ?[*]u8, len: usize, error_msg: ?[*:0]const u8 }`. Each call is independent — no global state, safe to invoke concurrently with separate inputs. The hand-written C header lives at [`include/zig_docx.h`](./include/zig_docx.h); a Swift package wrapper is in [`swift/`](./swift/).

---

## Benchmarks

Apple M2, macOS 26, 24 GB RAM. All times include file I/O.

| Operation | Input | Time | Peak RAM |
|---|---|---|---|
| DOCX → MDX | 14 KB blog post | 21 ms | 4 MB |
| XLSX → CSV | 11 KB spreadsheet | 18 ms | 4 MB |
| XLSX → Markdown table | 11 KB spreadsheet | 18 ms | 4 MB |
| PDF → Markdown (small) | 281 KB, 6 pages | 38 ms | 11 MB |
| PDF → Markdown (large) | 11 MB, 1,529 pages | 4.14 s | 24 MB |
| PDF → 417 chunks | 11 MB, 1,529 pages | 4.20 s | 40 MB |
| Anthropic export → markdown | 79 MB, 139 convos | 2.0 s | ~40 MB |
| Anthropic export → markdown | 337 MB, 682 convos | 5.7 s | ~80 MB |

See [`BENCHMARKS.md`](./BENCHMARKS.md) for the full hyperfine runs and [`bench.sh`](./bench.sh) to reproduce them.

---

## Architecture

All parsing and generation are pure Zig — no libc-linked XML, ZIP, or JSON libraries. libc is used only for path-based file I/O and is gated out of the WASM build.

```
src/
├── main.zig         — CLI entry, routing by file extension
├── ffi.zig          — C / WASM ABI surface (zig_docx_*)
│
├── docx.zig         — DOCX parser (Open Office XML → Document model)
├── docx_writer.zig  — DOCX serializer (Document model → .docx bytes)
├── md_parser.zig    — Markdown → Document model
├── mdx.zig          — Document model → MDX with frontmatter
├── fra.zig          — Fire Risk Assessment generator (JSON → DOCX)
├── redline.zig      — Redline proofreading sheet (JSON or two DOCX → DOCX)
├── word_diff.zig    — Word-level diff (LCS) tidied for a reader
│
├── xml.zig          — Minimal XML parser
├── zip.zig          — ZIP archive reader (DEFLATE)
├── zip_writer.zig   — ZIP archive writer
├── rels.zig         — DOCX relationships (rId → media / hyperlink)
├── styles.zig       — DOCX style definitions
│
├── xlsx.zig         — XLSX parser (SharedStrings + Sheet XML → cells)
├── pdf.zig          — PDF extraction via pdftotext / mutool
├── anthropic.zig    — Anthropic Claude conversations.json → per-convo markdown
├── claude_code.zig  — Claude Code transcript JSONL → per-session markdown
└── chunker.zig      — Section-aware chunker with MD5 hash linking
```

The DOCX writer emits unique drawing-object IDs per image (which stricter validators require), routes every piece of user text through `appendXmlEscaped`, gates control characters out of XML escaping, and clamps image dimensions before EMU conversion to prevent u64 overflow on hostile inputs. Image dimensions are detected from PNG and JPEG headers (with SOI signature verification on JPEG).

### Reader hardening

The ZIP reader refuses malformed and hostile archives rather than parsing them optimistically: DEFLATE-bomb caps (256 MB per entry, 1 GB cumulative, independent of the archive's own declared sizes), CRC-32 verification of every extracted entry against the central directory, ZIP64 sentinels rejected rather than read literally, duplicate entry names rejected, and central-directory records bounds-checked in full against the declared directory extent. The XML parser reads CDATA to its real terminator, decodes numeric character references, and chunks oversized entity-bearing text rather than truncating it mid-character. Embedded media names are reduced to a single safe path component before they reach `Document.media[].name` or the images FFI, so a consumer that writes them to disk cannot be walked out of its output directory.

### Testing

`zig build test` runs the unit tests plus `src/tier1_anchors.zig`, whose assertions are anchored outside this codebase:

- **`src/testdata/libreoffice_writer.docx`** — authored by LibreOffice Writer 26.2.1.2. Its expected text, entity decoding and table shape were read out with CPython's `xml.etree.ElementTree`; its per-entry CRC-32s and sizes with CPython's `zipfile`.
- **Generated output** — checked against PKWARE APPNOTE.TXT §4.3 record signatures/layout and ECMA-376 Part 2 (OPC) mandatory part names, with every entry's CRC verified (the same check `zipfile.testzip()` performs).
- **Hostile input** — markdown containing `<script>`, `&`, quotes and `]]>` must appear escaped in `word/document.xml` and read back verbatim.
- **Negative vectors** — tampered CRC, ZIP64 sentinels, an overrunning central directory, and duplicate entry names each produce their specific error.

Beyond `zig build test`:

- **`zig build wasm-test`** — the freestanding module under Node, instantiated with `{}`: generates a redline sheet, a tracked-changes sheet, Markdown with marks (and back), a two-document comparison, checks error messages, and that repeated calls do not grow memory.
- **`tests/redline_golden.sh`** — builds the CLI, makes the reference sheet from `src/testdata/redline_sheet.json` and its tracked twin, then checks the ZIP (`unzip -t`), every XML part (`xmllint`), the text macOS's `textutil` reads, and, when LibreOffice is installed, that it reads every `w:del` / `w:ins` as a tracked change by the named author.

The `chunker.zig` module is standalone and can be imported as a library:

```zig
const chunker = @import("chunker.zig");

var result = try chunker.chunkDocument(
    allocator,
    markdown_text,
    "source-name.md",
    .{ .target_words = 6000, .min_words = 500, .max_words = 8000 },
);
defer result.deinit();

for (result.chunks) |chunk| {
    // chunk.title, chunk.content, chunk.word_count, chunk.hash
}
```

---

## License

MIT. See [LICENSE](./LICENSE).

Part of [zig-forge](https://github.com/quantum-encoding/zig-forge). Developed by [QUANTUM ENCODING LTD](https://quantumencoding.io).
