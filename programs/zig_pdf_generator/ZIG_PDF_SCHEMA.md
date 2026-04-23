# Zig PDF Generator — canonical JSON schema reference

This is the **authoritative schema** for every JSON payload the Zig PDF
generator accepts. It is the contract that binds:

- the Zig template renderers (source of truth — if a parser and this doc
  disagree, the parser wins and this doc is stale — open an issue)
- the Tauri app's Rust serializers (`src-tauri/src/*_serializer.rs`)
- the Tauri app's Svelte quote builder (`buildPayload()` et al.)
- the Next.js integration TypeScript types (`integrations/nextjs/types.ts`)
- any other downstream consumer of `libzigpdf`

**When the engine changes**, update this file first. When the serializers
or the Svelte builder gain new inputs, cross-check here before adding
fields — if the engine already accepts it, you don't need to extend the
Zig side.

## Scope

Four templates are in active use as of 2026-04-23, plus one legacy:

| Template name (FFI)   | Zig module           | Visual style                                     |
|-----------------------|----------------------|--------------------------------------------------|
| `invoice`             | `invoice.zig`        | Standard invoice/quote with full branding        |
| `clean_quote`         | `clean_quote.zig`    | Minimalist consultant QUOTE/INVOICE/HND/INS      |
| `letter_quote`        | `letter_quote.zig`   | Premium letter-format (Montserrat, gold hairlines)|
| `presentation`        | `presentation.zig`   | Freeform canvas; positioned elements             |
| `proposal_legacy`     | `proposal.zig`       | Branded pitch-deck with metrics/charts (legacy)  |

### Critical routing note — "proposal"

The Tauri app's UI exposes a template called **"proposal"**. That name
routes through `generate_pdf_bytes_with_template("proposal")` →
`zigpdf_generate_presentation()` → `presentation.zig` — **not** the
legacy `proposal.zig`. The branded pitch-deck is reachable only via the
`proposal_legacy` template name. If you're working on what the app
labels "Proposal", you want the `presentation` schema below, not the
`proposal_legacy` schema.

## Conventions

- **Required?** "Yes" means the renderer errors or produces degraded
  output when the field is absent. "No" means the renderer defines a
  clean fallback (listed in the next column).
- **Type**: `string`, `number` (f64), `bool`, `array<T>`, `object`,
  `hex_color` (`#RRGGBB`), `data_url` (`data:image/…;base64,…` or a raw
  base64 string the renderer auto-wraps), `enum("a"|"b")`.
- **Fallback**: what happens when the key is absent, empty, or the wrong
  type. Most parsers use `dupeStr(key, default)` or `getFloat(key)` so
  missing-vs-empty string behaves the same.
- **UI gap** (per-template): fields the engine accepts but the Svelte
  builder, Rust serializer, or both currently do not author. These are
  candidates for the next UI expansion.

---

## Template: `invoice`

Standard invoice/quote renderer. Full branding (logo + company header +
client block + itemised table + totals + QR + payment button + footer).
Supports VeriFactu/CIS/crypto-receipt modes via optional fields.

**Entry point**: `zigpdf_generate_invoice(json, out_len)` → bytes, or
`zigpdf_generate_invoice_to_file(json, path)`.

### Top-level fields

