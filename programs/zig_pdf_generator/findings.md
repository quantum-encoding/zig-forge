# zig_pdf_generator — Red-Team Findings

**Audit date:** 2026-04-27
**Target:** `programs/zig_pdf_generator` (FFI/WASM/CLI PDF generator)
**Scope:** memory safety, integer overflow, PDF injection, error handling.
**Threat model:** attacker controls JSON input, base64-embedded images, raw image
bytes, or markdown source — i.e. anyone who can call the FFI / WASM / HTTP
front-end exposed by callers.

No patches in this report. Findings only.

---

## 1. PDF action injection via unescaped URL in `/URI` annotation — HIGH

**File:** `src/document.zig:1628-1651` (`writeAnnotationObject`)
**Reach:** `src/invoice.zig:723, 754, 838` — wires `data.payment_button_url` and
`data.branding_url` from JSON straight to `addLinkAnnotation`.
**JSON keys:** `payment_button_url`, `branding_url`.

```zig
// document.zig:1642
const dict = std.fmt.bufPrint(&dict_buf,
    "<< /Type /Annot /Subtype /Link /Rect [...] /Border [0 0 0] "
    "/A << /Type /Action /S /URI /URI ({s}) >> >>",
    .{ ..., annot.url });
```

`annot.url` is interpolated raw into a PDF literal string. No escaping of `(`,
`)`, `\\`. `appendPdfString` *exists* in this file (line 1659) but is **not**
applied here.

### Exploit sketch

Submit JSON with:

```json
{ "payment_button_url":
  "https://x.example/)>>/S/JavaScript/JS(app.alert\\(1\\))/X(<<(a" }
```

The unescaped `)` closes the URI literal early; the bytes that follow land
inside the action dictionary. A viewer that honours JS actions
(historically Acrobat with JS enabled, several legacy viewers) will execute
the injected `/JS` payload when the link is clicked, or just rewrite `/S /URI`
into `/S /JavaScript`. Same trick lets you swap `/URI` for `/Launch` to point
at a UNC path.

A subtler variant — even if no viewer runs JS — uses the injection to forge
arbitrary `/A` actions (e.g. `/Launch` with a crafted file spec, or a second
`/URI` that opens a phishing page after a benign first one), so PDF tooling
that scans for safe URLs sees the original domain while the viewer follows
the injected one.

### Fix direction

Run `appendPdfString` (already implemented, line 1659) over `annot.url` before
embedding. Better: also reject URLs containing `\x00..\x1F`, `(`, `)`, `\\`
at the JSON-parse boundary, *and* validate the scheme (`http`, `https`,
`mailto`, `tel`).

---

## 2. PNG decoder integer overflow — width/height attacker-controlled — HIGH

**File:** `src/image.zig:206-237` (`decodePng`).

```zig
// image.zig:207-211
const channels: u32 = if (png_info.color_type == 6) 4 else 3;
const scanline_bytes = png_info.width * channels + 1;          // u32 mul
const raw_size = scanline_bytes * png_info.height;             // u32 mul
var decompressed = try allocator.alloc(u8, raw_size);
...
// image.zig:236-237
const pixel_bytes = png_info.width * png_info.height * channels; // u32 mul
var pixels = try allocator.alloc(u8, pixel_bytes);
```

`png_info.width` / `.height` come straight out of the IHDR chunk (`u32`,
`readU32BE`). With ReleaseFast/ReleaseSmall, `u32 * u32` wraps silently —
allocation is sized to the wrapped value, but the inflate write loop
(`decompressed[scanline_start + ...]`) and the filter loop both index by the
*unwrapped* logical size.

### Exploit sketch

Craft a PNG (or base64-PNG via `company_logo_base64` / `qr_base64` /
`crypto_wallet_logo`) with:

- `width = 0x10001`, `height = 0x10000`, `color_type = 6` (RGBA)
- Then `width * 4 + 1 ≈ 0x40005`, `* height ≈ 0x4_0005_0000` → wraps to
  `0x0005_0000`. Allocation is ~320 KiB; filter loop tries to write
  `0x4_0005_0000` bytes → heap OOB write.

Even on Debug/ReleaseSafe (panics rather than UB), this is a remote crash
DoS for any caller that decodes attacker PNGs (every `*_to_file`,
WASM/FFI invocation that accepts logos / QR base64). On WASM32 (`usize ==
u32`) every PNG-handling FFI export inherits this directly.

