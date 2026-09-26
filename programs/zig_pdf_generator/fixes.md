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

## Wave 3 — 2026-09-26 — invoice document system (branch `pdf-sheet-styles`)

Engine bugs fixed while extending the invoice renderer to the quote / invoice /
receipt / custom × classic / squircle / glass / minimal / letterhead matrix.
Each changes output only for the payloads described; every other existing
payload renders byte-identically (checked against a 29-payload corpus rendered
by the pre-change binary).

| ID | Status | Files | Description |
|----|--------|-------|-------------|
| 7 | FIXED | src/json.zig | Absent `subtotal` / `tax_amount` / `total` rendered as `0.00` although the schema promised they are derived. Now: absent `subtotal` = sum of line totals; absent `tax_amount` = tax_rate × (subtotal + adjustments), 0 when `show_tax` is false; absent `total` = subtotal + adjustments + tax − IRPF. A present key — even an explicit `0` — is still drawn verbatim. Absent line `total` = qty × unit_price less `discount` %. |
| 8 | FIXED | src/invoice.zig | Qty printed with `{d:.0}` — `2.5` hours rendered as `2`. Now up to two decimals, trailing zeros trimmed (integers unchanged). |
| 9 | FIXED | src/invoice.zig | `notes` / `payment_terms` ignored `\n` (the raw byte went into the text run). Each paragraph now wraps separately; blank lines are kept. Long notes also page-break instead of running into the footer. |
| 10 | FIXED | src/invoice.zig | An invoice with no buyer still drew an empty `Bill To:` heading (classic) or an empty BILL TO card (squircle/glass). The block is now omitted; squircle/glass widen the FROM card across the row. |
| 11 | FIXED | src/invoice.zig | Multi-page invoices attached every link annotation (pay buttons, branding link) to page 1, at the coordinates of the last page. The renderer now advances the annotation page on each page break. Content streams are unchanged. |
| 12 | FIXED | src/invoice.zig | With `logo_inline`, the company VAT line stayed at the margin while the name and address indented past the logo. It now shares their indent. |
| 13 | FIXED | src/json.zig | A non-object entry in `items` left that array slot uninitialised, and `freeInvoiceData` then freed a garbage pointer. It now becomes an empty row. |
| 14 | CHANGED | src/invoice.zig | Quotes label their date `Valid Until:` instead of `Due Date:` (owner decision: a quote has a validity date, not a due date). `labels.due_date` or the new `due_date_label` still override it. |
| 15 | CHANGED | src/json.zig | The `receipt` preset no longer pins `theme:"classic"`; the default theme is still classic, so bare receipt payloads are unchanged, and a receipt can now take any `style`. |

Known limitation, not changed: the PNG decoder flattens alpha onto white
(`image.rgbaToRgb`), so a transparent logo or signature shows a white box over
the glass wash. Proper `/SMask` support would change every RGBA-logo payload.
