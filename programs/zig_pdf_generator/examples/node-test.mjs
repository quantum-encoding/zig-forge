#!/usr/bin/env node
/**
 * Node.js Test - PDF Generation via Zig WASM
 *
 * Run with: node examples/node-test.mjs
 * Requires: Node.js 18+ (for WASI support)
 */

import { readFile, writeFile } from 'fs/promises';
import { WASI } from 'wasi';
import { argv, env } from 'process';

// Initialize WASI
const wasi = new WASI({
  version: 'preview1',
  args: argv,
  env,
});

// Load WASM module
const wasmPath = new URL('../zig-out/lib/zigpdf.wasm', import.meta.url);
const wasmBuffer = await readFile(wasmPath);
const wasmModule = await WebAssembly.compile(wasmBuffer);

// Instantiate with WASI imports
const instance = await WebAssembly.instantiate(wasmModule, {
  wasi_snapshot_preview1: wasi.wasiImport,
});

// Initialize WASI
wasi.initialize(instance);

const exports = instance.exports;
const { memory, wasm_alloc, wasm_free } = exports;

/**
 * Generate PDF from JSON
 */
function generatePdf(functionName, data) {
  const generateFn = exports[functionName];
  if (!generateFn) {
    throw new Error(`Unknown function: ${functionName}`);
  }

  const encoder = new TextEncoder();
  const jsonStr = JSON.stringify(data);
  const jsonBytes = encoder.encode(jsonStr);

  // Allocate input buffer
  const inputPtr = wasm_alloc(jsonBytes.length + 1);
  if (inputPtr === 0) throw new Error('Allocation failed');

  // Write JSON
  const inputView = new Uint8Array(memory.buffer, inputPtr, jsonBytes.length + 1);
  inputView.set(jsonBytes);
  inputView[jsonBytes.length] = 0;

  // Allocate length output
  const lenPtr = wasm_alloc(4);
  if (lenPtr === 0) {
    wasm_free(inputPtr, jsonBytes.length + 1);
    throw new Error('Allocation failed');
  }

  // Generate PDF
  const pdfPtr = generateFn(inputPtr, lenPtr);
  wasm_free(inputPtr, jsonBytes.length + 1);

  if (pdfPtr === 0) {
    wasm_free(lenPtr, 4);
    const errorPtr = exports.zigpdf_get_error();
    const errorView = new Uint8Array(memory.buffer, errorPtr, 256);
    const errorEnd = errorView.indexOf(0);
    const errorMsg = new TextDecoder().decode(errorView.subarray(0, errorEnd));
    throw new Error(`Generation failed: ${errorMsg}`);
  }

  // Read length and copy PDF
  const pdfLen = new DataView(memory.buffer).getUint32(lenPtr, true);
  wasm_free(lenPtr, 4);

  const pdfBytes = new Uint8Array(memory.buffer, pdfPtr, pdfLen).slice();
  wasm_free(pdfPtr, pdfLen);

  return pdfBytes;
}

// =============================================================================
// Test: Generate Invoice
// =============================================================================

console.log('Testing Zig PDF WASM Module\n');
console.log('Version:', (() => {
  const ptr = exports.zigpdf_version();
  const view = new Uint8Array(memory.buffer, ptr, 20);
  return new TextDecoder().decode(view.subarray(0, view.indexOf(0)));
})());
console.log('Memory:', exports.wasm_memory_size(), 'pages');
console.log('');

// Test invoice generation
const invoiceData = {
  company_name: "Acme Corporation",
  company_address: "123 Business Street, London EC1A 1BB",
  client_name: "John Smith",
  client_address: "456 Client Road, Manchester M1 2AB",
  invoice_number: "INV-WASM-001",
  invoice_date: "2026-01-09",
  items: [
    { description: "Consulting Services", quantity: 10, unit_price: 150.00, total: 1500.00 },
    { description: "Software License", quantity: 1, unit_price: 500.00, total: 500.00 },
  ],
  subtotal: 2000.00,
  tax_rate: 0.20,
  tax_amount: 400.00,
  total: 2400.00,
  notes: "Generated with Zig WASM module"
};

console.log('Generating invoice PDF...');
const invoicePdf = generatePdf('zigpdf_generate_invoice', invoiceData);
await writeFile('/tmp/wasm-invoice.pdf', invoicePdf);
console.log(`✓ Invoice saved to /tmp/wasm-invoice.pdf (${invoicePdf.length} bytes)`);

// Test dividend voucher (Irish with DWT)
const dividendData = {
  jurisdiction: "Ireland",
  voucher: {
    number: "DIV-WASM-001",
    date: "31 March 2026",
    tax_year: "2025"
  },
  company: {
    name: "WASM TEST COMPANY LIMITED",
    registration_number: "999999",
    registered_address: {
      line1: "1 Test Street",
      city: "Dublin 2",
      postcode: "D02 TEST",
      country: "Ireland"
    }
  },
  shareholder: {
    name: "Test Shareholder",
    address: {
      line1: "2 Shareholder Lane",
      city: "Dublin",
      postcode: "D01 TEST",
      country: "Ireland"
    }
  },
  dividend: {
    shares_held: 100,
    share_class: "Ordinary",
    rate_per_share: 1.00,
    gross_amount: 100.00,
    dwt_rate: 0.25,
    dwt_withheld: 25.00,
    net_payable: 75.00,
    currency: "EUR"
  },
  payment: {
    method: "Bank Transfer",
    date: "1 April 2026",
    reference: "WASM-TEST-001"
  },
  declaration: {
    resolution_date: "25 March 2026",
    payment_date: "1 April 2026"
  },
  signatory: {
    role: "Director",
    name: "Test Director",
    date: "31 March 2026"
  }
};

console.log('Generating Irish dividend voucher PDF...');
const dividendPdf = generatePdf('zigpdf_generate_dividend_voucher', dividendData);
await writeFile('/tmp/wasm-dividend.pdf', dividendPdf);
console.log(`✓ Dividend voucher saved to /tmp/wasm-dividend.pdf (${dividendPdf.length} bytes)`);

console.log('\n✓ All tests passed!');
console.log('Memory after tests:', exports.wasm_memory_size(), 'pages');
