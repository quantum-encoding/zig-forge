# Fixes Log — zig_docx

## Wave 1 — 2026-04-27 — CRIT only

| ID | Status | Commit | Files | Description |
|---|---|---|---|---|
| C1 | RESOLVED | pending | src/zip.zig, src/docx.zig | DEFLATE bomb cap: per-entry 256 MB, archive-cumulative 1 GB; `inflate` now takes a `cap` and uses `.limited(cap)` so `allocRemaining` returns `error.StreamTooLong` on overflow. CD `uncompressed_size` (attacker-controlled) is no longer trusted; counter lives on `ZipArchive`, so `extract` is `*ZipArchive` and `parseDocument` follows. |
| C2 | RESOLVED | pending | src/anthropic.zig | Attachment `file_name` from `conversations.json` is now validated by `isSafeAttachmentName`: rejects empty / >255 / leading `.` / `/` / `\` / `\0`. On reject, the artifact is not written to disk; the markdown still lists the attachment for the user. Closes the zip-slip-via-JSON write that escaped `<output_dir>/artifacts/`. |

## Wave 2 — 2026-07-17 — HIGH (CLI input paths)

Landed by the tree-wide audit campaign's first wave; logged here retroactively.

| ID | Status | Files | Description |
|---|---|---|---|
| H1 | RESOLVED | src/main.zig | LFI via markdown image / letterhead paths. `resolveSafeImagePath` rejects NUL, absolute paths and `..` segments, resolves relative to the markdown file's directory, and `realpath`-verifies the result stays under `base_dir` (so symlink escapes are caught too). Opt out for trusted local use with `--allow-absolute-images`. |
| H2 | RESOLVED | src/claude_code.zig | Arbitrary file read via the `"Full output saved to: <path>"` spill reference parsed out of untrusted JSONL. `confinedSpillPath` requires the path to resolve under the session's own resources dir; the inlined content is capped at 16 KB. |
| H3 | RESOLVED | src/mdx.zig | Hyperlink URL injection into MDX. `isSafeLinkUrl` allowlists `http`/`https`/`mailto` and scheme-less relative references, rejects `javascript:`/`data:`/`vbscript:`/`file:` (case-insensitive, whitespace- and control-char-aware); links failing the check are emitted as plain text. |

## Wave 3 — 2026-07-19 — remaining HIGH/MEDIUM + external anchors

| ID | Status | Files | Description |
|---|---|---|---|
| H4 | RESOLVED | src/zip.zig | Central-directory bounds were checked for the filename only. Now the whole record (name + extra + comment) must fit inside the declared central directory, and duplicate entry names are refused (`ZipError.DuplicateEntry`) — the OOXML parser-differential trick where reader and consumer disagree on which part is real. Dup detection is a hash set, not an O(n²) scan. |
| H5 | RESOLVED | src/zip.zig | ZIP64 sentinels (`0xFFFFFFFF` sizes / local-header offset, `0xFFFF` entry count) were read as literal values. With no ZIP64 extra-field parser present, they are now refused via `ZipError.Zip64Unsupported` rather than silently misinterpreted. |
| H6 | RESOLVED | src/zip.zig | CRC-32 was never verified: the writer computed CRCs, the reader ignored them. `extract` now checks both the extracted length against the declared `uncompressed_size` and `std.hash.crc.Crc32` against the central-directory value (`ZipError.ChecksumMismatch`). |
| M1 | RESOLVED | src/xml.zig | The fixed 4 KB entity buffer silently truncated entity-bearing text and could split a UTF-8 sequence. `decodeEntities` now reports how much input it consumed and stops at the last whole unit that fits; `parseText` rewinds so the remainder arrives as the next text event (consumers concatenate). |
| M2 | MITIGATED | src/xml.zig | The per-element attribute cap dropped surplus attributes silently, so a document could pad an element to push a real attribute (e.g. `r:embed`) out of view. Cap raised to 64 and overflow is now reported via `ElementStart.attrs_truncated`. The borrowed lifetime of `attrs` (valid until the next `next()`) is documented rather than heap-allocated. |
| M3 | RESOLVED | src/xml.zig | CDATA sections were skipped to the first `>`, dropping the content and resuming parse inside the section. `<![CDATA[…]]>` is now read to its real terminator and emitted as literal text (no entity decoding). |
| M4 | RESOLVED | src/xml.zig | Numeric character references (`&#233;` / `&#xE9;`) passed through as literal text. Now decoded to UTF-8, with surrogate halves and codepoints above U+10FFFF refused (left literal) so no invalid UTF-8 can be produced. |
| M5 | RESOLVED | src/docx.zig | The media loop had no bound of its own. `MAX_MEDIA_FILES` (1024) and `MAX_MEDIA_TOTAL_BYTES` (128 MB) now bound what the in-memory `Document` — and every FFI consumer walking it — has to hold. |
| M6 | RESOLVED | src/zip.zig | EOCD fields were partly unvalidated. The central directory must now lie wholly inside the archive and end at or before the EOCD record describing it. |
| M7 | RESOLVED | src/docx.zig, src/ffi.zig, src/main.zig | ZIP entry names were stored verbatim in the public `Document.media[].name`, which the images FFI hands to callers who write them to disk. `sanitizeMediaName` reduces each to a single safe component under `media/` (rejecting `..`, separators, NUL, control bytes); media lookups go through `mediaNameMatches`, which compares basenames on both sides so sanitizing one side cannot desynchronize the match. |
| — | RESOLVED | src/ffi.zig | `ZigDocxInfo.image_count` used `@intCast(document.media.len)` — a panic in safety builds and a silent wrap in the ReleaseFast iOS/Android builds. Now saturates at `u16` max. |
| — | RESOLVED | src/zip.zig | OOM leak: the central-directory `errdefer` freed `filenames[0..0]`, leaking every duped name on a mid-loop allocation failure. Now frees `filenames[0..parsed]`. |
| — | RESOLVED | include/zig_docx.h, swift/…/ZigDocx.swift | Header drift: `ZigDocxImage`, `ZigDocxMarkdownResult`, `zig_docx_to_markdown_with_images`, `zig_docx_alloc` and `zig_docx_free_markdown_result` were exported and documented but absent from the C header, so JNI/Swift consumers could not reach the images API. Declarations added (purely additive; verified by compiling and linking a C client against `libzig_docx.a`) and surfaced in Swift as `docxToMarkdownWithImages`. |
| — | ADDED | src/tier1_anchors.zig, src/testdata/ | External anchors — see below. |

