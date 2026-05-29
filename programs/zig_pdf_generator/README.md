# Zig PDF Generator CLI & Library

A high-performance, premium PDF generation engine written in Zig 0.16.0. It provides an extremely fast, zero-dependency CLI and a binary-clean C FFI for generating beautiful, pixel-perfect PDF documents from structured JSON payloads.

---

## UNIX Philosophy & Stream Isolation

The `pdf-gen` CLI tool is built to integrate seamlessly with standard UNIX pipelines and automated build environments:

1. **Unbounded Stdin Parsing**: If no input file is specified, the CLI streams the input JSON from standard input (`stdin`) up to a **50MB safety threshold**, accommodating extremely large embedded base64 images or watermarks.
2. **Binary-Clean Stdout Isolation**: If no output file is specified, the generated raw PDF bytes are written directly to standard output (`stdout`). Standard output is guaranteed to be completely binary-clean.
3. **Stderr Routing for Diagnostics**: All diagnostic messages, informational headers, generator warnings, and parsing errors are written strictly to standard error (`stderr`) to prevent stream pollution.
4. **Flag Exclusivity Validation**: The five core template flags are strictly mutually exclusive. If multiple template flags are passed, the CLI immediately prints a validation error to `stderr` and exits with code `1`.
5. **Strict Schema Validation (fail-fast)**: Each template enforces presence checks on its required root fields. A payload that is valid JSON but is missing a critical field (or is shaped for a *different* template) is rejected with a specific `stderr` diagnostic naming the missing field and template, and a non-zero exit. The CLI **never** emits a blank/partial PDF on a schema mismatch.

### CLI Command Reference

```bash
# Compile the CLI executable
zig build

# View CLI options and help
./zig-out/bin/pdf-gen --help

# Method A: Standard File-to-File Invocation (Defaults to --basic)
./zig-out/bin/pdf-gen input.json output.pdf

# Method B: Absolute UNIX Pipelining (JSON on stdin -> PDF on stdout)
cat input.json | ./zig-out/bin/pdf-gen --letter > output.pdf

# Method C: Mixed Streaming
./zig-out/bin/pdf-gen --minimalist input.json > output.pdf
```

> [!IMPORTANT]
> The template selection flags (`--basic`, `--minimalist`, `--letter`, `--presentation`, `--proposal`) are mutually exclusive. Passing more than one flag will result in an error:
> ```bash
> $ ./zig-out/bin/pdf-gen --basic --letter input.json
> Error: Multiple template flags specified. Template flags (--basic, --minimalist, --letter, --presentation, --proposal) are mutually exclusive.
> ```

> [!WARNING]
> **Schema mismatches fail fast — they do not produce a blank PDF.** Feeding a payload shaped for one template into another flag is rejected with a specific diagnostic and exit code `1`:
> ```bash
> $ ./zig-out/bin/pdf-gen --letter crg_solar_proposal.json out.pdf
> Error: Schema mismatch. Missing required field 'company' (object) for --letter template.
>        A --letter payload requires a top-level "company" object and a non-empty "pages" array.
> $ echo $?
> 1
> ```

---

## Standardized Template Modes & Schemas

Each mode accepts a specific JSON schema mapping exactly to our high-performance Zig backend data structures.

```mermaid
graph TD
    JSON[Input JSON Payload] --> CLI{pdf-gen CLI}
    CLI -->|--basic| T1[Basic Invoice/Receipt]
    CLI -->|--minimalist| T2[Clean Consultant Quote]
    CLI -->|--letter| T3[Premium Letter Quote]
    CLI -->|--presentation| T4[Canvas Presentation]
    CLI -->|--proposal| T5[Structured Proposal]
```

---

### 1. Basic Template (`--basic`)
The standard professional invoice/receipt template. Ideal for traditional invoices, receipts, and transactional billing.

