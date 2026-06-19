# Handoff → Quantify frontend (Svelte builder)

**For the session that owns the Quantify quote/invoice builder UI** (`quantum-quote-generator` / the Svelte app that calls `zigpdf.wasm`).
Written 2026-06-19 by the zig_pdf_generator (engine) session.

The engine side is **done, tested, and shipped**. This document is the contract:
every new JSON field, the WASM exports, examples, and the UI controls you need to
author them. Nothing here needs engine changes — it's all wiring.

## How to get the engine

```
cd programs/zig_pdf_generator
zig build wasm        # -> zig-out/lib/zigpdf.wasm
```

The reference loader is already updated: `integrations/nextjs/zigpdf-loader.ts`
exposes `generateInvoice`, `generateReceipt`, `generateLetter`, `generateOrderEmail`,
etc. Types in `integrations/nextjs/types.ts`. Full field reference:
`ZIG_PDF_SCHEMA.md` (the `invoice` and new `letter` template sections).

## WASM exports you'll call

| Export | Loader method | Input | Output |
|---|---|---|---|
| `zigpdf_generate_invoice` | `generateInvoice(json)` | invoice JSON (now incl. the 3 new fields below) | PDF bytes |
| `zigpdf_generate_letter` | `generateLetter(json)` | letter JSON (new) | PDF bytes |
| `zigpdf_generate_order_email` | `generateOrderEmail(json)` | Stripe event JSON | JSON envelope (not PDF) |

---

## 1. Invoice — `table_style` (table look)

New field on the **invoice** JSON. Three looks; default unchanged.

```jsonc
{ "table_style": "bands" }   // bands (default) | boxes | minimal
```

- `bands` — alternating row fill (the original)
- `boxes` — bordered header + per-row grid (the "Spanish invoice" look)
- `minimal` — no fills, one rule under the header

**UI:** a 3-way segmented control / dropdown ("Table style: Bands / Boxes / Minimal").

## 2. Invoice — `payment_buttons` (multiple pay buttons)

New array. Each entry renders a real clickable PDF button. Falls back to the
existing single `payment_button_*` fields if the array is empty (back-compat).

```jsonc
{
  "payment_buttons": [
    { "label": "Pay by Card", "url": "https://checkout.stripe.com/…", "color": "#635BFF", "text_color": "#FFFFFF" },
    { "label": "PayPal",      "url": "https://paypal.me/…",           "color": "#003087" }
  ]
}
```

**UI:** a repeater ("Add payment button") with rows of {label, url, colour}.
Suggested presets: Stripe `#635BFF`, PayPal `#003087`, GoCardless `#F1F252`.

## 3. Invoice — IRPF retention row (Spanish freelancer invoices)

```jsonc
{ "irpf_rate": 0.15, "irpf_amount": 5.70 }   // both 0 (default) => row hidden
```

Renders a negative `IRPF (15%): -€5.70` row beneath the Tax row. `irpf_amount`
is the absolute figure (you compute it; `total = subtotal + tax − irpf`).

**UI:** an "Apply IRPF retention" toggle + a percentage input (compute the amount
client-side and send both). Only relevant for ES clients.

---

## 4. NEW template — `letter`

A flowing-prose letter: a **Markdown body** laid out across pages (headings,
paragraphs, lists, blockquotes, code, **tables** all render and page-break),
framed by a letterhead + signature, on top of an optional **full-page background
image**. Call `generateLetter(json)`.

```jsonc
{
  "body_markdown": "Dear …,\n\nThank you…\n\n## Summary\n\n| Item | Amount |\n|---|---|\n| Recovery | €12.99 |\n\nRegards.",
  "background_image": "data:image/jpeg;base64,…",  // or file path / raw base64; "" = none
  "background_opacity": 0.10,                        // <1 => faint watermark
  "background_fit": "cover",                         // cover | contain | stretch
  "company_name": "Quantum Encoding Ltd",
  "company_address": "33 Oxford Street\nCoalville, LE67 3GS",
  "sender_contact": "hello@quantumencoding.io · +44 …",
  "date": "19 June 2026",
  "reference": "QE-2026-0142",
  "recipient_name": "Mr Richard Tune",
  "recipient_address": "Calle Arquímedes 60\n29100 Coín, Málaga",
  "subject": "Domain recovery",
  "closing": "Yours sincerely,",
  "signature_name": "R. A. Tune",
  "signature_title": "Director",
  "accent_hex": "#1f6feb",
  "margin": 64
}
```

Full field table: `ZIG_PDF_SCHEMA.md` → "Template: `letter`".

**UI:** a "Letter" document mode with:
- a **Markdown editor** for `body_markdown` (this is the main input — let users write prose + tables),
- a background-image picker (file → base64 data URL) with opacity slider + fit selector,
- letterhead fields (company/address/contact/date/ref) and recipient fields,
- subject + closing + signature name/title,
- an accent-colour picker.

For the background image, send a **JPEG or a flat (non-transparent) PNG** — see limits.

---

## Known limits (engine-side; don't design UI that assumes otherwise)

1. **Transparent PNG backgrounds composite onto white** — the PNG decoder drops
   alpha. Use JPEG or a flat PNG for `background_image`. (Logos with transparency
   will get a white box.)
2. **Clickable links land only on page 1** in a single document's annotation set
   *unless* the renderer assigns pages. The engine now supports per-page
   annotations (`setAnnotationPage`), and invoices are single-page so pay buttons
   are fine. Markdown/letter inline links (`[text](url)`) are **styled but not yet
   clickable** — if you want clickable links inside letters, request the
   "markdown link annotations" follow-up (small engine add).
3. **Invoices don't paginate** — a very long item list truncates rather than
   flowing to page 2. Long content belongs in the `letter` type (which flows).
4. **Mixed page sizes in one document** aren't persisted (single MediaBox).

## What changed in the engine (commits on `main`)

- `table_style`, `payment_buttons`, IRPF row — invoice (`c8a28fc`)
- `letter` doc type — markdown body + background (`844a3aa`)
- per-page link annotations + `setAnnotationPage` (this change)

All verified: `zig build test` (85 tests), `zig build wasm`, `zig-lens --strict` clean.
