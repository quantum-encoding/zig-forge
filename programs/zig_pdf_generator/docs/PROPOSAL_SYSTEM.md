# CRG Direct Proposal System

## Overview

The proposal system generates branded PDF quotes for CRG Direct's solar, battery, heat pump, and EV charger installations. It produces professional multi-page PDFs with auto-layout, QR codes linking to the customer dashboard, and product-specific detail sections.

The system has three parts:

1. **PDF Generator** (`src/proposal.zig`) — Zig binary that takes structured JSON and produces a PDF
2. **Product Database** (`templates/crg_product_database.json`) — Catalogue of products, pricing, and pre-written proposal sections
3. **Svelte Admin UI** (to be built) — Web interface where admins build proposals by selecting products

## Architecture

```
Svelte Admin UI                    PDF Generator Binary
     |                                    |
     |  1. Admin selects products         |
     |  2. Adjusts quantities/pricing     |
     |  3. Adds client details            |
     |                                    |
     v                                    |
Product Database -----> Proposal JSON -----> proposal.zig -----> PDF bytes
(crg_product_database.json)                                        |
                                                                   v
                                                           Customer Dashboard
                                                           (view quote, accept)
```

## Proposal JSON Schema

The PDF generator accepts a single JSON object. Every field has a sensible default, so only the fields you need must be included.

```json
{
  "company_name": "CRG Direct",
  "company_address": "Unit 7 Solent Business Park, Fareham, Hampshire PO15 7FH",
  "company_logo_base64": null,
  "client_name": "Mr & Mrs Johnson",
  "client_address": "42 Oak Lane\nSouthampton\nSO16 3QR",
  "reference": "CRG-2026-00123",
  "date": "8 February 2026",
  "valid_until": "10 March 2026",
  "primary_color": "#16a34a",
  "secondary_color": "#1e3a2f",
  "property_image_base64": null,
  "footer": {
    "phone": "01329 800 123",
    "email": "info@crgdirect.co.uk",
    "website": "www.crgdirect.co.uk",
    "dashboard_text": "Sign in to your CRG Direct dashboard at dashboard.crgdirect.co.uk to view your quote, track progress and manage your installation.",
    "dashboard_url": "https://dashboard.crgdirect.co.uk/quotes/CRG-2026-00123"
  },
  "sections": []
}
```

### Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `company_name` | string | Yes | Displayed in header |
| `company_address` | string | No | Below company name in header |
| `company_logo_base64` | string | No | Base64-encoded logo image (PNG or JPEG) |
| `client_name` | string | Yes | "Prepared for:" in header |
| `client_address` | string | No | Newline-separated address lines |
| `reference` | string | Yes | Quote reference number |
| `date` | string | Yes | Quote date |
| `valid_until` | string | No | Expiry date |
| `primary_color` | hex string | No | Default `#16a34a` (CRG green) |
| `secondary_color` | hex string | No | Default `#1e3a2f` (dark green) |
| `property_image_base64` | string | No | Base64 satellite/solar API image, centered in header |
| `footer.phone` | string | No | Footer contact bar |
| `footer.email` | string | No | Footer contact bar |
| `footer.website` | string | No | Footer contact bar |
| `footer.dashboard_text` | string | No | Italic text above footer bar (dashboard CTA) |
| `footer.dashboard_url` | string | No | URL encoded as QR code on every page |

### Section Types

The `sections` array contains an ordered list of sections. Each section has a `type` field that determines which fields are used.

#### Text Section

```json
{
  "type": "text",
  "heading": "About Your Solar Panels",
  "content": "Paragraph text here.\n\nSecond paragraph.\n\n- Bullet point one\n- Bullet point two"
}
```

- `heading`: Rendered in bold primary colour, 14pt
- `content`: Word-wrapped body text. Newlines create paragraph breaks. Lines starting with `- ` render as bullet points.
- Supports UTF-8: pound signs, em dashes, bullets, smart quotes are all converted automatically.

#### Metrics Section

```json
{
  "type": "metrics",
  "heading": "Estimated System Performance",
  "metric_items": [
    { "label": "System Size", "value": "4.2 kWp" },
    { "label": "Annual Generation", "value": "3,800 kWh" },
    { "label": "Est. Annual Savings", "value": "\u00a31,140/yr" },
    { "label": "CO2 Offset", "value": "0.88 tonnes" }
  ]
}
```

- Renders as a row of coloured callout cards (1-4 cards)
- Cards auto-size to fill the page width
- Value text auto-scales if it's too wide for the card
- Use `\u00a3` for the pound sign in JSON

#### Table Section

```json
{
  "type": "table",
  "heading": "System Pricing",
  "table_items": [
    { "description": "JA Solar 420W Panels", "quantity": 10, "unit_price": 185.00, "total": 1850.00 },
    { "description": "GivEnergy 5.2kWh Battery", "quantity": 1, "unit_price": 2895.00, "total": 2895.00 }
  ],
  "subtotal": 4745.00,
  "tax_rate": 0.0,
  "total": 4745.00,
  "notes": "Includes: MCS certification, 10-year workmanship warranty"
}
```

- Header row with dark background
- Alternating row shading
- Pound signs formatted automatically with thousands separators
- `tax_rate` of 0 hides the VAT line
- `notes` renders in small italic grey text below totals (optional)

## Product Database

`templates/crg_product_database.json` contains all CRG Direct products. Structure:

```
categories
  solar_panels.products[]     — JA Solar 420W, LONGi 425W, Canadian Solar 440W
  batteries.products[]        — GivEnergy 5.2kWh, 9.5kWh, Tesla Powerwall 3
  inverters.products[]        — SolarEdge SE5000H, GivEnergy Hybrid 5kW
  heat_pumps.products[]       — Daikin 8kW, Mitsubishi 8.5kW, Vaillant 7kW
  ev_chargers.products[]      — myenergi zappi, Ohme Home Pro
  installation.products[]     — Standard solar install, scaffolding, heat pump install, EV install
  grants.products[]           — BUS grant (-£7,500), Warm Home Local (-£15,000), Octopus Zero Bills

bundles
  solar_only                  — panels + inverter + install + scaffolding
  solar_battery               — panels + battery AIO + install + scaffolding
  solar_battery_ev            — panels + battery + inverter + zappi + installs
  heat_pump                   — heat pump + install + BUS grant
  warm_home_grant             — panels + battery + inverter + heat pump + installs + WHG
  zero_bills                  — panels + powerwall + heat pump + installs + Octopus
```

### Each Product Contains

| Field | Description |
|-------|-------------|
| `id` | Unique identifier (e.g. `ja-solar-420w`) |
| `name` | Display name |
| `manufacturer` | Brand name |
| `unit_price` | Price per unit (negative for grants) |
| `table_item` | Object with `description` and `unit_price` — maps directly to a table row |
| `proposal_section` | Full section object (`type`, `heading`, `content`) — maps directly to a proposal section |

### How the Svelte Admin UI Should Use This

1. **Load the product database** at startup (fetch from API or embed in build)
2. **Present bundles** as quick-start options. When admin picks "Solar + Battery", pre-populate with the bundle's `default_products`
3. **Allow product swaps** — e.g. swap JA Solar for LONGi by selecting from `solar_panels.products[]`
4. **Quantity is per-product** — admin sets panel count, the UI calculates `total = quantity * unit_price`
5. **Build sections array** automatically:
   - First section: personalised intro text (admin can edit)
   - Metrics section: calculated from system spec (kWp, annual kWh, savings, CO2)
   - Table section: built from selected products' `table_item` entries
   - Product detail sections: each selected product's `proposal_section` (skip for installation/scaffolding items that have no section)
   - Grants section: if applicable, include the grant's `proposal_section`
   - Final section: "What Happens Next" (standard template, admin can edit)
6. **Calculate totals**: sum all `table_item.total` values for subtotal. Apply tax rate if needed. Include grant deductions.
7. **Set dashboard_url**: `https://dashboard.crgdirect.co.uk/quotes/{reference}` — this becomes the QR code
8. **POST the complete JSON** to the PDF generator API endpoint
9. **Store the JSON** in the database against the quote reference for the customer dashboard

### Warm Home Grant / Octopus Zero Bills Proposals

These are larger packages with multiple product categories. A typical Warm Home Grant proposal would have 8+ sections across 3-4 pages:

1. Your Personalised Quote (text)
2. Key Metrics (metrics — 4 cards)
3. System Pricing (table — 6+ line items including the grant deduction)
4. About Your Solar Panels (text — from product database)
5. About Your Battery Storage (text — from product database)
6. About Your Air Source Heat Pump (text — from product database)
7. Warm Home: Local Grant Scheme (text — from product database)
8. Why Choose CRG Direct? (text — standard template)
9. What Happens Next (text — standard template)

## CLI Usage

```bash
# Generate from JSON file
pdf-gen --proposal input.json output.pdf

# Generate demo (built-in CRG solar+battery example)
pdf-gen --demo-proposal output.pdf
```

## FFI Usage (from Svelte/Node via native addon or WASM)

```c
#include "zigpdf.h"

// Generate PDF bytes in memory
size_t len;
uint8_t* pdf = zigpdf_generate_proposal(json_string, &len);
if (pdf) {
    // Send pdf bytes as HTTP response
    zigpdf_free(pdf, len);
}

// Or write directly to file
int ok = zigpdf_generate_proposal_to_file(json_string, "/tmp/quote.pdf");
```

## QR Code

When `footer.dashboard_url` is set, a QR code is generated and rendered on every page footer (bottom-right). The QR code encodes the exact URL string. Customers can scan it with their phone camera to go directly to their quote on the dashboard.

The QR code is generated using the built-in `qrcode.zig` encoder (pure Zig, ISO 18004, Reed-Solomon error correction level M). No external dependencies.

## Property Image

When `property_image_base64` is set, the base64-encoded image (PNG or JPEG) is decoded and rendered centered in the header area with a light grey border and "Your property - satellite view" caption. This is intended for satellite imagery from the solar API showing the customer's roof.

## Page Layout

- A4 portrait (595.28 x 841.89 points)
- 50pt margins left/right/top, 65pt bottom (100pt when QR code present)
- Automatic page breaks — content flows across as many pages as needed
- Footer on every page: coloured bar with contact info, QR code + dashboard text, page numbers
- Header only on first page: company name, client details, reference info, property image

## Currency

All prices are rendered with the pound sign (£) using WinAnsiEncoding (byte `0xA3`). Thousands separators are included automatically. Use `\u00a3` in JSON for the pound sign in text content — the renderer converts UTF-8 to WinAnsi automatically.
