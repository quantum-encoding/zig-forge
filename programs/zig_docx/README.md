# zig-docx

**Universal document converter, generator, and chunker** written in pure Zig. Converts in both directions between DOCX, Markdown, PDF, XLSX, and Anthropic Claude JSON exports, generates DOCX files from Markdown or structured JSON (Fire Risk Assessments), and ships a section-aware chunker that produces hash-linked markdown ready for RAG pipelines.

Three artifacts from one source tree:

| Artifact | Size | Use |
|---|---|---|
| `zig-out/bin/zig-docx` | 3.6 MB | CLI binary, single static executable |
| `zig-out/lib/libzig_docx.a` | 5.8 MB | C-callable static library (Swift, Rust, Go, Python via cffi) |
| `zig-out/bin/zig_docx.wasm` | 3.1 MB | WASI reactor module for Node, browsers, edge runtimes |

No runtime dependencies for DOCX, MDX, XLSX, JSON, and chunking flows. PDF extraction shells out to `pdftotext` or `mutool`.

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

`zig build` produces the CLI **and** `libzig_docx.a` (static library). For the dynamic library, run `zig build dylib` (outputs `libzig_docx.dylib` on macOS, `.so` on Linux). For WASM, see the [WASM library](#wasm-library) section below.

Requires Zig 0.16.0-dev.3091 or later. For PDF extraction, install `poppler` (`brew install poppler` on macOS, `apt install poppler-utils` on Linux).

### WASM library

For embedding in a web app or serverless runtime, build the WASI reactor module:

```bash
zig build wasm
ls zig-out/bin/zig_docx.wasm
```

The module exports the same C FFI as the native lib — `zig_docx_md_to_docx`, `zig_docx_to_markdown`, `zig_docx_info`, `zig_docx_fra_from_json`, `zig_docx_alloc`, plus matching `_free` calls and `zig_docx_version`. Imports are vanilla `wasi_snapshot_preview1` syscalls — load with Node's `node:wasi`, wasmtime, wasmer, jco, or any WASI-compatible host.

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

The writer supports headings, ordered/unordered lists with nested levels, hyperlinks, inline images, tables with column widths, blockquotes, code blocks, and inline code. Letterhead images are sized automatically (max 6 inches wide, aspect-ratio preserved).

### DOCX → MDX

Converts a Word document to MDX with auto-extracted title from the first `# Heading`, blank lines between paragraphs, and properly rendered lists.

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
| `zig_docx_md_to_docx(md_ptr, md_len, opts)` | `ZigDocxResult` | Markdown → DOCX bytes |
| `zig_docx_to_markdown(docx_ptr, docx_len)` | `ZigDocxResult` | DOCX → MDX bytes |
| `zig_docx_fra_from_json(json_ptr, json_len)` | `ZigDocxResult` | FRA JSON → DOCX bytes |
| `zig_docx_info(docx_ptr, docx_len)` | `ZigDocxInfo` | Title, author, word/paragraph/image counts |
| `zig_docx_alloc(len)` | `?[*]u8` | Allocate inside library memory (WASM embedders) |
| `zig_docx_free(ptr, len)` | `void` | Release a buffer or result `data` |
| `zig_docx_free_string(ptr)` | `void` | Release a sentinel string |
| `zig_docx_free_info(info_ptr)` | `void` | Release `ZigDocxInfo` owned strings |
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

The DOCX writer emits unique drawing-object IDs per image (so stricter validators like python-docx accept the output), gates control characters out of XML escaping, and clamps image dimensions before EMU conversion to prevent u64 overflow on hostile inputs. Image dimensions are detected from PNG and JPEG headers (with SOI signature verification on JPEG).

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
