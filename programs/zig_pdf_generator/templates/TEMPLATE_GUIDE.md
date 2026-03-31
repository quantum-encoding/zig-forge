# ZigPDF Presentation Template Guide

This guide explains how to create JSON templates for the ZigPDF presentation engine. Use this to generate professional PDF documents like quotes, proposals, certificates, and sales pitches.

## Quick Start

```json
{
  "page_size": { "width": 842, "height": 595 },
  "pages": [
    {
      "background_color": "#ffffff",
      "elements": [
        {
          "type": "text",
          "content": "Hello World",
          "x": 100,
          "y": 100,
          "font_size": 24,
          "color": "#000000"
        }
      ]
    }
  ]
}
```

## Page Sizes

Common page sizes (width x height in points):

| Format | Landscape | Portrait |
|--------|-----------|----------|
| A4 | 842 x 595 | 595 x 842 |
| Letter | 792 x 612 | 612 x 792 |
| HD 1080p | 1920 x 1080 | 1080 x 1920 |

## Coordinate System

**IMPORTANT:** The coordinate system uses **top-down Y positioning**:
- `x=0` is the left edge
- `y=0` is the **top** edge
- Y increases going **down** the page
- For text elements, `y` represents the **baseline** position

This means:
- Text at `y=100` has its baseline at 100 points from the top
- A decorative line at `y=115` will appear **below** text at `y=100`
- Shapes at `y=100` have their top edge at 100 points from the top

## Element Types

### Text

```json
{
  "type": "text",
  "content": "Your text here",
  "x": 60,
  "y": 100,
  "font_size": 24,
  "color": "#000000",
  "font_weight": "normal",
  "font_style": "normal",
  "align": "left",
  "max_width": 400
}
```

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| content | string | required | The text to display |
| x | number | 0 | X position (left edge, or center/right if aligned) |
| y | number | 0 | Y position (text baseline from top) |
| font_size | number | 24 | Font size in points |
| color | string | "#000000" | Hex color code |
| font_weight | string | "normal" | "normal" or "bold" |
| font_style | string | "normal" | "normal" or "italic" |
| align | string | "left" | "left", "center", or "right" |
| max_width | number | null | Enable word wrapping at this width |
| line_height | number | 1.4 | Line spacing multiplier (for wrapped text) |

**Alignment behavior:**
- `"left"`: Text starts at x position
- `"center"`: Text is centered on x position
- `"right"`: Text ends at x position

**Text wrapping:**
When `max_width` is set, text automatically wraps to fit. Essential for long paragraphs or text inside boxes.

### Bullet List

```json
{
  "type": "bullet_list",
  "x": 60,
  "y": 200,
  "font_size": 12,
  "color": "#333333",
  "bullet_color": "#10B981",
  "line_spacing": 12,
  "indent": 15,
  "items": [
    "First item",
    "Second item",
    "Third item"
  ]
}
```

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| items | array | required | Array of strings for each bullet |
| x | number | 0 | X position of bullet |
| y | number | 0 | Y position of first item baseline |
| font_size | number | 18 | Font size |
| color | string | "#000000" | Text color |
| bullet_color | string | "#2563eb" | Bullet point color |
| line_spacing | number | 8 | Extra space between items |
| indent | number | 20 | Text offset from bullet |

### Table

```json
{
  "type": "table",
  "x": 60,
  "y": 150,
  "columns": ["Description", "Qty", "Price", "Total"],
  "column_widths": [300, 80, 100, 100],
  "rows": [
    ["Solar Panels 440W", "12", "£330", "£3,960"],
    ["Inverter 5kW", "1", "£1,520", "£1,520"],
    ["Installation", "1", "£1,650", "£1,650"]
  ],
  "header_bg_color": "#111827",
  "header_text_color": "#ffffff",
  "row_bg_color": "#ffffff",
  "alt_row_bg_color": "#F9FAFB",
  "text_color": "#374151",
  "border_color": "#E5E7EB",
  "font_size": 11,
  "header_font_size": 12,
  "padding": 10,
  "row_height": 30,
  "header_height": 35
}
```

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| columns | array | required | Column header strings |
| column_widths | array | null | Width of each column (auto if null) |
| rows | array | required | 2D array of cell contents |
| header_bg_color | string | "#2563eb" | Header background |
| header_text_color | string | "#ffffff" | Header text color |
| row_bg_color | string | "#ffffff" | Row background |
| alt_row_bg_color | string | "#f8f9fa" | Alternating row background |
| text_color | string | "#000000" | Cell text color |
| border_color | string | "#e0e0e0" | Table border color |
| font_size | number | 14 | Cell font size |
| header_font_size | number | 14 | Header font size |
| padding | number | 10 | Cell padding |
| row_height | number | 36 | Row height in points |
| header_height | number | 40 | Header row height |