#### Key Zig Struct Mapping (`InvoiceData`)
* **`document_type`** (`string`, optional): `"invoice"` or `"quote"`. Affects semantic labels.
* **`company_name`** (`string`, optional)
* **`company_address`** (`string`, optional)
* **`company_vat`** (`string`, optional)
* **`company_logo_base64`** (`string`, optional): Base64-encoded PNG/JPEG logo image.
* **`client_name`** (`string`, optional)
* **`client_address`** (`string`, optional)
* **`client_vat`** (`string`, optional)
* **`invoice_number`** (`string`, optional)
* **`invoice_date`** (`string`, optional)
* **`due_date`** (`string`, optional)
* **`items`** (`array`, optional): List of line item objects:
  * `description` (`string`)
  * `quantity` (`number` / float)
  * `unit_price` (`number` / float)
  * `total` (`number` / float, auto-calculated if omitted)
* **`subtotal`** (`number` / float, optional)
* **`tax_rate`** (`number` / float, optional): Decimal fraction (e.g. `0.21` for 21% VAT).
* **`tax_amount`** (`number` / float, optional)
* **`total`** (`number` / float, optional)
* **`primary_color`** (`string`, optional): Hex color (e.g., `"#627eea"`) for accents and branding.
* **`notes`** (`string`, optional)

#### Canonical Payload Example
```json
{
  "document_type": "invoice",
  "company_name": "Quantum Labs",
  "company_address": "789 Blockchain Ave, Crypto City, CC 12345",
  "company_vat": "US987654321",
  "client_name": "DeFi Protocol Inc",
  "client_address": "123 Smart Contract Blvd, Web3 Town",
  "client_vat": "US123456789",
  "invoice_number": "CRYPTO-2026-001",
  "invoice_date": "2026-01-04",
  "due_date": "2026-01-14",
  "items": [
    {"description": "Smart Contract Development", "quantity": 40.0, "unit_price": 250.0, "total": 10000.0},
    {"description": "Security Audit", "quantity": 1.0, "unit_price": 5000.0, "total": 5000.0}
  ],
  "subtotal": 15000.0,
  "tax_rate": 0.21,
  "tax_amount": 3150.0,
  "total": 18150.0,
  "primary_color": "#627eea",
  "notes": "Payment accepted in USD or equivalent cryptocurrency."
}
```

---

### 2. Minimalist Template (`--minimalist`)
A clean, white-paper layout utilizing a single accent color. The document type (QUOTE, INVOICE, HANDOVER, or INSPECTION) is automatically derived from the prefix of the `reference` field (e.g. `QTE-`, `INV-`, `HND-`, `INS-`).

