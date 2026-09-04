# `preset` verification renders

Generated through `zig-out/lib/zigpdf_web.wasm` (`zig build wasm-web`) — the
same build and the same `zigpdf_generate_invoice` (ptr,len)->ptr entry point the
Lutuno storefront calls, instantiated with an empty import object. `RESULTS.txt`
is the harness transcript.

| File | Payload | What it shows |
|---|---|---|
| `a-no-preset-lutuno.pdf` | Lutuno invoice, no `preset` | Classic layout, unchanged. Byte-identical to a HEAD-baseline build except the title, which now takes `primary_color` (`#3B30E0`) instead of the template gold `#b39a7d` — the only intended difference. |
| `b-preset-receipt.pdf` | `{"preset":"receipt", …}` | `RECEIPT` title, `Receipt #:` label, no Subtotal/Tax rows (the payload supplies `tax_rate`/`tax_amount`; the preset suppresses the rows), no branding footer. |
| `c-preset-squircle.pdf` | `{"preset":"squircle", …}` | Rounded FROM / BILL TO cards, rounded table container and TOTAL chip. |
| `e-preset-glass.pdf` | `{"preset":"glass", …}` | Squircle geometry with the translucent panels and top-edge sheens over a wash. |
| `f-preset-minimal.pdf` | `{"preset":"minimal", …}` | No row fills, single rule under the header, no branding footer. |
| — | `{"preset":"squircel", …}` | No PDF: refused. `zigpdf_get_error()` returns `JSON parse error: unknown "preset" (valid: receipt, squircle, glass, minimal)`. |

`render-*.png` are 80 dpi page-1 renders of each PDF.