### Fix direction

Use `std.math.mul` (overflow-checked) or cast to `u64`/`usize` before
multiplying, and reject any PNG where `width * height > some_sane_cap`
(e.g. 50 MP) before allocating.

---

## 3. PNG chunk length not bounded vs. `usize` — HIGH (WASM32) / MEDIUM (64-bit)

**File:** `src/image.zig:139-155, 184-195`.

```zig
fn readPngChunk(data: []const u8, offset: usize) ?PngChunk {
    if (offset + 12 > data.len) return null;
    const length = readU32BE(data[offset..]);            // attacker u32
    if (offset + 12 + length > data.len) return null;    // overflows usize on WASM32
    ...
}
```

`length` is u32 from attacker input, summed into `offset` (`usize`). On
WASM32 (the target of `src/wasm.zig`) `usize == u32`, so a chunk with
`length = 0xFFFFFFF0` makes `offset + 12 + length` wrap to a small value,
the overflow check passes, and the next slice (`data[offset+8..offset+8+length]`)
panics or — in ReleaseFast — points outside `data`. Combined with finding
#2, a single crafted PNG aborts any WASM Worker that touches it.

### Fix direction

`if (length > MAX_PNG_CHUNK or offset > data.len - 12 - length) return null;`
with subtraction-based bound and a hard cap (a few MB).

---

## 4. Base64 output-size underflow — HIGH

**File:** `src/image.zig:80-117` (`decodeBase64`).

```zig
const input = clean.items;
if (input.len == 0) return error.InvalidBase64;

var padding: usize = 0;
if (input.len > 0 and input[input.len - 1] == '=') padding += 1;
if (input.len > 1 and input[input.len - 2] == '=') padding += 1;

const output_len = (input.len / 4) * 3 - padding;        // usize underflow
var output = try allocator.alloc(u8, output_len);
```

For an input that whitespace-strips to `"="` (`input.len == 1`, `padding == 1`)
or `"=="` / `"abc=="` of length 2, `(input.len / 4) * 3` is `0` and the
subtraction wraps `usize` to `~0`. The next `allocator.alloc(u8, ~0)`
either explodes the heap (kills the WASM worker / process) or, with a
custom allocator, succeeds at a smaller size and the loop writes OOB.

Reachable from any caller that feeds a `data:image/...;base64,` URL —
notably `company_logo_base64`, `verifactu_qr_base64`, `qr_base64` from
JSON.

### Fix direction

Validate `input.len % 4 == 0` and `input.len >= 4`, or compute
`output_len` with `std.math.sub` (saturating). Reject non-canonical
short inputs.

---

## 5. PNG IDAT accumulation has no size bound — DoS — MEDIUM

**File:** `src/image.zig:184-195`.

```zig
} else if (std.mem.eql(u8, &chunk.chunk_type, "IDAT")) {
    try compressed_data.appendSlice(allocator, chunk.data);
}
```

A malicious PNG with thousands of large IDAT chunks balloons
`compressed_data` to whatever the input file allows (50 MiB cap from
`packBatch` — but base64-decoded payloads from JSON have no such limit
once you go through `loadImageFromBase64`). Coupled with the
`std.compress.flate` zlib bomb potential (deflate ratio ≈ 1000×) you can
exhaust process memory from JSON alone.

### Fix direction

Cap total compressed PNG size (e.g. 16 MiB) and total decompressed size
(e.g. 64 MiB).

---

## 6. JSON `items` array allocated to attacker-chosen length — DoS — MEDIUM

**File:** `src/json.zig:188-205`.

```zig
if (obj.get("items")) |items_val| {
    if (items_val == .array) {
        const items_array = items_val.array;
        var items = try allocator.alloc(invoice.LineItem, items_array.items.len);
```

`std.json` parses the whole document first, so memory for the JSON tree
is already bounded (well: bounded by the FFI-side length). But this
extra allocation is `len * @sizeOf(LineItem)` (`LineItem` is 4 × `f64` +
slice = 48 B). A 1 MiB JSON full of `[{},{},{}, ...]` (≈400 KiB items)
costs ~20 MiB extra. Same pattern repeats in `proposal.zig`,
`presentation.zig` etc.; combined with `c_allocator` on native and
`wasm_allocator`'s linear-grow on wasm, this is a cheap memory amplifier.

