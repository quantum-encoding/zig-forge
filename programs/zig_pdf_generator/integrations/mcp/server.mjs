#!/usr/bin/env node
/**
 * zigpdf MCP server — "the document engine for AI agents".
 * JSON in, PDF out, exposed as MCP tools so Claude Desktop / any MCP client
 * can generate invoices, quotes, letters, presentations, proposals and
 * company certificates directly.
 *
 * Zero dependencies: hand-rolled newline-delimited JSON-RPC over stdio
 * (the MCP stdio transport). The heavy lifting is the zig `pdf-gen` binary.
 *
 * Claude Desktop config (claude_desktop_config.json):
 *   "zigpdf": {
 *     "command": "node",
 *     "args": ["/path/to/zig_pdf_generator/integrations/mcp/server.mjs"],
 *     "env": { "PDF_GEN_BIN": "/path/to/zig-out/bin/pdf-gen" }   // optional
 *   }
 */
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import readline from 'node:readline';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const BIN = process.env.PDF_GEN_BIN ?? path.resolve(HERE, '../../zig-out/bin/pdf-gen');
const SCHEMA_MD = path.resolve(HERE, '../../ZIG_PDF_SCHEMA.md');
const OUT_DIR = process.env.PDF_OUT_DIR ?? path.join(os.homedir(), 'Documents', 'generated-pdfs');

const TEMPLATE_FLAGS = {
  invoice: '--basic',
  minimalist: '--minimalist',
  letter: '--letter',
  presentation: '--presentation',
  proposal: '--proposal',
};
const CERTIFICATE_TYPES = [
  'contract', 'share-certificate', 'dividend-voucher', 'stock-transfer',
  'board-resolution', 'director-consent', 'director-appointment',
  'director-resignation', 'written-resolution',
];

const TOOLS = [
  {
    name: 'generate_pdf',
    description:
      'Generate a pixel-perfect PDF document from structured JSON. Templates: ' +
      'invoice (invoices/quotes/receipts — supports theme:"squircle" for rounded-card styling, ' +
      'company_logo_base64, logo_banner, logo_link_url, table_style, payment_buttons), ' +
      'minimalist (clean consultant quote), letter (premium letter-style quote), ' +
      'presentation (freeform slide deck), proposal (structured proposal with metrics), ' +
      'certificate (company/legal documents — set certificate_type). ' +
      'Call get_pdf_schema first for the exact JSON fields of a template. ' +
      'Returns the absolute path of the written PDF.',
    inputSchema: {
      type: 'object',
      properties: {
        template: { type: 'string', enum: [...Object.keys(TEMPLATE_FLAGS), 'certificate'], description: 'Which document template to render' },
        certificate_type: { type: 'string', enum: CERTIFICATE_TYPES, description: 'Required when template=certificate' },
        data: { type: 'object', description: 'The document JSON payload (see get_pdf_schema)' },
        output_path: { type: 'string', description: `Absolute path for the PDF. Default: ${OUT_DIR}/<name>.pdf` },
        filename: { type: 'string', description: 'Filename (without directory) when output_path is not given' },
      },
      required: ['template', 'data'],
    },
  },
  {
    name: 'get_pdf_schema',
    description:
      'Return the JSON field reference for a document template (invoice, clean_quote/minimalist, ' +
      'letter_quote, letter, presentation, proposal). Call this before generate_pdf when unsure of fields.',
    inputSchema: {
      type: 'object',
      properties: {
        template: { type: 'string', description: 'Template name to look up; omit for the full reference' },
      },
    },
  },
];