### External anchors (golden rule §1)

`src/tier1_anchors.zig` replaces the previous internal-expectation/roundtrip-only posture:

- `src/testdata/libreoffice_writer.docx` was authored by **LibreOffice Writer 26.2.1.2**, not by this codebase. Its per-entry CRC-32s and uncompressed sizes come from **CPython `zipfile`**, and its expected paragraph text, entity decoding, and table shape from **CPython `xml.etree.ElementTree`**.
- Generated `.docx` output is asserted against **PKWARE APPNOTE.TXT** §4.3 record signatures and layout invariants, and **ECMA-376** Part 2 (OPC) mandatory part names.
- Hostile markdown (`<script>`, `&`, quotes, `]]>`) is asserted to be escaped in `word/document.xml` and to read back verbatim — the same file parses clean under `ElementTree` and `zipfile.testzip()`.
- Negative vectors: tampered CRC, ZIP64 sentinels, an overrunning central directory, and duplicate entry names each produce their specific error.

The previously-dark `zip.zig` and `fra.zig` test blocks are wired into `zig build test` via the reference block in `docx.zig`.

### Known behavioural change

CRC-32 verification means an archive whose central directory records wrong CRCs is now rejected outright instead of being parsed. Verified against LibreOffice-authored, Word-authored (four `crg-direct` blog documents plus a 232-paragraph spec), self-generated, and LibreOffice-authored `.xlsx` inputs — all pass. A producer that writes zeroed CRCs into the central directory would newly fail.
