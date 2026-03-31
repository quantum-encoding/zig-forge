/**
 * Firebase Functions - PDF Generation via Zig WASM
 *
 * This example shows how to use the zigpdf.wasm module in Firebase Functions
 * to generate PDFs from Stripe webhooks or HTTP requests.
 *
 * Setup:
 * 1. Build the WASM module: `zig build wasm`
 * 2. Copy zig-out/lib/zigpdf.wasm to your functions directory
 * 3. Deploy with: firebase deploy --only functions
 *
 * package.json dependencies:
 * ```json
 * {
 *   "engines": { "node": "18" },
 *   "dependencies": {
 *     "firebase-admin": "^12.0.0",
 *     "firebase-functions": "^4.5.0",
 *     "@google-cloud/storage": "^7.0.0"
 *   }
 * }
 * ```
 */

const functions = require('firebase-functions');
const admin = require('firebase-admin');
const { readFileSync } = require('fs');
const path = require('path');

admin.initializeApp();

// =============================================================================
// WASM Module Loading
// =============================================================================

let wasmExports = null;
let wasmMemory = null;

/**
 * Initialize the WASM module (lazy loaded on first request)
 */
async function initWasm() {
  if (wasmExports) return wasmExports;

  const wasmPath = path.join(__dirname, 'zigpdf.wasm');
  const wasmBuffer = readFileSync(wasmPath);
  const wasmModule = await WebAssembly.compile(wasmBuffer);

  // Create memory instance for WASI
  wasmMemory = new WebAssembly.Memory({ initial: 256, maximum: 1024 });

  const instance = await WebAssembly.instantiate(wasmModule, {
    wasi_snapshot_preview1: {
      fd_write: (fd, iovs_ptr, iovs_len, nwritten_ptr) => {
        // Stub - could implement logging
        return 0;
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
        const now = BigInt(Date.now()) * 1000000n;
        view.setBigUint64(time_ptr, now, true);
        return 0;
      },
      random_get: (buf_ptr, buf_len) => {
        const buffer = new Uint8Array(instance.exports.memory.buffer, buf_ptr, buf_len);
        require('crypto').randomFillSync(buffer);
        return 0;
      },
    },
  });

  wasmExports = instance.exports;
  return wasmExports;
}

/**
 * Generate a PDF from JSON data
 */
function generatePdf(exports, functionName, data) {
  const { memory, wasm_alloc, wasm_free } = exports;
  const generateFn = exports[functionName];

  if (!generateFn) {
    throw new Error(`Unknown PDF function: ${functionName}`);
  }

  const encoder = new TextEncoder();
  const jsonStr = JSON.stringify(data);
  const jsonBytes = encoder.encode(jsonStr);

  // Allocate input buffer
  const inputPtr = wasm_alloc(jsonBytes.length + 1);
  if (inputPtr === 0) throw new Error('Failed to allocate input buffer');

  const inputView = new Uint8Array(memory.buffer, inputPtr, jsonBytes.length + 1);
  inputView.set(jsonBytes);
  inputView[jsonBytes.length] = 0;

  // Allocate output length pointer
  const lenPtr = wasm_alloc(4);
  if (lenPtr === 0) {
    wasm_free(inputPtr, jsonBytes.length + 1);
    throw new Error('Failed to allocate length buffer');
  }

  try {
    const pdfPtr = generateFn(inputPtr, lenPtr);
    wasm_free(inputPtr, jsonBytes.length + 1);

    if (pdfPtr === 0) {
      wasm_free(lenPtr, 4);
      const errorPtr = exports.zigpdf_get_error();
      const errorView = new Uint8Array(memory.buffer, errorPtr, 256);
      const errorEnd = errorView.indexOf(0);
      const errorMsg = new TextDecoder().decode(errorView.subarray(0, errorEnd));
      throw new Error(`PDF generation failed: ${errorMsg}`);
    }

    const pdfLen = new DataView(memory.buffer).getUint32(lenPtr, true);
    wasm_free(lenPtr, 4);

    const pdfBytes = new Uint8Array(memory.buffer, pdfPtr, pdfLen).slice();
    wasm_free(pdfPtr, pdfLen);

    return pdfBytes;
  } catch (e) {
    try { wasm_free(inputPtr, jsonBytes.length + 1); } catch {}
    try { wasm_free(lenPtr, 4); } catch {}
    throw e;
  }
}

// =============================================================================
// HTTP Functions
// =============================================================================

/**
 * Generate Invoice PDF
 * POST /generateInvoice
 */
