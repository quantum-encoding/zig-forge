# Zig PDF Generator - JSON Schema Guide

Generate professional invoices, quotes, contracts, and documents by providing structured JSON data. This guide enables AI systems to produce valid JSON in a single request.

## Quick Start

```bash
# Generate invoice from JSON file
pdf-gen invoice.json output.pdf

# Generate from stdin
echo '{"company_name":"Acme","items":[...],"total":100}' | pdf-gen --stdin output.pdf

# Generate demo invoice
pdf-gen --demo demo.pdf

# Generate contract from JSON file
pdf-gen --contract contract.json output.pdf

# Generate demo contract
pdf-gen --demo-contract demo_contract.pdf
```

## Complete JSON Schema

```json
{
  "document_type": "invoice",
  "company_name": "Your Company Ltd",
  "company_address": "123 Business Street\nLondon, UK\nEC1A 1BB",
  "company_vat": "GB123456789",
  "company_logo_base64": null,

  "client_name": "Client Name",
  "client_address": "456 Client Road\nManchester, UK",
  "client_vat": "GB987654321",

  "invoice_number": "INV-2024-001",
  "invoice_date": "2024-01-09",
  "due_date": "2024-02-09",

  "display_mode": "itemized",
  "items": [
    {
      "description": "Product or service description",
      "quantity": 10,
      "unit_price": 25.00,
      "total": 250.00
    }
  ],

  "subtotal": 250.00,
  "tax_rate": 0.20,
  "tax_amount": 50.00,
  "total": 300.00,

  "notes": "Thank you for your business",
  "payment_terms": "Payment due within 30 days",

  "primary_color": "#b39a7d",
  "secondary_color": "#2c3e50"
}
```

## Field Reference

### Document Type (Required)
| Field | Type | Values | Description |
|-------|------|--------|-------------|
| `document_type` | string | `"invoice"`, `"quote"` | Determines header text |

### Company Information
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `company_name` | string | Yes | Your business name |
| `company_address` | string | Yes | Full address (use `\n` for line breaks) |
| `company_vat` | string | No | VAT/Tax registration number |
| `company_logo_base64` | string | No | Base64-encoded PNG/JPEG logo |

### Client Information
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `client_name` | string | Yes | Client/customer name |
| `client_address` | string | Yes | Client address (use `\n` for line breaks) |
| `client_vat` | string | No | Client VAT number |

### Document Details
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `invoice_number` | string | Yes | Unique document reference |
| `invoice_date` | string | Yes | Issue date (any format, displayed as-is) |
| `due_date` | string | No | Payment due date |

### Line Items

#### Display Modes
| Mode | Description |
|------|-------------|
| `"itemized"` | Show full table with all items (default) |
| `"blackbox"` | Single summary line, hides item details |

#### Itemized Mode
```json
{
  "display_mode": "itemized",
  "items": [
    {
      "description": "Consulting services - January 2024",
      "quantity": 40,
      "unit_price": 75.00,
      "total": 3000.00
    },
    {
      "description": "Software license (annual)",
      "quantity": 1,
      "unit_price": 500.00,
      "total": 500.00
    }
  ]
}
```

**Note:** Long descriptions automatically wrap within the column. No character limit.

#### Blackbox Mode
```json
{
  "display_mode": "blackbox",
  "blackbox_description": "Professional services as agreed",
  "subtotal": 3500.00
}
```

### Totals (Required)
| Field | Type | Description |
|-------|------|-------------|
| `subtotal` | number | Sum of all item totals |
| `tax_rate` | number | Tax rate as decimal (0.20 = 20%) |
| `tax_amount` | number | Calculated tax amount |
| `total` | number | Final total including tax |

**Important:** You must calculate these values. The generator displays them as provided.

### Optional Sections
| Field | Type | Description |
|-------|------|-------------|
| `notes` | string | Displayed under "Notes:" heading. Auto-wraps. |
| `payment_terms` | string | Displayed under "Payment Terms:" heading. Auto-wraps. |

