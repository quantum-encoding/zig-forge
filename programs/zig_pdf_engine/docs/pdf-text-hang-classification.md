# pdf-text hangs: what they were

Measured 2026-09-20 against 13,265 real accounting PDFs: `pdf-text` never returned on 629 (5%).
All 629 were fetched and swept before and after the fix (`tests/termination_sweep.sh`).

| | before | after |
|---|---|---|
| never returns | 629 | 0 |
| returns text | 0 | 629 |
| returns nothing / error | 0 | 0 |

All 629 now extract in 3.2 s in total, serially. Against poppler's `pdftotext` on the same files,
comparing alphanumeric characters regardless of spacing: 608 files recover ≥ 95% of the text, 21
recover 54–80%, none less. The 21 are not a termination matter; see "Not fixed".

## The constructs

Two defects account for every one of the 629. Neither is malformed input: both are ordinary output
of mainstream PDF writers, which is why the rate was 5%.

### A. ToUnicode `bfrange` with a destination array — 264 files

```
<0001> <0037> [<0047> <0042> <0033> ... one entry per code ... ]
```

Producers in the sample: Qt 4.8/5.x (119), wkhtmltopdf (47), PDFium (10), unnamed (88). `CMap.parseBfRange` read array entries `while
(code <= src_end)`, so an array holding exactly one entry per code (the normal case) left the
closing `]` unread. The enclosing loop then did `parseHexToken(...) orelse continue` on the `]`:
not a hex token, cursor not moved, forever. No allocation, which is why RSS stayed flat.

The same parser also searched for `beginbfchar` before `beginbfrange` from each position, so a
`bfrange` section that preceded a `bfchar` section was skipped without being read, and it shifted
destination strings into a `u32`, so a ligature (`<00660066006C>`) or a surrogate pair decoded to
the wrong character. Both were silent text loss rather than hangs.

**Fix:** `cmap.zig` is now driven by a `Scanner` whose `next()` moves the cursor on every token;
sections are recognised as tokens, in the order they appear; destinations are UTF-16BE strings.

### B. `/Filter` written as an array — 365 files

```
<</Filter[/FlateDecode]/Length 2835>>            342 files
<</Filter [ /ASCII85Decode /FlateDecode ] ...>>  23 files
```

Producers in the sample: SPS APLOAD/iTextSharp (207), StreamServe (93), Crystal Reports (24),
Oracle PDF driver (18), ReportLab (5), PDFium (3), unnamed (15).

Two defects in a chain:

1. `Document.getDecompressedStream` understood `/Filter` only as a single name. Given an array it
   returned the **still-compressed bytes** as if decoded.
2. Those bytes were lexed as a content stream. `Lexer.next()` on a `)` that closes no string, or a
   `>` that is not half of `>>`, returned a zero-length `eof` token **without advancing**, and
   every `while (lex.next())` loop in the engine spun on it. (Here the operand stack grew as it
   spun, so this variant did allocate.)

**Fix:** one `filters.decodeStream` handles a name or an array (a chain), shared by `Document`,
`Page` and the xref-stream reader; a filter it cannot apply is `error.UnsupportedFilter`, never raw
bytes. `Lexer.next()` now consumes an unclaimed delimiter as a one-byte token, and the never-
advancing `eof` tag is gone.

## Found while in there (not among the 629)