exports.generateInvoice = functions.https.onRequest(async (req, res) => {
  if (req.method !== 'POST') {
    res.status(405).send('Method Not Allowed');
    return;
  }

  try {
    const exports = await initWasm();
    const pdfBytes = generatePdf(exports, 'zigpdf_generate_invoice', req.body);

    res.set('Content-Type', 'application/pdf');
    res.set('Content-Disposition', `attachment; filename="invoice-${req.body.invoice_number || 'document'}.pdf"`);
    res.send(Buffer.from(pdfBytes));
  } catch (e) {
    console.error('Invoice generation error:', e);
    res.status(500).json({ error: e.message });
  }
});

/**
 * Generate Dividend Voucher PDF
 * POST /generateDividendVoucher
 */
exports.generateDividendVoucher = functions.https.onRequest(async (req, res) => {
  if (req.method !== 'POST') {
    res.status(405).send('Method Not Allowed');
    return;
  }

  try {
    const exports = await initWasm();
    const pdfBytes = generatePdf(exports, 'zigpdf_generate_dividend_voucher', req.body);

    res.set('Content-Type', 'application/pdf');
    res.set('Content-Disposition', `attachment; filename="dividend-${req.body.voucher?.number || 'voucher'}.pdf"`);
    res.send(Buffer.from(pdfBytes));
  } catch (e) {
    console.error('Dividend voucher generation error:', e);
    res.status(500).json({ error: e.message });
  }
});

/**
 * Generate Share Certificate PDF
 * POST /generateShareCertificate
 */
exports.generateShareCertificate = functions.https.onRequest(async (req, res) => {
  if (req.method !== 'POST') {
    res.status(405).send('Method Not Allowed');
    return;
  }

  try {
    const exports = await initWasm();
    const pdfBytes = generatePdf(exports, 'zigpdf_generate_share_certificate', req.body);

    res.set('Content-Type', 'application/pdf');
    res.set('Content-Disposition', `attachment; filename="share-certificate-${req.body.certificate_number || 'document'}.pdf"`);
    res.send(Buffer.from(pdfBytes));
  } catch (e) {
    console.error('Share certificate generation error:', e);
    res.status(500).json({ error: e.message });
  }
});

// =============================================================================
// Stripe Webhook Handler
// =============================================================================

/**
 * Stripe Webhook Handler
 * Generates PDF invoices and stores them in Cloud Storage
 */