CLI is partially protected via `readFileAlloc(... .limited(10 MiB))` but
WASM/FFI callers (`integrations/nextjs/`, `examples/deployment/*.js`,
`zigpdf_generate_invoice`) impose no length cap on `json_input`.

### Fix direction

Cap `json_input` length at the FFI boundary (e.g. 1 MiB) and bound
`items_array.items.len` to a reasonable maximum (e.g. 1000 line items).

---

## 7. JPEG dimension scanner — wasted CPU, no infinite loop — LOW

**File:** `src/main.zig:787-808` (`detectJpegDimensions`).

`seg_len` is read from input without checking `seg_len >= 2`. The outer
guard `i + 9 < data.len` keeps the loop terminating, but a JPEG with
`seg_len == 0` makes the loop walk byte-by-byte until EOF; `seg_len ==
0xFFFF` jumps `i` past `data.len` immediately. Not exploitable, just a
sharpness issue.

---

## 8. `showText` / `appendPdfString` only escape `(` `)` `\\` — MEDIUM

**Files:** `src/document.zig:623-637` (`showText`) and `:1659-1668`
(`appendPdfString`).

PDF literal strings allow most bytes through, so the escape set is
*nearly* complete. But:

- `appendPdfString` is used for `/Title`, `/Author`, `/Subject`,
  `/Keywords`, `/Creator`, `/Producer`, `/CreationDate`, and arbitrary
  custom-key/value pairs (`document.zig:1463-1469`) — and the value goes
  in raw without UTF-8→WinAnsi mapping. A `/Title` containing UTF-8
  ëmojis is written as multi-byte WinAnsi nonsense; not a security bug,
  but if a downstream tool re-extracts and renders the title in a
  different encoding the bytes round-trip into something the user
  didn't sign.
- Neither helper escapes carriage return / linefeed. Most viewers
  accept them, but `\r` inside a literal string is treated as `\n` by
  some parsers, which can change apparent content during
  signature/round-trip flows.
- Custom metadata `key` (line 1465) is appended **without escape and
  without `/Name` validation** — a key like `Foo>>/MaliciousKey<<Bar`
  in JSON becomes a dictionary-injection equivalent to finding #1 (less
  reachable: only callers that wire JSON keys into custom metadata are
  affected — currently none of the renderers do, but `addCustomMetadata`
  is exported to FFI consumers via `lib.PdfDocument`).

---

## 9. `MAX_OBJECTS` / `next_object_id` array bounds — MEDIUM (latent)

**File:** `src/document.zig:35-39, 968, 1484-1488`.

```zig
const MAX_OBJECTS = 4096;
...
object_offsets: [MAX_OBJECTS]u32,
...
for (1..self.next_object_id) |i| {
    ... self.object_offsets[i] ...   // OOB if next_object_id > MAX_OBJECTS
}
```

Today the per-component limits (1 catalog + 1 pages + ≤48 fonts + ≤1024
images + ≤16 ExtGStates + ≤2048 page-objects + ≤16 annotations + 1 info
≈ 3155) keep `next_object_id` < `MAX_OBJECTS`. There is no
runtime assertion. A future bump of `MAX_PAGES`, `MAX_IMAGES`, or
addition of new resource categories will silently OOB-write
`object_offsets[obj_id]` on first allocation past the cap.

Same array is also referenced in every `writeObject` /
`writeStreamObject` / `writeImageObject` / `writeAnnotationObject` /
`writeFontFileObject` (`document.zig:1513, 1523, 1555, 1579, 1629`) —
all unguarded.

### Fix direction

Add `assert(self.next_object_id < MAX_OBJECTS)` at the top of `build()`
and in each `writeXObject`, or switch to `std.ArrayListUnmanaged(u32)`.

---

## 10. xref offsets silently truncated to `u32` — MEDIUM

**File:** `src/document.zig:1513, 1523, 1555, 1579, 1629`.

`self.object_offsets[obj_id] = @intCast(self.output.items.len);` — `u32`.
`@intCast` panics in safe modes when `output.items.len > 2^32 - 1` and
silently corrupts in ReleaseFast. The xref table format itself uses
10-digit decimal offsets so PDFs > 9_999_999_999 bytes can't be
expressed anyway; the write would still produce a non-conformant file.
For the current allocator-based design this is mostly self-DoS (large
`packImagesToPdf` runs), but worth a hard cap.