### Styling Options
| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `primary_color` | hex string | `"#b39a7d"` | Header bars, accents (gold) |
| `secondary_color` | hex string | `"#2c3e50"` | Section headers (dark blue) |
| `title_color` | hex string | `"#b39a7d"` | Document title color |
| `company_name_color` | hex string | `"#1a1a1a"` | Company name color |
| `font_family` | string | `"Helvetica"` | `"Helvetica"`, `"Times"`, `"Courier"` |
| `template_style` | string | `"professional"` | `"professional"`, `"modern"`, `"classic"` |

### Logo Placement
| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `logo_x` | number | 40 | X position in points |
| `logo_y` | number | 750 | Y position in points |
| `logo_width` | number | 80 | Width in points |
| `logo_height` | number | 50 | Height in points |

### Payment Button (Clickable Link)

Add a clickable payment button to your invoice that opens a URL when clicked. Works with any payment provider (Stripe, PayPal, GoCardless, etc.) or any URL.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `payment_button_url` | string | null | Payment/checkout URL (required to show button) |
| `payment_button_label` | string | `"Pay Now"` | Button text |
| `payment_button_color` | hex string | `"#635BFF"` | Button background color (Stripe purple) |
| `payment_button_text_color` | hex string | `"#FFFFFF"` | Button text color (white) |

**Example - Stripe Checkout:**
```json
{
  "payment_button_url": "https://checkout.stripe.com/pay/cs_live_abc123",
  "payment_button_label": "Pay £500.00",
  "payment_button_color": "#635BFF"
}
```

**Example - PayPal:**
```json
{
  "payment_button_url": "https://www.paypal.com/paypalme/yourname/500",
  "payment_button_label": "Pay with PayPal",
  "payment_button_color": "#0070BA"
}
```

**Example - GoCardless:**
```json
{
  "payment_button_url": "https://pay.gocardless.com/flow/RE000123",
  "payment_button_label": "Set Up Direct Debit",
  "payment_button_color": "#00C389"
}
```

**Notes:**
- Button appears automatically when `payment_button_url` is provided
- When a QR code is present, the button appears to the left of the QR code
- Without a QR code, the button appears standalone in the footer area
- The button is a real PDF link annotation - clicking it opens the URL
- Works on desktop PDF readers and mobile devices

---

## QR Code Options

### QR Mode Types
| Mode | Label Shown | Use Case |
|------|-------------|----------|
| `"none"` | — | No QR code |
| `"payment_link"` | "Scan to Pay" | Stripe/payment URL |
| `"bank_details"` | "Bank Details" | UK Faster Payments |
| `"verification"` | "Verify Invoice" | Hosted verification link |
| `"verifactu"` | "VeriFactu" | Spanish tax compliance |
| `"crypto"` | "Pay with [Network]" | Cryptocurrency payment |

### Basic QR Code (from base64 image)
```json
{
  "qr_mode": "payment_link",
  "qr_base64": "iVBORw0KGgoAAAANSUhEUgAA...",
  "qr_label": "Scan to Pay Online"
}
```

### Cryptocurrency Payment QR
The generator automatically creates a QR code with the payment URI:

```json
{
  "qr_mode": "crypto",
  "crypto_wallet": "bc1qxy2kgdygjrsqtzq2n0yrf2493p83kkfjhx0wlh",
  "crypto_network": "bitcoin",
  "crypto_amount": 0.005,
  "show_crypto_identicons": true
}
```

#### Supported Networks
| Network | Symbol | URI Scheme |
|---------|--------|------------|
| `"bitcoin"` | BTC | `bitcoin:` |
| `"ethereum"` | ETH | `ethereum:` |
| `"polygon"` | MATIC | `polygon:` |
| `"litecoin"` | LTC | `litecoin:` |
| `"solana"` | SOL | `solana:` |
| `"tron"` | TRX | `tron:` |
| `"dogecoin"` | DOGE | `dogecoin:` |
| `"cardano"` | ADA | `cardano:` |
| `"xrp"` | XRP | `xrp:` |
| `"bnb"` | BNB | `bnb:` |
| `"usdt"` | USDT | `usdt:` |
| `"usdc"` | USDC | `usdc:` |
| `"lightning"` | BTC | `lightning:` |