> [!IMPORTANT]
> **Required root fields (validated — missing → `error` + exit 1):**
> * **`company_name`** (`string`, **required**, non-empty): Missing → `Missing required field 'company_name' (string) for --minimalist template.`
> * **`sections`** (`array`, **required**, non-empty): Missing/empty → `Missing required field 'sections' (non-empty array) for --minimalist template.`
>
> `--minimalist` shares the `ProposalData` shape with `--proposal` (same required fields); the two differ only in visual style — see the comparison table in [§5](#5-proposal-template---proposal).

#### Key Zig Struct Mapping (`ProposalData`)
* **`company_name`** (`string`, **required**)
* **`company_address`** (`string`, optional)
* **`client_name`** (`string`, optional)
* **`client_address`** (`string`, optional)
* **`reference`** (`string`, optional): Driving reference identifier.
* **`date`** (`string`, optional)
* **`valid_until`** (`string`, optional)
* **`primary_color`** (`string`, optional): Accent hex color (e.g. `"#16a34a"`).
* **`sections`** (`array`, optional): List of sections containing content:
  * `section_type` (`string`): `"text"`, `"metrics"`, or `"table"`.
  * `heading` (`string`, optional)
  * `content` (`string`, optional): Used for `"text"` sections. Bullet formatting supported with leading `- ` or `* `.
  * `metric_items` (`array`, optional): Used for `"metrics"` sections. Format: `[{"label": "...", "value": "..."}]`.
  * `table_items` (`array`, optional): Used for `"table"` sections. Format: `[{"description": "...", "quantity": 1.0, "unit_price": 100.0, "total": 100.0}]`.
  * `subtotal` / `tax_rate` / `total` (`number` / float, optional): Financial sum lines on tables.
* **`footer`** (`object`, optional): Contact and metadata details:
  * `phone` (`string`, optional)
  * `email` (`string`, optional)
  * `website` (`string`, optional)
  * `dashboard_url` (`string`, optional): Renders an automatic QR code linking here on the final page.

#### Canonical Payload Example
```json
{
  "company_name": "Green Energy Solutions",
  "company_address": "456 Solar Way, eco-District",
  "client_name": "Ocean View Residency",
  "client_address": "88 Coastal Road, Marine Bay",
  "reference": "QTE-2026-889",
  "date": "2026-05-28",
  "valid_until": "2026-06-28",
  "primary_color": "#16a34a",
  "sections": [
    {
      "section_type": "text",
      "heading": "Project Overview",
      "content": "We propose a full residential solar grid installation.\n- 12x high-efficiency monocrystalline panels.\n- Smart grid microinverter with real-time analytics."
    },
    {
      "section_type": "metrics",
      "heading": "Projected Performance",
      "metric_items": [
        {"label": "Annual Generation", "value": "5.4 MWh"},
        {"label": "CO2 Displaced", "value": "2.1 Tons/yr"}
      ]
    },
    {
      "section_type": "table",
      "heading": "Financial Investment",
      "table_items": [
        {"description": "Photovoltaic Panel Array", "quantity": 12.0, "unit_price": 350.0, "total": 4200.0},
        {"description": "Grid Inverter & Storage Kit", "quantity": 1.0, "unit_price": 2800.0, "total": 2800.0}
      ],
      "subtotal": 7000.0,
      "tax_rate": 0.05,
      "total": 8400.0
    }
  ],
  "footer": {
    "phone": "+44 20 7946 0958",
    "email": "install@greenenergy.co.uk",
    "website": "www.greenenergy.co.uk",
    "dashboard_url": "https://portal.greenenergy.co.uk/quotes/QTE-2026-889"
  }
}
```

---

### 3. Premium Letter Template (`--letter`)
A premium, multi-page layout utilizing embedded Montserrat typography, elegant gold hairline separators, an optional watermark, and a formal letter structure. Best suited for high-value contractor quotes.

> [!IMPORTANT]
> **Required root fields (validated — missing → `error` + exit 1):**
> * **`company`** (`object`, **required**): Missing → `Missing required field 'company' (object) for --letter template.`
> * **`pages`** (`array`, **required**, non-empty): Missing/empty → `Missing required field 'pages' (non-empty array) for --letter template.`
>
> Note: the `--letter` schema is **distinct** from `--proposal`/`--minimalist`. It uses a top-level `company` *object* and a `pages` array of `{type:"description"|"itemized"}` — not the flat `company_name` + `sections` shape. Feeding a proposal-shaped payload here fails fast.

#### Key Zig Struct Mapping (`LetterQuoteData`)
* **`company`** (`object`): Centered title and subtitle block:
  * `name` (`string`)
  * `phone` (`string`)
  * `email` (`string`)
* **`client`** (`string`): Recipient client name.
* **`date`** (`string`)
* **`style`** (`object`):
  * `primary_color` (`string`): Title/header hex color (e.g. `"#1a2a5e"`).
  * `accent_color` (`string`): Hairlines and total highlights (e.g. `"#e8a83d"`).
  * `font_family` (`string`): `"montserrat"` (triggers premium embedded TrueType) or `"helvetica"`.
  * `watermark_image` (`string`, optional): Filepath or base64 data-URL.
  * `watermark_opacity` (`number` / float, optional): 0.0–1.0.
  * `watermark_scale` (`number` / float, optional): Width percentage.
* **`pages`** (`array`): Distinct pages of types `"description"` (prose block) or `"itemized"` (cost quote sheets):
  * `type` (`string`): `"description"` or `"itemized"`.
  * `blocks` (`array`, description only): Content items containing heading, paragraphs, and lists. Supporting inline `**bold**` formatting.
  * `sections` (`array`, itemized only): Section groupings of item lines.
  * `subtotal` / `tax_rate` / `total` (`number` / float)
  * `subtotal_text` / `tax_text` / `total_text` (`string`): Formatted localized currency representations.

#### Canonical Payload Example
> [!TIP]
> This is the verified canonical Spanish-reforms payload used for high-end residential quote generation.

```json
{
  "company": {
    "name":  "REFORMAS COSTA SOL",
    "phone": "+34 623194238",
    "email": "info@reformascostasol.com"
  },
  "client": "MARI CRUZ",
  "date":   "17/11/2025",
  "style": {
    "primary_color":     "#1a2a5e",
    "accent_color":      "#e8a83d",
    "font_family":       "montserrat",
    "watermark_image":   "templates/reformas_watermark.png",
    "watermark_opacity": 0.08,
    "watermark_scale":   0.55
  },
  "pages": [
    {
      "type": "description",
      "blocks": [
        { "type": "heading",   "text": "Proyecto reforma integral de vivienda (100 m²)." },
        { "type": "paragraph", "text": "Realizaremos una reforma integral orientada a transformar por completo la vivienda..." }
      ]
    },
    {
      "type": "itemized",
      "subtitle":            "PRESUPUESTO ESTIMADO",
      "project_label":       "DESCRIPCIÓN DE PROYECTO",
      "project_description": "REFORMA INTEGRAL DE PISO",
      "sections": [
        {
          "heading": "CUARTO DE BAÑO",
          "items": [
            "RETIRADA DE ACCESORIOS SANITARIOS ANTIGUOS"
          ]
        }
      ],
      "currency":      "€",
      "subtotal":      20310.00,
      "tax_rate":      0.21,
      "total":         24575.10,
      "subtotal_text": "€20.310",
      "tax_text":      "€4.265,10",
      "total_text":    "€24.575,10"
    }
  ]
}
```

---

### 4. Presentation Template (`--presentation`)
A freeform multi-page canvas-style engine where elements (text, bulleted lists, tables, shapes, and images) are absolutely positioned on a custom grid (default: 1080p layout). Excellent for rich marketing proposals or customized reporting slide decks.

#### Key Zig Struct Mapping (`PresentationData`)
* **`page_size`** (`object`, optional): Width/height in points. Defaults to `1920` x `1080`.
* **`default_font_size`** (`number` / float, optional): Default `24`.
* **`default_text_color`** (`string`, optional): Default `"#000000"`.
* **`default_background`** (`string`, optional): Default `"#ffffff"`.
* **`pages`** (`array`): Distinct slide page arrays with background and positioning elements:
  * `background_color` (`string`, optional)
  * `elements` (`array`): List of positioning components:
    * `type` (`string`): `"text"`, `"bullet_list"`, `"table"`, `"image"`, `"shape"`.
    * `x` / `y` (`number` / float): Top-left coordinates.
    * Elements have custom type-specific attributes (`font_size`, `items`, `columns`, `rows`, `base64`, `shape`, `fill_color`, `stroke_color`, etc.).

#### Canonical Payload Example
```json
{
  "page_size": { "width": 1920, "height": 1080 },
  "default_font_size": 24,
  "pages": [
    {
      "background_color": "#111827",
      "elements": [
        {
          "type": "shape",
          "shape": "rectangle",
          "x": 0.0,
          "y": 0.0,
          "width": 1920.0,
          "height": 160.0,
          "fill_color": "#1f2937",
          "stroke_width": 0.0
        },
        {
          "type": "text",
          "content": "Quarterly Technical Architecture Report",
          "x": 80.0,
          "y": 55.0,
          "font_size": 40.0,
          "font_weight": "bold",
          "color": "#f9fafb"
        },
        {
          "type": "bullet_list",
          "x": 100.0,
          "y": 280.0,
          "font_size": 28.0,
          "color": "#e5e7eb",
          "bullet_color": "#3b82f6",
          "line_spacing": 12.0,
          "items": [
            "Completed WASM standard memory deallocation layer",
            "Added explicit mutually exclusive flag validation to the CLI binary",
            "Isolated standard output to support high-throughput piping streams"
          ]
        }
      ]
    }
  ]
}
```

---

### 5. Proposal Template (`--proposal`)
A structured, multi-section A4 proposal/quote document with first-class support for **metric grids**, **itemized cost tables**, and **embedded charts** (pie / donut / bar / progress). Best suited for sales proposals, solar/construction quotes, and reports where the body is a sequence of typed content sections rather than a freeform canvas.

> [!IMPORTANT]
> **`--proposal` vs `--minimalist` — they consume similar (`ProposalData`-shaped) JSON but render very differently. Do not confuse them:**
> | | `--minimalist` (`clean_quote`) | `--proposal` (`proposal`) |
> |---|---|---|
> | Layout | Single-accent clean white quote sheet | Multi-section proposal w/ charts & metric grids |
> | Document type | Derived from `reference` prefix (`QTE-`/`INV-`/`HND-`/`INS-`) | Always a proposal |
> | Section `type`s | text / table | `text` / `metrics` / `table` / `chart` |
> | Charts | ✗ | ✓ (pie, donut, bar, progress) |
>
> A given payload (e.g. `templates/crg_solar_proposal.json`) is accepted by **both** flags — pick the flag for the *visual style* you want.

#### Required root fields (validated — missing → `error` + exit 1)
* **`company_name`** (`string`, **required**, non-empty): Sender identity. Missing → `Missing required field 'company_name' (string) for --proposal template.`
* **`sections`** (`array`, **required**, non-empty): The document body. Missing/empty → `Missing required field 'sections' (non-empty array) for --proposal template.`

#### Key Zig Struct Mapping (`ProposalData`)
* **`company_name`** (`string`, required) / **`company_address`** (`string`)
* **`company_logo_base64`** (`string`, optional): Embedded logo image.
* **`client_name`** / **`client_address`** (`string`)
* **`reference`** / **`date`** / **`valid_until`** (`string`)
* **`primary_color`** (`string`, default `"#16a34a"`) / **`secondary_color`** (`string`, default `"#1e3a2f"`) / **`title_color`** (`string`, optional)
* **`property_image_base64`** (`string`, optional): e.g. a satellite property view.
* **`footer`** (`object`, optional): `phone`, `email`, `website`, `dashboard_text`, `dashboard_url`.
* **`crypto_payment`** (`object`, optional): see the shared Cryptocurrency Payment Block below.
* **`sections`** (`array`, required): Each section is an object with a `type`:
  * `type: "text"` — `heading` (`string`), `content` (`string`).
  * `type: "metrics"` — `heading` plus `metric_items` (`array` of `{ "label": string, "value": string }`), rendered as a metric grid.
  * `type: "table"` — `heading` plus `table_items` (`array` of `{ "description": string, "quantity": number, "unit_price": number, "total": number }`), plus optional `subtotal` / `tax_rate` / `total` (`number`) and `notes` (`string`).
  * `type: "chart"` — `heading` plus `chart_spec` (`object`): `chart_type` (`"pie"|"donut"|"bar"|"progress"`), `segments` (`[{ "label", "value", "color?" }]` for pie/donut/progress), `categories` (`[string]`) + `series` (`[{ "name", "values": [number] }]`) for bar, plus optional `width` / `height` (`number`).

#### Canonical Payload Example
```json
{
  "company_name": "CRG Direct",
  "company_address": "Unit 7 Solent Business Park, Fareham, Hampshire PO15 7FH",
  "client_name": "Mr & Mrs Thompson",
  "reference": "CRG-2026-00456",
  "date": "29/05/2026",
  "valid_until": "28/06/2026",
  "primary_color": "#16a34a",
  "secondary_color": "#1e3a2f",
  "sections": [
    { "type": "text", "heading": "Executive Summary", "content": "A fully integrated 6.4 kWp solar PV and battery system..." },
    {
      "type": "metrics",
      "heading": "System Performance",
      "metric_items": [
        { "label": "Annual Generation", "value": "5,920 kWh" },
        { "label": "Estimated Savings", "value": "£1,240 / yr" },
        { "label": "Payback Period",    "value": "7.2 years" }
      ]
    },
    {
      "type": "table",
      "heading": "System Components & Pricing",
      "table_items": [
        { "description": "16 x 400W Monocrystalline Panels", "quantity": 16, "unit_price": 185.00, "total": 2960.00 },
        { "description": "Hybrid Inverter 6kW",              "quantity": 1,  "unit_price": 1450.00, "total": 1450.00 }
      ],
      "subtotal": 4410.00,
      "tax_rate": 0.0,
      "total": 4410.00,
      "notes": "Includes full installation and MCS certification."
    },
    {
      "type": "chart",
      "heading": "Energy Mix After Install",
      "chart_spec": {
        "chart_type": "donut",
        "segments": [
          { "label": "Solar",  "value": 62, "color": "#16a34a" },
          { "label": "Grid",   "value": 38, "color": "#94a3b8" }
        ]
      }
    }
  ],
  "footer": {
    "phone": "01329 800 123",
    "email": "info@crgdirect.co.uk",
    "website": "www.crgdirect.co.uk"
  }
}
```

> [!TIP]
> Verified working inputs: `templates/crg_solar_proposal.json` and `pdf-chart-tests/crg-proposal-test.json`.

---

### Modular Cryptocurrency Payment Block

All five templates (`--basic`, `--minimalist`, `--letter`, `--presentation`, `--proposal`) universally support an optional, premium cryptocurrency payment block (`crypto_payment`). This generates a beautiful, themed summary page (or canvas card) featuring transaction details, custom network colors, and a clean, native QR code.

To protect against transport-level floating point precision loss, the `amount` field is strictly defined and processed as a string slice.

#### Schema Definition (`CryptoPaymentBlock`)
* **`network`** (`string`): The cryptocurrency network name (e.g., `"bitcoin"`, `"ethereum"`, `"polygon"`, `"bnb"`, `"litecoin"`, `"dogecoin"`).
* **`to_address`** (`string`): The recipient's wallet address.
* **`from_address`** (`string`, optional): The sender's wallet address.
* **`amount`** (`string`, optional): The exact payment amount (e.g., `"5.50000000"`). **Must be passed as a string** to prevent IEEE-754 precision loss.
* **`currency`** (`string`, optional): Custom coin symbol override (defaults to the network's standard asset).

#### Canonical JSON Example
```json
"crypto_payment": {
  "network": "ethereum",
  "to_address": "0x742d35Cc6634C0532925a3b844Bc454e4438f44e",
  "from_address": "0x1111111111111111111111111111111111111111",
  "amount": "5.50000000",
  "currency": "ETH"
}
```

---

## Technical Validation

Every field type across these schemas maps explicitly to a field on the corresponding Zig templates, guaranteeing clean serialization. If any field types do not match, the JSON parser will throw a detailed diagnostic error to `stderr` with details of the violation.

To verify your environment, you can run the built-in test suite:
```bash
zig build test
```
*(Note: Minor pre-existing compression assertions in string-matching unit tests are a known library quirk and do not affect runtime execution of PDF generation).*