| Defect | Effect | Fix |
|---|---|---|
| Stream data extent found by searching for `endstream` and trimming every trailing CR/LF | About 1 stream in 100 has a zlib checksum ending in `0x0A`/`0x0D`; the trim cut it, the stream failed to decode and was **silently dropped**. One sample returned only its `COPY` watermark, which downstream reads as "scan". Affects documents that never hung, too. | `/Length` is honoured when it is a direct integer and `endstream` follows; otherwise at most one EOL byte is trimmed |
| `extractAllText` looped `for (0..page_count)` on the root's `/Count`, re-walking the page tree per page | A file claiming `/Count 4000000000` runs that many iterations; O(pages²) on honest files | The page tree's leaves are collected once and are the page list |
| Xref stream with `/W [0 0 0]` | Entries of no bytes never exhaust the data; the loop is bounded only by `/Index` | `error.InvalidXrefStreamW` |
| `PageTree` (render path) had no cycle guard | `/Kids` pointing at an ancestor recursed until the stack overflowed | visited set + depth cap, as `Document` already had |
| Inline images (`BI … ID <bytes> EI`) were lexed as syntax | Image bytes read as operators; an unbalanced `(` swallowed the rest of the page | data between `ID` and `EI` is skipped |
| Content-stream array nesting unbounded | A stream of `[` bytes overflows the stack | `error.NestingTooDeep` past 32 |
| `@intCast` on object/generation numbers read from the file; `\777` octal escape | Panic (a crash, not a hang) | checked casts; overflow dropped per the spec |
| Every page failing still gave exit 0 and empty stdout; every `pdf-text` error path exited 0 | A failure was indistinguishable from a scan | all-pages-failed returns the first error; `pdf-text` exits 1 on any failure |
| `pdf-info --help` was taken as a filename; the whole report went to stderr | | `-h/--help`, report on stdout, exit codes. It never shared the hang: 629/629 returned before and after |

## How termination is guaranteed

Chosen: **structural progress**, not a deadline. Every loop in the parse either consumes input
through a tokenizer that provably advances (`Lexer.next`, `cmap.Scanner.next`: non-null result ⇒
cursor moved ≥ 1 byte), or walks the object graph under a visited set plus a depth cap (xref `/Prev`
chain, page tree). Work is therefore bounded by file size, and the result is deterministic.

Not chosen:

* **A wall-clock deadline inside the parse.** It would make output depend on machine load, needs an
  injected clock to be testable, and hides the defect instead of removing it. The caller-side
  timeout stays a reasonable belt-and-braces, but nothing here relies on it.
* **A blanket iteration budget.** It bounds a loop nobody has understood. Counters are used only
  where the structure gives no natural bound (nesting depth, chain depth).

The invariant is tested directly: randomised byte strings are fed to both tokenizers asserting the
cursor moves on every token, and to the content-stream extractor; every truncation of the spec's
CMap example is parsed. Tests run under `test_watchdog.zig` (`alarm`), so a regression is a test
killed by SIGALRM, not a build that hangs. Each guard was mutation-tested: broken → red, restored →
green (9 mutations: both tokenizers' advance, filter array, `/Length`, EOL trim, page-tree visited
set, zero-width xref, bfrange array, inline-image skip).

## Not fixed

* **Text inside Form XObjects is not extracted.** The extractor does not follow `Do`. This is what
  the 21 partial files have in common (2–13 form XObjects each). Pre-existing, affects documents
  that never hung, and needs a recursive walk with its own cycle guard.
* **No word spacing from positioning.** Words set with `Td`/`Tm` moves instead of space characters
  come out run together (`DateBranchReference`). Pre-existing.
* **`LZWDecode`, `/DecodeParms` predictors on content streams, `/Filter` given as an indirect
  reference**: `error.UnsupportedFilter` — an error and a non-zero exit, where before it was raw
  bytes. None occurred in the 629.
* **Encrypted PDFs** are refused (exit 1), as before.
* **`FlateDecode` output is unbounded.** A deflate bomb costs memory (≈1000:1), not time; it ends
  in `OutOfMemory`. No cap was added.
* **`xref.zig` still has unchecked `@intCast`s** on values read from the file. They panic (abort
  with a trace) rather than hang. Sweeping them is a hardening pass of its own.
* **`zig build test-real` does not compile** and did not before this change: `editor.zig` and
  `real_pdf_tests.zig` use `std.time.Timer` / `posix.clock_gettime`, gone in Zig 0.16, and it
  expects a `test_invoice.pdf` that is not in the tree. The new whole-file tests are therefore
  wired into `zig build test`.