### VeriFactu (Spanish Tax Compliance)
```json
{
  "qr_mode": "verifactu",
  "qr_base64": "...",
  "verifactu_hash": "ABC123DEF456...",
  "verifactu_series": "A",
  "verifactu_nif": "B12345678",
  "verifactu_timestamp": "2024-01-09T10:30:00Z"
}
```

---

## Complete Examples

### Standard Invoice
```json
{
  "document_type": "invoice",
  "company_name": "Smith Plumbing Services",
  "company_address": "45 Trade Street\nBirmingham\nB1 2AB",
  "company_vat": "GB123456789",
  "client_name": "Mrs. Jane Wilson",
  "client_address": "12 Residential Lane\nCoventry\nCV1 3CD",
  "invoice_number": "INV-2024-0042",
  "invoice_date": "9 January 2024",
  "due_date": "9 February 2024",
  "display_mode": "itemized",
  "items": [
    {
      "description": "Emergency callout - blocked drain",
      "quantity": 1,
      "unit_price": 85.00,
      "total": 85.00
    },
    {
      "description": "Labour: Clear blockage and inspect pipework (2 hours)",
      "quantity": 2,
      "unit_price": 45.00,
      "total": 90.00
    },
    {
      "description": "Replacement P-trap and fittings",
      "quantity": 1,
      "unit_price": 28.50,
      "total": 28.50
    }
  ],
  "subtotal": 203.50,
  "tax_rate": 0.20,
  "tax_amount": 40.70,
  "total": 244.20,
  "notes": "Work completed on site. 12-month warranty on parts fitted. Please retain this invoice for your records.",
  "payment_terms": "Bank transfer within 14 days. Sort: 12-34-56 Acc: 12345678 Ref: INV-2024-0042",
  "primary_color": "#2563eb",
  "secondary_color": "#1e40af"
}
```

### Quote/Estimate
```json
{
  "document_type": "quote",
  "company_name": "Digital Solutions Agency",
  "company_address": "100 Tech Park\nManchester\nM1 1AA",
  "client_name": "Startup Innovations Ltd",
  "client_address": "50 Enterprise Way\nLeeds\nLS1 1BB",
  "invoice_number": "QUO-2024-015",
  "invoice_date": "9 January 2024",
  "due_date": "Valid until 9 February 2024",
  "display_mode": "itemized",
  "items": [
    {
      "description": "Website design and development - responsive 5-page site with CMS integration, contact forms, and SEO optimization",
      "quantity": 1,
      "unit_price": 2500.00,
      "total": 2500.00
    },
    {
      "description": "Logo design package - 3 concepts with 2 revision rounds",
      "quantity": 1,
      "unit_price": 450.00,
      "total": 450.00
    },
    {
      "description": "12-month hosting and maintenance",
      "quantity": 12,
      "unit_price": 25.00,
      "total": 300.00
    }
  ],
  "subtotal": 3250.00,
  "tax_rate": 0.20,
  "tax_amount": 650.00,
  "total": 3900.00,
  "notes": "50% deposit required to commence work. Final payment due on project completion. Timeline: 4-6 weeks from deposit.",
  "payment_terms": "Bank transfer or card payment accepted"
}
```

### Crypto Payment Invoice
```json
{
  "document_type": "invoice",
  "company_name": "Web3 Consulting",
  "company_address": "Remote",
  "client_name": "DeFi Protocol Inc",
  "client_address": "Decentralized",
  "invoice_number": "CRYPTO-001",
  "invoice_date": "2024-01-09",
  "display_mode": "itemized",
  "items": [
    {
      "description": "Smart contract audit - 2000 lines of Solidity",
      "quantity": 1,
      "unit_price": 5000.00,
      "total": 5000.00
    }
  ],
  "subtotal": 5000.00,
  "tax_rate": 0,
  "tax_amount": 0,
  "total": 5000.00,
  "qr_mode": "crypto",
  "crypto_wallet": "0x742d35Cc6634C0532925a3b844Bc9e7595f5bB01",
  "crypto_network": "ethereum",
  "crypto_amount": 2.5,
  "show_crypto_identicons": true,
  "notes": "Payment in ETH at current market rate. Transaction hash required for receipt.",
  "primary_color": "#627eea",
  "secondary_color": "#3c3c3d"
}
```

