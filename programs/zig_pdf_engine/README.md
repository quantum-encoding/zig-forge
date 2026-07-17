# zig_pdf_engine

A pure-Zig PDF parsing, rendering, and editing library with a C-ABI FFI surface for Android/desktop integration.

## What it does

`zig_pdf_engine` reads PDF files, resolves their object/xref structure, decodes common
stream filters, rasterizes page content to a bitmap, and can write out edited documents.
It has no external C dependencies for decompression — FlateDecode is handled by Zig's
built-in `std.compress`.

### Parser (`src/`)

- `lexer.zig` — PDF token scanner
- `xref.zig` — cross-reference table / xref-stream parsing
- `objects.zig` — PDF object model (`Object`, `ObjectRef`)
- `document.zig` — document loading, page tree, object streams (`Document`, `DocumentInfo`)
- `page.zig` — page and page-tree types (`Page`, `PageTree`)
- `cmap.zig` — CMap font-encoding handling (`CMap`)
- `filters.zig` — stream decoders: `FlateDecode`, `Ascii85Decode`, `AsciiHexDecode`
- `extract/text.zig` — text extraction (`TextExtractor`)

### Editor (`src/editor.zig`)

- `Editor`, `Writer` — construct/serialize edited PDF documents.

### Renderer (`src/render/`)

- `bitmap.zig`, `graphics_state.zig`, `path.zig`, `rasterizer.zig` — software raster pipeline (`Bitmap`, `Rasterizer`, `PathBuilder`, `Matrix`)
- `operators.zig`, `interpreter.zig`, `renderer.zig` — content-stream interpretation and page rendering (`PageRenderer`, `RenderQuality`)
- `image.zig` — image XObject decoding (`ImageRenderer`, `DecodedImage`)
- `font/` — `truetype.zig`, `glyph.zig`, `pdf_fonts.zig` (TrueType parsing, glyph rasterization, PDF font mapping)
- `ffi.zig` — C-ABI exports (`pdf_document_open`, `pdf_document_render_page`, `pdf_renderer_*`, `pdf_bitmap_*`, …)

## Building

The library module is exposed as `pdf-engine`:

```zig
const pdf_engine = b.dependency("zig_pdf_engine", .{}).module("pdf-engine");
```

Build steps:

| Step | Output |
|---|---|
| `zig build` (default) | `pdf_engine_core` static lib + `pdf_renderer` shared lib + CLI tools |
| `zig build core` | `pdf_engine_core` static library |
| `zig build shared` | native `pdf_renderer` shared library |
| `zig build android` / `android-shared` / `android-arm32` / `android-x86_64` / `android-all` | Android cross-compiled libraries (musl) |

## CLI tools

Built into `zig-out/bin/` (and runnable via `zig build`):

- `pdf-info` (`zig build info -- <file.pdf>`) — document metadata
- `pdf-text` (`zig build text -- <file.pdf>`) — extracted text
- `render-debug` (`zig build render -- <file.pdf>`) — render diagnostics

## Tests

```sh
zig build test        # library unit tests
zig build test-real   # integration tests against real PDF files
zig build test-all    # both
```

## Status

Work in progress. This library is not on the zig-forge audited/promoted list and should be
treated as unaudited for money-touching or hostile-input use (see the repo `CLAUDE.md`).
