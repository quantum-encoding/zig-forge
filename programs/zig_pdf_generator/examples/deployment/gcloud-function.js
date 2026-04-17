/**
 * Google Cloud Functions - PDF Generation via Zig WASM
 *
 * Standalone GCF example (without Firebase). Works with Cloud Run, Cloud Functions,
 * and any Node.js environment on GCP.
 *
 * Setup:
 * 1. Build the WASM module: `zig build wasm`
 * 2. Copy zig-out/lib/zigpdf.wasm to your function directory
 * 3. Deploy with: gcloud functions deploy generatePdf --runtime nodejs18 --trigger-http
 *
 * package.json:
 * ```json
 * {
 *   "engines": { "node": "18" },
 *   "dependencies": {
 *     "@google-cloud/functions-framework": "^3.3.0",
 *     "@google-cloud/storage": "^7.0.0",
 *     "@google-cloud/pubsub": "^4.0.0"
 *   }
 * }
 * ```
 */

const functions = require('@google-cloud/functions-framework');
const { Storage } = require('@google-cloud/storage');
const { PubSub } = require('@google-cloud/pubsub');
const { readFileSync } = require('fs');
const path = require('path');
const crypto = require('crypto');

const storage = new Storage();
const pubsub = new PubSub();

// =============================================================================
// WASM Module Loading
// =============================================================================

let wasmExports = null;

async function initWasm() {
  if (wasmExports) return wasmExports;

  const wasmPath = path.join(__dirname, 'zigpdf.wasm');
  const wasmBuffer = readFileSync(wasmPath);
  const wasmModule = await WebAssembly.compile(wasmBuffer);

  const instance = await WebAssembly.instantiate(wasmModule, {
    wasi_snapshot_preview1: {
      fd_write: () => 0,
      fd_close: () => 0,
      fd_seek: () => 0,
      fd_read: () => 0,
      proc_exit: (code) => { throw new Error(`Exit: ${code}`); },
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
        view.setBigUint64(time_ptr, BigInt(Date.now()) * 1000000n, true);
        return 0;
      },
      random_get: (buf_ptr, buf_len) => {
        const buffer = new Uint8Array(instance.exports.memory.buffer, buf_ptr, buf_len);
        crypto.randomFillSync(buffer);
        return 0;
      },
    },
  });

  wasmExports = instance.exports;
  return wasmExports;
}

function generatePdf(exports, functionName, data) {
  const { memory, wasm_alloc, wasm_free } = exports;
  const generateFn = exports[functionName];

  if (!generateFn) throw new Error(`Unknown function: ${functionName}`);

  const encoder = new TextEncoder();
  const jsonStr = JSON.stringify(data);
  const jsonBytes = encoder.encode(jsonStr);

  const inputPtr = wasm_alloc(jsonBytes.length + 1);
  if (inputPtr === 0) throw new Error('Allocation failed');

  new Uint8Array(memory.buffer, inputPtr, jsonBytes.length + 1).set(jsonBytes);
  new Uint8Array(memory.buffer)[inputPtr + jsonBytes.length] = 0;

  const lenPtr = wasm_alloc(4);
  if (lenPtr === 0) {
    wasm_free(inputPtr, jsonBytes.length + 1);
    throw new Error('Allocation failed');
  }

  const pdfPtr = generateFn(inputPtr, lenPtr);
  wasm_free(inputPtr, jsonBytes.length + 1);

  if (pdfPtr === 0) {
    wasm_free(lenPtr, 4);
    const errorPtr = exports.zigpdf_get_error();
    const errorView = new Uint8Array(memory.buffer, errorPtr, 256);
    throw new Error(new TextDecoder().decode(errorView.subarray(0, errorView.indexOf(0))));
  }

  const pdfLen = new DataView(memory.buffer).getUint32(lenPtr, true);
  wasm_free(lenPtr, 4);

  const pdfBytes = new Uint8Array(memory.buffer, pdfPtr, pdfLen).slice();
  wasm_free(pdfPtr, pdfLen);

  return pdfBytes;
}