### Blackbox/Summary Invoice
```json
{
  "document_type": "invoice",
  "company_name": "Confidential Services Ltd",
  "company_address": "Private",
  "client_name": "Corporate Client",
  "client_address": "Disclosed separately",
  "invoice_number": "PRIV-2024-001",
  "invoice_date": "January 2024",
  "display_mode": "blackbox",
  "blackbox_description": "Professional services as per agreement dated 1st January 2024",
  "subtotal": 15000.00,
  "tax_rate": 0.20,
  "tax_amount": 3000.00,
  "total": 18000.00,
  "payment_terms": "Net 30"
}
```

### Invoice with Payment Button
```json
{
  "document_type": "invoice",
  "company_name": "Modern Agency Ltd",
  "company_address": "100 Digital Street\nLondon, UK\nEC2A 4NE",
  "company_vat": "GB123456789",
  "client_name": "Tech Startup Inc",
  "client_address": "50 Innovation Way\nManchester, M1 2AB",
  "invoice_number": "INV-2024-0099",
  "invoice_date": "12 January 2024",
  "due_date": "26 January 2024",
  "display_mode": "itemized",
  "items": [
    {
      "description": "Website redesign - full responsive site with CMS",
      "quantity": 1,
      "unit_price": 3500.00,
      "total": 3500.00
    },
    {
      "description": "Monthly hosting and maintenance",
      "quantity": 3,
      "unit_price": 150.00,
      "total": 450.00
    }
  ],
  "subtotal": 3950.00,
  "tax_rate": 0.20,
  "tax_amount": 790.00,
  "total": 4740.00,
  "notes": "Thank you for your business. Click the button below to pay securely online.",
  "payment_terms": "Payment due within 14 days",
  "payment_button_url": "https://checkout.stripe.com/pay/cs_live_example123",
  "payment_button_label": "Pay £4,740.00",
  "payment_button_color": "#635BFF",
  "primary_color": "#4f46e5",
  "secondary_color": "#1e1b4b"
}
```

---

## Contract/Document Schema

For generating contracts, agreements, and multi-section documents with variable substitution.

### Complete Contract JSON Schema

```json
{
  "document_type": "document",
  "title": "Service Agreement",
  "subtitle": "Professional Services Contract",
  "date_line": "Effective Date: January 9, 2024",
  "footer": "Page {{page_number}} of {{total_pages}}",

  "header": {
    "logo_base64": null,
    "company_name": "Your Company Ltd",
    "show_on_all_pages": true
  },

  "styling": {
    "primary_color": "#1a365d",
    "secondary_color": "#2c5282",
    "font_family": "Helvetica",
    "heading_size": 13,
    "body_size": 10,
    "line_height": 14,
    "page_margins": {
      "top": 72,
      "right": 50,
      "bottom": 72,
      "left": 50
    }
  },

  "parties": [
    {
      "role": "Service Provider",
      "name": "{{provider_name}}",
      "address": "123 Business Street\nLondon, UK",
      "identifier": "Company Reg: 12345678"
    },
    {
      "role": "Client",
      "name": "{{client_name}}",
      "address": "456 Client Road\nManchester, UK",
      "identifier": ""
    }
  ],

  "sections": [
    {
      "heading": "1. Scope of Work",
      "content": "The Provider agrees to deliver the following services:\n- Initial consultation and requirements gathering\n- Design and development of the agreed solution\n- Testing and quality assurance\n- Documentation and training"
    },
    {
      "heading": "2. Payment Terms",
      "content": "Total project value: {{project_value}}\n\nPayment schedule:\n- 50% upon signing ({{deposit_amount}})\n- 50% upon completion"
    },
    {
      "heading": "3. Timeline",
      "content": "Project commencement: {{start_date}}\nEstimated completion: {{end_date}}\n\nMilestones will be agreed in writing."
    }
  ],

  "signatures": [
    {
      "role": "For the Provider",
      "name_line": "Name: _______________________",
      "date_line": "Date: _______________________"
    },
    {
      "role": "For the Client",
      "name_line": "Name: _______________________",
      "date_line": "Date: _______________________"
    }
  ],

  "variables": {
    "provider_name": "Acme Services Ltd",
    "client_name": "Client Corporation",
    "project_value": "£10,000",
    "deposit_amount": "£5,000",
    "start_date": "15 January 2024",
    "end_date": "15 March 2024"
  }
}
```