**Table height calculation:**
```
total_height = header_height + (row_count * row_height)
```

### Shape

```json
{
  "type": "shape",
  "shape": "rectangle",
  "x": 60,
  "y": 100,
  "width": 200,
  "height": 100,
  "fill_color": "#10B981",
  "stroke_color": "#047857",
  "stroke_width": 2
}
```

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| shape | string | required | "rectangle", "line", "circle", "ellipse" |
| x | number | 0 | X position |
| y | number | 0 | Y position (top of shape) |
| width | number | 100 | Width |
| height | number | 100 | Height (0 for horizontal lines) |
| fill_color | string | null | Fill color (null = no fill) |
| stroke_color | string | "#000000" | Border/stroke color |
| stroke_width | number | 1 | Border width |

**Line shape:**
For horizontal lines, use `height: 0`:
```json
{
  "type": "shape",
  "shape": "line",
  "x": 60,
  "y": 115,
  "width": 100,
  "height": 0,
  "stroke_color": "#10B981",
  "stroke_width": 3
}
```

### Image (Base64)

```json
{
  "type": "image",
  "base64": "iVBORw0KGgoAAAANSUhEUgAA...",
  "x": 60,
  "y": 100,
  "width": 200,
  "height": 150,
  "maintain_aspect": true
}
```

## Color Format

All colors use hex format with # prefix:
- `"#10B981"` - 6-digit hex (RGB)
- `"#fff"` - 3-digit shorthand NOT supported, use `"#ffffff"`

## Common Patterns

### Page Header (Dark Bar)

```json
{
  "type": "shape",
  "shape": "rectangle",
  "x": 0,
  "y": 0,
  "width": 842,
  "height": 55,
  "fill_color": "#111827"
},
{
  "type": "text",
  "content": "COMPANY NAME",
  "x": 60,
  "y": 33,
  "font_size": 14,
  "font_weight": "bold",
  "color": "#10B981"
},
{
  "type": "text",
  "content": "Section Title",
  "x": 782,
  "y": 33,
  "font_size": 11,
  "color": "#6EE7B7",
  "align": "right"
}
```

### Section Title with Decorative Underline

```json
{
  "type": "text",
  "content": "Section Title",
  "x": 60,
  "y": 95,
  "font_size": 26,
  "font_weight": "bold",
  "color": "#111827"
},
{
  "type": "shape",
  "shape": "line",
  "x": 60,
  "y": 108,
  "width": 60,
  "height": 0,
  "stroke_color": "#10B981",
  "stroke_width": 3
}
```

The underline at `y=108` appears ~13 points below the text baseline at `y=95`.

### Stats Box Grid

```json
{
  "type": "shape",
  "shape": "rectangle",
  "x": 60,
  "y": 200,
  "width": 170,
  "height": 90,
  "fill_color": "#F0FDF4",
  "stroke_color": "#A7F3D0",
  "stroke_width": 1
},
{
  "type": "text",
  "content": "2,500+",
  "x": 145,
  "y": 240,
  "font_size": 28,
  "font_weight": "bold",
  "color": "#059669",
  "align": "center"
},
{
  "type": "text",
  "content": "Installations",
  "x": 145,
  "y": 268,
  "font_size": 11,
  "color": "#065F46",
  "align": "center"
}
```

Note: Center-aligned text uses `x` as the center point (145 = 60 + 170/2).

