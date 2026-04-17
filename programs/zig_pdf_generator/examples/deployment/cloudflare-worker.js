/**
 * Cloudflare Worker - PDF Generation via Zig WASM
 *
 * This example shows how to use the zigpdf.wasm module in a Cloudflare Worker
 * to generate PDFs from Stripe webhooks or API requests.
 *
 * Setup:
 * 1. Build the WASM module: `zig build wasm`
 * 2. Copy zig-out/lib/zigpdf.wasm to your worker directory
 * 3. Import and instantiate as shown below
 *
 * Usage with wrangler.toml:
 * ```toml
 * [build]
 * command = "echo 'Using pre-built WASM'"
 *
 * [[wasm_modules]]
 * binding = "ZIGPDF"
 * path = "zigpdf.wasm"
 * ```
 */

// Type definitions for better IDE support
/** @typedef {WebAssembly.Exports & { memory: WebAssembly.Memory, wasm_alloc: Function, wasm_free: Function }} ZigPdfExports */

/**
 * Initialize the WASM module
 * @param {WebAssembly.Module} wasmModule - The WASM module (from env.ZIGPDF in Cloudflare)
 * @returns {Promise<ZigPdfExports>}
 */
async function initZigPdf(wasmModule) {
  const instance = await WebAssembly.instantiate(wasmModule, {
    // WASI imports (minimal implementation for Cloudflare Workers)
    wasi_snapshot_preview1: {
      // Required WASI functions - stub implementations
      fd_write: (fd, iovs_ptr, iovs_len, nwritten_ptr) => {
        // Could implement console logging here if needed
        return 0; // Success
      },
      fd_close: () => 0,
      fd_seek: () => 0,
      fd_read: () => 0,
      proc_exit: (code) => { throw new Error(`Process exit: ${code}`); },
      environ_sizes_get: (count_ptr, size_ptr) => {
        const view = new DataView(instance.exports.memory.buffer);
        view.setUint32(count_ptr, 0, true);
        view.setUint32(size_ptr, 0, true);
        return 0;
      },
      environ_get: () => 0,
      args_sizes_get: (argc_ptr, argv_buf_size_ptr) => {
        const view = new DataView(instance.exports.memory.buffer);
        view.setUint32(argc_ptr, 0, true);
        view.setUint32(argv_buf_size_ptr, 0, true);
        return 0;
      },
      args_get: () => 0,
      clock_time_get: (clock_id, precision, time_ptr) => {
        const view = new DataView(instance.exports.memory.buffer);
        const now = BigInt(Date.now()) * 1000000n; // Convert to nanoseconds
        view.setBigUint64(time_ptr, now, true);
        return 0;
      },
      random_get: (buf_ptr, buf_len) => {
        const buffer = new Uint8Array(instance.exports.memory.buffer, buf_ptr, buf_len);
        crypto.getRandomValues(buffer);
        return 0;
      },
    },
  });

  return instance.exports;
}

/**
 * Generate a PDF from JSON data
 * @param {ZigPdfExports} exports - The WASM exports
 * @param {string} functionName - The PDF generation function name (e.g., 'zigpdf_generate_invoice')
 * @param {object} data - The JSON data for the PDF
 * @returns {Uint8Array|null} - The PDF bytes or null on error
 */
function generatePdf(exports, functionName, data) {
  const { memory, wasm_alloc, wasm_free } = exports;
  const generateFn = exports[functionName];

  if (!generateFn) {
    throw new Error(`Unknown PDF function: ${functionName}`);
  }

  // Encode JSON to bytes
  const encoder = new TextEncoder();
  const jsonStr = JSON.stringify(data);
  const jsonBytes = encoder.encode(jsonStr);

  // Allocate input buffer (+1 for null terminator)
  const inputPtr = wasm_alloc(jsonBytes.length + 1);
  if (inputPtr === 0) {
    throw new Error('Failed to allocate input buffer');
  }

  // Write JSON to WASM memory
  const inputView = new Uint8Array(memory.buffer, inputPtr, jsonBytes.length + 1);
  inputView.set(jsonBytes);
  inputView[jsonBytes.length] = 0; // Null terminate

  // Allocate output length pointer (4 bytes for u32)
  const lenPtr = wasm_alloc(4);
  if (lenPtr === 0) {
    wasm_free(inputPtr, jsonBytes.length + 1);
    throw new Error('Failed to allocate length buffer');
  }

  try {
    // Generate PDF
    const pdfPtr = generateFn(inputPtr, lenPtr);

    // Free input buffer
    wasm_free(inputPtr, jsonBytes.length + 1);

    if (pdfPtr === 0) {
      wasm_free(lenPtr, 4);
      // Get error message
      const errorPtr = exports.zigpdf_get_error();
      const errorView = new Uint8Array(memory.buffer, errorPtr, 256);
      const errorEnd = errorView.indexOf(0);
      const errorMsg = new TextDecoder().decode(errorView.subarray(0, errorEnd));
      throw new Error(`PDF generation failed: ${errorMsg}`);
    }

    // Read output length
    const pdfLen = new DataView(memory.buffer).getUint32(lenPtr, true);
    wasm_free(lenPtr, 4);

    // Copy PDF bytes (must copy before freeing!)
    const pdfBytes = new Uint8Array(memory.buffer, pdfPtr, pdfLen).slice();

    // Free PDF buffer
    wasm_free(pdfPtr, pdfLen);

    return pdfBytes;
  } catch (e) {
    // Cleanup on error
    try { wasm_free(inputPtr, jsonBytes.length + 1); } catch {}
    try { wasm_free(lenPtr, 4); } catch {}
    throw e;
  }
}

