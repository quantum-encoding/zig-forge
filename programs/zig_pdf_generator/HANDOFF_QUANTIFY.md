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

## Encryption (AES-256, password-protected PDFs)

Set `password` (+ optional `owner_password`) on the **letter** input to produce
an AES-256 `/V5 /R6` encrypted PDF (ISO 32000-2). Validated end-to-end by qpdf
(`--check` clean, `--decrypt` renders) and pikepdf (R6/V5/256-bit; wrong password
rejected). **Native only** — the WASM build has no CSPRNG seed, so the WASM
export does not expose `password` (don't surface "encrypt" in a browser-only
flow). UI: an "Encrypt with password" field on the letter builder, server-side.
(Engine API `PdfDocument.enableEncryption(user, owner, perms, seed)` is generic —
invoices can get the same with a small follow-up.)

## ML-DSA tamper-seal (post-quantum "cryptographically sealed" PDFs)

A **proprietary** post-quantum seal (FIPS 204 ML-DSA-65), NOT a standard PDF
signature — no viewer shows a green check; verify with our `pdf-seal` tool.
Signs the PDF bytes over a `/ByteRange` and appends a `/Type /QESeal` revision
with the signature + public key. Any later edit to the body breaks verification.

- CLI: `pdf-seal sign <in> <out> <64-hex-seed>` / `pdf-seal verify <in>`
  (exit 0 = valid, 1 = invalid/no-seal). The seed is the business's persistent
  32-byte ML-DSA key; pin the embedded public key to a known key for authenticity.
- Native/server-side only — a signing key must never reach a browser/WASM bundle.
- Validated: 5 unit tests (valid / deterministic / 1-byte-tamper→invalid /
  wrong-key→invalid / no-seal) + real-file E2E (qpdf `--check` clean, still
  renders, tamper→exit 1). Primitive is NIST ACVP-anchored.
- UI: surface as a server-side "seal / verify" action; show the seal status +
  public-key fingerprint. Not a browser feature.

## Known limits (engine-side; don't design UI that assumes otherwise)

1. **Transparent PNGs composite onto white** — a PNG with a transparent
   background now blends cleanly into the (white) page; no more white/black box.
   Note this is a flatten-onto-white, not true alpha, so a transparent image
   placed over a *coloured* region would show white there (pages are white by
   default, so this is rarely an issue). JPEG/flat PNG also fine.
2. **Links are clickable, on the correct page.** Markdown/letter inline links
   (`[text](url)`) now render as real clickable PDF annotations, attached to the
   page they're drawn on (verified on a 3-page letter). Pay-button links on
   invoices also use this. Cap is 64 link annotations per document — extra links
   beyond that still render as text, just not clickable.
3. **Invoices now paginate** — a long item list flows across pages, the table
   header is redrawn on each page, and the totals block is kept together on the
   last page (moved to a fresh page if it wouldn't fit). The page-1 header
   (company / bill-to / meta) is not repeated; continuation pages show just the
   table header. Notes/QR/pay-buttons render on the last page.
4. **Mixed page sizes in one document** aren't persisted (single MediaBox).

## What changed in the engine (commits on `main`)

- `table_style`, `payment_buttons`, IRPF row — invoice (`c8a28fc`)
- `letter` doc type — markdown body + background (`844a3aa`)
- per-page link annotations + `setAnnotationPage` (this change)

All verified: `zig build test` (85 tests), `zig build wasm`, `zig-lens --strict` clean.