### Contract Field Reference

#### Document Settings
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `document_type` | string | Yes | Must be `"document"` for contracts |
| `title` | string | Yes | Main document title |
| `subtitle` | string | No | Subtitle displayed below title |
| `date_line` | string | No | Date line displayed at top |
| `footer` | string | No | Footer text (supports `{{page_number}}` and `{{total_pages}}`) |

#### Header Options
| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `header.logo_base64` | string | null | Base64-encoded PNG/JPEG logo |
| `header.company_name` | string | "" | Company name in header |
| `header.show_on_all_pages` | bool | true | Show header on every page |

#### Styling Options
| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `styling.primary_color` | hex | `"#1a365d"` | Primary accent color |
| `styling.secondary_color` | hex | `"#2c5282"` | Secondary color |
| `styling.font_family` | string | `"Helvetica"` | Font family |
| `styling.heading_size` | number | 13 | Section heading font size |
| `styling.body_size` | number | 10 | Body text font size |
| `styling.line_height` | number | 14 | Line height in points |
| `styling.page_margins` | object | 72/50/72/50 | Page margins (top/right/bottom/left) |

#### Parties Array
Each party object:
| Field | Type | Description |
|-------|------|-------------|
| `role` | string | Party role (e.g., "Service Provider", "Client") |
| `name` | string | Party name (supports `{{variable}}` substitution) |
| `address` | string | Address (use `\n` for line breaks) |
| `identifier` | string | Optional identifier (company reg, etc.) |

#### Sections Array
Each section object:
| Field | Type | Description |
|-------|------|-------------|
| `heading` | string | Section heading (numbered, e.g., "1. Scope") |
| `content` | string | Section content (supports `\n` for paragraphs) |

**Bullet Points:** Lines starting with `- ` are rendered as bullet points.

#### Signatures Array
Each signature object:
| Field | Type | Description |
|-------|------|-------------|
| `role` | string | Signatory role |
| `name_line` | string | Name line text |
| `date_line` | string | Date line text |

#### Variables Object
Key-value pairs for `{{variable}}` substitution throughout the document.

### Contract Examples

#### Service Agreement
```json
{
  "document_type": "document",
  "title": "Web Development Contract",
  "subtitle": "Fixed-Price Agreement",
  "date_line": "Contract Date: {{contract_date}}",
  "parties": [
    {"role": "Developer", "name": "WebDev Studio", "address": "Tech Park, London", "identifier": ""},
    {"role": "Client", "name": "{{client_company}}", "address": "{{client_address}}", "identifier": ""}
  ],
  "sections": [
    {"heading": "1. Project Scope", "content": "Development of a responsive e-commerce website including:\n- Homepage with featured products\n- Product catalog with search and filters\n- Shopping cart and checkout\n- Admin dashboard"},
    {"heading": "2. Deliverables", "content": "- Fully functional website\n- Source code repository access\n- Documentation\n- 30-day post-launch support"},
    {"heading": "3. Payment", "content": "Total: {{total_price}}\n\n- 30% deposit: {{deposit}}\n- 40% on design approval: {{milestone_1}}\n- 30% on completion: {{final_payment}}"},
    {"heading": "4. Timeline", "content": "- Week 1-2: Design phase\n- Week 3-5: Development\n- Week 6: Testing and launch"},
    {"heading": "5. Terms", "content": "Both parties agree to the terms outlined above. Changes require written agreement."}
  ],
  "signatures": [
    {"role": "Developer", "name_line": "Name: _________________", "date_line": "Date: _________________"},
    {"role": "Client", "name_line": "Name: _________________", "date_line": "Date: _________________"}
  ],
  "variables": {
    "contract_date": "January 9, 2024",
    "client_company": "Retail Corp Ltd",
    "client_address": "High Street, Manchester",
    "total_price": "£8,500",
    "deposit": "£2,550",
    "milestone_1": "£3,400",
    "final_payment": "£2,550"
  },
  "styling": {"primary_color": "#1e40af", "secondary_color": "#3b82f6"}
}
```