| Field                          | Type                             | Required? | Fallback                          | Notes                                                                        |
|--------------------------------|----------------------------------|-----------|-----------------------------------|------------------------------------------------------------------------------|
| `document_type`                | `enum("invoice"\|"quote")`       | No        | `"invoice"`                       | Semantic only; affects the label word, not the layout                         |
| `company_name`                 | string                           | No        | `""`                              | Header + footer                                                              |
| `company_address`              | string                           | No        | `""`                              | Single line; no `\n` splitting in this template                              |
| `company_vat`                  | string                           | No        | `""`                              | Tax/VAT ID; informational                                                    |
| `company_logo_base64`          | data_url                         | No        | none                              | Rendered top-left when present                                               |
| `client_name`                  | string                           | No        | `""`                              | Recipient block                                                              |
| `client_address`               | string                           | No        | `""`                              | Displayed above items                                                        |
| `client_vat`                   | string                           | No        | `""`                              | Client tax ID; informational                                                 |
| `invoice_number`               | string                           | No        | `""`                              | Reference (e.g. `INV-2025-001`, `Q-2026-001`)                                |
| `invoice_date`                 | string                           | No        | `""`                              | Free-form date; not parsed                                                   |
| `due_date`                     | string                           | No        | `""`                              | Free-form date; not parsed                                                   |
| `display_mode`                 | `enum("itemized"\|"blackbox")`   | No        | `"itemized"`                      | `blackbox` collapses items into one summary line using `blackbox_description` |
| `items`                        | array<LineItem>                  | No        | `[]`                              | See **LineItem**                                                             |
| `blackbox_description`         | string                           | No        | `""`                              | One-line summary used when `display_mode="blackbox"`                         |
| `subtotal`                     | number                           | No        | `0`                               | Pre-tax total; recalculated from items if absent                             |
| `tax_rate`                     | number                           | No        | `0.21`                            | Fraction (`0.0`–`1.0`); 21% default                                          |
| `tax_amount`                   | number                           | No        | derived                           | `subtotal * tax_rate` if absent                                              |
| `total`                        | number                           | No        | derived                           | `subtotal + tax_amount` if absent                                            |
| `notes`                        | string                           | No        | `""`                              | Free-form text block below items                                             |
| `payment_terms`                | string                           | No        | `""`                              | Separate from notes — specifically payment terms                             |
| `primary_color`                | hex_color                        | No        | `#b39a7d`                         | Accents, hairlines, headers                                                  |
| `secondary_color`              | hex_color                        | No        | `#2c3e50`                         | Secondary accent; rarely visible in invoice                                  |
| `title_color`                  | hex_color                        | No        | inherits `primary_color`          | Document-type word (INVOICE / QUOTE)                                         |
| `company_name_color`           | hex_color                        | No        | `#1a1a1a`                         | Company-name text                                                            |
| `font_family`                  | `enum("Helvetica"\|"Times-Roman"\|"Courier")` | No | `"Helvetica"`                 | Values not in the enum fall back to Helvetica                                |
| `template_style`               | `enum("professional"\|"modern"\|"classic"\|"creative")` | No | `"professional"` | Cosmetic variation; `professional` is the only one rendered today            |
| `logo_x`, `logo_y`             | number                           | No        | `40`, `750`                       | Logo position (points, PDF coord system)                                      |
| `logo_width`, `logo_height`    | number                           | No        | `80`, `50`                        | Logo dimensions (points)                                                     |
| `show_branding`                | bool                             | No        | `true`                            | "Generated by Quantum Quote" footer link                                     |
| `branding_url`                 | string                           | No        | canonical marketing URL           | Destination for the footer link                                              |
| `payment_button_url`           | string                           | No        | none                              | When set, renders a clickable PDF button with a link annotation              |
| `payment_button_label`         | string                           | No        | `"Pay Now"`                       | Button text                                                                  |
| `payment_button_color`         | hex_color                        | No        | `#635BFF`                         | Button fill (Stripe purple default)                                          |
| `payment_button_text_color`    | hex_color                        | No        | `#FFFFFF`                         | Button text colour                                                           |
| `qr_mode`                      | `enum("none"\|"verifactu"\|"payment_link"\|"bank_details"\|"verification"\|"crypto")` | No | `"none"` | Determines QR placement and label. `"payment"` is an alias for `"payment_link"` |
| `qr_base64`                    | data_url                         | No        | none                              | QR image to render when `qr_mode != "none"`                                  |
| `qr_label`                     | string                           | No        | derived from `qr_mode`            | Caption text under the QR                                                    |
| `verifactu_qr_base64`          | data_url                         | No        | none                              | **Legacy**; auto-promotes to `qr_base64` + `qr_mode="verifactu"`              |
| `verifactu_hash`               | string                           | No        | none                              | Spanish e-invoice hash (huella)                                              |
| `verifactu_series`             | string                           | No        | none                              | Invoice series code                                                          |
| `verifactu_nif`                | string                           | No        | none                              | Tax ID (NIF) for VeriFactu                                                   |
| `verifactu_timestamp`          | string                           | No        | none                              | Hash chain timestamp                                                         |
| `crypto_wallet`                | string                           | No        | none                              | Recipient wallet address (triggers crypto-receipt layout)                    |
| `crypto_network`               | string                           | No        | `"bitcoin"`                       | `bitcoin`, `ethereum`, `solana`, `polygon`, `litecoin`, `dogecoin`, `cardano`, etc. |
| `crypto_amount`                | number                           | No        | none                              | Optional exact amount to request                                             |
| `crypto_sender_wallet`         | string                           | No        | none                              | Sender wallet (for receipts/confirmations)                                   |
| `show_crypto_identicons`       | bool                             | No        | `false`                           | Render blockie identicons for wallet addresses                               |
| `crypto_custom_symbol`         | string                           | No        | derived from network              | Overrides default token symbol (e.g. `USDC` on Ethereum)                     |