// =============================================================================
// HTTP Function - Generate Any PDF
// =============================================================================

/**
 * Main HTTP endpoint for PDF generation
 *
 * POST /generatePdf
 * Body: { "type": "invoice", "data": { ... } }
 *
 * Query params:
 * - store=true: Save to Cloud Storage and return URL
 * - bucket=my-bucket: Custom bucket name
 */
functions.http('generatePdf', async (req, res) => {
  // CORS headers
  res.set('Access-Control-Allow-Origin', '*');
  if (req.method === 'OPTIONS') {
    res.set('Access-Control-Allow-Methods', 'POST');
    res.set('Access-Control-Allow-Headers', 'Content-Type');
    res.status(204).send('');
    return;
  }

  if (req.method !== 'POST') {
    res.status(405).json({ error: 'Method not allowed' });
    return;
  }

  const { type, data } = req.body;

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

  const functionName = functionMap[type];
  if (!functionName) {
    res.status(400).json({ error: `Unknown PDF type: ${type}` });
    return;
  }

  try {
    const exports = await initWasm();
    const pdfBytes = generatePdf(exports, functionName, data);

    // Store in Cloud Storage if requested
    if (req.query.store === 'true') {
      const bucketName = req.query.bucket || process.env.GCS_BUCKET || 'pdf-storage';
      const bucket = storage.bucket(bucketName);
      const fileName = `${type}/${Date.now()}-${crypto.randomBytes(4).toString('hex')}.pdf`;
      const file = bucket.file(fileName);

      await file.save(Buffer.from(pdfBytes), {
        metadata: { contentType: 'application/pdf' },
      });

      const [signedUrl] = await file.getSignedUrl({
        action: 'read',
        expires: Date.now() + 24 * 60 * 60 * 1000,
      });

      res.json({
        success: true,
        type: type,
        size: pdfBytes.length,
        storagePath: `gs://${bucketName}/${fileName}`,
        downloadUrl: signedUrl,
      });
    } else {
      res.set('Content-Type', 'application/pdf');
      res.set('Content-Disposition', `attachment; filename="${type}.pdf"`);
      res.send(Buffer.from(pdfBytes));
    }
  } catch (e) {
    console.error('PDF generation error:', e);
    res.status(500).json({ error: e.message });
  }
});

// =============================================================================
// Pub/Sub Trigger - Async PDF Generation
// =============================================================================

/**
 * Pub/Sub triggered function for async PDF generation
 * Useful for batch processing or queue-based workflows
 *
 * Topic message format:
 * {
 *   "type": "invoice",
 *   "data": { ... },
 *   "callbackUrl": "https://...", // Optional webhook
 *   "outputBucket": "my-bucket",
 *   "outputPath": "invoices/123.pdf"
 * }
 */