function generatePdf(args) {
  return new Promise((resolve) => {
    const template = String(args.template ?? 'invoice');
    let flagArgs;
    if (template === 'certificate') {
      const ct = String(args.certificate_type ?? '');
      if (!CERTIFICATE_TYPES.includes(ct)) {
        return resolve({ error: `certificate_type must be one of: ${CERTIFICATE_TYPES.join(', ')}` });
      }
      flagArgs = ['--certificate', ct];
    } else {
      const flag = TEMPLATE_FLAGS[template];
      if (!flag) return resolve({ error: `unknown template "${template}"` });
      flagArgs = [flag];
    }

    let outPath = args.output_path ? String(args.output_path) : null;
    if (!outPath) {
      fs.mkdirSync(OUT_DIR, { recursive: true });
      const base = (args.filename ? String(args.filename) : `${template}-${new Date().toISOString().slice(0, 19).replace(/[:T]/g, '-')}.pdf`)
        .replace(/[^A-Za-z0-9._ -]/g, '_');
      outPath = path.join(OUT_DIR, base.endsWith('.pdf') ? base : base + '.pdf');
    }

    const child = spawn(BIN, flagArgs, { stdio: ['pipe', 'pipe', 'pipe'] });
    const out = [];
    const err = [];
    child.stdout.on('data', (d) => out.push(d));
    child.stderr.on('data', (d) => err.push(d));
    child.on('error', (e) => resolve({ error: `could not run pdf-gen at ${BIN}: ${e.message}` }));
    child.on('close', (code) => {
      const stderr = Buffer.concat(err).toString().trim();
      const pdf = Buffer.concat(out);
      if (code !== 0 || pdf.length < 100 || !pdf.subarray(0, 5).toString().startsWith('%PDF')) {
        return resolve({ error: stderr || `pdf-gen exited ${code} without producing a PDF` });
      }
      try {
        fs.mkdirSync(path.dirname(outPath), { recursive: true });
        fs.writeFileSync(outPath, pdf);
      } catch (e) {
        return resolve({ error: `PDF generated but could not write ${outPath}: ${e.message}` });
      }
      resolve({ path: outPath, bytes: pdf.length, note: stderr || undefined });
    });
    child.stdin.write(JSON.stringify(args.data ?? {}));
    child.stdin.end();
  });
}

function getSchema(args) {
  let md;
  try {
    md = fs.readFileSync(SCHEMA_MD, 'utf8');
  } catch {
    return { error: `schema reference not found at ${SCHEMA_MD}` };
  }
  const t = args?.template ? String(args.template).toLowerCase() : null;
  if (!t) return { text: md };
  const alias = { minimalist: 'clean_quote', invoice: 'invoice', letter: 'letter', presentation: 'presentation', proposal: 'proposal_legacy' }[t] ?? t;
  const re = new RegExp('^## Template: `' + alias + '`[\\s\\S]*?(?=^## |$(?![\\s\\S]))', 'm');
  const m = md.match(re);
  return { text: m ? m[0] : `No section for "${t}". Available: invoice, clean_quote, letter_quote, letter, presentation, proposal_legacy.\n\n` + md.slice(0, 2000) };
}

// ── minimal MCP over stdio (newline-delimited JSON-RPC 2.0) ──
const rl = readline.createInterface({ input: process.stdin });
const send = (msg) => process.stdout.write(JSON.stringify(msg) + '\n');

rl.on('line', async (line) => {
  if (!line.trim()) return;
  let req;
  try { req = JSON.parse(line); } catch { return; }
  const { id, method, params } = req;
  const reply = (result) => id !== undefined && send({ jsonrpc: '2.0', id, result });
  const fail = (code, message) => id !== undefined && send({ jsonrpc: '2.0', id, error: { code, message } });

  try {
    if (method === 'initialize') {
      reply({
        protocolVersion: params?.protocolVersion ?? '2024-11-05',
        capabilities: { tools: {} },
        serverInfo: { name: 'zigpdf', version: '1.0.0' },
      });
    } else if (method === 'notifications/initialized' || method?.startsWith('notifications/')) {
      // no response to notifications
    } else if (method === 'ping') {
      reply({});
    } else if (method === 'tools/list') {
      reply({ tools: TOOLS });
    } else if (method === 'tools/call') {
      const name = params?.name;
      const args = params?.arguments ?? {};
      let result;
      if (name === 'generate_pdf') result = await generatePdf(args);
      else if (name === 'get_pdf_schema') result = getSchema(args);
      else return fail(-32602, `unknown tool "${name}"`);
      if (result.error) {
        reply({ content: [{ type: 'text', text: `Error: ${result.error}` }], isError: true });
      } else if (result.text) {
        reply({ content: [{ type: 'text', text: result.text }] });
      } else {
        reply({ content: [{ type: 'text', text: `PDF written: ${result.path} (${result.bytes} bytes)${result.note ? `\n${result.note}` : ''}` }] });
      }
    } else {
      fail(-32601, `method not found: ${method}`);
    }
  } catch (e) {
    fail(-32603, String(e?.message ?? e));
  }
});