---

## 11. `last_error` is process-global, mutable, non-thread-safe — MEDIUM

**File:** `src/ffi.zig:85-93`, `src/wasm.zig:93-101`.

`var last_error: [256]u8 = undefined;` is a single global. Any concurrent
FFI caller (e.g. the AWS Lambda / Cloudflare Worker examples spawning
overlapping invocations) gets a torn / overlapping error message via
`zigpdf_get_error`. The PDF data path is independent so this is mostly an
information-disclosure / log-poisoning issue, not memory corruption —
but `setLastError` is also called from many error paths and races could
expose pieces of one tenant's input/path to another.

---

## 12. QR Galois-field tables initialised lazily without sync — LOW

**File:** `src/qrcode.zig:85-110`.

```zig
const GF = struct {
    var exp_table: [512]u8 = undefined;
    var log_table: [256]u8 = undefined;
    var initialized: bool = false;

    fn init() void {
        if (initialized) return;
        ... // populates tables, sets initialized = true
    }
};
```

Two threads racing into `GF.init()` on first QR encode see a
half-populated table → garbled QR codes (data integrity loss, not
memory). On WASM there are no threads. On native FFI the host can
trivially trigger this; treat it as a footgun before turning on
thread-pooled FFI.

---

## 13. `addLinkAnnotation` borrows the URL pointer — LOW (correct today, fragile)

**File:** `src/document.zig:1127-1138`.

```zig
self.annotations[self.annotation_count] = .{ ..., .url = url };
```

The slice is stored as-is; the URL must outlive `doc.build()`. Today
every caller in the tree (`invoice.zig`, `crypto_receipt.zig`, etc.)
gets the URL from `InvoiceData` whose backing memory survives the whole
render path, so this works. Any future caller passing a stack buffer or
a freed JSON value here gets a use-after-free that lands inside the
output PDF as garbage / leaked heap bytes — silent data corruption with
information-disclosure flavour.

### Fix direction

Either dupe inside `addLinkAnnotation`, or add a comment + arena
guarantee at the API.

---

## 14. `addImage` overflow-id buffer aliasing — LOW

**File:** `src/document.zig:1074-1086`.

```zig
const s = std.fmt.bufPrint(&self.image_id_overflow, "Im{d}", .{id}) catch return "Im0";
return s;
```

`image_id_overflow: [16]u8` is a single per-document scratch buffer.
Calling `addImage` more than once for ids ≥ 32 (`image_id_table.len`)
overwrites the previous return slice in place. Any caller that hung on
to a returned id past a second `addImage` call now reads the wrong id
(or — if they used `[]const u8` semantics — a byte sequence that
straddles the new content). All current callsites use the slice
immediately, so today this is benign; a future caller that builds a list
of ids before drawing is silently broken.

---

## 15. PNG filter loop accumulates with `+%=` — LOW (intentional, for the record)

**File:** `src/image.zig:250-307`.