exports.stripeWebhook = functions.https.onRequest(async (req, res) => {
  if (req.method !== 'POST') {
    res.status(405).send('Method Not Allowed');
    return;
  }

  const stripe = require('stripe')(functions.config().stripe?.secret_key || process.env.STRIPE_SECRET_KEY);
  const endpointSecret = functions.config().stripe?.webhook_secret || process.env.STRIPE_WEBHOOK_SECRET;

  let event;

  try {
    // Verify Stripe signature
    const sig = req.headers['stripe-signature'];
    event = stripe.webhooks.constructEvent(req.rawBody, sig, endpointSecret);
  } catch (err) {
    console.error('Webhook signature verification failed:', err.message);
    res.status(400).send(`Webhook Error: ${err.message}`);
    return;
  }

  try {
    if (event.type === 'invoice.payment_succeeded') {
      const invoice = event.data.object;

      // Map Stripe invoice to our format
      const invoiceData = {
        invoice_number: invoice.number,
        invoice_date: new Date(invoice.created * 1000).toISOString().split('T')[0],
        company_name: functions.config().company?.name || 'Your Company',
        company_address: functions.config().company?.address || 'Your Address',
        client_name: invoice.customer_name || invoice.customer_email,
        client_address: formatAddress(invoice.customer_address),
        items: invoice.lines.data.map(line => ({
          description: line.description || 'Service',
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

      // Generate PDF
      const exports = await initWasm();
      const pdfBytes = generatePdf(exports, 'zigpdf_generate_invoice', invoiceData);

      // Store in Cloud Storage
      const bucket = admin.storage().bucket();
      const fileName = `invoices/${invoice.id}.pdf`;
      const file = bucket.file(fileName);

      await file.save(Buffer.from(pdfBytes), {
        metadata: {
          contentType: 'application/pdf',
          metadata: {
            stripeInvoiceId: invoice.id,
            customerEmail: invoice.customer_email,
          },
        },
      });

      // Get signed URL for download (valid for 7 days)
      const [signedUrl] = await file.getSignedUrl({
        action: 'read',
        expires: Date.now() + 7 * 24 * 60 * 60 * 1000,
      });

      console.log(`Invoice ${invoice.id} saved to ${fileName}`);

      // Optionally trigger email via Firestore (use with Firebase Extension)
      await admin.firestore().collection('mail').add({
        to: invoice.customer_email,
        message: {
          subject: `Invoice ${invoice.number}`,
          html: `<p>Thank you for your payment. Please find your invoice attached.</p>`,
          attachments: [{
            filename: `invoice-${invoice.number}.pdf`,
            path: signedUrl,
          }],
        },
      });

      res.json({ success: true, invoiceId: invoice.id, pdfUrl: signedUrl });
    } else {
      res.json({ received: true, type: event.type });
    }
  } catch (e) {
    console.error('Webhook processing error:', e);
    res.status(500).json({ error: e.message });
  }
});

// =============================================================================
// Firestore Trigger (Alternative Pattern)
// =============================================================================

/**
 * Firestore Trigger - Generate PDF when document created
 * Watches the 'pdf_requests' collection
 */
exports.onPdfRequest = functions.firestore
  .document('pdf_requests/{requestId}')
  .onCreate(async (snap, context) => {
    const data = snap.data();
    const requestId = context.params.requestId;

    try {
      const exports = await initWasm();

      // Determine which PDF type to generate
      const functionMap = {
        'invoice': 'zigpdf_generate_invoice',
        'dividend_voucher': 'zigpdf_generate_dividend_voucher',
        'share_certificate': 'zigpdf_generate_share_certificate',
        'contract': 'zigpdf_generate_contract',
        'board_resolution': 'zigpdf_generate_board_resolution',
        'stock_transfer': 'zigpdf_generate_stock_transfer',
        'director_consent': 'zigpdf_generate_director_consent',
        'director_appointment': 'zigpdf_generate_director_appointment',
        'director_resignation': 'zigpdf_generate_director_resignation',
        'written_resolution': 'zigpdf_generate_written_resolution',
      };

      const functionName = functionMap[data.type];
      if (!functionName) {
        throw new Error(`Unknown PDF type: ${data.type}`);
      }

      // Generate PDF
      const pdfBytes = generatePdf(exports, functionName, data.data);

      // Store in Cloud Storage
      const bucket = admin.storage().bucket();
      const fileName = `pdfs/${data.type}/${requestId}.pdf`;
      const file = bucket.file(fileName);

      await file.save(Buffer.from(pdfBytes), {
        metadata: {
          contentType: 'application/pdf',
          metadata: {
            requestId: requestId,
            type: data.type,
          },
        },
      });

      // Get download URL
      const [signedUrl] = await file.getSignedUrl({
        action: 'read',
        expires: Date.now() + 24 * 60 * 60 * 1000, // 24 hours
      });

      // Update the request document with result
      await snap.ref.update({
        status: 'completed',
        pdfUrl: signedUrl,
        storagePath: fileName,
        completedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      console.log(`PDF generated: ${fileName}`);

    } catch (e) {
      console.error('PDF generation error:', e);
      await snap.ref.update({
        status: 'error',
        error: e.message,
        failedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }
  });

// =============================================================================
// Health Check
// =============================================================================

exports.health = functions.https.onRequest(async (req, res) => {
  try {
    const exports = await initWasm();

    const versionPtr = exports.zigpdf_version();
    const versionView = new Uint8Array(exports.memory.buffer, versionPtr, 20);
    const versionEnd = versionView.indexOf(0);
    const version = new TextDecoder().decode(versionView.subarray(0, versionEnd));

    res.json({
      status: 'ok',
      version: version,
      memory_pages: exports.wasm_memory_size(),
      runtime: process.version,
    });
  } catch (e) {
    res.status(500).json({ status: 'error', error: e.message });
  }
});

// =============================================================================
// Helper Functions
// =============================================================================

function formatAddress(addr) {
  if (!addr) return '';
  return [addr.line1, addr.line2, addr.city, addr.state, addr.postal_code, addr.country]
    .filter(Boolean)
    .join(', ');
}

// =============================================================================
// Available PDF Types
// =============================================================================

/*
PDF Generation Functions:
- zigpdf_generate_invoice          - Business invoices
- zigpdf_generate_contract         - Legal contracts
- zigpdf_generate_share_certificate - Company share certificates
- zigpdf_generate_dividend_voucher  - UK/Irish dividend vouchers (with DWT)
- zigpdf_generate_stock_transfer    - Stock transfer forms
- zigpdf_generate_board_resolution  - Board resolutions
- zigpdf_generate_director_consent  - Director consent forms
- zigpdf_generate_director_appointment - Director appointment letters
- zigpdf_generate_director_resignation - Director resignation letters
- zigpdf_generate_written_resolution   - Written shareholder resolutions

Usage with Firestore Trigger:
Create a document in 'pdf_requests' collection:
{
  "type": "invoice",
  "data": { ... invoice data ... }
}

The function will generate the PDF and update the document with:
{
  "status": "completed",
  "pdfUrl": "https://...",
  "storagePath": "pdfs/invoice/..."
}
*/