### Text Box with Background

```json
{
  "type": "shape",
  "shape": "rectangle",
  "x": 60,
  "y": 400,
  "width": 720,
  "height": 70,
  "fill_color": "#F0FDF4",
  "stroke_color": "#10B981",
  "stroke_width": 1
},
{
  "type": "text",
  "content": "TESTIMONIAL",
  "x": 80,
  "y": 420,
  "font_size": 9,
  "font_weight": "bold",
  "color": "#065F46"
},
{
  "type": "text",
  "content": "\"Your testimonial text here...\"",
  "x": 80,
  "y": 445,
  "font_size": 10,
  "font_style": "italic",
  "color": "#047857",
  "max_width": 660
}
```

**IMPORTANT:** Use `max_width` for long text to prevent overflow. Calculate as:
```
max_width = box_width - (2 * horizontal_padding)
Example: 720 - (2 * 20) = 680
```

### Page Footer

```json
{
  "type": "shape",
  "shape": "line",
  "x": 60,
  "y": 545,
  "width": 722,
  "height": 0,
  "stroke_color": "#E5E7EB",
  "stroke_width": 1
},
{
  "type": "text",
  "content": "Page 1 of 5",
  "x": 421,
  "y": 565,
  "font_size": 10,
  "color": "#9CA3AF",
  "align": "center"
}
```

### Dark Footer Band

```json
{
  "type": "shape",
  "shape": "rectangle",
  "x": 0,
  "y": 500,
  "width": 842,
  "height": 95,
  "fill_color": "#111827"
},
{
  "type": "text",
  "content": "COMPANY NAME",
  "x": 60,
  "y": 525,
  "font_size": 14,
  "font_weight": "bold",
  "color": "#10B981"
},
{
  "type": "text",
  "content": "Address | Phone | Email",
  "x": 60,
  "y": 548,
  "font_size": 10,
  "color": "#9CA3AF"
}
```

## Layout Tips

### Vertical Spacing

For consistent layouts, establish a grid:
- Page header: y=0 to y=55
- Content area: y=70 to y=530
- Page footer: y=545 to y=595

### Text Centering in Boxes

To vertically center text in a box:
```
text_y = box_y + (box_height / 2) + (font_size * 0.3)
```

Example for box at y=200, height=80, font_size=24:
```
text_y = 200 + 40 + 7 = 247
```

### Table Positioning

Calculate table end position:
```
table_end_y = table_y + header_height + (row_count * row_height)
```

Place elements below the table after this Y position.

### Avoid Overlaps

When placing elements:
1. Calculate the bounding box of preceding elements
2. Add appropriate margin (typically 15-30 points)
3. Position new elements below

## Template Structure for Quotes/Proposals

A typical multi-page quote follows this structure:

1. **Cover Page** (dark theme)
   - Company branding
   - Document title
   - Customer details boxes
   - Contact info in footer

2. **Why Choose Us**
   - Stats/credibility boxes
   - Certifications sidebar
   - Testimonial

3. **Your System/Scope**
   - Category boxes with bullet lists
   - Product/service descriptions

4. **Investment/Pricing**
   - Itemized pricing table
   - Totals box (positioned after table)
   - VAT notes

5. **Terms & Acceptance**
   - Savings projections (if applicable)
   - Signature section
   - Company details footer

## Validation Checklist

Before generating:

- [ ] All text with long content has `max_width` set
- [ ] Tables end before the next element starts
- [ ] Totals boxes don't overlap pricing tables
- [ ] Colors use 6-digit hex format (#RRGGBB)
- [ ] Page footers are at consistent Y positions
- [ ] Centered text uses correct x for center point
- [ ] Element arrays are valid JSON (no trailing commas)

## Example Templates

See these templates for reference:
- `crg_direct_quote.json` - Solar/renewable energy quote
- `construction_proposal.json` - Construction project proposal

## Generating PDFs

Command line:
```bash
./pdf-gen --presentation template.json output.pdf
```

WASM (browser/Node.js):
```javascript
const pdfBytes = zigPdf.generatePresentation(JSON.stringify(templateData));
```