#### `LineItem` (items[])

| Field         | Type   | Required? | Fallback | Notes                                           |
|---------------|--------|-----------|----------|-------------------------------------------------|
| `description` | string | No        | `""`     | Item name/description                           |
| `quantity`    | number | No        | `0`      |                                                 |
| `unit_price`  | number | No        | `0`      |                                                 |
| `total`       | number | No        | derived  | `quantity * unit_price` if omitted              |

### UI gap (invoice)

Fields accepted by the engine that the Svelte builder does not currently author:

- `display_mode: "blackbox"` — engine supports single-line summary but the builder always sends `itemized`
- `template_style` — no UI switcher; cosmetic-only today
- `logo_x`/`logo_y`/`logo_width`/`logo_height` — positioning is hard-coded in the builder
- `payment_button_url` / `payment_button_label` / `payment_button_color` / `payment_button_text_color` — no UI for clickable PDF buttons
- `verifactu_*` — Rust `generate_quote_pdf_zig` sets these when a quote has VeriFactu data; no Svelte UI
- `crypto_*` — invoiceData has the fields but the builder doesn't surface them; reached only via direct JSON edit
- `show_branding` / `branding_url` — always defaulted

---

## Template: `clean_quote`

Minimalist consultant-style layout with a single accent colour. Document
type is **derived from the `reference` prefix**:

| Prefix | Rendered word |
|--------|---------------|
| `QTE`  | `QUOTE`       |
| `INV`  | `INVOICE`     |
| `HND`  | `HANDOVER`    |
| `INS`  | `INSPECTION`  |

Any other prefix (or no prefix) defaults to `QUOTE`.

Shares the `ProposalData` schema with `proposal_legacy` — the JSON is
identical; the Zig renderer differs.

**Entry point**: `zigpdf_generate_clean_quote(json, out_len)`.

### Top-level fields

| Field                     | Type                   | Required? | Fallback                      | Notes                                                                 |
|---------------------------|------------------------|-----------|-------------------------------|-----------------------------------------------------------------------|
| `company_name`            | string                 | No        | `""`                          | Bold 18pt, left-aligned header                                        |
| `company_address`         | string                 | No        | `""`                          | Grey 9.5pt, below name                                                |
| `company_logo_base64`     | data_url               | No        | none                          | Accepted but not rendered in this template                            |
| `property_image_base64`   | data_url               | No        | none                          | Accepted but not rendered in this template                            |
| `client_name`             | string                 | No        | `""`                          | "PREPARED FOR" block, bold 13pt                                       |
| `client_address`          | string                 | No        | `""`                          | Grey 10.5pt; **truncated at first `\n`** (quirk — use first line only)|
| `reference`               | string                 | No        | `""`                          | Drives doc-type word — see prefix table above                         |
| `date`                    | string                 | No        | `""`                          | DATE label + value                                                    |
| `valid_until`             | string                 | No        | `""`                          | VALID UNTIL label + value                                             |
| `primary_color`           | hex_color              | No        | `#16a34a`                     | Hairlines, bullet dots, section labels                                |
| `secondary_color`         | hex_color              | No        | `#1e3a2f`                     | Accepted but not used in this template                                |
| `title_color`             | hex_color              | No        | `primary_color`               | Doc-type word (QUOTE/INVOICE/…)                                       |
| `sections`                | array<Section>         | No        | `[]`                          | See **Section** below                                                 |
| `footer`                  | object                 | No        | `{}`                          | See **Footer** below                                                  |

#### `Footer` (footer)

| Field            | Type   | Required? | Fallback            | Notes                                                                          |
|------------------|--------|-----------|---------------------|--------------------------------------------------------------------------------|
| `phone`          | string | No        | `""`                | Contact line in header                                                         |
| `email`          | string | No        | `""`                | Contact line in header                                                         |
| `website`        | string | No        | `""`                | Header + footer                                                                |
| `dashboard_text` | string | No        | derived from ref    | QR caption (grey 8pt); if empty, derived from `reference` prefix               |
| `dashboard_url`  | string | No        | `""`                | When non-empty, a QR is generated and rendered bottom-right on the final page  |

#### `Section` (sections[])

The `type` field is a discriminator; different types use different subsets of fields.