#### Rental Agreement
```json
{
  "document_type": "document",
  "title": "Residential Tenancy Agreement",
  "date_line": "Commencement Date: {{start_date}}",
  "parties": [
    {"role": "Landlord", "name": "{{landlord_name}}", "address": "{{landlord_address}}", "identifier": ""},
    {"role": "Tenant", "name": "{{tenant_name}}", "address": "As per property", "identifier": ""}
  ],
  "sections": [
    {"heading": "Property", "content": "{{property_address}}"},
    {"heading": "Term", "content": "Fixed term of {{term_length}} commencing {{start_date}} and ending {{end_date}}."},
    {"heading": "Rent", "content": "Monthly rent: {{monthly_rent}}\nDue on: 1st of each month\nDeposit held: {{deposit_amount}}"},
    {"heading": "Obligations", "content": "The Tenant agrees to:\n- Pay rent on time\n- Maintain the property in good condition\n- Not sublet without permission\n- Provide reasonable notice before vacating"}
  ],
  "signatures": [
    {"role": "Landlord", "name_line": "Signature: _______________", "date_line": "Date: _______________"},
    {"role": "Tenant", "name_line": "Signature: _______________", "date_line": "Date: _______________"}
  ],
  "variables": {
    "landlord_name": "Property Holdings Ltd",
    "landlord_address": "123 Management St, London",
    "tenant_name": "John Smith",
    "property_address": "Flat 2, 45 Oak Lane\nBirmingham\nB15 2TT",
    "term_length": "12 months",
    "start_date": "1st February 2024",
    "end_date": "31st January 2025",
    "monthly_rent": "£1,200",
    "deposit_amount": "£1,200 (5 weeks)"
  }
}
```

---

## Share Certificate Schema

For generating UK-style share certificates with decorative borders, company details, and signatory blocks.

### Quick Start

```bash
# Generate share certificate from JSON
pdf-gen --certificate certificate.json output.pdf

# Generate demo certificate
pdf-gen --demo-certificate demo_cert.pdf
```

### Complete Share Certificate JSON Schema

```json
{
  "template": {
    "id": "share_certificate_uk",
    "version": "1.0.0",
    "style": {
      "border_color": "#00B5AD",
      "accent_color": "#00B5AD",
      "font_family": "Helvetica"
    }
  },

  "certificate": {
    "number": "2025-002",
    "issue_date": "2025-12-21"
  },

  "company": {
    "name": "QUANTUM ENCODING LTD",
    "registration_number": "(Company No. 12345678)",
    "registered_address": {
      "line1": "123 Tech Park",
      "line2": "Innovation Drive",
      "city": "London",
      "postcode": "EC1A 1BB",
      "country": "United Kingdom"
    },
    "logo": {
      "source": {
        "base64": {
          "data": "iVBORw0KGgo...",
          "mime_type": "image/png"
        }
      },
      "width_mm": 35,
      "height_mm": 28
    }
  },

  "holder": {
    "name": "Mr Lance John Pearson",
    "address": {
      "line1": "45 Residential Street",
      "city": "Manchester",
      "postcode": "M1 2AB",
      "country": "United Kingdom"
    }
  },

  "shares": {
    "quantity": 5,
    "quantity_words": null,
    "class": "Ordinary",
    "nominal_value": 0.01,
    "currency": "GBP",
    "paid_status": "fully paid",
    "share_numbers": {
      "from": 1,
      "to": 5
    }
  },

  "signatories": [
    {
      "role": "Director",
      "name": "James Smith",
      "date": "21 December 2025",
      "address": {
        "line1": "100 Director Lane",
        "city": "London",
        "postcode": "W1A 1AA"
      }
    },
    {
      "role": "Witness",
      "name": "Sarah Johnson",
      "date": "21 December 2025",
      "address": {
        "line1": "200 Witness Road",
        "city": "London",
        "postcode": "EC1V 9BD"
      }
    }
  ]
}
```

### Share Certificate Field Reference