// =============================================================================
// Cloudflare Worker Handler
// =============================================================================

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    // Initialize WASM on first request (could be cached)
    const exports = await initZigPdf(env.ZIGPDF);

    // Route: POST /generate/invoice
    if (request.method === 'POST' && url.pathname === '/generate/invoice') {
      try {
        const data = await request.json();
        const pdfBytes = generatePdf(exports, 'zigpdf_generate_invoice', data);

        return new Response(pdfBytes, {
          headers: {
            'Content-Type': 'application/pdf',
            'Content-Disposition': `attachment; filename="invoice-${data.invoice_number || 'document'}.pdf"`,
          },
        });
      } catch (e) {
        return new Response(JSON.stringify({ error: e.message }), {
          status: 500,
          headers: { 'Content-Type': 'application/json' },
        });
      }
    }

    // Route: POST /generate/dividend-voucher
    if (request.method === 'POST' && url.pathname === '/generate/dividend-voucher') {
      try {
        const data = await request.json();
        const pdfBytes = generatePdf(exports, 'zigpdf_generate_dividend_voucher', data);

        return new Response(pdfBytes, {
          headers: {
            'Content-Type': 'application/pdf',
            'Content-Disposition': `attachment; filename="dividend-${data.voucher?.number || 'voucher'}.pdf"`,
          },
        });
      } catch (e) {
        return new Response(JSON.stringify({ error: e.message }), {
          status: 500,
          headers: { 'Content-Type': 'application/json' },
        });
      }
    }

    // Route: POST /webhook/stripe (Stripe invoice webhook)
    if (request.method === 'POST' && url.pathname === '/webhook/stripe') {
      try {
        // Verify Stripe signature (implement with your Stripe secret)
        const signature = request.headers.get('stripe-signature');
        const body = await request.text();
        // const event = stripe.webhooks.constructEvent(body, signature, env.STRIPE_WEBHOOK_SECRET);
        const event = JSON.parse(body); // Simplified for example

        if (event.type === 'invoice.payment_succeeded') {
          const invoice = event.data.object;

          // Map Stripe invoice to our format
          const invoiceData = {
            invoice_number: invoice.number,
            invoice_date: new Date(invoice.created * 1000).toISOString().split('T')[0],
            company_name: "Your Company Name",
            company_address: "Your Address",
            client_name: invoice.customer_name || invoice.customer_email,
            client_address: invoice.customer_address?.line1 || "",
            items: invoice.lines.data.map(line => ({
              description: line.description,
              quantity: line.quantity || 1,
              unit_price: line.unit_amount / 100,
              total: line.amount / 100,
            })),
            subtotal: invoice.subtotal / 100,
            tax_rate: invoice.tax ? (invoice.tax / invoice.subtotal) : 0,
            tax_amount: (invoice.tax || 0) / 100,
            total: invoice.amount_paid / 100,
            currency: invoice.currency.toUpperCase(),
          };

          const pdfBytes = generatePdf(exports, 'zigpdf_generate_invoice', invoiceData);

          // Store PDF (e.g., R2, S3) and/or send email
          // await env.R2_BUCKET.put(`invoices/${invoice.id}.pdf`, pdfBytes);

          // Send email with Resend/SendGrid
          // await sendInvoiceEmail(invoice.customer_email, pdfBytes);

          return new Response(JSON.stringify({ success: true, invoiceId: invoice.id }), {
            headers: { 'Content-Type': 'application/json' },
          });
        }

        return new Response(JSON.stringify({ received: true }), {
          headers: { 'Content-Type': 'application/json' },
        });
      } catch (e) {
        return new Response(JSON.stringify({ error: e.message }), {
          status: 500,
          headers: { 'Content-Type': 'application/json' },
        });
      }
    }

    // Health check
    if (url.pathname === '/health') {
      const version = exports.zigpdf_version();
      const versionView = new Uint8Array(exports.memory.buffer, version, 20);
      const versionEnd = versionView.indexOf(0);
      const versionStr = new TextDecoder().decode(versionView.subarray(0, versionEnd));

      return new Response(JSON.stringify({
        status: 'ok',
        version: versionStr,
        memory_pages: exports.wasm_memory_size(),
      }), {
        headers: { 'Content-Type': 'application/json' },
      });
    }

    return new Response('Not Found', { status: 404 });
  },
};

// =============================================================================
// Available PDF Generation Functions
// =============================================================================

/*
The following functions are available in the WASM module:

- zigpdf_generate_invoice          - Business invoices
- zigpdf_generate_contract         - Legal contracts/documents
- zigpdf_generate_share_certificate - Company share certificates
- zigpdf_generate_dividend_voucher  - UK/Irish dividend vouchers (with DWT support)
- zigpdf_generate_stock_transfer    - Stock transfer forms
- zigpdf_generate_board_resolution  - Board resolutions
- zigpdf_generate_director_consent  - Director consent forms
- zigpdf_generate_director_appointment - Director appointment letters
- zigpdf_generate_director_resignation - Director resignation letters
- zigpdf_generate_written_resolution   - Written shareholder resolutions

Memory management:
- wasm_alloc(size)     - Allocate memory, returns pointer or 0 on failure
- wasm_free(ptr, size) - Free previously allocated memory
- wasm_memory_size()   - Get current memory size in 64KB pages
- wasm_memory_grow(n)  - Grow memory by n pages, returns -1 on failure

Error handling:
- zigpdf_get_error()   - Get last error message (null-terminated string)
- zigpdf_version()     - Get version string
*/