| Field           | Type                                             | Required? | Fallback | Notes                                                                                      |
|-----------------|--------------------------------------------------|-----------|----------|--------------------------------------------------------------------------------------------|
| `type`          | `enum("text"\|"metrics"\|"table"\|"chart")`      | No        | `"text"` | `chart` is **unsupported** in the clean_quote renderer — degrades to text                  |
| `heading`       | string                                           | No        | `""`     | Section title. Special triggers: containing "Included"/"Includes" → bulleted list rendering; "Next Steps"/"Notes"/"Terms" → smaller-body rendering |
| `content`       | string                                           | No        | `""`     | Prose. `- ` or `* ` prefix at line start renders as a bullet with the accent colour        |
| `metric_items`  | array<MetricItem>                                | No        | `[]`     | For `type="metrics"`                                                                       |
| `table_items`   | array<TableItem>                                 | No        | `[]`     | For `type="table"`                                                                         |
| `subtotal`      | number                                           | No        | `0`      | Rendered under the table; hidden when `0` and no tax                                        |
| `tax_rate`      | number                                           | No        | `0`      | Fraction; when `> 0`, a VAT line is rendered above Total                                    |
| `total`         | number                                           | No        | `0`      | Bold total row; hidden when `0`                                                            |
| `notes`         | string (nullable)                                | No        | `null`   | Prose block below the table (table sections only)                                          |
| `chart_spec`    | object                                           | No        | `null`   | Parsed but **unsupported** — degrades to a text section                                    |

#### `MetricItem` (sections[].metric_items[])

| Field   | Type   | Required? | Fallback | Notes                                             |
|---------|--------|-----------|----------|---------------------------------------------------|
| `label` | string | No        | `""`     | Small bold 9pt label (grey)                       |
| `value` | string | No        | `""`     | Large bold value; auto-scales 12–20pt to fit      |

#### `TableItem` (sections[].table_items[])

| Field         | Type   | Required? | Fallback | Notes                 |
|---------------|--------|-----------|----------|-----------------------|
| `description` | string | No        | `""`     |                       |
| `quantity`    | number | No        | `0`      |                       |
| `unit_price`  | number | No        | `0`      |                       |
| `total`       | number | No        | derived  |                       |

### UI gap (clean_quote)

- `secondary_color` — accepted; never exposed in the builder
- `company_logo_base64` / `property_image_base64` — accepted but the renderer doesn't place them
- `footer.dashboard_url` — generates a QR on the last page; **no Svelte UI** to set it
- Bullet content inside text sections (`- item` prefix) — no UI primitive; reached only via raw content prose or direct JSON edit
- `chart_spec` — accepted but degrades to text; don't bother surfacing until Zig supports it

---

## Template: `letter_quote`

Premium letter-format quote (Montserrat embedded TrueType, gold hairline
separators, optional watermark, two-page description + itemised estimate
flow). See `templates/LETTER_QUOTE_GUIDE.md` for the authoring guide and
`templates/reformas_sample.json` for the canonical example.

**Entry point**: `zigpdf_generate_letter_quote(json, out_len)`.

### Top-level fields

| Field       | Type                       | Required? | Fallback | Notes                                                                |
|-------------|----------------------------|-----------|----------|----------------------------------------------------------------------|
| `company`   | object                     | No        | `{}`     | See **Company** below                                                |
| `client`    | string                     | No        | `""`     | Displayed after the `CLIENTE:` label (letter-spaced, bold)           |
| `date`      | string                     | No        | `""`     | Displayed after the `FECHA:` label (free-form; not parsed)           |
| `style`     | object                     | No        | `{}`     | See **Style** below                                                  |
| `pages`     | array<Page>                | No        | `[]`     | Each page is either `description` or `itemized` — see below          |

#### `Company` (company)

| Field   | Type   | Required? | Fallback | Notes                                                                 |
|---------|--------|-----------|----------|-----------------------------------------------------------------------|
| `name`  | string | No        | `""`     | Hero title — centred, bold, letter-spaced, 28pt                       |
| `phone` | string | No        | `""`     | Subtitle line (phone · email), letter-spaced                           |
| `email` | string | No        | `""`     | Subtitle line                                                          |

#### `Style` (style)