#### Template Settings
| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `template.id` | string | `"share_certificate_uk"` | Template identifier |
| `template.version` | string | `"1.0.0"` | Template version |
| `template.style.border_color` | hex | `"#00B5AD"` | Decorative border color (teal) |
| `template.style.accent_color` | hex | `"#00B5AD"` | Title and accent color |
| `template.style.font_family` | string | `"Helvetica"` | Font family |

#### Certificate Information
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `certificate.number` | string | Yes | Certificate reference number |
| `certificate.issue_date` | string | Yes | Date of issue |

#### Company Information
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `company.name` | string | Yes | Full company name |
| `company.registration_number` | string | Yes | Companies House number |
| `company.registered_address` | object | Yes | Registered office address |
| `company.logo` | object | No | Company logo (base64 or path) |

#### Address Object
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `line1` | string | Yes | First line of address |
| `line2` | string | No | Second line |
| `line3` | string | No | Third line |
| `city` | string | No | City/town |
| `county` | string | No | County/region |
| `postcode` | string | Yes | Postal code |
| `country` | string | No | Country (default: "United Kingdom") |

#### Holder Information
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `holder.name` | string | Yes | Full name of shareholder |
| `holder.address` | object | Yes | Shareholder address |

#### Share Details
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `shares.quantity` | number | Yes | Number of shares |
| `shares.quantity_words` | string | No | Auto-generated if null (e.g., "FIVE") |
| `shares.class` | string | No | Share class (default: "Ordinary") |
| `shares.nominal_value` | number | Yes | Value per share (e.g., 0.01) |
| `shares.currency` | string | No | `"GBP"`, `"EUR"`, `"USD"` (default: GBP) |
| `shares.paid_status` | string | No | `"fully paid"`, `"partly paid"`, `"unpaid"` |
| `shares.share_numbers` | object | No | Optional range `{from: 1, to: 5}` |

#### Signatories Array
Each signatory object:
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `role` | string | Yes | `"Director"`, `"Secretary"`, `"Witness"`, `"Authorised Signatory"` |
| `name` | string | Yes | Signatory's full name |
| `date` | string | Yes | Date of signing |
| `address` | object | No | Signatory's address |
| `signature` | object | No | Base64-encoded signature image |

### Share Certificate Examples

#### Basic Share Certificate
```json
{
  "certificate": {
    "number": "001",
    "issue_date": "4 January 2026"
  },
  "company": {
    "name": "TECH STARTUP LTD",
    "registration_number": "(Company No. 15678901)",
    "registered_address": {
      "line1": "WeWork Building",
      "line2": "123 Innovation Street",
      "city": "London",
      "postcode": "EC2A 4NE"
    }
  },
  "holder": {
    "name": "Dr. Alice Thompson",
    "address": {
      "line1": "42 Science Park",
      "city": "Cambridge",
      "postcode": "CB2 1TN"
    }
  },
  "shares": {
    "quantity": 1000,
    "class": "Ordinary A",
    "nominal_value": 0.001,
    "currency": "GBP",
    "paid_status": "fully paid"
  },
  "signatories": [
    {
      "role": "Director",
      "name": "Bob Williams",
      "date": "4 January 2026"
    },
    {
      "role": "Secretary",
      "name": "Carol Davis",
      "date": "4 January 2026"
    }
  ]
}
```

#### Preference Shares Certificate
```json
{
  "template": {
    "style": {
      "border_color": "#2E5090",
      "accent_color": "#2E5090"
    }
  },
  "certificate": {
    "number": "PREF-2026-001",
    "issue_date": "15 February 2026"
  },
  "company": {
    "name": "INVESTMENT HOLDINGS PLC",
    "registration_number": "(Company No. 08765432)",
    "registered_address": {
      "line1": "Financial Tower",
      "line2": "1 Capital Square",
      "city": "Edinburgh",
      "postcode": "EH1 3EG",
      "country": "Scotland"
    }
  },
  "holder": {
    "name": "Venture Capital Partners LLP",
    "address": {
      "line1": "Investment House",
      "line2": "50 Fund Street",
      "city": "London",
      "postcode": "EC4M 7AN"
    }
  },
  "shares": {
    "quantity": 50000,
    "class": "Series A Preference",
    "nominal_value": 1.00,
    "currency": "GBP",
    "paid_status": "fully paid",
    "share_numbers": {
      "from": 1,
      "to": 50000
    }
  },
  "signatories": [
    {
      "role": "Director",
      "name": "Sir Richard Blackwood",
      "date": "15 February 2026",
      "address": {
        "line1": "Manor House",
        "city": "Surrey",
        "postcode": "GU1 3TY"
      }
    },
    {
      "role": "Director",
      "name": "Lady Margaret Greene",
      "date": "15 February 2026"
    }
  ]
}
```

