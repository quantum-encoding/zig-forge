# zig-docx

**Universal document converter and chunker** written in pure Zig. Extracts text from DOCX, PDF, XLSX, and Anthropic Claude JSON exports, with a built-in section-aware chunker that produces hash-linked markdown ready for RAG pipelines.

Single 2.7 MB static binary. No runtime dependencies (except `pdftotext` for PDF extraction).

---

## Supported formats

| Input | Output | Notes |
|---|---|---|
| **DOCX** | MDX (Markdown with YAML frontmatter) | Images extracted to `images/` folder |
| **PDF**  | Markdown | Via `pdftotext` (poppler) or `mutool` (mupdf) |
| **XLSX** | CSV or Markdown table | Auto-resolves shared strings and formulas |
| **JSON** | Per-conversation markdown files | Anthropic Claude `conversations.json` export |
| **MD / TXT / MDX** | Chunked markdown | Direct chunking of any markdown/text source |

Every output can optionally be **chunked** into RAG-ready markdown files with hash-linked navigation between chunks.

---

## Install

### Just this program (no full repo clone)

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

Requires Zig 0.16.0-dev.3091 or later. For PDF extraction, install `poppler` (`brew install poppler` on macOS, `apt install poppler-utils` on Linux).

---

## Usage

```
zig-docx <file> [options]
zig-docx <folder/>              Batch mode (DOCX only)
```

### Commands

| Flag | Description |
|---|---|
| *(default)* | Convert to the appropriate output format for the input type |
| `--info`, `-i` | Show document structure / stats without converting |
| `--list`, `-l` | List files inside a ZIP archive (DOCX / XLSX) |
| `--chunk`, `-c` | Chunk the markdown output with hash-linked navigation |
| `--markdown`, `--md` | XLSX: output markdown table instead of CSV |
| `--anthropic` | JSON: extract Claude conversations (auto-detected from `.json` extension) |

### Options

| Flag | Description |
|---|---|
| `-o <path>` | Write output to file or folder |
| `--title "..."` | Set MDX frontmatter title (DOCX only) |
| `--description "..."` | Set MDX frontmatter description |
| `--author "..."` | Set MDX frontmatter author |
| `--date "..."` | Set MDX frontmatter date |
| `--slug "..."` | Set MDX frontmatter slug |
| `-h`, `--help` | Show help |

---

## Examples

### DOCX → MDX (for blog posts)

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
- Merges sections under 500 words with the next section
- Splits sections over 8000 words at paragraph boundaries
- Target chunk size: 6000 words

### Markdown/text file → Chunks

You can chunk any existing markdown or text file directly:

```bash
# Chunk an existing markdown file
zig-docx notes.md --chunk -o chunks/

# Chunk a large plain text file
zig-docx big-doc.txt --chunk -o chunks/

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

All parsing is pure Zig — no libc-linked XML or JSON libraries.

```
src/
├── main.zig         — CLI entry, routing by file extension
├── docx.zig         — DOCX parser (Open Office XML → Document model)
├── mdx.zig          — MDX output generator with frontmatter
├── xlsx.zig         — XLSX parser (SharedStrings + Sheet XML → cells)
├── pdf.zig          — PDF extraction via pdftotext/mutool
├── anthropic.zig    — Claude conversations.json → per-convo markdown
├── chunker.zig      — Section-aware chunker with MD5 hash linking
├── xml.zig          — Minimal XML parser (pure Zig)
├── zip.zig          — ZIP archive reader (pure Zig, DEFLATE)
├── rels.zig         — DOCX relationships (rId → media/hyperlink)
└── styles.zig       — DOCX style definitions
```

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

Part of [quantum-zig-forge](https://github.com/quantum-encoding/zig-forge). Developed by [QUANTUM ENCODING LTD](https://quantumencoding.io).