| Field                | Type                    | Required? | Fallback      | Notes                                                                                     |
|----------------------|-------------------------|-----------|---------------|-------------------------------------------------------------------------------------------|
| `primary_color`      | hex_color               | No        | `#1a2a5e`     | Title, labels, section headings (navy default)                                            |
| `accent_color`       | hex_color               | No        | `#e8a83d`     | Hairline separators + TOTAL row colour (gold default)                                     |
| `font_family`        | `enum("montserrat"\|"helvetica")` | No | `"helvetica"` | Only `"montserrat"` triggers the embedded TTF; anything else falls back to Helvetica       |
| `watermark_image`    | string (path or data_url)| No       | none          | Filesystem path OR `data:image/…;base64,…` URL; auto-wrapped to PNG data URL if raw base64 |
| `watermark_opacity`  | number                  | No        | `0.08`        | 0.0–1.0; only emitted when a watermark is present                                          |
| `watermark_scale`    | number                  | No        | `0.60`        | Fraction of page width; only emitted when a watermark is present                          |

#### `Page` (pages[]) — discriminator `type`

Two variants. `type="description"` for the prose letter page; `type="itemized"` for the estimate page.

##### Page type: `description`

| Field     | Type                    | Required? | Fallback | Notes                                                                      |
|-----------|-------------------------|-----------|----------|----------------------------------------------------------------------------|
| `type`    | `"description"`         | Yes       | —        | Discriminator                                                              |
| `blocks`  | array<DescriptionBlock> | No        | `[]`     | Ordered content blocks; rendered sequentially with vertical spacing        |

###### `DescriptionBlock` — discriminator `type`

| Field   | Type                                              | Required?              | Fallback       | Notes                                                         |
|---------|---------------------------------------------------|------------------------|----------------|---------------------------------------------------------------|
| `type`  | `enum("heading"\|"paragraph"\|"bullets")`         | Yes                    | —              | Determines rendering                                          |
| `text`  | string                                            | for heading, paragraph | `""`           | Inline `**bold**` markers honoured (wrap-safe)                |
| `items` | array<string>                                     | for bullets            | `[]`           | Bullet items; inline `**bold**` honoured                      |

##### Page type: `itemized`

| Field                | Type                      | Required? | Fallback         | Notes                                                                            |
|----------------------|---------------------------|-----------|------------------|----------------------------------------------------------------------------------|
| `type`               | `"itemized"`              | Yes       | —                | Discriminator                                                                    |
| `subtitle`           | string                    | No        | `""`             | Centred banner (e.g. `PRESUPUESTO ESTIMADO`); rendered in accent colour          |
| `project_label`      | string                    | No        | `""`             | Left half of project row (e.g. `PROJECT`, `DESCRIPCIÓN DE PROYECTO`)             |
| `project_description`| string                    | No        | `""`             | Right half (bold, letter-spaced)                                                 |
| `sections`           | array<ItemizedSection>    | No        | `[]`             | Section groupings of line items                                                  |
| `currency`           | string                    | No        | `""`             | Symbol (`€`, `£`, `$`, `¥`) for formatted totals                                 |
| `subtotal`           | number                    | No        | `0`              | Numeric subtotal                                                                 |
| `tax_rate`           | number                    | No        | `0`              | Fraction (e.g. `0.21` for 21%)                                                   |
| `total`              | number                    | No        | `0`              | Numeric total                                                                    |
| `subtotal_text`      | string                    | No        | derived          | Pre-formatted string (e.g. `€20.310`); preferred for locale-aware formatting     |
| `tax_text`           | string                    | No        | derived          | Pre-formatted tax amount                                                         |
| `total_text`         | string                    | No        | derived          | Pre-formatted total                                                              |

###### `ItemizedSection` (sections[])

| Field     | Type           | Required? | Fallback | Notes                                                                      |
|-----------|----------------|-----------|----------|----------------------------------------------------------------------------|
| `heading` | string         | No        | `""`     | Section heading (upper-case convention, rendered bold in primary colour)   |
| `items`   | array<string>  | No        | `[]`     | Line items; inline `**bold**` honoured (inclusion tags, etc.)              |

### UI gap (letter_quote)

- **`pages[]` as a structured author surface** — the Svelte builder currently auto-derives description page blocks from `notes` (split on `\n\n`) and `payment_terms` (heuristically bulleted). There is no UI for: direct heading blocks, explicit paragraph boundaries, per-item inline `**bold**` markers, per-section item grouping on the itemised page
- **`subtitle` override** — auto-chosen as `INVOICE` / `ESTIMATE` from `invoiceData.document_type`; no UI for `PRESUPUESTO ESTIMADO` / custom subtitles
- **`project_label` / `project_description` override** — currently sourced from `invoiceData.blackbox_description`; no explicit separation
- **Multi-section grouping on the itemised page** — builder always produces one default section; no UI to split line items into categories (`CUARTO DE BAÑO` vs `COCINA`)
- **Watermark** — already surfaced via ZigPdfSettings (global), but no per-quote override
- **`subtotal_text` / `tax_text` / `total_text` formatted strings** — serializer generates these; builder uses naive `formatCurrencyLetterQuote` (EUR-only heuristic)