---

## AI Prompt Template

### For Invoices

Use this prompt to generate invoice JSON:

```
Generate a JSON invoice with these details:
- Company: [name, address, VAT if applicable]
- Client: [name, address]
- Invoice number: [number]
- Date: [date]
- Items: [list each item with description, quantity, unit price]
- Tax rate: [percentage as decimal, e.g., 0.20 for 20%]
- Notes: [any additional notes]
- Payment terms: [how/when to pay]

Calculate subtotal (sum of item totals), tax_amount (subtotal × tax_rate), and total (subtotal + tax_amount).

Output valid JSON matching the invoice schema exactly - no markdown, no comments.
```

### For Contracts

Use this prompt to generate contract JSON:

```
Generate a JSON contract with these details:
- Document title: [title]
- Parties: [list each party with role, name, address]
- Sections: [list each section with heading and content]
- Signatures: [who needs to sign]
- Variables to substitute: [list variables and their values]

Structure sections with clear headings (numbered). Use "\n" for line breaks.
Start bullet point lines with "- " for automatic bullet formatting.

Output valid JSON matching the contract schema exactly - no markdown, no comments.
```

### For Share Certificates

Use this prompt to generate share certificate JSON:

```
Generate a JSON share certificate with these details:
- Certificate number: [number]
- Issue date: [date]
- Company: [name, registration number, registered address]
- Shareholder: [full name, address]
- Shares: [quantity, class, nominal value per share, currency]
- Signatories: [list each with role, name, date, optional address]

The quantity_words field will be auto-generated (e.g., 5 becomes "FIVE").
Use UK address format with line1, city, postcode, country.

Output valid JSON matching the share certificate schema exactly - no markdown, no comments.
```

---

## Validation Checklist

### For Invoices
- [ ] `document_type` is `"invoice"` or `"quote"`
- [ ] All required string fields are present (can be empty `""`)
- [ ] Each item has `description`, `quantity`, `unit_price`, `total`
- [ ] Item `total` = `quantity` × `unit_price`
- [ ] `subtotal` = sum of all item totals
- [ ] `tax_amount` = `subtotal` × `tax_rate`
- [ ] `total` = `subtotal` + `tax_amount`
- [ ] Colors are hex format: `"#RRGGBB"`
- [ ] No trailing commas in arrays/objects
- [ ] Numbers are not quoted (no `"100"`, use `100`)

### For Contracts
- [ ] `document_type` is `"document"`
- [ ] `title` is provided
- [ ] `parties` array has at least one party
- [ ] `sections` array has at least one section
- [ ] Each section has `heading` and `content`
- [ ] `signatures` array matches the number of signing parties
- [ ] `variables` object includes all `{{placeholder}}` values used
- [ ] Colors are hex format: `"#RRGGBB"`
- [ ] No trailing commas in arrays/objects

### For Share Certificates
- [ ] `certificate.number` and `certificate.issue_date` are provided
- [ ] `company.name` and `company.registration_number` are provided
- [ ] `company.registered_address` has `line1` and `postcode`
- [ ] `holder.name` and `holder.address` are provided
- [ ] `shares.quantity` is a positive integer
- [ ] `shares.nominal_value` is a positive number
- [ ] `shares.currency` is `"GBP"`, `"EUR"`, or `"USD"` (optional, defaults to GBP)
- [ ] `shares.paid_status` is `"fully paid"`, `"partly paid"`, or `"unpaid"` (optional)
- [ ] `signatories` array has at least one signatory
- [ ] Each signatory has `role`, `name`, and `date`
- [ ] Colors are hex format: `"#RRGGBB"`
- [ ] No trailing commas in arrays/objects
