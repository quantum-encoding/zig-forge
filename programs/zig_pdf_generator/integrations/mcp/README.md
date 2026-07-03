# zigpdf MCP server

**The document engine for AI agents.** JSON in, PDF out — invoices, quotes,
letters, presentations, proposals and company certificates — exposed as MCP
tools so Claude Desktop (or any MCP client) generates real branded documents.

Zero dependencies: one Node file speaking MCP stdio, shelling to the zig
`pdf-gen` binary (fast, deterministic, no browser, no LaTeX).

## Setup

1. Build the engine: `cd programs/zig_pdf_generator && zig build`
2. Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "zigpdf": {
      "command": "node",
      "args": ["/ABSOLUTE/PATH/programs/zig_pdf_generator/integrations/mcp/server.mjs"]
    }
  }
}
```

Optional env: `PDF_GEN_BIN` (binary path), `PDF_OUT_DIR` (default `~/Documents/generated-pdfs`).

## Tools

- **`generate_pdf`** — `{ template, data, output_path?, filename?, certificate_type? }`.
  Templates: `invoice` (incl. quotes/receipts, `theme:"squircle"`, logos/banners with
  clickable links, payment buttons), `minimalist`, `letter`, `presentation`,
  `proposal`, `certificate` (contracts, share certificates, board resolutions…).
  Returns the written PDF's absolute path.
- **`get_pdf_schema`** — `{ template? }` → the JSON field reference, so the
  model can self-serve the exact payload format.

## Example (what Claude does)

> "Make CRG a £4,040 invoice with the squircle theme and export it"

Claude calls `get_pdf_schema {template: "invoice"}`, builds the payload, calls
`generate_pdf`, and tells you where the PDF landed. Strict fail-fast schema
validation means a bad payload gets a named-field error, never a blank PDF.