---

## Template: `presentation`

Freeform canvas-style renderer. Used for multi-page pitch decks with
absolute-positioned elements. The Tauri app exposes this under the name
**"proposal"** — see the routing note at the top of this doc.

**Entry point**: `zigpdf_generate_presentation(json, out_len)` (no to-file
variant; the CLI uses `--presentation <in> <out>`).

### Top-level fields

| Field                 | Type            | Required? | Fallback                          | Notes                                   |
|-----------------------|-----------------|-----------|-----------------------------------|-----------------------------------------|
| `page_size`           | object          | No        | `{ width: 1920, height: 1080 }`   | Canvas dimensions                       |
| `pages`               | array<Page>     | No        | `[]`                              | Each page has a background + elements   |
| `default_font_size`   | number          | No        | `24`                              | Fallback for text elements without their own value |
| `default_text_color`  | hex_color       | No        | `#000000`                         | Fallback for text elements              |
| `default_background`  | hex_color       | No        | `#ffffff`                         | Fallback for pages without `background_color` |

#### `PageSize` (page_size)

| Field    | Type   | Required? | Fallback | Notes                    |
|----------|--------|-----------|----------|--------------------------|
| `width`  | number | No        | `1920`   | Points                   |
| `height` | number | No        | `1080`   | Points                   |

#### `Page` (pages[])

| Field              | Type              | Required? | Fallback | Notes                                        |
|--------------------|-------------------|-----------|----------|----------------------------------------------|
| `background_color` | hex_color         | No        | white    | Inherits `default_background` when absent    |
| `elements`         | array<Element>    | No        | `[]`     | See **Element** variants below               |

#### `Element` (pages[].elements[]) — discriminator `type`

Five element types. Coordinate system: top-left origin in points.

##### `type: "text"`

| Field         | Type                                | Required? | Fallback       | Notes                                                   |
|---------------|-------------------------------------|-----------|----------------|---------------------------------------------------------|
| `content`     | string                              | No        | `""`           | UTF-8 accepted; decoded to WinAnsi at render time       |
| `x`, `y`      | number                              | No        | `0`, `0`       |                                                         |
| `font_size`   | number                              | No        | `24`           |                                                         |
| `font_weight` | `enum("normal"\|"bold")`            | No        | `"normal"`     |                                                         |
| `font_style`  | `enum("normal"\|"italic")`          | No        | `"normal"`     |                                                         |
| `color`       | hex_color                           | No        | `#000000`      |                                                         |
| `text_align`  | `enum("left"\|"center"\|"right")`   | No        | `"left"`       |                                                         |
| `max_width`   | number                              | No        | none           | When set, enables word wrap                             |
| `line_height` | number                              | No        | `1.4`          | Multiplier of font_size                                 |

##### `type: "bullet_list"`

| Field          | Type            | Required? | Fallback    | Notes                                      |
|----------------|-----------------|-----------|-------------|--------------------------------------------|
| `items`        | array<string>   | No        | `[]`        | Bullet items                               |
| `x`, `y`       | number          | No        | `0`, `0`    |                                            |
| `font_size`    | number          | No        | `18`        |                                            |
| `color`        | hex_color       | No        | `#000000`   | Item text                                  |
| `bullet_color` | hex_color       | No        | `#2563eb`   | Bullet dot colour                          |
| `line_spacing` | number          | No        | `8`         | Points between items                       |
| `indent`       | number          | No        | `20`        | Bullet indent from left edge               |

##### `type: "table"`