functions.cloudEvent('generatePdfAsync', async (cloudEvent) => {
  const message = JSON.parse(Buffer.from(cloudEvent.data.message.data, 'base64').toString());

  const { type, data, callbackUrl, outputBucket, outputPath } = message;

  const functionMap = {
    'invoice': 'zigpdf_generate_invoice',
    'dividend_voucher': 'zigpdf_generate_dividend_voucher',
    'share_certificate': 'zigpdf_generate_share_certificate',
    'contract': 'zigpdf_generate_contract',
  };

  const functionName = functionMap[type];
  if (!functionName) {
    console.error(`Unknown PDF type: ${type}`);
    return;
  }

  try {
    const exports = await initWasm();
    const pdfBytes = generatePdf(exports, functionName, data);

    // Store in Cloud Storage
    const bucketName = outputBucket || process.env.GCS_BUCKET || 'pdf-storage';
    const fileName = outputPath || `${type}/${Date.now()}.pdf`;
    const bucket = storage.bucket(bucketName);
    const file = bucket.file(fileName);

    await file.save(Buffer.from(pdfBytes), {
      metadata: { contentType: 'application/pdf' },
    });

    const [signedUrl] = await file.getSignedUrl({
      action: 'read',
      expires: Date.now() + 7 * 24 * 60 * 60 * 1000,
    });

    console.log(`PDF generated: gs://${bucketName}/${fileName}`);

    // Callback webhook if provided
    if (callbackUrl) {
      await fetch(callbackUrl, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          success: true,
          type: type,
          storagePath: `gs://${bucketName}/${fileName}`,
          downloadUrl: signedUrl,
        }),
      });
    }

    // Publish completion event
    const topic = pubsub.topic('pdf-completed');
    await topic.publishMessage({
      json: {
        type: type,
        storagePath: `gs://${bucketName}/${fileName}`,
        downloadUrl: signedUrl,
      },
    });

  } catch (e) {
    console.error('Async PDF generation error:', e);

    if (callbackUrl) {
      await fetch(callbackUrl, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ success: false, error: e.message }),
      });
    }
  }
});

// =============================================================================
// Cloud Storage Trigger - Process Uploaded JSON
// =============================================================================

/**
 * Triggered when a JSON file is uploaded to the 'pdf-requests' folder
 * Generates PDF and saves it to 'pdf-output' folder
 */
functions.cloudEvent('onJsonUpload', async (cloudEvent) => {
  const file = cloudEvent.data;
  const bucketName = file.bucket;
  const fileName = file.name;

  // Only process JSON files in the pdf-requests folder
  if (!fileName.startsWith('pdf-requests/') || !fileName.endsWith('.json')) {
    return;
  }

  try {
    const bucket = storage.bucket(bucketName);
    const [contents] = await bucket.file(fileName).download();
    const request = JSON.parse(contents.toString());

    const { type, data } = request;
    const functionName = {
      'invoice': 'zigpdf_generate_invoice',
      'dividend_voucher': 'zigpdf_generate_dividend_voucher',
    }[type];

    if (!functionName) {
      console.error(`Unknown type: ${type}`);
      return;
    }

    const exports = await initWasm();
    const pdfBytes = generatePdf(exports, functionName, data);

    // Save PDF
    const outputPath = fileName.replace('pdf-requests/', 'pdf-output/').replace('.json', '.pdf');
    await bucket.file(outputPath).save(Buffer.from(pdfBytes), {
      metadata: { contentType: 'application/pdf' },
    });

    console.log(`Converted ${fileName} -> ${outputPath}`);

  } catch (e) {
    console.error('Storage trigger error:', e);
  }
});

// =============================================================================
// Health Check
// =============================================================================

functions.http('health', async (req, res) => {
  try {
    const exports = await initWasm();
    const versionPtr = exports.zigpdf_version();
    const versionView = new Uint8Array(exports.memory.buffer, versionPtr, 20);
    const version = new TextDecoder().decode(versionView.subarray(0, versionView.indexOf(0)));

    res.json({
      status: 'ok',
      version: version,
      memory_pages: exports.wasm_memory_size(),
      runtime: process.version,
      platform: 'Google Cloud Functions',
    });
  } catch (e) {
    res.status(500).json({ status: 'error', error: e.message });
  }
});

// =============================================================================
// Local Development / Express Server
// =============================================================================

if (process.env.LOCAL_DEV) {
  const express = require('express');
  const app = express();
  app.use(express.json());

  app.post('/generatePdf', async (req, res) => {
    req.query = req.query || {};
    await exports.generatePdf(req, res);
  });

  app.get('/health', async (req, res) => {
    await exports.health(req, res);
  });

  const port = process.env.PORT || 8080;
  app.listen(port, () => {
    console.log(`PDF Generator running on http://localhost:${port}`);
  });
}