The PNG filter loop uses wrapping `+%=` for Sub/Up/Average/Paeth, which
matches the spec. For Average it does `(left + up) / 2` with `u16`s,
which is also correct. Mentioned only because the same file uses
unchecked `u32` arithmetic everywhere else (#2) — the wrapping operators
are the careful bits, the others are the cliff.

---

## 16. `readPngChunk` reads CRC past length without re-checking — LOW

**File:** `src/image.zig:143-155`.

```zig
if (offset + 12 + length > data.len) return null;
return PngChunk{
    ...
    .data = data[offset + 8 .. offset + 8 + length],
    .crc = readU32BE(data[offset + 8 + length ..]),  // reads 4 bytes
};
```

When `offset + 12 + length == data.len`, the slice for `crc` is exactly
4 bytes — fine. The CRC value is then never validated anywhere; an
attacker can therefore skip CRC entirely and still drive the
overflow paths in #2/#3. Not itself a vulnerability, but if you ever
treat CRC as an authenticity hint you'd be wrong to.

---

## 17. WASM `wasm_alloc`/`wasm_free` size lies — LOW (by design)

**File:** `src/wasm.zig:77-87`.

The free path trusts the JS caller's `size` argument:

```zig
export fn wasm_free(ptr: usize, size: usize) void {
    if (ptr == 0) return;
    const slice_ptr: [*]u8 = @ptrFromInt(ptr);
    wasm_allocator.free(slice_ptr[0..size]);
}
```

If JS passes the wrong size, the `wasm_allocator` (Zig's free-list
allocator) gets a corrupted free. Worker-internal only — but it's the
exact failure mode that turns a benign Worker bug into a heap-spray
primitive if a caller ever hands JS the alloc length without
verification. Document this loudly.

---

## 18. `Color.fromHex` swallows bad input → silent black — INFO

**File:** `src/document.zig:65-83`.

`parseInt(..., 16) catch 0` on each byte. A stray non-hex char yields
black. Combined with the "invalid hex returns black" behaviour, an
attacker can force colour fallbacks but nothing memory-relevant. Worth
noting because the same idiom (`catch 0`, `catch ""`) is repeated many
times across `json.zig` and the renderers, which means parse failures
are routinely converted to plausible-but-wrong defaults rather than
errors. That's a design choice, not a bug; it does make detection of
malformed input harder.

---

## 19. `writeAnnotationObject` `dict_buf: [512]u8` silently drops long URLs — INFO

**File:** `src/document.zig:1641-1648`.

```zig
var dict_buf: [512]u8 = undefined;
const dict = std.fmt.bufPrint(&dict_buf, "...", .{...}) catch return error.BufferTooSmall;
```

A URL > ~480 chars triggers `error.BufferTooSmall`, aborting the entire
PDF render. Combine with finding #1 — short attacker URLs work for
injection, long ones DoS. Fix #1 properly (escape + allocPrint) and
this disappears.

---

## 20. Renderer pattern: returned PDF slice depends on defer order — INFO

**Pattern across `invoice.zig`, `proposal.zig`, `letter_quote.zig`,
`contract.zig`, …**

`generateXxx`/`generateXxxFromJson` does:

```zig
var renderer = ...;
defer renderer.deinit();
const pdf_output = try renderer.render();           // borrows renderer.doc.output
return try allocator.dupe(u8, pdf_output);          // dupes BEFORE defer fires
```

This is correct in Zig — `defer` runs after the return value is
materialised — but a casual refactor that changes the return path
(e.g. assigning `pdf_output` to a struct field, switching to early
`errdefer`-only) reintroduces a UAF. Worth a comment at each call site.

---

## Severity summary

| # | Severity | Category | Surface |
|---|---|---|---|
| 1 | HIGH | PDF injection | Any caller that sets `payment_button_url` / `branding_url` |
| 2 | HIGH | Heap OOB write | Any caller that decodes attacker PNGs |
| 3 | HIGH (WASM32) / MED | OOB read / panic | All WASM PNG paths |
| 4 | HIGH | Heap OOM / OOB | Any caller of `decodeBase64` |
| 5 | MED | DoS | Base64 PNG paths |
| 6 | MED | DoS | All FFI/WASM JSON entry points |
| 7 | LOW | CPU waste | `--images` CLI |
| 8 | MED | Encoding / dictionary injection (latent) | `/Info` metadata |
| 9 | MED (latent) | Heap OOB write | All `build()` paths if limits move |
| 10 | MED | Truncation | Any >4 GB output |
| 11 | MED | Information disclosure | Concurrent FFI |
| 12 | LOW | Data integrity | Concurrent QR encode |
| 13 | LOW | Use-after-free (latent) | Future callers of `addLinkAnnotation` |
| 14 | LOW | Aliasing (latent) | Future callers of `addImage` past id 31 |
| 15 | INFO | — | — |
| 16 | LOW | CRC ignored | PNG path |
| 17 | LOW | Allocator corruption (caller error) | WASM free |
| 18 | INFO | Silent fallback | All hex colour parsing |
| 19 | INFO | Silent DoS | Long URLs |
| 20 | INFO | Defer-order foot-gun | All renderers |

## Top 4 to fix first

1. Escape annotation URLs (#1) — only PDF-spec injection in the tree.
2. Width/height bounds + checked multiplications in PNG (#2, #3).
3. Base64 length bounds (#4).
4. JSON input cap at FFI boundary + per-array caps (#6, partly #5).