| Field                 | Type                      | Required? | Fallback         | Notes                                                  |
|-----------------------|---------------------------|-----------|------------------|--------------------------------------------------------|
| `x`, `y`              | number                    | No        | `0`, `0`         |                                                        |
| `columns`             | array<string>             | No        | `[]`             | Header labels                                          |
| `rows`                | array<array<TableCell\|string>> | No   | `[]`             | Each row is an array of cells (string or object)       |
| `column_widths`       | array<number> (nullable)  | No        | auto             | When omitted, columns auto-size                        |
| `header_bg_color`     | hex_color                 | No        | `#2563eb`        |                                                        |
| `header_text_color`   | hex_color                 | No        | `#ffffff`        |                                                        |
| `row_bg_color`        | hex_color                 | No        | `#ffffff`        |                                                        |
| `alt_row_bg_color`    | hex_color                 | No        | `#f8f9fa`        | Zebra striping                                         |
| `text_color`          | hex_color                 | No        | `#000000`        |                                                        |
| `border_color`        | hex_color                 | No        | `#e0e0e0`        |                                                        |
| `border_width`        | number                    | No        | `1`              |                                                        |
| `font_size`           | number                    | No        | `14`             |                                                        |
| `header_font_size`    | number                    | No        | `14`             |                                                        |
| `padding`             | number                    | No        | `10`             |                                                        |
| `row_height`          | number                    | No        | `36`             |                                                        |
| `header_height`       | number                    | No        | `40`             |                                                        |

###### `TableCell` (row entries)

A cell may be a plain string (shorthand for `{ content }`) OR an object:

| Field        | Type                                   | Required? | Fallback        | Notes                                        |
|--------------|----------------------------------------|-----------|-----------------|----------------------------------------------|
| `content`    | string                                 | No        | `""`            |                                              |
| `text_align` | `enum("left"\|"center"\|"right")`      | No        | `"left"`        |                                              |
| `color`      | hex_color                              | No        | table `text_color` |                                           |
| `bg_color`   | hex_color                              | No        | row bg          | Overrides zebra striping for this cell       |

##### `type: "image"`

| Field             | Type       | Required? | Fallback | Notes                                                             |
|-------------------|------------|-----------|----------|-------------------------------------------------------------------|
| `base64`          | data_url   | No        | `""`     | `data:image/...;base64,...` or raw base64                         |
| `x`, `y`          | number     | No        | `0`, `0` |                                                                   |
| `width`, `height` | number     | No        | `100`    |                                                                   |
| `maintain_aspect` | bool       | No        | `true`   | If true and only one dimension is set, scales to fit              |

##### `type: "shape"`

| Field           | Type                                                                 | Required? | Fallback     | Notes                                                                 |
|-----------------|----------------------------------------------------------------------|-----------|--------------|-----------------------------------------------------------------------|
| `shape`         | `enum("rectangle"\|"rounded_rectangle"\|"circle"\|"ellipse"\|"line")` | No      | `"rectangle"`|                                                                       |
| `x`, `y`        | number                                                               | No        | `0`, `0`     | For `circle`: centre. For `line`: start point                         |
| `width`, `height` | number                                                             | No        | `100`, `100` | For `circle`: `width` = radius. For `line`: end-offset from `x`, `y`  |
| `fill_color`    | hex_color (nullable)                                                 | No        | `null`       | When `null`, no fill                                                  |
| `stroke_color`  | hex_color                                                            | No        | `#000000`    |                                                                       |
| `stroke_width`  | number                                                               | No        | `1`          |                                                                       |
| `corner_radius` | number                                                               | No        | `0`          | Used only for `rounded_rectangle`                                     |
| `opacity`       | number                                                               | No        | `1.0`        | 0.0–1.0                                                               |

### UI gap (presentation)

- **No Svelte builder UI exists** for presentation/canvas. Users reach it only via the raw JSON editor panel in ZigPdfView or by programmatic Rust code
- **No Rust serializer** — there is no `presentation_serializer.rs` that maps `QuoteWithDetails` → presentation JSON. The existing `buildPresentationJson(data)` in `ZigPdfView.svelte` is a client-side remapping and produces only a specific "pitch-deck" shape
- `default_font_size` / `default_text_color` / `default_background` — accepted but the builder never populates them; elements provide their own values
- Table rendering support is partial and not fully documented; treat as experimental

---

## Template: `proposal_legacy`

Branded first-page proposal with an accent header bar, logo, "PROPOSAL"
label, and structured sections (text / metrics / table / chart). Schema
is identical to `clean_quote` — the difference is purely in the Zig
renderer's layout.

**Entry point**: `zigpdf_generate_proposal(json, out_len)` — reachable
only via explicit `proposal_legacy` template name or the CLI
`--proposal` flag.

Refer to the **clean_quote** tables above for the full field list —
`ProposalData`, `Footer`, `Section`, `MetricItem`, `TableItem`.

### Template-specific rendering notes

