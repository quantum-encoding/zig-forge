# Letter Quote — authoring guide for AI assistants

The **Letter Quote** template renders premium Word-document-style quotes that
look like something a boutique firm would send by email — centred hero title,
thin gold hairline separators, letter-spaced navy labels, and a multi-page
flow (prose description page + itemised estimate page).

This guide tells you how to write the JSON that drives it. The canonical
example lives at **`templates/reformas_sample.json`** — read it before
generating your own, and imitate its shape.

Render with:

```bash
pdf-gen --letter-quote input.json output.pdf
```

---

## Visual vocabulary (what the design "wants")

- **Centred hero title** at the top — the company name, big, letter-spaced,
  navy bold. Subtitle directly under it is `phone  |  email`, same navy, less
  tracked.
- **Gold hairline rules** separate every major band (header/title/dates/body,
  and again at the very bottom of each page). Never use multiple stacked
  rules; never use heavy strokes.
- **Letter-spaced labels everywhere labels appear.** `CLIENTE:`, `FECHA:`,
  `DESCRIPCIÓN DE PROYECTO:`, `SUBTOTAL`, `TOTAL` — all tracked. The renderer
  handles the tracking; you just provide plain strings.
- **Two-page rhythm** — page 1 is a letter-style project description with
  paragraphs, payment terms, notes; page 2 is the itemised estimate with
  section blocks (e.g. *CUARTO DE BAÑO*, *COCINA*) listing line items and a
  right-aligned totals block. The **`TOTAL`** row is drawn in the gold
  accent colour.
- Section headings on the itemised page are **all-caps bold navy**. Line items
  are **all-caps regular**, with parenthetical inclusions **bolded via
  `**markers**`** (e.g. `**(MATERIAL INCLUIDO)**`). Keep items terse — one line
  ideally, wrap gracefully otherwise.

You are writing for a template that *already looks premium*. Do not add
decoration, colour variety, icons, or filler copy.

---

## Top-level schema

```jsonc
{
  "company": {
    "name":  "STRING — ALL-CAPS trading name, shown as the hero title",
    "phone": "STRING — e.g. +34 623194238",
    "email": "STRING — e.g. hello@example.com"
  },

  "client": "STRING — customer name, will be shown tracked next to CLIENTE:",
  "date":   "STRING — free-form, usually DD/MM/YYYY or locale equivalent",

  "style": {
    "primary_color": "#RRGGBB — default #1a2a5e (navy). Used for title, labels, section headings",
    "accent_color":  "#RRGGBB — default #e8a83d (gold). Used for hairlines and TOTAL row",
    "watermark_image": "RESERVED — leave empty for now"
  },

  "pages": [ /* one or more page objects, see below */ ]
}
```

All fields are optional. Sensible defaults will be applied. Colours fall back
to the navy / gold pair if omitted — you almost never need to override them.

---

## Page types

`pages` is an ordered array. The renderer produces one PDF page per entry. Two
types are supported today: `description` and `itemized`. Mix and match freely.

### `description` — prose / letter page

```jsonc
{
  "type": "description",
  "blocks": [
    { "type": "heading",   "text": "Short bold heading — sentence case" },
    { "type": "paragraph", "text": "Full paragraph. Inline **bold** is honoured." },
    { "type": "bullets",   "items": ["First term", "Second term", "Third term"] }
  ]
}
```

Block types:

| `type`      | Fields                | Notes                                                            |
|-------------|-----------------------|------------------------------------------------------------------|
| `heading`   | `text`                | Bold, always drawn in full — strip any `**` markers yourself.     |
| `paragraph` | `text`                | Inline `**bold**` is honoured (and wrap-safe).                    |
| `bullets`   | `items` (array)       | Small dot bullet, items may contain `**bold**`.                   |

Use headings *sparingly* — one per thematic block (e.g. "Duración estimada",
"Condiciones de pago", "Términos y condiciones"). Prefer `**BOLD PREFIX:**`
inside a paragraph over a dedicated heading when the section is a single
sentence (e.g. `**NOTA:** …`).

### `itemized` — estimate page

