# Fixes Log — zig_pdf_generator

## Wave 1 — 2026-04-27 — CRIT only

| ID | Status | Commit | Files | Description |
| — | NO_CRITS | — | — | No CRIT findings in audit; HIGH-tier integer-overflow chain deferred to Wave 2 |

## Wave 2 — 2026-09-04 — HIGH tier (integer-overflow chain) + #6

| ID | Status | Commit | Files | Description |
| 1 | OPEN | — | src/document.zig | PDF action injection via unescaped `/URI` — untouched this wave |
| 2 | FIXED | e9e12206 | src/image.zig | PNG width/height overflow: pixel count capped at 50 MP; scanline/pixel sizing moved to u64 and range-checked before narrowing to usize (wasm32 `usize` is u32, where the products wrapped and under-sized the buffers the filter loop then walked in full) |
| 3 | FIXED | e9e12206 | src/image.zig | Chunk length bounded by subtraction (`data.len - offset - 12 < length`) instead of a sum that wraps on wasm32, plus a 16 MiB per-chunk cap |
| 4 | FIXED | e9e12206 | src/image.zig | `decodeBase64` requires a canonical length; `"="` no longer underflows `output_len` to ~0 |
| 5 | FIXED | e9e12206 | src/image.zig | Accumulated IDAT capped at 32 MiB — the zlib bomb bounded from the compressed side, as the pixel cap bounds it from the inflated side |
| 6 | FIXED | 3ce2624b | src/json.zig | `items` capped at 500 (`TooManyLineItems`), checked before any allocation |

Found while bounding the above, not in the original report — both silent, both fixed in e9e12206:

- A PNG that inflated to fewer bytes than IHDR promised left the tail of the scanline buffer uninitialised, and the filter loop read all of it — rendering heap contents into the output PDF. Now `DecompressFailed`.
- Adam7-interlaced PNGs were decoded as if their scanlines were sequential (garbage output). Now refused.

Every bound above is mutation-tested: removing it turns exactly one named test red. The base64 mutation reproduces the original integer-overflow panic.