- `primary_color` default is `#16a34a` (green)
- `secondary_color` default is `#1e3a2f` (dark green) — this is the company-name colour in proposal_legacy, unlike clean_quote where it's unused
- `company_logo_base64` IS rendered top-left (unlike clean_quote)
- `property_image_base64` IS rendered centred below the header (unlike clean_quote)
- `footer.phone` / `footer.email` are accepted but **not currently displayed** in the rendered footer (website only)
- `chart_spec` — same as clean_quote, **unsupported** and degrades to text

### UI gap (proposal_legacy)

- No direct Svelte UI today. The CLI accepts it via `pdf-gen --proposal input.json out.pdf`; a legacy demo fixture exists inside `proposal.zig` but no production caller uses this template

---

## Routing matrix

| Template name (API) | FFI function                          | Zig module         | Svelte builder?                              | Rust serializer?                 |
|---------------------|---------------------------------------|--------------------|----------------------------------------------|----------------------------------|
| `invoice`           | `zigpdf_generate_invoice`             | `invoice.zig`      | ✓ primary path via inline `json!{}`          | ✗ (inline in `commands.rs`)      |
| `clean_quote`       | `zigpdf_generate_clean_quote`         | `clean_quote.zig`  | ✓ `remapToSections(invoiceData)`             | ✗                                |
| `letter_quote`      | `zigpdf_generate_letter_quote`        | `letter_quote.zig` | ✓ `buildLetterQuotePayload(invoiceData)`     | ✓ `letter_quote_serializer.rs`   |
| `proposal`          | `zigpdf_generate_presentation`        | `presentation.zig` | ✓ `buildPresentationJson(invoiceData)`       | ✗                                |
| `proposal_legacy`   | `zigpdf_generate_proposal`            | `proposal.zig`     | ✗ (CLI / demo fixture only)                  | ✗                                |

## Implementation priority for the templateData refactor

Based on the UI-gap findings above, when `invoiceData.templateData` is
introduced as a discriminated union, these are the highest-value
per-template fields to author explicitly:

**letter_quote** — most leverage because currently-auto-derived blocks
are imprecise:

- `subtitle` override (`PRESUPUESTO ESTIMADO` / `ESTIMATE` / custom)
- `project_label` + `project_description` separation
- Separate `terms` textarea rendered as its own block (currently collapsed into `notes`)
- Multi-section item grouping (`sections[]` with distinct headings)
- Explicit inline `**bold**` authoring hint in the UI

**clean_quote** — smaller gap but important for consultants:

- `footer.dashboard_url` + `footer.dashboard_text` (QR code generation)
- Per-section `heading` override (detect "Next Steps" / "What's Included" triggers)
- Bullet content support in text sections

**invoice** — lowest priority; most fields either defaulted correctly or
belong in settings:

- `display_mode: "blackbox"` toggle (single-line summary mode)
- `payment_button_*` clickable PDF button config
- `verifactu_*` surfaced only when the quote has VeriFactu data

**proposal** (→ presentation) — deliberately deferred; canvas builder is
a separate UX problem:

- Consider a `presentation_serializer.rs` to map `QuoteWithDetails` →
  canned slides (title / stats / pricing / CTA) rather than expecting
  users to author elements directly

## Structured-editor follow-ups (out of scope for the immediate refactor)

The following fields would benefit from richer-than-textarea editing, in
rough priority order:

1. `letter_quote.pages[].blocks[]` — a typed-block editor (heading /
   paragraph / bullets) replacing the split-on-`\n\n` heuristic
2. `letter_quote.pages[].sections[]` — category-grouping UI for line
   items (per-section heading + drag-assign items)
3. `presentation.pages[].elements[]` — a canvas/form editor for
   positioned elements (entirely separate UX problem — likely a
   dedicated builder component)
4. Inline `**bold**` rich-text editing — low priority; textarea with
   documented markers works fine until it doesn't

These are all UI swaps on existing schema, not schema changes — they can
land incrementally after the discriminated-union refactor without
re-breaking anything.

## Update policy

- **Zig renderer source is the truth.** When this doc and a parser
  disagree, the parser wins. Patch the doc; don't patch the parser to
  match the doc.
- **One-doc-to-rule-them-all.** The ensure-drift-visible invariant is
  that Rust serializers, Svelte builders, and Next.js types ALL point
  at this doc. When adding a field to any of those, check this doc
  first. When adding a field to the Zig parser, update this doc in the
  same commit.
- **Conventions in the table matter.** "No fallback" means the renderer
  falls back to `null` / empty. "derived" means the parser computes a
  value from other fields. "unsupported" means the parser accepts the
  field but the renderer silently drops or degrades it.