```jsonc
{
  "type": "itemized",
  "subtitle":            "PRESUPUESTO ESTIMADO",
  "project_label":       "DESCRIPCIÓN DE PROYECTO",
  "project_description": "REFORMA INTEGRAL DE PISO",
  "sections": [
    {
      "heading": "CUARTO DE BAÑO",
      "items": [
        "RETIRADA DE ACCESORIOS SANITARIOS ANTIGUOS",
        "IMPERMEABILIZACIÓN CON LÁMINA GEOTEXTIL **(MATERIAL INCLUIDO)**"
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
```

Field guide:

- `subtitle` — the centred tracked banner shown immediately under the hero
  rule. Leave empty to omit. Usually `PRESUPUESTO ESTIMADO` / `ESTIMATE` /
  `BUDGET`, etc.
- `project_label` + `project_description` — the *"DESCRIPCIÓN DE PROYECTO:
  REFORMA INTEGRAL DE PISO"* row. Label is automatically followed by a colon
  and tracked; description is tracked bold. Either or both may be empty.
- `sections[]` — ordered. Each section has a bold navy **`heading`** and an
  array of `items`. Items are plain strings; inline `**bold**` is honoured for
  inclusions like `**(MATERIAL INCLUIDO)**`. Use an empty string `""` in
  `items` to force a blank line inside a section.
- `currency` — prefix used when totals are rendered from numbers.
- `subtotal` / `tax_rate` / `total` — numbers. `tax_rate` is a fraction
  (`0.21` = 21%). If these are provided without the `*_text` overrides, the
  renderer formats them as `{currency}{amount:.2f}`.
- `subtotal_text` / `tax_text` / `total_text` — **preferred for localised
  currency formatting.** The renderer's generic `{currency}{amount:.2f}` won't
  match Spanish / European thousand and decimal separators. If you need
  `€20.310` or `€4.265,10`, supply the exact string here. The numeric fields
  are still useful for downstream systems (accounting, CSV export, etc.).

---

## Inline bold rule

Anywhere we say "inline `**bold**` is honoured" — that means you can wrap a
run of text in `**double-asterisks**` and it will render bold at that point.
The parser is wrap-safe: if the bold run straddles a line break, the opening
marker is preserved on the new line.

Do **not** nest bold. Do **not** use Markdown headings (`#`, `##`), italics,
or any other Markdown — only `**bold**` is recognised.

---

## Authoring checklist

Before you hand the JSON back:

- [ ] Hero title in **ALL-CAPS**.
- [ ] `client` typically provided in upper-case when name is short.
- [ ] On the itemised page, `sections[].heading` and `sections[].items` are
      **ALL-CAPS**.
- [ ] Inline bold used only for prefixes (`**NOTA:**`) and inclusions
      (`**(MATERIAL INCLUIDO)**`) — not for whole sentences.
- [ ] Totals use `*_text` overrides when the locale needs non-ASCII
      separators.
- [ ] Pages flow logically: description → itemised (the most common
      arrangement), or itemised-only if there's no prose cover letter.
- [ ] No extra fields. The schema ignores unknowns silently — don't rely on
      that, keep the payload tight.

---

## Minimal example

```json
{
  "company": { "name": "ACME STUDIO", "phone": "+44 20 7946 0000", "email": "hello@acme.io" },
  "client":  "JANE DOE",
  "date":    "2026-04-23",
  "pages": [
    {
      "type": "itemized",
      "subtitle": "ESTIMATE",
      "project_label": "PROJECT",
      "project_description": "WEBSITE REDESIGN",
      "sections": [
        { "heading": "DESIGN", "items": [
            "DISCOVERY WORKSHOP (2 DAYS)",
            "BRAND SYSTEM REFRESH **(STYLE GUIDE INCLUDED)**",
            "HI-FI MOCKUPS FOR 8 KEY SCREENS"
        ]},
        { "heading": "BUILD", "items": [
            "NEXT.JS FRONTEND",
            "HEADLESS CMS INTEGRATION **(SANITY.IO LICENCE NOT INCLUDED)**"
        ]}
      ],
      "currency": "£",
      "subtotal": 12000,
      "tax_rate": 0.20,
      "total":    14400,
      "subtotal_text": "£12,000.00",
      "tax_text":      "£2,400.00",
      "total_text":    "£14,400.00"
    }
  ]
}
```

## Full example

See **`templates/reformas_sample.json`** — mirrors the Reformas Costa Sol
reference document and exercises every feature in the schema.
